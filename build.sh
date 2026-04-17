#!/bin/bash
set -e

IMAGE_NAME="debian13-minimal.raw"
MOUNT_DIR="/mnt/deb13"
DEBIAN_VERSION="trixie"

echo "==== 1. 环境准备 ===="
apt-get update
apt-get install -y debootstrap parted dosfstools btrfs-progs

echo "==== 2. 创建 1GB 镜像 ===="
# 创建稀疏文件，不占实际空间
truncate -s 1G $IMAGE_NAME
parted -s $IMAGE_NAME mktable gpt
parted -s $IMAGE_NAME mkpart ESP fat32 1MiB 51MiB
parted -s $IMAGE_NAME set 1 esp on
parted -s $IMAGE_NAME mkpart primary btrfs 51MiB 100%

echo "==== 3. 格式化与挂载 ===="
LOOP_DEV=$(losetup -fP --show $IMAGE_NAME)
mkfs.fat -F32 ${LOOP_DEV}p1
mkfs.btrfs -L "root" ${LOOP_DEV}p2
mkdir -p $MOUNT_DIR
mount -o compress=zstd:3,discard=async ${LOOP_DEV}p2 $MOUNT_DIR
mkdir -p $MOUNT_DIR/boot/efi
mount ${LOOP_DEV}p1 $MOUNT_DIR/boot/efi

echo "==== 4. 最小化注入 (variant=minbase) ===="
# 仅安装最核心包
debootstrap --arch=amd64 --variant=minbase $DEBIAN_VERSION $MOUNT_DIR http://deb.debian.org/debian

echo "==== 5. 极致精简配置 (Chroot) ===="
# 提前写入 UUID
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

# 1. 强制禁止安装“推荐”和“建议”包 (大幅缩减体积)
cat <<CONF > /etc/apt/apt.conf.d/01norecommend
Install-Recommends "0";
Install-Suggests "0";
CONF

apt-get update

# 2. 安装精简版内核 (专门为云环境优化，剔除物理驱动)
# 加上 btrfs-progs, grub-efi, systemd, openssh-server, curl
apt-get install -y linux-image-cloud-amd64 grub-efi-amd64 btrfs-progs systemd-sysv openssh-server ca-certificates curl

# 3. 网络配置 (systemd-networkd)
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

# 4. 系统设置
echo "deb13-min" > /etc/hostname
echo "root:password" | chpasswd
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl enable ssh

# 5. 引导安装
grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-floppy
update-grub

# 6. 【极致清理】
# 删除文档、手册、语言包、APT 缓存
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
rm -rf /usr/share/locale/*
find /var/log -type f -delete
apt-get autoremove -y
apt-get clean
EOF

echo "==== 6. 卸载与压缩 ===="
sync
# 关键：在卸载前对 btrfs 进行碎片整理压缩
btrfs filesystem defragment -r -czstd $MOUNT_DIR || true

umount $MOUNT_DIR/run $MOUNT_DIR/sys $MOUNT_DIR/proc $MOUNT_DIR/dev $MOUNT_DIR/boot/efi $MOUNT_DIR
losetup -d $LOOP_DEV

# 使用最高等级压缩
gzip -9 "$IMAGE_NAME"
echo "极简镜像构建完成！"
