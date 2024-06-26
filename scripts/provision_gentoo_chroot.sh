#!/bin/bash

set -e
set -x

# Grab the latest portage
echo "Syncing Portage"
emerge-webrsync && emerge --sync --quiet

# Set the portage profile
eselect profile set default/linux/amd64/23.0/systemd
. /etc/profile

emerge net-misc/axel

cat >> /etc/portage/make.conf <<EOT
FETCHCOMMAND="axel --num-connections=4 --no-proxy --quiet --timeout=2 --no-clobber --output=\"\${DISTDIR}/\${FILE}\" \"\${URI}\""
RESUMECOMMAND="axel --num-connections=4 --no-proxy --quiet --timeout=2 --no-clobber --output=\"\${DISTDIR}/\${FILE}\" \"\${URI}\""
EOT

# Install updates
echo "Updating system"
emerge -uDN @world

# Set the system locale
echo "Setting locale"
locale-gen
eselect locale set "de_DE.utf8"

. /etc/profile

# Grab the kernel sources
echo "Installing kernel source"
emerge sys-kernel/gentoo-sources

# Install kernel build tools and configure
echo "Preparing to build kernel"

echo "sys-kernel/genkernel -firmware" > /etc/portage/package.use/genkernel
emerge sys-kernel/genkernel sys-boot/grub sys-fs/fuse sys-apps/dmidecode sys-fs/btrfs-progs

if [ "$(dmidecode -s system-manufacturer)" == "Microsoft Corporation" ]; then
  # Ensure hyperv modules are loaded at boot, and included in the initramfs
  echo 'MODULES_HYPERV="hv_vmbus hv_storvsc hv_balloon hv_netvsc hv_utils"' >> /usr/share/genkernel/arch/x86_64/modules_load
  echo 'modules="hv_storvsc hv_netvsc hv_vmbus hv_utils hv_balloon"' >> /etc/conf.d/modules
  sed -ri "s/(HWOPTS='.*)'/\1 hyperv'/" /usr/share/genkernel/defaults/initrd.defaults
fi

# Build the kernel with genkernel
echo "Building the kernel"

time genkernel --kernel-config=/proc/config.gz --makeopts=-j$(nproc) all

# Build & install the VM tools

# If we're running on hyper-v, enable the tools
if [ "$(dmidecode -s system-manufacturer)" == "Microsoft Corporation" ]; then
  # kernel modules are already built in the kernel
  cd /usr/src/linux/tools/hv
  make
  cp hv_fcopy_daemon hv_vss_daemon hv_kvp_daemon /usr/sbin
  systemctl enable hv_fcopy_daemon.service
  systemctl enable hv_vss_daemon.service
  systemctl enable hv_kvp_daemon.service
elif [ "$(dmidecode -s system-product-name)" == "VirtualBox" ]; then
  # Install VirtualBox from portage
  echo "app-emulation/virtualbox-guest-additions ~amd64" > /etc/portage/package.accept_keywords/virtualbox
  emerge app-emulation/virtualbox-guest-additions
  systemctl enable virtualbox-guest-additions.service
elif [[ "$(dmidecode -s system-product-name)" =~ .*VMware.* ]]; then
  echo "app-emulation/open-vm-tools ~amd64" > /etc/portage/package.accept_keywords/vmware
  emerge app-emulation/open-vm-tools
  systemctl enable vmtoolsd
else
  echo "Unknown hypervisor! :(" 1>&2
fi

# Set up the things we need for a base system
echo "Configuring up the base system"

# sudo and cron
echo "app-admin/sudo -sendmail" > /etc/portage/package.use/sudo
emerge sys-process/cronie app-admin/sudo

# systemd setup and hostname
systemd-machine-id-setup  --print
systemd-machine-id-setup  --commit # remember to remove this before packaging the box
echo "gentoo-minimal" > /etc/hostname
echo "127.0.1.1 gentoo-minimal.local gentoo-minimal" >> /etc/hosts

# networking
cat > /etc/systemd/network/50-dhcp.network <<EOT
[Match]
Name=en*

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
EOT

systemctl enable systemd-networkd.service

# ssh
systemctl enable sshd.service
echo "UseDNS no" >> /etc/ssh/sshd_config

yes YES | etc-update --automode -9

# Create the ansible user with the ansible public key
echo "Creating ansible user"

date > /etc/ansible_box_build_time

useradd -s /bin/bash -m ansible
#echo -e "!" | passwd ansible

mkdir -pm 700 /home/ansible/.ssh
wget -O /home/ansible/.ssh/authorized_keys 'https://github.com/kn0rki.keys'
chmod 0600 /home/ansible/.ssh/authorized_keys
chown -R ansible:ansible /home/ansible/.ssh
mkdir /etc/sudoers.d
echo 'ansible ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/ansible

# Install grub and hope everything is ready!
echo "Installing bootloader"

grub-install --target=x86_64-efi --efi-directory=/boot
grub-mkconfig -o /boot/grub/grub.cfg

echo "Installing additional tools"
emerge gentoolkit sys-fs/dosfstools

echo "Updating resolv.conf"

rm /etc/resolv.conf
ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl enable systemd-resolved.service

echo "Removing provision script"
rm /root/provision_gentoo_chroot.sh
