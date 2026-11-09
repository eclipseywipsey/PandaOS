#!/bin/sh
# Builds a PandaOS ISO and enforces the size budget (550 MiB target, 625 MiB cap).
#
# Inputs (environment variables):
#   LIBC          musl (default) or glibc
#   BASE_ROOTFS   directory with the base userland for this libc (dinit, busybox/
#                 coreutils, grub, tar, zstd, mkfs tools, newfs_ffs, ...)
#   KERNEL_DIR    directory with vmlinuz-linux, vmlinuz-linux-libre and matching
#                 initramfs-*.img (built with ufs, btrfs, vfat in the kernel)
#   SETS_EXTRA    optional directory of extra <name>.tar.zst sets (xbase, icewm, ...)
#   OUT           output ISO (default pandaos-$LIBC.iso)
#
# Needs: zig, tar, zstd, mksquashfs, grub-mkrescue (with xorriso, mtools).
set -eu

LIBC="${LIBC:-musl}"
OUT="${OUT:-pandaos-$LIBC.iso}"
TARGET_MIB=550
CAP_MIB=625
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

: "${BASE_ROOTFS:?set BASE_ROOTFS to the base userland directory}"
: "${KERNEL_DIR:?set KERNEL_DIR to the kernel directory}"

case "$LIBC" in
  musl)  ZIG_TARGET=x86_64-linux-musl ;;
  glibc) ZIG_TARGET=x86_64-linux-gnu ;;
  *) echo "LIBC must be musl or glibc" >&2; exit 1 ;;
esac

echo "==> building PandaOS tools ($ZIG_TARGET)"
(cd "$HERE" && zig build -Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSmall --prefix "$WORK/tools")

echo "==> assembling base set"
BASE="$WORK/base"
mkdir -p "$BASE"
cp -a "$BASE_ROOTFS"/. "$BASE"/
install -Dm755 "$WORK/tools/bin/pkg"             "$BASE/usr/bin/pkg"
install -Dm755 "$WORK/tools/bin/panda-settings"  "$BASE/usr/bin/panda-settings"
install -Dm644 "$HERE/assets/backgrounds/default.png" \
        "$BASE/usr/share/backgrounds/pandaos/default.png"
mkdir -p "$BASE/usr/ports" "$BASE/var/lib/pkg/db" "$BASE/etc/panda/session.d"

echo "==> staging ISO tree"
ISO="$WORK/iso"
mkdir -p "$ISO/boot" "$ISO/sets" "$ISO/live"
tar -C "$BASE" --owner=0 --group=0 --numeric-owner --zstd -cpf "$ISO/sets/base.tar.zst" .
for k in linux linux-libre; do
  # a kernel set: /boot/vmlinuz-<k> and /boot/initramfs-<k>.img
  KS="$WORK/kernel-$k"
  mkdir -p "$KS/boot"
  cp "$KERNEL_DIR/vmlinuz-$k" "$KS/boot/"
  [ -f "$KERNEL_DIR/initramfs-$k.img" ] && cp "$KERNEL_DIR/initramfs-$k.img" "$KS/boot/"
  tar -C "$KS" --owner=0 --group=0 --numeric-owner --zstd -cpf "$ISO/sets/kernel-$k.tar.zst" .
done
[ -n "${SETS_EXTRA:-}" ] && cp "$SETS_EXTRA"/*.tar.zst "$ISO/sets/"

# Live environment: the base userland plus the installer.
LIVE="$WORK/live"
mkdir -p "$LIVE"
cp -a "$BASE"/. "$LIVE"/
install -Dm755 "$WORK/tools/bin/pandaos-install" "$LIVE/usr/bin/pandaos-install"
mksquashfs "$LIVE" "$ISO/live/root.squashfs" -comp zstd -Xcompression-level 19 -noappend

cp "$KERNEL_DIR/vmlinuz-linux" "$ISO/boot/vmlinuz"
cp "$KERNEL_DIR/initramfs-linux.img" "$ISO/boot/initramfs.img"
mkdir -p "$ISO/boot/grub"
cat > "$ISO/boot/grub/grub.cfg" <<'GRUB'
set timeout=3
menuentry "PandaOS installer" {
    linux /boot/vmlinuz pandaos.live=1 quiet
    initrd /boot/initramfs.img
}
GRUB

echo "==> building ISO"
grub-mkrescue -o "$OUT" "$ISO" -volid PANDAOS

BYTES=$(stat -c %s "$OUT")
MIB=$((BYTES / 1048576))
echo "==> $OUT: ${MIB} MiB (target ${TARGET_MIB}, cap ${CAP_MIB})"
if [ "$MIB" -gt "$CAP_MIB" ]; then
  echo "ERROR: over the hard cap" >&2; exit 2
elif [ "$MIB" -gt "$TARGET_MIB" ]; then
  echo "WARNING: over the ${TARGET_MIB} MiB target" >&2
fi
