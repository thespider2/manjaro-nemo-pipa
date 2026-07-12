#!/usr/bin/env bash
# Build a Manjaro ARM Nemomobile image for Xiaomi Pad 6 (pipa).
#
# Requires: manjaro-arm-tools (buildarmimg), aarch64 host or qemu-user,
#           pacman access to Manjaro ARM + pipa-pkgs + nemo-pipa-packaging repos.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE:-pipa}"
EDITION="${EDITION:-nemomobile}"
BRANCH="${BRANCH:-unstable}"
VERSION="${VERSION:-dev-$(date +%Y%m%d)}"
OUT_DIR="${OUT_DIR:-$ROOT/images}"

PIPA_REPO_URL="${PIPA_REPO_URL:-https://thespider2.github.io/pipa-pkgs/repo/}"
NEMO_REPO_URL="${NEMO_REPO_URL:-https://thespider2.github.io/nemo-pipa-packaging/repo/}"
# Optional upstream Nemo Manjaro packages while local rebuilds catch up
NEMO_UPSTREAM_REPO="${NEMO_UPSTREAM_REPO:-https://img.nemomobile.net/manjaro/}"

mkdir -p "$OUT_DIR"

echo "==> Installing profiles"
sudo "$ROOT/scripts/install-profiles.sh"

# Inject custom pacman repos into the build chroot helper if present
REPO_SNIPPET=$(mktemp)
cat > "$REPO_SNIPPET" << REPOEOF
[pipa-pkgs]
SigLevel = Optional TrustAll
Server = ${PIPA_REPO_URL}\$arch

[nemo-pipa]
SigLevel = Optional TrustAll
Server = ${NEMO_REPO_URL}\$arch
REPOEOF

if [[ -n "${NEMO_UPSTREAM_REPO}" && "${NEMO_UPSTREAM_REPO}" != "none" ]]; then
  cat >> "$REPO_SNIPPET" << REPOEOF

[nemomobile]
SigLevel = Optional TrustAll
Server = ${NEMO_UPSTREAM_REPO}\$repo/\$arch
REPOEOF
fi

echo "==> Extra pacman repos:"
cat "$REPO_SNIPPET"

# manjaro-arm-tools looks for custom repo fragments in a few places depending on version.
# Copy snippet next to the image output for operators and into /etc if writable.
EXTRA_REPO_DIR="${EXTRA_REPO_DIR:-/usr/share/manjaro-arm-tools/pacman}"
if [[ -d "$(dirname "$EXTRA_REPO_DIR")" ]]; then
  sudo mkdir -p "$EXTRA_REPO_DIR"
  sudo cp "$REPO_SNIPPET" "$EXTRA_REPO_DIR/nemo-pipa-extra.conf"
fi
cp "$REPO_SNIPPET" "$OUT_DIR/extra-repos.conf"
rm -f "$REPO_SNIPPET"

echo "==> Running buildarmimg -d $DEVICE -e $EDITION -v $VERSION -b $BRANCH"
if ! command -v buildarmimg >/dev/null 2>&1; then
  cat << MSG
ERROR: buildarmimg not found.

Install manjaro-arm-tools on a Manjaro ARM (aarch64) host, or use the
Dockerfile in this repository:

  docker build -t manjaro-nemo-pipa .
  docker run --rm --privileged -v "\$PWD/images:/out" manjaro-nemo-pipa

MSG
  exit 127
fi

sudo buildarmimg -d "$DEVICE" -e "$EDITION" -v "$VERSION" -b "$BRANCH"

# Collect images if buildarmimg wrote to the default path
DEFAULT_IMG_DIR="/var/cache/manjaro-arm-tools/img"
if [[ -d "$DEFAULT_IMG_DIR" ]]; then
  echo "==> Copying images from $DEFAULT_IMG_DIR to $OUT_DIR"
  cp -a "$DEFAULT_IMG_DIR"/*"$DEVICE"*nemo* "$OUT_DIR"/ 2>/dev/null || \
    cp -a "$DEFAULT_IMG_DIR"/*.img.xz "$OUT_DIR"/ 2>/dev/null || true
fi

echo "==> Done. Images in $OUT_DIR"
ls -lah "$OUT_DIR" || true
