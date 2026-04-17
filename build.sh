#!/bin/bash
set -e
set -x

URL="https://github.com/ninjayo/debian13-minimal-for1gdisk/releases/download/v1.0/debian-final.qcow2"
IMG="debian-final.qcow2"
UEFI_IMG="debian-uefi.qcow2"
MNT="/mnt/debian_chroot"

[ "$EUID" -ne 0 ] && { echo "❌ 需要 root"; exit 1; }

cleanup() {
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

echo "=> 📦 安装依赖..."
apt-get update -qq
apt-get install -y -qq qemu-utils gdisk dosfstools parted wget btrfs-progs

echo "=> 📥 下载镜像..."
[ -f "$IMG" ] || wget -nv -O "$IMG" "$URL" || exit 1

echo "=> 🛠️ 扩容..."
cp "$IMG" "$UEFI_IMG"
qemu-img resize "$UEFI_IMG" +300M

echo "=> 🔌 配置 NBD..."
modprobe nbd max_part=8 || true
for i in {0..15}; do [ -e "/dev/nbd$i" ] || mknod "/dev/nbd$i" b 43 $((i*16)); done

NBD_DEV=""
for i in {0..15}; do
    if [ -f "/sys/class/block/nbd$i/size" ] && [ "$(cat /sys/class/block/nbd$i/size)" -eq 0 ]; then
        NBD_DEV="/dev/nbd$i"; break
    fi
done
[ -z "$NBD_DEV" ] && { echo "❌ 无空闲 NBD"; exit 1; }

qemu-nbd -f qcow2 -c "$NBD_DEV" "$UEFI_IMG"
sleep 3

echo "=> 💽 GPT 转换 + EFI 分区..."
sgdisk -g "$NBD_DEV"
sgdisk -e "$NBD_DEV"
sgdisk -n 0:0:0 -t 0:EF00 -c 0:"EFI System" "$NBD_DEV"
partprobe "$NBD_DEV"
sleep 3

# 获取 EFI 分区
EFI_PART=$(ls -1 ${NBD_DEV}p* 2>/dev/null | tail -1)
mkfs.fat -F 32 "$EFI_PART"

# 识别根分区（无阻塞）
ROOT_PART=""; ROOT_FSTYPE=""
for part in $(ls ${NBD_DEV}p* 2>/dev/null | sort -V); do
    [ "$part" = "$EFI_PART" ] && continue
    FSTYPE=$(blkid -s TYPE -o value "$part" 2>/dev/null)
    [ -n "$FSTYPE" ] && [ "$FSTYPE" != "vfat" ] && { ROOT_PART="$part"; ROOT_FSTYPE="$FSTYPE"; break; }
done
[ -z "$ROOT_PART" ] && { echo "❌ 未找到根分区"; exit 1; }

echo "根分区: $ROOT_PART (类型: $ROOT_FSTYPE)"
mkdir -p "$MNT"
mount -t "$ROOT_FSTYPE" "$ROOT_PART" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$EFI_PART" "$MNT/boot/efi"

mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

cat /etc/resolv.conf > "$MNT/etc/resolv.conf"
cat > "$MNT/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian trixie main
deb http://deb.debian.org/debian-security trixie-security main
deb http://deb.debian.org/debian trixie-updates main
EOF

chroot "$MNT" /bin/bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq grub-efi-amd64
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy
    update-grub
    apt-get clean
"

EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
sed -i '/\/boot\/efi/d' "$MNT/etc/fstab"
echo "UUID=$EFI_UUID  /boot/efi  vfat  umask=0077  0  1" >> "$MNT/etc/fstab"

umount "$MNT/dev/pts" || true
umount "$MNT/dev" || true
umount "$MNT/proc" || true
umount "$MNT/sys" || true
umount "$MNT/boot/efi" || true
umount "$MNT" || true
qemu-nbd -d "$NBD_DEV" || true

echo "=> ✅ 完成！镜像: $UEFI_IMG"
