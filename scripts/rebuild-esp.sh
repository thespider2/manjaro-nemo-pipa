#!/usr/bin/env bash
# Rebuild nemo_esp.raw (4096-sector + pocketblue shim/grub) without a full image build.
# Usage (as root): rebuild-esp.sh [output-esp.raw]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO_ROOT/images/nemo_esp.raw}"
EFI_TEMPLATE="$REPO_ROOT/efi-template"
BOOT_LABEL="${BOOT_LABEL:-boot}"
ESP_LABEL="${ESP_LABEL:-NEMOPIPA}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root (loop mount)" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
MNT=$(mktemp -d)
cleanup() { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

truncate -s 128M "$OUT"
mkfs.fat -F 16 -S 4096 -s 4 -n "$ESP_LABEL" "$OUT"
mount -o loop "$OUT" "$MNT"
mkdir -p "$MNT/EFI/BOOT" "$MNT/EFI/nemo" "$MNT/EFI/fedora"

for src in \
  "$EFI_TEMPLATE/EFI/BOOT/BOOTAA64.EFI" \
  "$EFI_TEMPLATE/EFI/BOOT/FBAA64.EFI" \
  "$EFI_TEMPLATE/EFI/BOOT/grubaa64.efi" \
  "$EFI_TEMPLATE/EFI/BOOT/shimaa64.efi" \
  "$EFI_TEMPLATE/EFI/BOOT/BOOTAA64.CSV"
do
  [ -f "$src" ] && cp -f "$src" "$MNT/EFI/BOOT/"
done
for vendor in nemo fedora; do
  mkdir -p "$MNT/EFI/$vendor"
  for f in grubaa64.efi shimaa64.efi mmaa64.efi BOOTAA64.CSV; do
    [ -f "$EFI_TEMPLATE/EFI/$vendor/$f" ] && cp -f "$EFI_TEMPLATE/EFI/$vendor/$f" "$MNT/EFI/$vendor/"
  done
  [ -f "$EFI_TEMPLATE/EFI/$vendor/shimaa64.efi" ] && \
    cp -f "$EFI_TEMPLATE/EFI/$vendor/shimaa64.efi" "$MNT/EFI/$vendor/BOOTAA64.EFI"
done

for shim_vendor in nemo fedora BOOT; do
  mkdir -p "$MNT/EFI/$shim_vendor"
  cat > "$MNT/EFI/$shim_vendor/grub.cfg" <<ESPCFG
if [ -f \${config_directory}/bootuuid.cfg ]; then
  source \${config_directory}/bootuuid.cfg
fi
if [ -n "\${BOOT_UUID}" ]; then
  search --fs-uuid "\${BOOT_UUID}" --set prefix --no-floppy
else
  search --label $BOOT_LABEL --set prefix --no-floppy
fi
if [ -d (\$prefix)/grub2 ]; then
  set prefix=(\$prefix)/grub2
  configfile \$prefix/grub.cfg
else
  set prefix=(\$prefix)/boot/grub2
  configfile \$prefix/grub.cfg
fi
boot
ESPCFG
  printf 'set BOOT_UUID=""\n' > "$MNT/EFI/$shim_vendor/bootuuid.cfg"
done

umount "$MNT"
rmdir "$MNT"
trap - EXIT

xz -T0 -9 -k -f "$OUT"
echo "Wrote $OUT and ${OUT}.xz"
ls -lah "$OUT" "${OUT}.xz"
echo "Flash with: fastboot flash rawdump $OUT"
