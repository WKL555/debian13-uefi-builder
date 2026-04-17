#!/bin/bash
# ==========================================================
# 脚本名称: build.sh
# 功能: Debian 13 (Btrfs + UEFI + systemd-networkd)
# ==========================================================

set -e

IMAGE_NAME="debian13-uefi-networkd.raw"
MOUNT_DIR="/mnt/deb13"
DEBIAN_VERSION="trixie"

echo "==== 1. 基础准备 ===="
apt-get update
apt-get install -y debootstrap parted dosfstools btrfs-progs

echo "==== 2. 创建镜像与分区 ===="
dd if=/dev/zero of=$IMAGE_NAME bs=1M count=1024
parted -s $IMAGE_NAME mktable gpt
parted -s $IMAGE_NAME mkpart ESP fat32 1MiB 51MiB
parted -s $IMAGE_NAME set 1 esp on
parted -s $IMAGE_NAME mkpart primary btrfs 51MiB 100%

echo "==== 3. 格式化与挂载 (zstd压缩) ===="
LOOP_DEV=$(losetup -fP --show $IMAGE_NAME)
mkfs.fat -F32 ${LOOP_DEV}p1
mkfs.btrfs -L "root" ${LOOP_DEV}p2
mkdir -p $MOUNT_DIR
mount -o compress=zstd:3 ${LOOP_DEV}p2 $MOUNT_DIR
mkdir -p $MOUNT_DIR/boot/efi
mount ${LOOP_DEV}p1 $MOUNT_DIR/boot/efi

echo "==== 4. 注入系统 ===="
debootstrap --arch=amd64 --variant=minbase $DEBIAN_VERSION $MOUNT_DIR http://deb.debian.org/debian

echo "==== 5. 配置 Chroot 环境 ===="
mount --bind /dev $MOUNT_DIR/dev
mount --bind /proc $MOUNT_DIR/proc
mount --bind /sys $MOUNT_DIR/sys
mount --bind /run $MOUNT_DIR/run

cat << 'EOF' | chroot $MOUNT_DIR /bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update

# 安装内核及必要工具 (剔除 ifupdown)
apt-get install -y --no-install-recommends \
    linux-image-amd64 grub-efi-amd64 btrfs-progs systemd-sysv \
    openssh-server ca-certificates curl

# ---- Networkd 配置开始 ----

# 1. 配置所有网卡自动通过 DHCP 获取地址 (适配通配符)
cat <<NET > /etc/systemd/network/20-wire.network
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6PrivacyExtensions=yes
NET

# 2. 设置 Resolved (DNS) 符号链接
# 这是 systemd-resolved 工作的标准方式
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 3. 启用服务
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable ssh

# ---- Networkd 配置结束 ----

# 基础系统配置
echo "deb13-networkd" > /etc/hostname
echo "root:password" | chpasswd
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# 安装引导
grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-floppy
update-grub

apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

echo "==== 6. 卸载与收尾 ===="
# 写入 fstab
ROOT_UUID=$(blkid -s UUID -o value ${LOOP_DEV}p2)
EFI_UUID=$(blkid -s UUID -o value ${LOOP_DEV}p1)
echo "UUID=$ROOT_UUID / btrfs defaults,compress=zstd:3 0 0" > $MOUNT_DIR/etc/fstab
echo "UUID=$EFI_UUID /boot/efi vfat defaults 0 2" >> $MOUNT_DIR/etc/fstab

umount $MOUNT_DIR/run $MOUNT_DIR/sys $MOUNT_DIR/proc $MOUNT_DIR/dev $MOUNT_DIR/boot/efi $MOUNT_DIR
losetup -d $LOOP_DEV

gzip -9 $IMAGE_NAME
echo "构建完成！"
