#!/bin/bash
# 自动将 MBR/Legacy Debian qcow2 镜像转换为 UEFI 支持版本
# 适配 GitHub Actions 环境
set -e
set -x   # 调试模式，在 Actions 中查看每一步

# 常量定义
URL="https://github.com/ninjayo/debian13-minimal-for1gdisk/releases/download/v1.0/debian-final.qcow2"
IMG="debian-final.qcow2"
UEFI_IMG="debian-uefi.qcow2"
MNT="/mnt/debian_chroot"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (例如: sudo ./build.sh)"
  exit 1
fi

# 安装依赖
echo "=> 📦 安装必需软件包..."
apt-get update -qq
apt-get install -y -qq qemu-utils gdisk dosfstools parted wget

# 清理函数
cleanup() {
    echo "=> 🧹 执行清理..."
    set +e
    mountpoint -q "$MNT/sys" && umount "$MNT/sys"
    mountpoint -q "$MNT/proc" && umount "$MNT/proc"
    mountpoint -q "$MNT/dev/pts" && umount "$MNT/dev/pts"
    mountpoint -q "$MNT/dev" && umount "$MNT/dev"
    mountpoint -q "$MNT/boot/efi" && umount "$MNT/boot/efi"
    mountpoint -q "$MNT" && umount "$MNT"
    [ -n "$NBD_DEV" ] && qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
    rm -rf "$MNT"
}
trap cleanup EXIT INT TERM

# 下载原始镜像
echo "=> 📥 下载原始镜像..."
if [ ! -f "$IMG" ]; then
    wget -nv -O "$IMG" "$URL" || { echo "❌ 下载失败"; exit 1; }
fi

# 扩容镜像 (预留 300MB 用于 EFI 分区和系统更新)
echo "=> 🛠️ 复制镜像并扩容 300MB..."
cp "$IMG" "$UEFI_IMG"
qemu-img resize "$UEFI_IMG" +300M

# 加载 NBD 模块并准备设备
echo "=> 🔌 配置 NBD 设备..."
modprobe nbd max_part=8 || true
# 确保设备节点存在
for i in {0..15}; do
    [ -e "/dev/nbd$i" ] || mknod "/dev/nbd$i" b 43 $((i * 16))
done

# 寻找空闲 NBD 设备
NBD_DEV=""
for i in {0..15}; do
    if [ -f "/sys/class/block/nbd$i/size" ] && [ "$(cat /sys/class/block/nbd$i/size)" -eq 0 ]; then
        NBD_DEV="/dev/nbd$i"
        break
    fi
done
[ -z "$NBD_DEV" ] && { echo "❌ 无空闲 NBD 设备"; exit 1; }
echo "使用设备: $NBD_DEV"

qemu-nbd -f qcow2 -c "$NBD_DEV" "$UEFI_IMG"
sleep 3

# 转换分区表为 GPT 并创建 EFI 分区
echo "=> 💽 转换 GPT 并创建 EFI 分区..."
sgdisk -g "$NBD_DEV"               # MBR -> GPT
sgdisk -e "$NBD_DEV"               # 将备份 GPT 表移至末尾
sgdisk -n 0:0:0 -t 0:EF00 -c 0:"EFI System" "$NBD_DEV"
partprobe "$NBD_DEV"
sleep 2

# 获取分区名 (假设原分区为 p1，新 EFI 分区为最后一个)
ROOT_PART="${NBD_DEV}p1"
EFI_PART=$(ls -1 ${NBD_DEV}p* | tail -1)

echo "=> 💾 格式化 EFI 分区 $EFI_PART 为 FAT32..."
mkfs.fat -F 32 "$EFI_PART"

# 挂载文件系统
echo "=> 📂 挂载镜像内容..."
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$EFI_PART" "$MNT/boot/efi"

# 挂载虚拟文件系统
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

# 配置 chroot 网络和 apt 源
echo "=> 🌐 配置 chroot 网络环境..."
cat /etc/resolv.conf > "$MNT/etc/resolv.conf"
cat > "$MNT/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian trixie main
deb http://deb.debian.org/debian-security trixie-security main
deb http://deb.debian.org/debian trixie-updates main
EOF

# 在 chroot 中安装 UEFI 引导
echo "=> ⚙️ 安装 GRUB-EFI..."
chroot "$MNT" /bin/bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq grub-efi-amd64
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy
    update-grub
    apt-get clean
"

# 更新 fstab
echo "=> 📝 更新 /etc/fstab..."
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
sed -i '/\/boot\/efi/d' "$MNT/etc/fstab"
echo "UUID=$EFI_UUID  /boot/efi  vfat  umask=0077  0  1" >> "$MNT/etc/fstab"

# 手动卸载 (清理函数会在 exit 时再做一遍，但先做一次可避免部分问题)
echo "=> 🧽 预清理挂载点..."
umount "$MNT/dev/pts" || true
umount "$MNT/dev" || true
umount "$MNT/proc" || true
umount "$MNT/sys" || true
umount "$MNT/boot/efi" || true
umount "$MNT" || true
qemu-nbd -d "$NBD_DEV" || true

echo "=> ✅ 完成！UEFI 镜像已生成: $UEFI_IMG"
