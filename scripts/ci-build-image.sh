#!/usr/bin/env bash
# CI: resolve upstream openSUSE NEMO aarch64 image from OBS and stage pipa overlays.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/images}"
OBS_IMAGES="${OBS_IMAGES:-https://download.opensuse.org/repositories/devel:/NemoMobile/images/}"
PATTERN="${NEMO_IMAGE_PATTERN:-openSUSE-Tumbleweed-ARM-NEMO-efi.aarch64}"
# Set DOWNLOAD_IMAGE=0 to only resolve URL + ship overlays (saves ~1.3GiB CI bandwidth)
DOWNLOAD_IMAGE="${DOWNLOAD_IMAGE:-1}"
mkdir -p "$OUT_DIR"
chmod +x "$ROOT/scripts"/*.sh

echo "==> Host: $(uname -a)"
"$ROOT/scripts/validate-recipe.sh"

echo "==> Resolving latest OBS image matching ${PATTERN}*.raw.xz"
JSON_URL="${OBS_IMAGES%/}/?jsontable"
CANDIDATE=$(
  python3 - "$JSON_URL" "$PATTERN" <<'PY'
import json, sys, urllib.request
url, pat = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=60) as r:
    data = json.load(r)
names = [
    e["name"]
    for e in data.get("data", [])
    if e.get("name", "").startswith(pat) and e["name"].endswith(".raw.xz")
]
if not names:
    sys.stderr.write(f"ERROR: no {pat}*.raw.xz in {url}\n")
    sys.exit(1)
# Build number sorts after date prefix for current OBS naming
print(sorted(names)[-1])
PY
)

URL="${OBS_IMAGES%/}/$CANDIDATE"
echo "==> Selected $URL"
printf '%s\n' "$URL" > "$OUT_DIR/upstream-image.url"

if [[ "$DOWNLOAD_IMAGE" == "1" ]]; then
  echo "==> Downloading image (set DOWNLOAD_IMAGE=0 to skip)"
  curl -fL --retry 3 -o "$OUT_DIR/$CANDIDATE" "$URL"
  curl -fL -o "$OUT_DIR/${CANDIDATE}.sha256" "${URL}.sha256" || true
  if [[ -f "$OUT_DIR/${CANDIDATE}.sha256" ]]; then
    (cd "$OUT_DIR" && sha256sum -c "${CANDIDATE}.sha256") || true
  fi
else
  echo "==> Skipping image download (DOWNLOAD_IMAGE=$DOWNLOAD_IMAGE)"
fi

echo "==> Staging pipa overlay tarball"
tar -C "$ROOT" -czf "$OUT_DIR/pipa-nemo-overlay.tar.gz" \
  profiles/overlays/pipa \
  profiles/overlays/nemomobile \
  profiles/devices/pipa

cat > "$OUT_DIR/BUILDINFO.txt" << INFO
upstream_image=$CANDIDATE
upstream_url=$URL
obs_project=devel:NemoMobile
device=pipa
download_image=$DOWNLOAD_IMAGE
nemo_device_rpm=https://thespider2.github.io/nemo-pipa-packaging/repo/
note=Flash/boot pipa kernel separately; this artifact is upstream NEMO + pipa overlay bundle.
git_sha=${GITHUB_SHA:-unknown}
INFO

ls -lah "$OUT_DIR"
echo "==> Done"
