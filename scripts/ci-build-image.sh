#!/usr/bin/env bash
# CI: fetch upstream openSUSE NEMO aarch64 image and apply pipa overlays.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/images}"
OBS_IMAGES="${OBS_IMAGES:-https://download.opensuse.org/repositories/devel:/NemoMobile/images/}"
PATTERN="${NEMO_IMAGE_PATTERN:-openSUSE-Tumbleweed-ARM-NEMO-efi.aarch64}"
mkdir -p "$OUT_DIR"
chmod +x "$ROOT/scripts"/*.sh

echo "==> Host: $(uname -a)"
"$ROOT/scripts/validate-recipe.sh"

echo "==> Resolving latest OBS image matching $PATTERN"
INDEX=$(curl -fsSL "$OBS_IMAGES")
# Pick newest raw.xz for efi aarch64
CANDIDATE=$(printf '%s\n' "$INDEX" | grep -oE "href=\"${PATTERN}[^\"]+\\.raw\\.xz\"" | sed 's/href="//;s/"$//' | sed 's|^\./||' | sort -u | tail -n1)
if [[ -z "$CANDIDATE" ]]; then
  echo "ERROR: no image matching $PATTERN under $OBS_IMAGES"
  exit 1
fi
URL="${OBS_IMAGES%/}/$CANDIDATE"
echo "==> Downloading $URL"
curl -fL --retry 3 -o "$OUT_DIR/$CANDIDATE" "$URL"

# Optional sha256
SHA=$(printf '%s\n' "$INDEX" | grep -oE "href=\"${CANDIDATE}\\.sha256\"" | head -1 | sed 's/href="//;s/"$//' | sed 's|^\./||' || true)
if [[ -n "$SHA" ]]; then
  curl -fL -o "$OUT_DIR/$CANDIDATE.sha256" "${OBS_IMAGES%/}/$SHA" || true
  if [[ -f "$OUT_DIR/$CANDIDATE.sha256" ]]; then
    (cd "$OUT_DIR" && sha256sum -c "$CANDIDATE.sha256" || true)
  fi
fi

echo "==> Staging pipa overlay tarball (applied on-device or in later rootfs step)"
tar -C "$ROOT" -czf "$OUT_DIR/pipa-nemo-overlay.tar.gz" \
  profiles/overlays/pipa \
  profiles/overlays/nemomobile \
  profiles/devices/pipa

cat > "$OUT_DIR/BUILDINFO.txt" << INFO
upstream_image=$CANDIDATE
upstream_url=$URL
obs_project=devel:NemoMobile
device=pipa
nemo_device_rpm=https://thespider2.github.io/nemo-pipa-packaging/repo/
note=Flash/boot pipa kernel separately; this artifact is upstream NEMO + pipa overlay bundle.
git_sha=${GITHUB_SHA:-unknown}
INFO

# Keep compressed upstream image + overlay as CI artifacts (do not recompress further)
ls -lah "$OUT_DIR"
echo "==> Done (openSUSE upstream image fetched; no Manjaro rebuild)"
