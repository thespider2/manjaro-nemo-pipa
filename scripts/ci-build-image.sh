#!/usr/bin/env bash
# CI: fetch openSUSE NEMO rootfs, inject pipa-pkgs, emit pipa flash layout
# (esp/boot/rootfs + Mu-Silicium) matching Ultramarine / EndeavourOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/images}"
OBS_IMAGES="${OBS_IMAGES:-https://download.opensuse.org/repositories/devel:/NemoMobile/images/}"
# Prefer rootfs tarball for composition (not the full EFI disk image)
ROOTFS_PATTERN="${NEMO_ROOTFS_PATTERN:-openSUSE-Tumbleweed-ARM-NEMO.aarch64-rootfs.aarch64}"
DOWNLOAD_ROOTFS="${DOWNLOAD_ROOTFS:-1}"
RUN_POSTPROCESS="${RUN_POSTPROCESS:-1}"

mkdir -p "$OUT_DIR"
chmod +x "$ROOT/scripts"/*.sh

echo "==> Host: $(uname -a)"
"$ROOT/scripts/validate-recipe.sh"

echo "==> Resolving latest OBS rootfs matching ${ROOTFS_PATTERN}*.tar.xz"
JSON_URL="${OBS_IMAGES%/}/?jsontable"
ROOTFS_NAME=$(
  python3 - "$JSON_URL" "$ROOTFS_PATTERN" <<'PY'
import json, sys, urllib.request
url, pat = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=60) as r:
    data = json.load(r)
names = [
    e["name"]
    for e in data.get("data", [])
    if e.get("name", "").startswith(pat) and e["name"].endswith(".tar.xz")
]
if not names:
    sys.stderr.write(f"ERROR: no {pat}*.tar.xz in {url}\n")
    sys.exit(1)
print(sorted(names)[-1])
PY
)
ROOTFS_URL="${OBS_IMAGES%/}/$ROOTFS_NAME"
echo "==> Selected $ROOTFS_URL"
printf '%s\n' "$ROOTFS_URL" > "$OUT_DIR/upstream-rootfs.url"

echo "==> Staging pipa overlay tarball"
tar -C "$ROOT" -czf "$OUT_DIR/pipa-nemo-overlay.tar.gz" \
  profiles/overlays/pipa \
  profiles/overlays/nemomobile \
  profiles/devices/pipa
cp -a "$ROOT/profiles/devices/pipa" "$OUT_DIR/pipa-packages.txt"
cp -a "$ROOT/profiles/services/nemomobile" "$OUT_DIR/pipa-services.txt"
export OVERLAY_TAR="$OUT_DIR/pipa-nemo-overlay.tar.gz"

ROOTFS_FILE="$OUT_DIR/$ROOTFS_NAME"
if [[ "$DOWNLOAD_ROOTFS" == "1" ]]; then
  echo "==> Downloading rootfs"
  curl -fL --retry 3 -o "$ROOTFS_FILE" "$ROOTFS_URL"
  curl -fL -o "${ROOTFS_FILE}.sha256" "${ROOTFS_URL}.sha256" || true
  if [[ -f "${ROOTFS_FILE}.sha256" ]]; then
    (cd "$OUT_DIR" && sha256sum -c "$(basename "$ROOTFS_FILE").sha256") || true
  fi
else
  echo "==> DOWNLOAD_ROOTFS=0 — skipping rootfs download / post-process"
  cat > "$OUT_DIR/BUILDINFO.txt" << INFO
upstream_rootfs=$ROOTFS_NAME
upstream_url=$ROOTFS_URL
note=Set DOWNLOAD_ROOTFS=1 and RUN_POSTPROCESS=1 to produce esp/boot/rootfs flashables.
INFO
  ls -lah "$OUT_DIR"
  exit 0
fi

if [[ "$RUN_POSTPROCESS" == "1" ]]; then
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "==> Elevating for post-process (loop mounts)"
    exec sudo -E OUT_DIR="$OUT_DIR" OVERLAY_TAR="$OVERLAY_TAR" \
      "$ROOT/scripts/post-process-pipa.sh" "$ROOTFS_FILE" "$OUT_DIR/flashable"
  else
    "$ROOT/scripts/post-process-pipa.sh" "$ROOTFS_FILE" "$OUT_DIR/flashable"
  fi
  # Promote flashables to images/ root for artifact upload
  if [[ -d "$OUT_DIR/flashable" ]]; then
    cp -a "$OUT_DIR/flashable"/. "$OUT_DIR"/
  fi
fi

ls -lah "$OUT_DIR"
echo "==> Done"
