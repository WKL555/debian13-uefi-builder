#!/bin/bash
# 自动将 MBR/Legacy 的 Debian qcow2 镜像转换为 UEFI 支持版本
set -e

URL="https://github.com/ninjayo/debian13-minimal-for1gdisk/releases/download/v1.0/debian-final.qcow2"
IMG="debian-final.qcow2"
UEFI_IMG="debian-uefi.qcow2"
MNT="/mnt/debian_chroot"

# 1. 权限与依赖检查
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (例如: sudo ./make-uefi.sh)"
  exit 1
fi

for cmd in qemu-nbd sgdisk mkfs.fat chroot wget partprobe; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ 错误: 未找到命令 '$cmd'。请先安装 qemu-utils, gdisk, dosfstools, parted。"
        exit 1
    fi
done

NBD_DEV=""

# 设置清理钩子，确保遇到错误或结束时能正确卸载并清理进程
cleanup() {
    echo "=> 🧹 执行清理工作..."
    mountpoint -q "$MNT/sys" && umount "$MNT/sys"
    mountpoint -q "$MNT/proc" && umount "$MNT/proc"
    mountpoint -q "$MNT/dev/pts" && umount "$MNT/dev/pts"
    mountpoint -q "$MNT/dev" && umount "$MNT/dev"
    mountpoint -q "$MNT/boot/efi" && umount "$MNT/boot/efi"
    mountpoint -q "$MNT" && umount "$MNT"

    if [ -n "$NBD_DEV" ]; then
        qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
    fi
    rm -rf "$MNT"
}
trap cleanup EXIT INT TERM

# 2. 下载与扩容
echo "=> 📦 1. 检查并下载原镜像..."
if [ ! -f "$IMG" ]; then
    wget -O "$IMG" "$URL"
fi

echo "=> 🛠️  2. 复制并为镜像扩容 (预留 150MB 给 EFI 分区)..."
cp "$IMG" "$UEFI_IMG"
qemu-img resize "$UEFI_IMG" +150M

# 3. 挂载 NBD 设备
echo "=> 🔌 3. 挂载镜像到 NBD 虚拟总线..."
modprobe nbd max_part=8
# 自动寻找空闲的 NBD 设备
for i in {0..15}; do
    if [ -f "/sys/class/block/nbd$i/size" ] && [ "$(cat /sys/class/block/nbd$i/size)" -eq 0 ]; then
        NBD_DEV="/dev/nbd$i"
        break
    fi
done

if [ -z "$NBD_DEV" ]; then
    echo "❌ 错误: 宿主机没有空闲的 /dev/nbd 设备"
    exit 1
fi

qemu-nbd -f qcow2 -c "$NBD_DEV" "$UEFI_IMG"
sleep 2 # 等待内核识别

# 4. 修改分区表为 GPT 并创建 EFI 分区
echo "=> 💽 4. 转换 MBR 为 GPT 并创建 EFI 分区..."
sgdisk -g "$NBD_DEV"  # 将 MBR 转换为 GPT (如果是GPT则无害)
sgdisk -e "$NBD_DEV"  # 将备份 GPT 表移到磁盘末尾，覆盖扩容出来的 150M
# 新建 EFI 分区 (利用最后的空闲空间)，设定类型代码为 EF00
sgdisk -n 0:0:0 -t 0:EF00 -c 0:"EFI System" "$NBD_DEV"
partprobe "$NBD_DEV"
sleep 2

# 动态获取分区号
ROOT_PART="${NBD_DEV}p1" # 原极简镜像只有 1 个根分区
EFI_PART=$(ls -1 ${NBD_DEV}p* | sort | tail -n 1) # 刚才新建的最后一个分区就是 EFI 分区

echo "=> 💾 5. 格式化 EFI 分区 ($EFI_PART) 为 FAT32..."
mkfs.fat -F 32 "$EFI_PART"

# 5. 挂载文件系统
echo "=> 📂 6. 挂载文件系统..."
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$EFI_PART" "$MNT/boot/efi"

# 挂载宿主机虚拟系统，供 Chroot 环境调用
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

# 拷贝 DNS 配置，确保 chroot 内可联网下载 apt 包
cat /etc/resolv.conf > "$MNT/etc/resolv.conf"

# 6. Chroot 安装 UEFI 引导
echo "=> ⚙️  7. 进入 Chroot 安装 grub-efi-amd64..."
chroot "$MNT" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    # 安装 UEFI 版的 GRUB 包
    apt-get install -y grub-efi-amd64
    # 将 GRUB 写入 EFI 分区
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy
    # 更新引导配置
    update-grub
"

# 7. 更新 fstab
echo "=> 📝 8. 更新 /etc/fstab 以自动挂载 EFI 分区..."
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
# 清理可能存在的旧 efi 挂载记录，并写入新纪录
sed -i '/\/boot\/efi/d' "$MNT/etc/fstab"
echo "UUID=$EFI_UUID  /boot/efi  vfat  umask=0077  0  1" >> "$MNT/etc/fstab"

echo "=> 🎉 9. 制作完成！新的 UEFI 镜像文件为: $UEFI_IMG"
# 退出脚本时会触发自动 umount 与资源清理
