#!/usr/bin/env bash
# Connect a laptop to Nemo pipa over USB RNDIS without NetworkManager hanging.
# Usage: sudo ./scripts/laptop-rndis-connect.sh [iface]
set -euo pipefail

TABLET_IP="${TABLET_IP:-172.16.42.1}"
LAPTOP_IP="${LAPTOP_IP:-172.16.42.2}"
PREFIX="${PREFIX:-24}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

pick_iface() {
  local d state rest devpath
  while read -r d state rest; do
    case "$d" in
      lo|wlan*|wlp*|wl*|br*|docker*|virbr*|veth*) continue ;;
    esac
    # USB RNDIS often reports operstate UNKNOWN even when LOWER_UP is set.
    devpath="$(readlink -f "/sys/class/net/$d/device" 2>/dev/null || true)"
    if [ -n "$devpath" ] && [[ "$devpath" == *"/usb"* ]]; then
      echo "$d"
      return 0
    fi
  done < <(ip -br link)

  # Host-side MAC from usb-rndis-gadget.sh
  ip -br link | awk '$3 == "02:00:00:00:00:02" {print $1; exit}'

  # systemd USB NIC names: enpXsYfZuW
  ip -br link | awk '$1 ~ /^enp.*u[0-9]+$/ {print $1; exit}'
}

IFACE="${1:-$(pick_iface || true)}"
if [ -z "${IFACE:-}" ]; then
  echo "Could not detect USB RNDIS interface. Plug in the tablet, then:" >&2
  echo "  ip -br link" >&2
  echo "  sudo $0 <iface>" >&2
  exit 1
fi

echo "Using interface: $IFACE"

if command -v nmcli >/dev/null 2>&1; then
  echo "Telling NetworkManager to stop managing $IFACE (prevents DHCP hang)..."
  nmcli dev set "$IFACE" managed no 2>/dev/null || true
  nmcli dev disconnect "$IFACE" 2>/dev/null || true
fi

ip link set "$IFACE" up
ip addr flush dev "$IFACE" 2>/dev/null || true
ip addr add "${LAPTOP_IP}/${PREFIX}" dev "$IFACE"

echo "Laptop ${LAPTOP_IP}/${PREFIX}  ->  tablet ${TABLET_IP}"
ping -c 2 -W 2 "$TABLET_IP" || echo "WARN: ping failed (SSH may still work)"

echo
echo "SSH:  ssh root@${TABLET_IP}    # password: linux"
echo "      ssh nemo@${TABLET_IP}    # password: 1234"
echo
echo "To re-enable NetworkManager later:  nmcli dev set $IFACE managed yes"
