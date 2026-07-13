#!/usr/bin/env bash
# Enable pipa hardware services and fix Arch-pkgs-on-openSUSE library paths.
# Called from post-process-pipa.sh / configure-nemo-session.sh with ROOTFS_DIR set.
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:?}"

echo "=== Pipa hardware configuration ==="

# pipa-pkgs (Arch) install shared libs under /usr/lib; openSUSE ldconfig only scans /usr/lib64.
install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/ld.so.conf.d/pipa-arch-libs.conf" <<'EOF'
/usr/lib
EOF

# nemo-device-pipa sparse (pulse, sensors, camera) — sibling repo if present
DEVICE_SPARSE="${DEVICE_SPARSE:-/home/ayman/nemo-pipa-packaging/device/nemo-device-pipa/sparse}"
if [ -d "$DEVICE_SPARSE" ]; then
  rsync -a "$DEVICE_SPARSE"/ "$ROOTFS_DIR"/
fi

# Ensure pulse uses pipa ALSA UCM profile when pulseaudio is installed
if [ -f "$ROOTFS_DIR/etc/sysconfig/pulseaudio" ]; then
  sed -i 's|^CONFIG=.*|CONFIG="-n --file=/etc/pulse/pipa_nemo.pa"|' \
    "$ROOTFS_DIR/etc/sysconfig/pulseaudio" 2>/dev/null || true
fi

enable_svc() {
  local svc="$1"
  if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/$svc" ]; then
    mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
    ln -sfn "/usr/lib/systemd/system/$svc" \
      "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/$svc"
  fi
}

# Qualcomm / pipa bring-up order (see profiles/services/nemomobile)
for svc in \
  pd-mapper.service \
  tqftpserv.service \
  rmtfs.service \
  pipa-sensors-persist.service \
  bootmac-bluetooth.service \
  hexagonrpcd-sdsp.service \
  hexagonrpcd-adsp-rootpd.service \
  pipa-audio-init.service \
  pipa-speaker-route.service \
  cameras_setup.service \
  bluetooth.service \
  connman.service \
  systemd-timesyncd.service
do
  enable_svc "$svc"
done

# Maliit on-screen keyboard for Glacier apps
if [ -f "$ROOTFS_DIR/usr/lib64/systemd/user/maliit-server.service" ] \
  && [ ! -e "$ROOTFS_DIR/usr/lib/systemd/user/maliit-server.service" ]; then
  mkdir -p "$ROOTFS_DIR/usr/lib/systemd/user"
  ln -sfn /usr/lib64/systemd/user/maliit-server.service \
    "$ROOTFS_DIR/usr/lib/systemd/user/maliit-server.service"
fi
install -Dm644 "$(dirname "$0")/../sparse/etc/systemd/user/maliit-server.service.d/pipa.conf" \
  "$ROOTFS_DIR/etc/systemd/user/maliit-server.service.d/pipa.conf" 2>/dev/null || true
NEMO_USER="${NEMO_USER:-nemo}"
if [ -f "$ROOTFS_DIR/usr/lib/systemd/user/maliit-server.service" ] \
  || [ -f "$ROOTFS_DIR/usr/lib64/systemd/user/maliit-server.service" ]; then
  mkdir -p "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/user-session.target.wants"
  ln -sfn /usr/lib/systemd/user/maliit-server.service \
    "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/user-session.target.wants/maliit-server.service"
fi
mkdir -p "$ROOTFS_DIR/var/lib/environment/nemo"
printf 'QT_IM_MODULE=Maliit\n' > "$ROOTFS_DIR/var/lib/environment/nemo/60-pipa-im.conf"

# Camera / Browser / Music launchers (Glacier or openSUSE fallbacks)
install -Dm755 "$(dirname "$0")/../sparse/usr/bin/nemo-app-fallback" \
  "$ROOTFS_DIR/usr/bin/nemo-app-fallback" 2>/dev/null || true
for desk in glacier-camera glacier-browser glacier-music; do
  install -Dm644 "$(dirname "$0")/../sparse/usr/share/applications/${desk}.desktop" \
    "$ROOTFS_DIR/usr/share/applications/${desk}.desktop" 2>/dev/null || true
done
install -Dm644 "$(dirname "$0")/../sparse/etc/udev/rules.d/50-pipa-dmaheap.rules" \
  "$ROOTFS_DIR/etc/udev/rules.d/50-pipa-dmaheap.rules" 2>/dev/null || true
install -Dm644 "$(dirname "$0")/../sparse/etc/udev/rules.d/55-pipa-rtc.rules" \
  "$ROOTFS_DIR/etc/udev/rules.d/55-pipa-rtc.rules" 2>/dev/null || true

# iio-sensor-proxy is socket-activated on some images; ensure wanted link if static unit exists
if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/iio-sensor-proxy.service" ]; then
  enable_svc iio-sensor-proxy.service
fi

# rtc0 on pipa returns I/O errors; prefer rtc1
install -Dm644 "$(dirname "$0")/../sparse/etc/udev/rules.d/55-pipa-rtc.rules" \
  "$ROOTFS_DIR/etc/udev/rules.d/55-pipa-rtc.rules" 2>/dev/null || true

# Enable PulseAudio for the graphical user (Glacier)
NEMO_USER="${NEMO_USER:-nemo}"
if [ -f "$ROOTFS_DIR/usr/lib/systemd/user/pulseaudio.service" ]; then
  mkdir -p "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/default.target.wants"
  ln -sfn /usr/lib/systemd/user/pulseaudio.service \
    "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/default.target.wants/pulseaudio.service"
  ln -sfn /usr/lib/systemd/user/pulseaudio.socket \
    "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/default.target.wants/pulseaudio.socket" 2>/dev/null || true
fi

# OBS rootfs often ships libpulse but not the pulseaudio daemon or libssc deps
OBS_EXTRA_PKGS=(libqmi-glib5 libqrtr-glib0 libprotobuf-c1 libmbim-glib4 pulseaudio pulseaudio-utils connman-client)
if [ -f "$ROOTFS_DIR/usr/lib/rpm/rpm" ] || [ -d "$ROOTFS_DIR/var/lib/rpm" ]; then
  echo "  (OBS packages ${OBS_EXTRA_PKGS[*]} must be in rootfs build — install on live device if missing)"
fi

# Soften hexagonrpcd restart storms
install -Dm644 "$(dirname "$0")/../sparse/usr/lib/systemd/system/hexagonrpcd-sdsp.service.d/20-pipa-limits.conf" \
  "$ROOTFS_DIR/usr/lib/systemd/system/hexagonrpcd-sdsp.service.d/20-pipa-limits.conf" 2>/dev/null || true
install -Dm644 "$(dirname "$0")/../sparse/usr/lib/systemd/system/hexagonrpcd-sdsp.service.d/20-pipa-limits.conf" \
  "$ROOTFS_DIR/usr/lib/systemd/system/hexagonrpcd-adsp-rootpd.service.d/20-pipa-limits.conf" 2>/dev/null || true

# Ensure privileged group for mapplauncherd
if ! grep -q '^privileged:' "$ROOTFS_DIR/etc/group" 2>/dev/null; then
  echo 'privileged:x:490:nemo' >> "$ROOTFS_DIR/etc/group"
fi

echo "Pipa hardware units enabled; ld.so.conf.d/pipa-arch-libs.conf installed"
