#!/bin/bash
# ==========================================================
# 脚本名称: build.sh
# 功能: 构建 Debian 13 (Trixie) 最小化镜像 (Btrfs + UEFI + zstd)
# 适配: 1GB 磁盘空间, x86_64 架构
# ==========================================================

# 遇到错误立即停止
set -e

IMAGE_NAME="debian13-uefi-btrfs-1g.raw"
MOUNT_DIR="/mnt/deb13"
DEBIAN_VERSION="trixie"

echo "==== 1. 安装构建基础依赖 ===="
apt-get update
apt-get install -y debootstrap parted dosfstools mtools btrfs-progs

echo "==== 2. 创建 1GB 镜像文件并配置 GPT 分区 ===="
# 创建一个 1024MB 的稀疏文件
dd if=/dev/zero of=$IMAGE_NAME bs=1M count=1024
parted -s $IMAGE_NAME mktable gpt
# EFI 分区: 50MB (FAT32)
parted -s $IMAGE_NAME mkpart ESP fat32 1MiB 51MiB
parted -s $IMAGE_NAME set 1 esp on
# Root 分区: 剩余全部 (Btrfs)
parted -s $IMAGE_NAME mkpart primary btrfs 51MiB 100%

echo "==== 3. 挂载 Loop 设备 ===="
LOOP_DEV=$(losetup -fP --show $IMAGE_NAME)
echo "设备已挂载至: $LOOP_DEV"

echo "==== 4. 格式化分区 ===="
# 格式化 EFI 分区
mkfs.fat -F32 ${LOOP_DEV}p1
# 格式化 Btrfs 分区
mkfs.btrfs -L "cloud_root" ${LOOP_DEV}p2

echo "==== 5. 挂载分区并开启 zstd:3 压缩 ===="
mkdir -p $MOUNT_DIR
# 关键：挂载时开启 compress=zstd:3
mount -o compress=zstd:3 ${LOOP_DEV}p2 $MOUNT_DIR
mkdir -p $MOUNT_DIR/boot/efi
mount ${LOOP_DEV}p1 $MOUNT_DIR/boot/efi

echo "==== 6. 注入 Debian 13 基础系统 (minbase 模式) ===="
# 使用 minbase 减小初始体积
debootstrap --arch=amd64 --variant=minbase $DEBIAN_VERSION $MOUNT_DIR http://deb.debian.org/debian

echo "==== 7. 预配置 fstab (运行时自动压缩) ===="
ROOT_UUID=$(blkid -s UUID -o value ${LOOP_DEV}p2)
EFI_UUID=$(blkid -s UUID -o value ${LOOP_DEV}p1)
cat <<FSTAB > $MOUNT_DIR/etc/fstab
UUID=$ROOT_UUID / btrfs defaults,compress=zstd:3 0 0
UUID=$EFI_UUID /boot/efi vfat defaults 0 2
FSTAB

echo "==== 8. 进入 Chroot 环境安装核心组件 ===="
# 挂载虚拟文件系统
mount --bind /dev $MOUNT_DIR/dev
mount --bind /proc $MOUNT_DIR/proc
mount --bind /sys $MOUNT_DIR/sys
mount --bind /run $MOUNT_DIR/run

cat << 'EOF' | chroot $MOUNT_DIR /bin/bash
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1. 更新源
echo "deb http://deb.debian.org/debian trixie main" > /etc/apt/sources.list
echo "deb http://deb.debian.org/debian trixie-updates main" >> /etc/apt/sources.list
apt-get update

# 2. 安装必须包 (btrfs-progs 是识别文件系统的核心)
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    grub-efi-amd64 \
    btrfs-progs \
    systemd-sysv \
    openssh-server \
    ifupdown \
    isc-dhcp-client \
    ca-certificates \
    curl \
    iproute2

# 3. 设置主机名
echo "deb13-btrfs" > /etc/hostname

# 4. 设置 Root 密码
echo "root:password" | chpasswd

# 5. 允许 SSH Root 登录
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# 6. 配置网络 (适配常见网卡名)
cat <<NET > /etc/network/interfaces
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp

allow-hotplug ens3
iface ens3 inet dhcp
NET

# 7. 安装 GRUB 到 EFI 分区
# 注意：Btrfs 压缩不影响现代 GRUB 读取内核
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy
update-grub

# 8. 清理空间
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

echo "==== 9. 解除挂载并收尾 ===="
umount $MOUNT_DIR/run
umount $MOUNT_DIR/sys
umount $MOUNT_DIR/proc
umount $MOUNT_DIR/dev
umount $MOUNT_DIR/boot/efi
umount $MOUNT_DIR
losetup -d $LOOP_DEV

echo "==== 10. 最终压缩打包 ===="
# 这一步是为了方便网络传输
gzip -9 $IMAGE_NAME
echo "构建成功: ${IMAGE_NAME}.gz"
