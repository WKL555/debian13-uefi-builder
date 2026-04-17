#!/bin/bash
# ==========================================================
# 脚本名称: build.sh
# 功能: 极简 Debian 13 (Btrfs + UEFI + qcow2压缩)
# ==========================================================
set -e

RAW_IMAGE="debian13-temp.raw"
QCOW2_IMAGE="debian13-minimal.qcow2"
MOUNT_DIR="/mnt/deb13"
DEBIAN_VERSION="trixie"

echo "==== 1. 环境准备 ===="
# 必须安装 qemu-utils 才能使用 qemu-img
apt-get update
apt-get install -y debootstrap parted dosfstools btrfs-progs qemu-utils

echo "==== 2. 创建临时 1GB 镜像 ===="
truncate -s 1G $RAW_IMAGE
parted -s $RAW_IMAGE mktable gpt
parted -s $RAW_IMAGE mkpart ESP fat32 1MiB 51MiB
parted -s $RAW_IMAGE set 1 esp on
parted -s $RAW_IMAGE mkpart primary btrfs 51MiB 100%

echo "==== 3. 格式化与挂载 ===="
LOOP_DEV=$(losetup -fP --show $RAW_IMAGE)
mkfs.fat -F32 ${LOOP_DEV}p1
mkfs.btrfs -L "root" ${LOOP_DEV}p2
mkdir -p $MOUNT_DIR
mount -o compress=zstd:3,discard=async ${LOOP_DEV}p2 $MOUNT_DIR
mkdir -p $MOUNT_DIR/boot/efi
mount ${LOOP_DEV}p1 $MOUNT_DIR/boot/efi

echo "==== 4. 最小化注入系统 ===="
debootstrap --arch=amd64 --variant=minbase $DEBIAN_VERSION $MOUNT_DIR http://deb.debian.org/debian

echo "==== 5. 极致精简配置 ===="
ROOT_UUID=$(blkid -s UUID -o value ${LOOP_DEV}p2)
EFI_UUID=$(blkid -s UUID -o value ${LOOP_DEV}p1)
cat <<FSTAB > $MOUNT_DIR/etc/fstab
UUID=$ROOT_UUID / btrfs defaults,compress=zstd:3,noatime 0 0
UUID=$EFI_UUID /boot/efi vfat defaults 0 2
FSTAB

mount --bind /dev $MOUNT_DIR/dev
mount --bind /proc $MOUNT_DIR/proc
mount --bind /sys $MOUNT_DIR/sys
mount --bind /run $MOUNT_DIR/run

cat << 'EOF' | chroot $MOUNT_DIR /bin/bash
export DEBIAN_FRONTEND=noninteractive

# 禁用推荐包安装
cat <<CONF > /etc/apt/apt.conf.d/01norecommend
Install-Recommends "0";
Install-Suggests "0";
CONF

apt-get update
apt-get install -y linux-image-cloud-amd64 grub-efi-amd64 btrfs-progs systemd-sysv openssh-server ca-certificates curl

# 网络配置
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-networkd
systemctl enable systemd-resolved
mkdir -p /etc/systemd/network
cat <<NET > /etc/systemd/network/20-wired.network
[Match]
Name=e*
[Network]
DHCP=yes
NET

# 系统设置
echo "deb13-qcow2" > /etc/hostname
echo "root:password" | chpasswd
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl enable ssh

# 引导
grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-floppy
update-grub

# 清理
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/locale/*
find /var/log -type f -delete
apt-get autoremove -y
apt-get clean
EOF

echo "==== 6. 卸载分区 ===="
sync
btrfs filesystem defragment -r -czstd $MOUNT_DIR || true
umount $MOUNT_DIR/run $MOUNT_DIR/sys $MOUNT_DIR/proc $MOUNT_DIR/dev $MOUNT_DIR/boot/efi $MOUNT_DIR
losetup -d $LOOP_DEV

echo "==== 7. 转换为 QCOW2 并极限压缩 ===="
# -c 参数代表开启 qcow2 内部压缩
qemu-img convert -f raw -O qcow2 -c "$RAW_IMAGE" "$QCOW2_IMAGE"
rm -f "$RAW_IMAGE" # 删除原文件

echo "构建完成: $QCOW2_IMAGE"
