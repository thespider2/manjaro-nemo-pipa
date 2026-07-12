#!/usr/bin/env bash
# Split openSUSE NEMO rootfs + pipa-pkgs kernel into pipa flash layout
# (same mapping as Ultramarine / EndeavourOS).
#
# Usage (as root):
#   post-process-pipa.sh <nemo-rootfs.tar.xz|extracted-rootfs-dir> [output-dir]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATE=$(date +%Y%m%d)
INPUT="${1:?usage: $0 <rootfs.tar.xz|rootfs-dir> [output-dir]}"
OUTPUT_DIR="${2:-$REPO_ROOT/images/nemo-pipa-${DATE}}"

ROOTFS_LABEL="nemo-pipa"
BOOT_LABEL="boot"
ESP_LABEL="NEMOPIPA"

SILICIUM_URL="${SILICIUM_URL:-https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img}"
PIPA_REPO_URL="${PIPA_REPO_URL:-https://thespider2.github.io/pipa-pkgs/repo/}"
VBMETA_DISABLED="$REPO_ROOT/assets/vbmeta-disabled.img"
EFI_TEMPLATE="$REPO_ROOT/efi-template"
OVERLAY_TAR="${OVERLAY_TAR:-$REPO_ROOT/images/pipa-nemo-overlay.tar.gz}"

# Arch packages to inject from pipa-pkgs (kernel + critical hardware)
PIPA_INJECT_PKGS=(
  linux-pipa
  xiaomi-pipa-firmware
  pipa-dracut
  pipa-grub-config
  pipa-metapkg
  alsa-ucm-conf-sm8250
  pipa-sound-conf
  pipa-sensors
  qrtr
  rmtfs
  tqftpserv
  pd-mapper
  hexagonrpc
  libssc
  bootmac
  swclock-offset
  qbootctl
  iio-sensor-proxy
)

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root (loop mounts)" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$REPO_ROOT/images/.cache"
WORK=$(mktemp -d)
ROOTFS_DIR="$WORK/rootfs"
BOOT_MNT="$WORK/boot"
ESP_MNT="$WORK/esp"
PKG_CACHE="$REPO_ROOT/images/.cache/pipa-pkgs"
mkdir -p "$ROOTFS_DIR" "$BOOT_MNT" "$ESP_MNT" "$PKG_CACHE"

cleanup() {
  umount "$ROOTFS_DIR/boot" 2>/dev/null || true
  umount "$BOOT_MNT" 2>/dev/null || true
  umount "$ESP_MNT" 2>/dev/null || true
  umount "$ROOTFS_DIR/proc" 2>/dev/null || true
  umount "$ROOTFS_DIR/sys" 2>/dev/null || true
  umount "$ROOTFS_DIR/dev" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== Preparing NEMO rootfs ==="
if [ -d "$INPUT" ]; then
  rsync -aHAX "$INPUT"/ "$ROOTFS_DIR"/
elif [[ "$INPUT" == *.tar.xz ]] || [[ "$INPUT" == *.tar.gz ]] || [[ "$INPUT" == *.tgz ]]; then
  tar -C "$ROOTFS_DIR" -xf "$INPUT"
else
  echo "Unsupported input: $INPUT" >&2
  exit 1
fi

# Apply pipa overlays if present
if [ -f "$OVERLAY_TAR" ]; then
  echo "=== Applying pipa overlay ==="
  TMPO=$(mktemp -d)
  tar -C "$TMPO" -xzf "$OVERLAY_TAR"
  if [ -d "$TMPO/profiles/overlays/nemomobile" ]; then
    rsync -a "$TMPO/profiles/overlays/nemomobile/" "$ROOTFS_DIR/" --exclude overlay.txt || true
  fi
  if [ -d "$TMPO/profiles/overlays/pipa" ]; then
    rsync -a "$TMPO/profiles/overlays/pipa/" "$ROOTFS_DIR/" --exclude overlay.txt || true
  fi
  rm -rf "$TMPO"
fi

# Also copy device package sparse from sibling packaging repo if available
DEVICE_SPARSE="${DEVICE_SPARSE:-/home/ayman/nemo-pipa-packaging/device/nemo-device-pipa/sparse}"
if [ -d "$DEVICE_SPARSE" ]; then
  echo "=== Applying nemo-device-pipa sparse ==="
  rsync -a "$DEVICE_SPARSE"/ "$ROOTFS_DIR"/
fi

echo "=== Fetching/injecting pipa-pkgs (kernel + hardware) ==="
# Resolve latest matching package filenames from repo index
INDEX=$(curl -fsSL "$PIPA_REPO_URL")
inject_one() {
  local name="$1"
  local file
  file=$(printf '%s\n' "$INDEX" | grep -oE "href=\"${name}-[^\"]+\.pkg\.tar\.(xz|zst)\"" | sed 's/href="//;s/"$//' | sort -V | tail -n1 || true)
  if [ -z "$file" ]; then
    echo "WARNING: package not found in pipa-pkgs: $name"
    return 0
  fi
  local dest="$PKG_CACHE/$file"
  if [ ! -f "$dest" ]; then
    echo "  downloading $file"
    curl -fL --retry 3 -o "$dest" "${PIPA_REPO_URL%/}/$file"
  fi
  echo "  extracting $file"
  tar -C "$ROOTFS_DIR" -xf "$dest" --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.BUILDINFO' --exclude='.INSTALL' 2>/dev/null \
    || tar -C "$ROOTFS_DIR" -xf "$dest"
}

for pkg in "${PIPA_INJECT_PKGS[@]}"; do
  inject_one "$pkg"
done

# Remove Arch package metadata leftovers if any
rm -f "$ROOTFS_DIR"/.PKGINFO "$ROOTFS_DIR"/.MTREE "$ROOTFS_DIR"/.BUILDINFO "$ROOTFS_DIR"/.INSTALL 2>/dev/null || true

# Prefer linux-pipa modules; drop stock openSUSE kernels so find/dracut don't pick them
mapfile -t _mod_dirs < <(find "$ROOTFS_DIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V || true)
KERNEL_VER=""
for d in "${_mod_dirs[@]}"; do
  case "$d" in
    *pipa*|*PIPA*) KERNEL_VER="$d"; break ;;
  esac
done
if [ -z "$KERNEL_VER" ]; then
  for d in "${_mod_dirs[@]}"; do
    # Arch linux-pipa often uses uname like 6.x.y-N-pipa or similar; skip *-default / *-vanilla
    case "$d" in
      *-default|*-vanilla|*-slowroll*) continue ;;
      *) KERNEL_VER="$d"; break ;;
    esac
  done
fi
if [ -z "$KERNEL_VER" ]; then
  echo "ERROR: no kernel modules after pipa-pkgs inject" >&2
  ls -la "$ROOTFS_DIR/usr/lib/modules" >&2 || true
  exit 1
fi
for d in "${_mod_dirs[@]}"; do
  if [ "$d" != "$KERNEL_VER" ]; then
    echo "Removing unused stock kernel modules: $d"
    rm -rf "$ROOTFS_DIR/usr/lib/modules/$d"
  fi
done
echo "Kernel version: $KERNEL_VER"

mkdir -p "$ROOTFS_DIR/boot/dtbs/qcom" "$ROOTFS_DIR/boot/grub" "$ROOTFS_DIR/boot/grub2"

# Locate kernel / dtb — prefer pipa/vmlinuz over any pre-existing Image.gz from NEMO rootfs
KERNEL_IMAGE=""
for f in \
  "$ROOTFS_DIR/boot/vmlinuz-linux-pipa" \
  "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER" \
  "$ROOTFS_DIR/usr/lib/modules/$KERNEL_VER/vmlinuz" \
  "$ROOTFS_DIR/boot/Image.gz" \
  "$ROOTFS_DIR/boot/Image"
do
  [ -f "$f" ] && KERNEL_IMAGE="$f" && break
done
if [ -z "$KERNEL_IMAGE" ]; then
  for f in "$ROOTFS_DIR"/boot/vmlinuz-*; do
    [ -f "$f" ] && KERNEL_IMAGE="$f" && break
  done
fi
[ -n "$KERNEL_IMAGE" ] || { echo "ERROR: kernel image missing" >&2; ls -la "$ROOTFS_DIR/boot" >&2; exit 1; }
echo "Kernel image: $KERNEL_IMAGE"

# Ensure Image.gz on boot (skip no-op same-file copy; GNU cp -f still errors on same path)
DEST_GZ="$ROOTFS_DIR/boot/Image.gz"
if [[ "$KERNEL_IMAGE" == *.gz ]]; then
  if [ "$KERNEL_IMAGE" -ef "$DEST_GZ" ] || [ "$KERNEL_IMAGE" = "$DEST_GZ" ]; then
    :
  else
    cp -f "$KERNEL_IMAGE" "$DEST_GZ"
  fi
else
  gzip -c -9 "$KERNEL_IMAGE" > "$DEST_GZ"
fi
# Uncompressed Image if available / derivable
if [ ! -f "$ROOTFS_DIR/boot/Image" ]; then
  if [[ "$KERNEL_IMAGE" == *.gz ]]; then
    gunzip -c "$KERNEL_IMAGE" > "$ROOTFS_DIR/boot/Image" || true
  elif [ ! "$KERNEL_IMAGE" -ef "$ROOTFS_DIR/boot/Image" ]; then
    cp -f "$KERNEL_IMAGE" "$ROOTFS_DIR/boot/Image"
  fi
fi

# Copy into dest dir, skipping sources that already live there (GNU cp errors on same file)
cp_into() {
  local dest="$1"; shift
  mkdir -p "$dest"
  local src
  for src in "$@"; do
    [ -e "$src" ] || continue
    if [ "$src" -ef "$dest/$(basename "$src")" ] || [ "$src" = "$dest/$(basename "$src")" ]; then
      continue
    fi
    cp -f "$src" "$dest/"
  done
}

# DTBs — linux-pipa already ships them under boot/dtbs/qcom/
shopt -s nullglob
dtb_files=("$ROOTFS_DIR"/boot/dtbs/qcom/sm8250-xiaomi-pipa*.dtb)
if [ ${#dtb_files[@]} -eq 0 ]; then
  dtb_files=("$ROOTFS_DIR"/usr/lib/modules/"$KERNEL_VER"/dtb/qcom/sm8250-xiaomi-pipa*.dtb)
fi
if [ ${#dtb_files[@]} -eq 0 ]; then
  dtb_files=("$ROOTFS_DIR"/usr/lib/modules/"$KERNEL_VER"/devicetree/sm8250-xiaomi-pipa*.dtb)
fi
shopt -u nullglob
if [ ${#dtb_files[@]} -eq 0 ]; then
  echo "ERROR: no pipa DTB found" >&2
  find "$ROOTFS_DIR" -name 'sm8250-xiaomi-pipa*.dtb' 2>/dev/null | head >&2 || true
  exit 1
fi
cp_into "$ROOTFS_DIR/boot/dtbs/qcom" "${dtb_files[@]}"
echo "DTBs: ${dtb_files[*]}"

TARGET_KERNEL_CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 quiet splash clk_ignore_unused pd_ignore_unused"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/boot/cmdline.txt"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/etc/cmdline" 2>/dev/null || true

echo "=== Generating initramfs (dracut) ==="
INITRAMFS_STABLE="initramfs-linux-pipa.img"
if command -v dracut >/dev/null 2>&1 || [ -x "$ROOTFS_DIR/usr/bin/dracut" ]; then
  mount --bind /proc "$ROOTFS_DIR/proc" 2>/dev/null || true
  mount --bind /sys "$ROOTFS_DIR/sys" 2>/dev/null || true
  mount --bind /dev "$ROOTFS_DIR/dev" 2>/dev/null || true
  if chroot "$ROOTFS_DIR" /usr/bin/dracut --force --kver "$KERNEL_VER" "/boot/initramfs-$KERNEL_VER.img" 2>/dev/null \
    || chroot "$ROOTFS_DIR" dracut --force --kver "$KERNEL_VER" "/boot/initramfs-$KERNEL_VER.img" 2>/dev/null; then
    cp -f "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" "$ROOTFS_DIR/boot/$INITRAMFS_STABLE"
  else
    echo "WARNING: dracut failed; looking for existing initramfs"
  fi
  umount "$ROOTFS_DIR/proc" 2>/dev/null || true
  umount "$ROOTFS_DIR/sys" 2>/dev/null || true
  umount "$ROOTFS_DIR/dev" 2>/dev/null || true
fi

INITRAMFS=""
for f in "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" "$ROOTFS_DIR/boot/$INITRAMFS_STABLE" "$ROOTFS_DIR/boot/initramfs.img" "$ROOTFS_DIR/boot/initrd.img"; do
  [ -f "$f" ] && INITRAMFS="$f" && break
done
if [ -z "$INITRAMFS" ]; then
  echo "WARNING: no initramfs — creating minimal placeholder (may not boot until regenerated on device)"
  # Tiny cpio placeholder so flash artifacts exist; device needs proper initramfs later
  (cd "$WORK" && mkdir -p empty && printf '' | cpio -o -H newc 2>/dev/null | gzip > "$ROOTFS_DIR/boot/$INITRAMFS_STABLE") || \
    dd if=/dev/zero bs=1M count=2 of="$ROOTFS_DIR/boot/$INITRAMFS_STABLE"
  INITRAMFS="$ROOTFS_DIR/boot/$INITRAMFS_STABLE"
elif [ ! "$INITRAMFS" -ef "$ROOTFS_DIR/boot/$INITRAMFS_STABLE" ] \
  && [ "$INITRAMFS" != "$ROOTFS_DIR/boot/$INITRAMFS_STABLE" ]; then
  cp -f "$INITRAMFS" "$ROOTFS_DIR/boot/$INITRAMFS_STABLE"
fi

cat > "$ROOTFS_DIR/etc/fstab" <<FSTAB
LABEL=$ROOTFS_LABEL / ext4 defaults,x-systemd.growfs 0 1
LABEL=$BOOT_LABEL /boot ext4 defaults 0 2
FSTAB

mkdir -p "$ROOTFS_DIR/boot/grub"
cat > "$ROOTFS_DIR/boot/grub/grub.cfg" <<GRUB
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
GRUB

echo "=== Creating boot.raw ==="
truncate -s 1024M "$OUTPUT_DIR/nemo_boot.raw"
mkfs.ext4 -F -L "$BOOT_LABEL" -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file "$OUTPUT_DIR/nemo_boot.raw"
mount -o loop "$OUTPUT_DIR/nemo_boot.raw" "$BOOT_MNT"

cp -f "$ROOTFS_DIR/boot/Image.gz" "$BOOT_MNT/Image.gz"
[ -f "$ROOTFS_DIR/boot/Image" ] && cp -f "$ROOTFS_DIR/boot/Image" "$BOOT_MNT/Image"
cp -f "$ROOTFS_DIR/boot/$INITRAMFS_STABLE" "$BOOT_MNT/$INITRAMFS_STABLE"
[ -f "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" ] && cp -f "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" "$BOOT_MNT/"
mkdir -p "$BOOT_MNT/dtbs/qcom" "$BOOT_MNT/grub2"
cp -f "$ROOTFS_DIR"/boot/dtbs/qcom/sm8250-xiaomi-pipa*.dtb "$BOOT_MNT/dtbs/qcom/"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$BOOT_MNT/cmdline.txt"

kernel_rel="Image"
[ -f "$BOOT_MNT/Image" ] || kernel_rel="Image.gz"
dtb_rels=()
for dtb in "$BOOT_MNT"/dtbs/qcom/sm8250-xiaomi-pipa*.dtb; do
  dtb_rels+=("dtbs/qcom/$(basename "$dtb")")
done

"$REPO_ROOT/scripts/write-pipa-grub-cfg.sh" \
  "$BOOT_MNT/grub2/grub.cfg" "$BOOT_LABEL" "$TARGET_KERNEL_CMDLINE" \
  "$kernel_rel" "$INITRAMFS_STABLE" "${dtb_rels[@]}"

umount "$BOOT_MNT"

echo "=== Creating esp.raw ==="
# Match pocketblue / Mu-Silicium: 4096-byte sectors (UFS). 512-byte FATs often
# leave Silicium stuck in MsTemp without ever loading BOOTAA64.
truncate -s 128M "$OUTPUT_DIR/nemo_esp.raw"
mkfs.fat -F 16 -S 4096 -s 4 -n "$ESP_LABEL" "$OUTPUT_DIR/nemo_esp.raw"
mount -o loop "$OUTPUT_DIR/nemo_esp.raw" "$ESP_MNT"
mkdir -p "$ESP_MNT/EFI/BOOT" "$ESP_MNT/EFI/nemo" "$ESP_MNT/EFI/fedora"

# Pocketblue-style shim + Fedora grub (plain cp — FAT has no ownership)
for src in \
  "$EFI_TEMPLATE/EFI/BOOT/BOOTAA64.EFI" \
  "$EFI_TEMPLATE/EFI/BOOT/FBAA64.EFI" \
  "$EFI_TEMPLATE/EFI/BOOT/grubaa64.efi" \
  "$EFI_TEMPLATE/EFI/BOOT/shimaa64.efi" \
  "$EFI_TEMPLATE/EFI/BOOT/BOOTAA64.CSV"
do
  [ -f "$src" ] && cp -f "$src" "$ESP_MNT/EFI/BOOT/"
done
for vendor in nemo fedora; do
  mkdir -p "$ESP_MNT/EFI/$vendor"
  for f in grubaa64.efi shimaa64.efi mmaa64.efi BOOTAA64.CSV; do
    [ -f "$EFI_TEMPLATE/EFI/$vendor/$f" ] && cp -f "$EFI_TEMPLATE/EFI/$vendor/$f" "$ESP_MNT/EFI/$vendor/"
  done
  # shim as BOOTAA64 in vendor dir too (some loaders look here)
  [ -f "$EFI_TEMPLATE/EFI/$vendor/shimaa64.efi" ] && \
    cp -f "$EFI_TEMPLATE/EFI/$vendor/shimaa64.efi" "$ESP_MNT/EFI/$vendor/BOOTAA64.EFI"
done

for shim_vendor in nemo fedora BOOT; do
  mkdir -p "$ESP_MNT/EFI/$shim_vendor"
  cat > "$ESP_MNT/EFI/$shim_vendor/grub.cfg" <<ESPCFG
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
  cat > "$ESP_MNT/EFI/$shim_vendor/bootuuid.cfg" <<UUIDCFG
set BOOT_UUID=""
UUIDCFG
done
umount "$ESP_MNT"

echo "=== Creating rootfs.raw ==="
# Clear /boot contents from rootfs image (live on cust partition)
rm -rf "$ROOTFS_DIR/boot"/*
mkdir -p "$ROOTFS_DIR/boot/grub"
cat > "$ROOTFS_DIR/boot/grub/grub.cfg" <<GRUB
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
GRUB

SIZE=$(du -sBM "$ROOTFS_DIR" | awk '{print $1}' | tr -d 'M')
SIZE=$((SIZE + SIZE / 8 + 512))
echo "Rootfs size: ${SIZE}M"
truncate -s "${SIZE}M" "$OUTPUT_DIR/nemo_rootfs.raw"
MKE2FS_DEVICE_PHYS_SECTSIZE=4096 MKE2FS_DEVICE_SECTSIZE=4096 \
  mkfs.ext4 -L "$ROOTFS_LABEL" "$OUTPUT_DIR/nemo_rootfs.raw"
ROOT_MNT=$(mktemp -d)
mount -o loop "$OUTPUT_DIR/nemo_rootfs.raw" "$ROOT_MNT"
rsync -aHAX --exclude '/tmp/*' "$ROOTFS_DIR"/ "$ROOT_MNT"/
umount "$ROOT_MNT"
rmdir "$ROOT_MNT"

echo "=== Fetching Mu-Silicium ==="
curl -fL --retry 3 -o "$OUTPUT_DIR/silicium.img" "$SILICIUM_URL"
cp -f "$VBMETA_DISABLED" "$OUTPUT_DIR/vbmeta-disabled.img"

echo "=== Writing flash scripts ==="
cat > "$OUTPUT_DIR/flash.sh" <<'FLASH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "### Nemomobile (openSUSE) - Xiaomi Pad 6 single-boot flasher"
echo "### Flashes rootfs to userdata."

need() {
  local f="$1"
  if [[ -f "$f" ]]; then
    echo "$f"
  elif [[ -f "$f.xz" ]]; then
    echo "==> Decompressing $f.xz" >&2
    xz -dkf "$f.xz"
    echo "$f"
  else
    echo "ERROR: missing $f or $f.xz" >&2
    exit 1
  fi
}

fastboot getvar product 2>&1 | grep pipa
read -r -p "Proceed with flashing? [Y/n]: " CONFIRM
case "${CONFIRM:-Y}" in y|Y|yes|YES|"") ;; *) echo "Aborted."; exit 0 ;; esac
if [[ -f vbmeta-disabled.img || -f vbmeta-disabled.img.xz ]]; then
  fastboot flash vbmeta_ab "$(need vbmeta-disabled.img)" || true
fi
fastboot flash boot_ab "$(need silicium.img)"
fastboot flash rawdump "$(need nemo_esp.raw)"
fastboot flash cust "$(need nemo_boot.raw)"
fastboot flash userdata "$(need nemo_rootfs.raw)"
fastboot reboot
FLASH
chmod +x "$OUTPUT_DIR/flash.sh"

cat > "$OUTPUT_DIR/flash-multiboot.sh" <<'MFLASH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "### Nemomobile (openSUSE) - Xiaomi Pad 6 multiboot flasher"
ROOTFS_PART="${1:-linux}"
BOOT_SLOT="${2:-boot_ab}"

need() {
  local f="$1"
  if [[ -f "$f" ]]; then
    echo "$f"
  elif [[ -f "$f.xz" ]]; then
    echo "==> Decompressing $f.xz" >&2
    xz -dkf "$f.xz"
    echo "$f"
  else
    echo "ERROR: missing $f or $f.xz" >&2
    exit 1
  fi
}

fastboot getvar product 2>&1 | grep pipa
echo "  Mu-Silicium -> $BOOT_SLOT"
echo "  ESP         -> rawdump"
echo "  boot        -> cust"
echo "  rootfs      -> $ROOTFS_PART"
read -r -p "Proceed? [Y/n]: " CONFIRM
case "${CONFIRM:-Y}" in y|Y|yes|YES|"") ;; *) echo "Aborted."; exit 0 ;; esac
if [[ -f vbmeta-disabled.img || -f vbmeta-disabled.img.xz ]]; then
  fastboot flash vbmeta_ab "$(need vbmeta-disabled.img)" || true
fi
fastboot flash "$BOOT_SLOT" "$(need silicium.img)"
fastboot flash rawdump "$(need nemo_esp.raw)"
fastboot flash cust "$(need nemo_boot.raw)"
fastboot flash "$ROOTFS_PART" "$(need nemo_rootfs.raw)"
fastboot reboot
MFLASH
chmod +x "$OUTPUT_DIR/flash-multiboot.sh"

cat > "$OUTPUT_DIR/BUILDINFO.txt" <<INFO
Nemomobile openSUSE Pipa Image
==============================
Build date:     $DATE
Kernel:         $KERNEL_VER
Rootfs label:   $ROOTFS_LABEL
Boot label:     $BOOT_LABEL
ESP label:      $ESP_LABEL
Silicium URL:   $SILICIUM_URL
Pipa pkgs:      $PIPA_REPO_URL
Flash (decompress .xz first, or use flash.sh):
  silicium.img(.xz)    -> boot_ab
  nemo_esp.raw(.xz)    -> rawdump
  nemo_boot.raw(.xz)   -> cust
  nemo_rootfs.raw(.xz) -> userdata (or linux for multiboot)
INFO

echo "=== Compressing flashables with xz ==="
XZ_OPTS=(-T0 -9)
for f in nemo_esp.raw nemo_boot.raw nemo_rootfs.raw silicium.img vbmeta-disabled.img; do
  if [[ -f "$OUTPUT_DIR/$f" ]]; then
    echo "  xz ${XZ_OPTS[*]} $f"
    xz "${XZ_OPTS[@]}" -f "$OUTPUT_DIR/$f"
  fi
done

(cd "$OUTPUT_DIR" && sha256sum -- *.xz *.sh BUILDINFO.txt > SHA256SUMS 2>/dev/null || true)

# Optional zip for local builds only (CI uploads xz flash files directly)
if [[ "${MAKE_FLASH_ZIP:-0}" == "1" ]]; then
  (cd "$OUTPUT_DIR" && zip -r "$REPO_ROOT/images/nemo-pipa-${DATE}.zip" .)
fi

echo "=== Done ==="
echo "Output: $OUTPUT_DIR"
ls -lah "$OUTPUT_DIR"
