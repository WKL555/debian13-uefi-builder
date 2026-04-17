#!/bin/bash
# 遇到错误立即停止
set -e

IMAGE_NAME="debian13-uefi-1g.raw"
MOUNT_DIR="/mnt/deb13"
DEBIAN_VERSION="trixie"

echo "==== 1. 安装构建依赖 ===="
apt-get update
apt-get install -y debootstrap parted dosfstools mtools

echo "==== 2. 创建 1GB 镜像文件并分区 ===="
dd if=/dev/zero of=$IMAGE_NAME bs=1M count=1024
parted -s $IMAGE_NAME mktable gpt
parted -s $IMAGE_NAME mkpart ESP fat32 1MiB 50MiB
parted -s $IMAGE_NAME set 1 esp on
parted -s $IMAGE_NAME mkpart primary ext4 50MiB 100%

echo "==== 3. 挂载虚拟设备 ===="
LOOP_DEV=$(losetup -fP --show $IMAGE_NAME)
echo "已挂载到: $LOOP_DEV"

echo "==== 4. 格式化分区 ===="
mkfs.fat -F32 ${LOOP_DEV}p1
mkfs.ext4 -F ${LOOP_DEV}p2

echo "==== 5. 挂载到本地目录 ===="
mkdir -p $MOUNT_DIR
mount ${LOOP_DEV}p2 $MOUNT_DIR
mkdir -p $MOUNT_DIR/boot/efi
mount ${LOOP_DEV}p1 $MOUNT_DIR/boot/efi

echo "==== 6. 注入 Debian 13 基础系统 (最小化) ===="
debootstrap --arch=amd64 --variant=minbase $DEBIAN_VERSION $MOUNT_DIR http://deb.debian.org/debian

echo "==== 7. 在外部提取 UUID 并生成 fstab ===="
ROOT_UUID=$(blkid -s UUID -o value ${LOOP_DEV}p2)
EFI_UUID=$(blkid -s UUID -o value ${LOOP_DEV}p1)
echo "UUID=$ROOT_UUID / ext4 defaults 0 1" > $MOUNT_DIR/etc/fstab
echo "UUID=$EFI_UUID /boot/efi vfat defaults 0 2" >> $MOUNT_DIR/etc/fstab

echo "==== 8. 挂载系统核心目录进入 Chroot ===="
mount --bind /dev $MOUNT_DIR/dev
mount --bind /proc $MOUNT_DIR/proc
mount --bind /sys $MOUNT_DIR/sys
mount --bind /run $MOUNT_DIR/run

cat << 'EOF' | chroot $MOUNT_DIR /bin/bash
# 环境变量设置
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 主机名
echo "debian13-uefi" > /etc/hostname

# 完善 APT 源
cat <<APT > /etc/apt/sources.list
deb http://deb.debian.org/debian trixie main
deb http://deb.debian.org/debian trixie-updates main
APT

apt-get update

# 安装核心组件 (内核, GRUB, 网络, SSH)
apt-get install -y --no-install-recommends \
    linux-image-amd64 grub-efi-amd64 systemd-sysv \
    openssh-server ifupdown isc-dhcp-client net-tools ca-certificates curl vim

# 安装并配置 GRUB 引导 (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy
update-grub

# 开启 SSH Root 登录密码验证
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
# 设置 root 密码为 password (你可以自行修改)
echo "root:password" | chpasswd

# 配置网络 (DHCP 自动获取 IP)
cat <<NET > /etc/network/interfaces
auto lo
iface lo inet loopback

allow-hotplug eth0
allow-hotplug ens3
allow-hotplug enp3s0
iface eth0 inet dhcp
iface ens3 inet dhcp
iface enp3s0 inet dhcp
NET

# 清理垃圾减小体积
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

echo "==== 9. 卸载并清理环境 ===="
umount $MOUNT_DIR/run
umount $MOUNT_DIR/sys
umount $MOUNT_DIR/proc
umount $MOUNT_DIR/dev
umount $MOUNT_DIR/boot/efi
umount $MOUNT_DIR
losetup -d $LOOP_DEV

echo "==== 10. 高压缩比打包 ===="
# 使用 gzip 极限压缩
gzip -9 $IMAGE_NAME
echo "构建完成: ${IMAGE_NAME}.gz"
