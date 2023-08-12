#!/bin/bash

set -e
set -x

# disable blanking so we can look for problems on the VM console
setterm -blank 0 -powersave off

# This will have been written out by the typed boot command
#export CONFIG_SERVER_URI=`cat /root/config_server_uri`

# Pipe some commands into fdisk to partition
# Works better than sfdisk as the size of the final partition is flexible
echo "Partitioning SDA"

fdisk /dev/sda <<EOT
n
p
1

+256M
n
p
2

+4G
n
p
3


t
2
82
w
EOT

# Create some filesystems and enable swap (which we'll want for the build, particularly when hv_balloon misbehaves)
echo "Creating filesystems"

mkfs.ext4 /dev/sda1
mkswap /dev/sda2
mkfs.ext4 /dev/sda3

swapon /dev/sda2

# Pull the latest stage3 and unpack into the new filesystem
echo "Unpacking stage 3"

mount /dev/sda3 /mnt/gentoo

mkdir -p /mnt/gentoo/boot
mount /dev/sda1 /mnt/gentoo/boot

FOO="$(curl -SsLl https://mirror.netcologne.de/gentoo/releases/amd64/autobuilds/current-stage3-amd64-systemd/ | grep 'href="stage3-amd64-systemd' | head -n 1 | cut -d '"' -f 2)"
curl -SsLl "https://mirror.netcologne.de/gentoo/releases/amd64/autobuilds/current-stage3-amd64-systemd/`echo $FOO`" | tar xpJ -C /mnt/gentoo --xattrs --numeric-owner && break


# modify the chroot with some custom settings
echo "Setting up chroot configuration"

# configure portage
cat >> /mnt/gentoo/etc/portage/make.conf <<EOT
EMERGE_DEFAULT_OPTS="--quiet-build --jobs=4 --autounmask-continue --verbose --deep --newuse  --autounmask-write=y --autounmask=y --color=y --columns --nospinner --rebuild-if-new-rev=y --update"
USE="-doc -X -gnome -kde symlink"
EOT

# use systemd
sed -i 's/USE="/USE="systemd /' /mnt/gentoo/etc/portage/make.conf
sed -i 's/CFLAGS="-O2/CFLAGS="-march=znver2 -pipe/' /mnt/gentoo/etc/portage/make.conf
#echo 'LDFLAGS="-s"' >> /mnt/gentoo/etc/portage/make.conf

# package-specific configuration and unmasks
mkdir -p /mnt/gentoo/etc/portage/package.accept_keywords
mkdir -p /mnt/gentoo/etc/portage/package.use
#touch /mnt/gentoo/etc/portage/package.accept_keywords/zzz-autounmask
#touch /mnt/gentoo/etc/portage/package.use/zzz-autounmask

#echo "sys-kernel/gentoo-sources" > /mnt/gentoo/etc/portage/package.accept_keywords/kernel
#echo "sys-kernel/open-vm-tools" > /mnt/gentoo/etc/portage/package.accept_keywords/open-vm-tools

#echo "sys-kernel/gentoo-sources symlink" > /mnt/gentoo/etc/portage/package.use/kernel
echo "sys-boot/grub efiemu -fonts -nls -themes" > /mnt/gentoo/etc/portage/package.use/grub
echo "sys-apps/systemd nat" > /mnt/gentoo/etc/portage/package.use/systemd

# Locale and time
echo "Europe/Berlin" > /mnt/gentoo/etc/timezone
cat > /mnt/gentoo/etc/locale.gen <<EOT
en_US ISO-8859-1
en_US.UTF-8 UTF-8
de_DE ISO-8859-1
de_DE.UTF-8 UTF-8
EOT

# Create an fstab
cat > /mnt/gentoo/etc/fstab <<EOT
/dev/sda1 /boot ext4 noauto,noatime    1 2
/dev/sda2 none  swap sw                0 0
/dev/sda3 /     ext4 noauto,noatime    0 1
EOT


# enter the chroot and run the in-chroot script
echo "Entering chroot"

mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

cp /etc/resolv.conf /mnt/gentoo/etc/resolv.conf

wget https://raw.githubusercontent.com/kn0rki/packer-gentoo/master/scripts/provision_gentoo_chroot.sh -O /mnt/gentoo/root/provision_gentoo_chroot.sh
chmod +x /mnt/gentoo/root/provision_gentoo_chroot.sh

chroot /mnt/gentoo /root/provision_gentoo_chroot.sh

# and get ready to reboot
echo "Chroot finished, ready to restart"

umount -l /mnt/gentoo/{proc,sys,dev,boot,}

# hail mary!
reboot
