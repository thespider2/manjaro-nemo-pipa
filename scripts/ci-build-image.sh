#!/usr/bin/env bash
# CI entrypoint: install profiles and run buildarmimg when available.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/images}"
DEVICE="${DEVICE:-pipa}"
EDITION="${EDITION:-nemomobile}"
BRANCH="${BRANCH:-unstable}"
VERSION="${VERSION:-ci-$(date +%Y%m%d%H%M)-${GITHUB_SHA:-local}}"
VERSION="${VERSION:0:32}"

mkdir -p "$OUT_DIR"
chmod +x "$ROOT/scripts"/*.sh

echo "==> Host: $(uname -a)"
echo "==> Staging profiles"
DEST="$OUT_DIR/profile-staging" "$ROOT/scripts/install-profiles.sh"
"$ROOT/scripts/validate-recipe.sh" || true

# Also install into manjaro-arm-tools path when present
if [[ -d /usr/share/manjaro-arm-tools ]] || command -v buildarmimg >/dev/null 2>&1; then
  DEST=/usr/share/manjaro-arm-tools/profiles/arm-profiles "$ROOT/scripts/install-profiles.sh" || \
    sudo DEST=/usr/share/manjaro-arm-tools/profiles/arm-profiles "$ROOT/scripts/install-profiles.sh" || true
fi

# Write extra pacman repos for the image build
cat > "$OUT_DIR/extra-repos.conf" << REPOEOF
[pipa-pkgs]
SigLevel = Optional TrustAll
Server = ${PIPA_REPO_URL:-https://thespider2.github.io/pipa-pkgs/repo/}\$arch

[nemo-pipa]
SigLevel = Optional TrustAll
Server = ${NEMO_REPO_URL:-https://thespider2.github.io/nemo-pipa-packaging/repo/}\$arch
REPOEOF

if [[ "${NEMO_UPSTREAM_REPO:-}" != "none" ]]; then
  cat >> "$OUT_DIR/extra-repos.conf" << REPOEOF

[nemomobile]
SigLevel = Optional TrustAll
Server = ${NEMO_UPSTREAM_REPO:-https://img.nemomobile.net/manjaro/}\$repo/\$arch
REPOEOF
fi

if ! command -v buildarmimg >/dev/null 2>&1; then
  echo "WARNING: buildarmimg not installed in this container yet."
  echo "Packaging recipe + profile staging as CI artifact; install manjaro-arm-tools for full images."
  tar -C "$ROOT" -czf "$OUT_DIR/manjaro-nemo-pipa-profiles-${VERSION}.tar.gz" profiles scripts README.md Makefile
  # Non-zero would fail CI before packages exist; succeed with staged recipe while stack is bootstrapping
  if [[ "${CI_REQUIRE_IMAGE:-0}" == "1" ]]; then
    exit 1
  fi
  echo "CI_REQUIRE_IMAGE!=1 — uploaded profile recipe instead of .img"
  exit 0
fi

echo "==> buildarmimg -d $DEVICE -e $EDITION -v $VERSION -b $BRANCH"
buildarmimg -d "$DEVICE" -e "$EDITION" -v "$VERSION" -b "$BRANCH"

DEFAULT_IMG_DIR="/var/cache/manjaro-arm-tools/img"
if [[ -d "$DEFAULT_IMG_DIR" ]]; then
  cp -a "$DEFAULT_IMG_DIR"/*.img* "$OUT_DIR"/ 2>/dev/null || true
  cp -a "$DEFAULT_IMG_DIR"/*.zip "$OUT_DIR"/ 2>/dev/null || true
fi
ls -lah "$OUT_DIR"
