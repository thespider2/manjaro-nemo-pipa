#!/usr/bin/env bash
# Patch an existing nemo_rootfs.raw in place.
#
# IMAGE_MODE=full     (default) — Glacier UI + hardware enabled like PinePhone NEMO
# IMAGE_MODE=bringup            — console-only, mask UI/connman (USB SSH debug)
#
# Usage:
#   sudo ./scripts/patch-rootfs.sh [/path/to/nemo_rootfs.raw]
#   sudo IMAGE_MODE=bringup ./scripts/patch-rootfs.sh ...
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS_IMG="${1:-/home/ayman/Downloads/nemo-pipa-flashable/nemo_rootfs.raw}"
IMAGE_MODE="${IMAGE_MODE:-full}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root" >&2
  exit 1
fi
if [ ! -f "$ROOTFS_IMG" ]; then
  echo "Missing $ROOTFS_IMG" >&2
  exit 1
fi

MNT=$(mktemp -d)
cleanup() {
  sync
  umount "$MNT" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Mounting $ROOTFS_IMG (mode=$IMAGE_MODE) ==="
mount -o loop "$ROOTFS_IMG" "$MNT"

export ROOTFS_DIR="$MNT"
"$REPO_ROOT/scripts/configure-nemo-session.sh"
"$REPO_ROOT/scripts/configure-pipa-hardware.sh"

if [[ "${INJECT_FULL_PACKAGES:-0}" == "1" ]]; then
  ROOTFS_DIR="$MNT" "$REPO_ROOT/scripts/inject-full-packages.sh"
fi

echo "=== USB RNDIS + SSH ==="
install -Dm755 "$REPO_ROOT/scripts/usb-rndis-gadget.sh" "$MNT/usr/bin/usb-rndis-gadget.sh"
install -Dm644 "$REPO_ROOT/sparse/usr/lib/systemd/system/usb-rndis.service" \
  "$MNT/usr/lib/systemd/system/usb-rndis.service"
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" "$MNT/etc/modules-load.d"
ln -sfn /usr/lib/systemd/system/usb-rndis.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/usb-rndis.service"
cat > "$MNT/etc/modules-load.d/usb-gadget.conf" <<'EOF'
libcomposite
usb_f_rndis
EOF

if [ -f "$MNT/usr/lib/systemd/system/sshd.service" ]; then
  ln -sfn /usr/lib/systemd/system/sshd.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/sshd.service"
elif [ -f "$MNT/usr/lib/systemd/system/ssh.service" ]; then
  ln -sfn /usr/lib/systemd/system/ssh.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/ssh.service"
fi
if [ -f "$MNT/etc/ssh/sshd_config" ]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$MNT/etc/ssh/sshd_config"
  grep -q '^PermitRootLogin' "$MNT/etc/ssh/sshd_config" \
    || echo 'PermitRootLogin yes' >> "$MNT/etc/ssh/sshd_config"
fi

# ConnMan: keep for Glacier WiFi UI; never block boot on online
ln -sfn /dev/null "$MNT/etc/systemd/system/connman-wait-online.service"
ln -sfn /dev/null "$MNT/etc/systemd/system/firewalld.service"
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/firewalld.service"
# DSME reboot-loops on pipa (RTC errors)
ln -sfn /dev/null "$MNT/etc/systemd/system/dsme.service"

if [ -f "$MNT/etc/sysconfig/network/ifcfg-eth0" ]; then
  sed -i "s/^STARTMODE=.*/STARTMODE='off'/" "$MNT/etc/sysconfig/network/ifcfg-eth0" \
    || echo "STARTMODE='off'" >> "$MNT/etc/sysconfig/network/ifcfg-eth0"
fi
mkdir -p "$MNT/etc/connman"
if ! grep -q 'NetworkInterfaceBlacklist' "$MNT/etc/connman/main.conf" 2>/dev/null; then
  cat >> "$MNT/etc/connman/main.conf" <<'EOF'

[General]
NetworkInterfaceBlacklist=usb0,rndis0,docker0,veth0,virbr0,ifb0
EOF
fi

case "$IMAGE_MODE" in
  bringup)
    echo "=== BRINGUP: console only, UI masked ==="
    ln -sfn /usr/lib/systemd/system/multi-user.target "$MNT/etc/systemd/system/default.target"
    ln -sfn /dev/null "$MNT/etc/systemd/system/glacier-session.service"
    ln -sfn /dev/null "$MNT/etc/systemd/system/mce.service"
    ln -sfn /dev/null "$MNT/etc/systemd/system/connman.service"
    rm -f "$MNT/etc/systemd/system/graphical.target.wants/glacier-session.service"
    ;;
  full|*)
    echo "=== FULL: graphical.target + Lipstick + hardware ==="
    ln -sfn /usr/lib/systemd/system/graphical.target "$MNT/etc/systemd/system/default.target"
    rm -f "$MNT/etc/systemd/system/glacier-session.service"  # clear bringup mask if any
    rm -f "$MNT/etc/systemd/system/mce.service" "$MNT/etc/systemd/system/connman.service"
    ln -sfn /usr/lib/systemd/system/glacier-session.service \
      "$MNT/etc/systemd/system/graphical.target.wants/glacier-session.service"
    if [ -f "$MNT/usr/lib/systemd/system/mce.service" ]; then
      ln -sfn /usr/lib/systemd/system/mce.service \
        "$MNT/etc/systemd/system/multi-user.target.wants/mce.service"
    fi
    if [ -f "$MNT/usr/lib/systemd/system/connman.service" ]; then
      ln -sfn /usr/lib/systemd/system/connman.service \
        "$MNT/etc/systemd/system/multi-user.target.wants/connman.service"
    fi
    ;;
esac

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo
echo "Patched ($IMAGE_MODE): $ROOTFS_IMG"
echo "Flash:   fastboot flash userdata $ROOTFS_IMG"
echo "SSH:     ssh root@172.16.42.1  (linux)   ssh nemo@172.16.42.1  (1234)"
