#!/usr/bin/env bash
# Build missing Glacier apps (not in OBS) from nemomobile-ux git into ROOTFS_DIR.
# Prefer native aarch64 host (GitHub ubuntu-24.04-arm). Uses chroot + rootfs zypper/cmake.
#
# Apps: glacier-camera, glacier-music, glacier-browser
# Fallbacks are injected separately (qcam / amberol / angelfish).
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:?}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${GLACIER_SRC_CACHE:-$REPO_ROOT/images/.cache/glacier-src}"
BUILD_BROWSER="${BUILD_GLACIER_BROWSER:-1}"
BUILD_MUSIC="${BUILD_GLACIER_MUSIC:-1}"
BUILD_CAMERA="${BUILD_GLACIER_CAMERA:-1}"

mkdir -p "$CACHE"

if [[ "$(uname -m)" != "aarch64" ]]; then
  echo "WARNING: host is $(uname -m); glacier app build needs aarch64 (skipping)"
  exit 0
fi

need_bin() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
need_bin curl
need_bin git

mount_chroot() {
  mount --bind /proc "$ROOTFS_DIR/proc" 2>/dev/null || true
  mount --bind /sys "$ROOTFS_DIR/sys" 2>/dev/null || true
  mount --bind /dev "$ROOTFS_DIR/dev" 2>/dev/null || true
  mount --bind /dev/pts "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
  cp -a /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
}

umount_chroot() {
  umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
  umount "$ROOTFS_DIR/dev" 2>/dev/null || true
  umount "$ROOTFS_DIR/sys" 2>/dev/null || true
  umount "$ROOTFS_DIR/proc" 2>/dev/null || true
}
trap umount_chroot EXIT

clone_app() {
  local name="$1"
  local dest="$CACHE/$name"
  if [ ! -d "$dest/.git" ]; then
    git clone --depth 1 "https://github.com/nemomobile-ux/${name}.git" "$dest"
  else
    git -C "$dest" fetch --depth 1 origin HEAD && git -C "$dest" reset --hard FETCH_HEAD || true
  fi
  # Stage sources into rootfs build area
  rm -rf "$ROOTFS_DIR/tmp/build-$name"
  mkdir -p "$ROOTFS_DIR/tmp"
  cp -a "$dest" "$ROOTFS_DIR/tmp/build-$name"
}

ensure_obs_repo() {
  if [ ! -f "$ROOTFS_DIR/etc/zypp/repos.d/devel_NemoMobile.repo" ]; then
    cat > "$ROOTFS_DIR/etc/zypp/repos.d/devel_NemoMobile.repo" <<'EOF'
[devel_NemoMobile]
name=devel:NemoMobile
enabled=1
autorefresh=1
baseurl=https://download.opensuse.org/repositories/devel:/NemoMobile/openSUSE_Tumbleweed/
gpgcheck=0
EOF
  fi
}

echo "=== Building extra Glacier apps into rootfs ==="
mount_chroot
ensure_obs_repo

# Common build deps + per-app
chroot "$ROOTFS_DIR" /usr/bin/zypper --non-interactive --gpg-auto-import-keys ref 2>&1 | tail -5 || true
chroot "$ROOTFS_DIR" /usr/bin/zypper --non-interactive install -y --no-recommends \
  cmake gcc-c++ pkgconf-pkg-config git \
  libglacierapp-devel \
  qt6-base-devel qt6-declarative-devel qt6-tools \
  qt6-multimedia-devel qt6-multimedia-imports \
  libtag-devel \
  qtmpris-qt6-devel \
  2>&1 | tee /tmp/zypper-glacier-deps.log | tail -40 || true

if [[ "$BUILD_BROWSER" == "1" ]]; then
  chroot "$ROOTFS_DIR" /usr/bin/zypper --non-interactive install -y --no-recommends \
    qt6-webengine-devel qt6-webengine-imports \
    2>&1 | tee -a /tmp/zypper-glacier-deps.log | tail -20 || true
fi

build_one() {
  local name="$1"
  echo "--- build $name ---"
  clone_app "$name"
  if chroot "$ROOTFS_DIR" /bin/bash -lc "
    set -e
    cd /tmp/build-$name
    cmake -B build -S . -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j\"\$(nproc)\"
    cmake --install build
  " 2>&1 | tee "/tmp/build-$name.log" | tail -30; then
    echo "OK: $name installed"
    # Wrap desktop if present
    local desk
    for desk in "$ROOTFS_DIR"/usr/share/applications/${name}.desktop \
                "$ROOTFS_DIR"/usr/share/applications/*${name}*.desktop; do
      [ -f "$desk" ] || continue
      grep -q nemo-app-launch "$desk" && continue
      sed -i 's|^Exec=\(.*\)|Exec=/usr/bin/nemo-app-launch \1|' "$desk"
    done
  else
    echo "WARNING: failed to build $name (see /tmp/build-$name.log)"
    return 0
  fi
}

[[ "$BUILD_CAMERA" == "1" ]] && build_one glacier-camera
[[ "$BUILD_MUSIC" == "1" ]] && build_one glacier-music
[[ "$BUILD_BROWSER" == "1" ]] && build_one glacier-browser

# Cleanup build trees to keep rootfs smaller
rm -rf "$ROOTFS_DIR"/tmp/build-glacier-*

echo "=== Glacier extra apps build finished ==="
ls -la "$ROOTFS_DIR"/usr/bin/glacier-camera \
       "$ROOTFS_DIR"/usr/bin/glacier-music \
       "$ROOTFS_DIR"/usr/bin/glacier-browser 2>/dev/null || true
