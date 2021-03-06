#!/usr/bin/env bash
# stop on errors
set -eu

HOST_NAME="blackarch-box"

################################################################################
# return codes
SUCCESS=0
FAILURE=1

CHROOT="/mnt"

# path to blackarch-installer
BI_PATH="/usr/share/blackarch-installer"

LANGUAGE='en_US.UTF-8'
KEYMAP='us'
TIMEZONE='UTC'
CONFIG_SCRIPT='/usr/local/bin/arch-config.sh'

echo "[+] Check environment for run deploying"
# check needed variables for running script
if [ -z ${PACKER_BUILDER_TYPE+x} ]; then  echo "\$PACKER_BUILDER_TYPE variable is unset"; exit $FAILURE;  fi

# check environment for run script
if [ `id -u` -ne 0 ]
then
    echo "You must be root to run the BlackArch packer installer!"; exit $FAILURE;
fi

if [ -f "/var/lib/pacman/db.lck" ]
then
    echo "pacman locked - Please remove /var/lib/pacman/db.lck"; exit $FAILURE;
fi

if ! curl -s "http://www.google.com/" > /dev/null
then
    echo "No Internet connection! Check your network (settings)."; exit $FAILURE;
fi

VAGRANT_PASSWORD=$(/usr/bin/openssl passwd -quiet  -crypt 'vagrant')
ROOT_PASSWORD=$(/usr/bin/openssl passwd -quiet  -crypt 'blackarch')
if [[ $PACKER_BUILDER_TYPE == "qemu" ]]; then
	DISK='/dev/vda'
else
	DISK='/dev/sda'
fi
ROOT_PART="${DISK}1"


enable_multilib()
{
# enable multilib in pacman.conf if x86_64 present
if [ "`uname -m`" = "x86_64" ]
then
    echo "[+] Enabling multilib support"
    if grep -q "#\[multilib\]" /etc/pacman.conf
    then
        # it exists but commented
        sed -i '/\[multilib\]/{ s/^#//; n; s/^#//; }' /etc/pacman.conf
    elif ! grep -q "\[multilib\]" /etc/pacman.conf
    then
        # it does not exist at all
        printf "[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" \
            >> /etc/pacman.conf
    fi
fi
}

prepare_env()
{
    localectl set-keymap --no-convert us  # set keymap to use
    # enable color mode in pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    enable_multilib
    # update pacman package database
    echo "[+] Updating pacman database"
    pacman -Syy --noconfirm > /dev/null
    pacman -S --noconfirm gptfdisk > /dev/null
    return $SUCCESS

}


prepare_disk()
{
    # make and format partitions
    echo "[+] Clearing partition table on ${DISK}"
    /usr/bin/sgdisk --zap ${DISK}
    echo "[+] Destroying magic strings and signatures on ${DISK}"
    /usr/bin/dd if=/dev/zero of=${DISK} bs=512 count=2048
    /usr/bin/wipefs --all ${DISK}
    echo "[+] Creating /root partition on ${DISK}"
    /usr/bin/sgdisk --new=1:0:0 ${DISK}
    echo "[+] Setting ${DISK} bootable"
    /usr/bin/sgdisk ${DISK} --attributes=1:set:2
    echo '[+] Creating /root filesystem (ext4)'
    /usr/bin/mkfs.ext4 -O ^64bit -F -m 0 -q -L root ${ROOT_PART}
}

mount_filesystem()
{
    echo "[+] Mounting ${ROOT_PART} to ${CHROOT}"
    /usr/bin/mount -o noatime,errors=remount-ro ${ROOT_PART} ${CHROOT}
}

umount_filesystem()
{
    echo "[+] Unmounting filesystems"
    umount -Rf ${CHROOT} > /dev/null 2>&1
}

install_base()
{
    echo "[+] Installing ArchLinux base packages"
    # install ArchLinux base and base-devel packages
    /usr/bin/pacstrap ${CHROOT} base > /dev/null

    # add blackach repo for prevent input wait in strap shell
    echo '[blackarch]' >> "${CHROOT}/etc/pacman.conf"
    echo 'Server = https://www.mirrorservice.org/sites/blackarch.org/blackarch/$repo/os/$arch' >> "${CHROOT}/etc/pacman.conf"

    /usr/bin/arch-chroot ${CHROOT} pacman -Syy --force > /dev/null
    /usr/bin/arch-chroot ${CHROOT} pacman -S --noconfirm  base-devel > /dev/null
    echo "[+] Updating /etc files"
    cp -r ${BI_PATH}/data/etc/. ${CHROOT}/etc/.
    /usr/bin/arch-chroot ${CHROOT} pacman -S --noconfirm gptfdisk openssh syslinux > /dev/null
    /usr/bin/arch-chroot ${CHROOT} syslinux-install_update -i -a -m
    /usr/bin/sed -i "s|sda3|${ROOT_PART##/dev/}|" "${CHROOT}/boot/syslinux/syslinux.cfg"
    /usr/bin/sed -i 's/TIMEOUT 50/TIMEOUT 10/' "${CHROOT}/boot/syslinux/syslinux.cfg"
    cp ${BI_PATH}/data/boot/grub/splash.png ${CHROOT}/boot/grub/splash.png | true
    echo '[+] Generating the filesystem table'
    /usr/bin/genfstab -p ${CHROOT} >> "${CHROOT}/etc/fstab"
    # sync disk
    sync
}


configure_system(){
echo '[+] Generating the system configuration script'
/usr/bin/install --mode=0755 /dev/null "${CHROOT}${CONFIG_SCRIPT}"
cp /etc/udev/rules.d/81-dhcpcd.rules "${CHROOT}/etc/udev/rules.d/81-dhcpcd.rules"

cat <<-EOF > "${CHROOT}${CONFIG_SCRIPT}"
    #!/bin/sh
    # stop on errors
    set -eu
	echo '${HOST_NAME}' > /etc/hostname
	/usr/bin/ln -f -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
	echo 'KEYMAP=${KEYMAP}' > /etc/vconsole.conf
	/usr/bin/sed -i 's/#${LANGUAGE}/${LANGUAGE}/' /etc/locale.gen
	/usr/bin/locale-gen
	/usr/bin/mkinitcpio -p linux
	/usr/bin/usermod --password ${ROOT_PASSWORD} root
	/usr/bin/sed -i 's/#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
	/usr/bin/systemctl enable sshd.service

	# Vagrant-specific configuration
	echo "[+] Enable vagrant support"
	/usr/bin/useradd --password ${VAGRANT_PASSWORD} --comment 'Vagrant User' --create-home --user-group vagrant
	echo 'Defaults env_keep += "SSH_AUTH_SOCK"' > /etc/sudoers.d/10_vagrant
	echo 'vagrant ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/10_vagrant
	/usr/bin/chmod 0440 /etc/sudoers.d/10_vagrant
	/usr/bin/install --directory --owner=vagrant --group=vagrant --mode=0700 /home/vagrant/.ssh
	/usr/bin/curl --output /home/vagrant/.ssh/authorized_keys --location https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub
	/usr/bin/chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
	/usr/bin/chmod 0600 /home/vagrant/.ssh/authorized_keys

	# clean up
	echo "[+] remove gptfdisk"
	/usr/bin/pacman -Rcns --noconfirm gptfdisk > /dev/null
EOF


echo '[+] Entering chroot and configuring system'
/usr/bin/arch-chroot ${CHROOT} /bin/bash ${CONFIG_SCRIPT}
rm "${CHROOT}${CONFIG_SCRIPT}"

# http://comments.gmane.org/gmane.linux.arch.general/48739
echo '[+] Adding workaround for shutdown race condition'
/usr/bin/install --mode=0644 /root/poweroff.timer "${CHROOT}/etc/systemd/system/poweroff.timer"
}

main()
{
    prepare_env
    prepare_disk
    mount_filesystem
    install_base
    configure_system
    umount_filesystem
    /usr/bin/systemctl reboot
}

main
