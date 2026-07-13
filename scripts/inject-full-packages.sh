#!/usr/bin/env bash
# Inject full Glacier/OBS + openSUSE dependency RPMs into a pipa rootfs.
# Mirrors what PinePhone NEMO JeOS gets via patterns-nemomobile + zypper,
# plus openSUSE libs that Arch pipa-pkgs (libssc/hexagonrpc) need on openSUSE.
#
# Usage: ROOTFS_DIR=/path/to/rootfs ./inject-full-packages.sh
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:?}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${PKG_CACHE:-$REPO_ROOT/images/.cache/obs-rpms}"
OBS_BASE="${OBS_BASE:-https://download.opensuse.org/repositories/devel:/NemoMobile/openSUSE_Tumbleweed}"
TW_BASE="${TW_BASE:-https://download.opensuse.org/ports/aarch64/tumbleweed/repo/oss/aarch64}"
PIPA_REPO_URL="${PIPA_REPO_URL:-https://thespider2.github.io/pipa-pkgs/repo/}"

mkdir -p "$CACHE"

extract_rpm() {
  local rpm="$1"
  if command -v rpm2cpio >/dev/null 2>&1; then
    (cd "$ROOTFS_DIR" && rpm2cpio "$rpm" | cpio -idmu --quiet)
  elif command -v bsdtar >/dev/null 2>&1; then
    bsdtar -C "$ROOTFS_DIR" -xf "$rpm"
  else
    echo "ERROR: need rpm2cpio or bsdtar to extract $rpm" >&2
    return 1
  fi
}

# Resolve exact RPM filename from an HTML directory listing
resolve_obs() {
  local name="$1" arch="${2:-aarch64}"
  local index
  index=$(curl -fsSL "$OBS_BASE/$arch/" 2>/dev/null || true)
  printf '%s\n' "$index" | grep -oE "href=\"${name}-[0-9][^\"]+\.rpm\"" \
    | sed 's/href="//;s/"$//' | grep -v debug | grep -vE 'devel|tests|ts-devel|doc' \
    | sort -V | tail -n1
}

resolve_tw() {
  local name="$1"
  local index
  index=$(curl -fsSL "$TW_BASE/" 2>/dev/null || true)
  printf '%s\n' "$index" | grep -oE "href=\"${name}-[0-9][^\"]+\.rpm\"" \
    | sed 's/href="//;s/"$//' | sort -V | tail -n1
}

fetch_and_extract() {
  local url="$1" dest="$2"
  if [ ! -f "$dest" ]; then
    echo "  download $(basename "$dest")"
    curl -fL --retry 3 -o "$dest" "$url"
  fi
  echo "  extract $(basename "$dest")"
  extract_rpm "$dest" || true
}

echo "=== Injecting full Glacier / OBS apps ==="
# Apps + session extras from devel:NemoMobile (same family as PinePhone pattern + more)
OBS_PKGS=(
  glacier-alarmclock
  glacier-calc
  glacier-filemuncher
  glacier-gallery
  glacier-gallery-qmlplugin
  glacier-settings
  glacier-settings-developermode
  maliit-framework-qt6
  maliit-nemo-keyboard
  mapplauncherd
  mapplauncherd-qt6
  nemo-glacier-system-config
  nemo-qml-plugin-alarms-qt6
  nemo-qml-plugin-contacts-qt6
  qtcontacts-sqlite-qt6
  libglacierapp-examples
)

for pkg in "${OBS_PKGS[@]}"; do
  file=$(resolve_obs "$pkg" aarch64 || true)
  if [ -z "$file" ]; then
    file=$(resolve_obs "$pkg" noarch || true)
    if [ -n "$file" ]; then
      fetch_and_extract "$OBS_BASE/noarch/$file" "$CACHE/$file"
      continue
    fi
    echo "WARNING: OBS package not found: $pkg"
    continue
  fi
  fetch_and_extract "$OBS_BASE/aarch64/$file" "$CACHE/$file"
done

echo "=== Injecting openSUSE Tumbleweed runtime deps ==="
# Needed so PulseAudio + libssc + cam tools work on the openSUSE rootfs
TW_PKGS=(
  pulseaudio
  pulseaudio-utils
  pulseaudio-module-bluetooth
  connman-client
  libqmi-glib5
  libqrtr-glib0
  libprotobuf-c1
  libmbim-glib4
  libtdb1
  libspeexdsp1
  libwebrtc-audio-processing-1-3
  libfftw3-3
  libQt6OpenGLWidgets6
  libevent-2_1-7
  libtiff6
  libSDL2-2_0-0
  rtkit
)

for pkg in "${TW_PKGS[@]}"; do
  file=$(resolve_tw "$pkg" || true)
  if [ -z "$file" ]; then
    echo "WARNING: TW package not found: $pkg"
    continue
  fi
  fetch_and_extract "$TW_BASE/$file" "$CACHE/$file"
done

echo "=== Injecting pipa-pkgs camera tools (cam/qcam) ==="
PIPA_INDEX=$(curl -fsSL "$PIPA_REPO_URL" || true)
for pkg in libcamera-tools libcamera-ipa libcamera; do
  file=$(printf '%s\n' "$PIPA_INDEX" | grep -oE "href=\"${pkg}-[^\"]+\.pkg\.tar\.(xz|zst)\"" \
    | sed 's/href="//;s/"$//' | sort -V | tail -n1 || true)
  [ -n "$file" ] || continue
  dest="$CACHE/$file"
  if [ ! -f "$dest" ]; then
    curl -fL --retry 3 -o "$dest" "${PIPA_REPO_URL%/}/$file"
  fi
  echo "  extract $file"
  tar -C "$ROOTFS_DIR" -xf "$dest" --exclude='.PKGINFO' --exclude='.MTREE' \
    --exclude='.BUILDINFO' --exclude='.INSTALL' 2>/dev/null || tar -C "$ROOTFS_DIR" -xf "$dest"
done

# Ensure pulse user exists (RPM scripts may have been skipped)
if ! grep -q '^pulse:' "$ROOTFS_DIR/etc/passwd" 2>/dev/null; then
  echo 'pulse:x:468:468:PulseAudio:/var/run/pulse:/sbin/nologin' >> "$ROOTFS_DIR/etc/passwd"
fi
if ! grep -q '^pulse:' "$ROOTFS_DIR/etc/group" 2>/dev/null; then
  echo 'pulse:!:468:' >> "$ROOTFS_DIR/etc/group"
fi
if ! grep -q '^pulse-access:' "$ROOTFS_DIR/etc/group" 2>/dev/null; then
  echo 'pulse-access:!:469:' >> "$ROOTFS_DIR/etc/group"
fi
if ! grep -q '^privileged:' "$ROOTFS_DIR/etc/group" 2>/dev/null; then
  echo 'privileged:!:490:nemo' >> "$ROOTFS_DIR/etc/group"
fi

# Pulse config for pipa
mkdir -p "$ROOTFS_DIR/etc/sysconfig"
echo 'CONFIG="-n --file=/etc/pulse/pipa_nemo.pa"' > "$ROOTFS_DIR/etc/sysconfig/pulseaudio"

# ldconfig path for Arch libs
install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/ld.so.conf.d/pipa-arch-libs.conf" <<'EOF'
/usr/lib
EOF

echo "=== Full package injection done ==="
