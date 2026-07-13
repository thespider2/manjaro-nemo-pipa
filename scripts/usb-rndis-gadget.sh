#!/bin/bash
# Mainline configfs USB RNDIS for Xiaomi Pad 6 (pipa / SM8250).
# Device: 172.16.42.1/24 — laptop: sudo ip addr add 172.16.42.2/24 dev <usb>
set -uo pipefail

USB_IDVENDOR="18D1"
USB_IDPRODUCT="D001"
USB_IPRODUCT="Nemo Pipa"
USB_ISERIAL="nemo-pipa"
USB_IMANUFACTURER="NemoMobile"
LOCAL_IP="172.16.42.1"
GADGET_DIR="/sys/kernel/config/usb_gadget"
GADGET="${GADGET_DIR}/g1"

write() {
  echo -n "$2" > "$1"
}

force_device_role() {
  # SM8250 often boots DWC3 in host mode → empty /sys/class/udc until switched.
  local f
  for f in /sys/class/usb_role/*/role; do
    [ -e "$f" ] || continue
    echo "Setting usb_role $(dirname "$f") -> device (was: $(cat "$f" 2>/dev/null || true))"
    echo device > "$f" 2>/dev/null || echo peripheral > "$f" 2>/dev/null || true
  done
  for f in /sys/devices/platform/*/dwc3/*/mode \
           /sys/devices/platform/*/*/dwc3/*/mode \
           /sys/kernel/debug/usb/*.dwc3/mode \
           /sys/kernel/debug/*/dwc3/mode; do
    [ -e "$f" ] || continue
    echo "Setting dwc3 mode $f -> device (was: $(cat "$f" 2>/dev/null || true))"
    echo device > "$f" 2>/dev/null || echo peripheral > "$f" 2>/dev/null || true
  done
  # Also try common SM8250 controller paths
  for f in /sys/devices/platform/soc@0/a600000.usb/usb_role/a600000.usb-role-switch/role \
           /sys/devices/platform/soc/a600000.usb/usb_role/a600000.usb-role-switch/role \
           /sys/bus/platform/devices/a600000.usb/usb_role/*/role; do
    [ -e "$f" ] || continue
    echo device > "$f" 2>/dev/null || true
  done
}

wait_for_udc() {
  local i udc
  for i in $(seq 1 40); do
    udc="$(ls -1 /sys/class/udc 2>/dev/null | head -n1 || true)"
    if [ -n "$udc" ]; then
      echo "$udc"
      return 0
    fi
    # re-assert role a few times while waiting
    if [ $((i % 5)) -eq 0 ]; then
      force_device_role
    fi
    sleep 0.25
  done
  return 1
}

cleanup_gadget() {
  if [ -d "$GADGET" ]; then
    echo "" > "$GADGET/UDC" 2>/dev/null || true
    find "$GADGET/configs" -type l -delete 2>/dev/null || true
    rmdir "$GADGET"/configs/c.1/strings/* 2>/dev/null || true
    rmdir "$GADGET"/configs/* 2>/dev/null || true
    rmdir "$GADGET"/functions/* 2>/dev/null || true
    rmdir "$GADGET"/strings/* 2>/dev/null || true
    rmdir "$GADGET" 2>/dev/null || true
  fi
}

mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
modprobe libcomposite 2>/dev/null || true
modprobe usb_f_rndis 2>/dev/null || true
modprobe usb_f_ecm 2>/dev/null || true

echo "=== Forcing USB controller into device mode ==="
force_device_role

echo "=== Waiting for UDC ==="
UDC="$(wait_for_udc || true)"
if [ -z "${UDC:-}" ]; then
  echo "WARN: no UDC under /sys/class/udc after role switch (USB gadget skipped)" >&2
  echo "--- debug ---" >&2
  ls -la /sys/class/udc 2>&1 || true
  ls -la /sys/class/usb_role 2>&1 || true
  find /sys/class/usb_role /sys/devices/platform -name role 2>/dev/null | head -20 || true
  find /sys -path '*dwc3*/mode' 2>/dev/null | head -20 || true
  dmesg | grep -iE 'dwc3|udc|gadget|usb.role' | tail -30 || true
  exit 0
fi
echo "Using UDC: $UDC"

cleanup_gadget
mkdir -p "$GADGET"
write "$GADGET/idVendor"  "0x$USB_IDVENDOR"
write "$GADGET/idProduct" "0x$USB_IDPRODUCT"
write "$GADGET/bcdDevice" "0x0100"
write "$GADGET/bcdUSB"    "0x0200"
mkdir -p "$GADGET/strings/0x409"
write "$GADGET/strings/0x409/serialnumber" "$USB_ISERIAL"
write "$GADGET/strings/0x409/manufacturer" "$USB_IMANUFACTURER"
write "$GADGET/strings/0x409/product"      "$USB_IPRODUCT"

mkdir -p "$GADGET/functions/rndis.usb0"
write "$GADGET/functions/rndis.usb0/dev_addr" "02:00:00:00:00:01" 2>/dev/null || true
write "$GADGET/functions/rndis.usb0/host_addr" "02:00:00:00:00:02" 2>/dev/null || true

mkdir -p "$GADGET/configs/c.1/strings/0x409"
write "$GADGET/configs/c.1/strings/0x409/configuration" "rndis"
write "$GADGET/configs/c.1/bmAttributes" "0x80"
write "$GADGET/configs/c.1/MaxPower" "250"
ln -sf "$GADGET/functions/rndis.usb0" "$GADGET/configs/c.1/"

write "$GADGET/UDC" "$UDC"

USB_IFACE=""
for _ in $(seq 1 40); do
  for cand in usb0 rndis0; do
    if [ -d "/sys/class/net/$cand" ]; then
      USB_IFACE=$cand
      break 2
    fi
  done
  sleep 0.25
done

if [ -z "$USB_IFACE" ]; then
  echo "WARN: RNDIS netdev did not appear" >&2
  ip link || true
  exit 0
fi

ip link set "$USB_IFACE" up
ip addr flush dev "$USB_IFACE" 2>/dev/null || true
ip addr add "${LOCAL_IP}/24" dev "$USB_IFACE" 2>/dev/null \
  || ifconfig "$USB_IFACE" "$LOCAL_IP" netmask 255.255.255.0 up

# Offer DHCP so laptop NetworkManager does not hang waiting for an address.
if command -v dnsmasq >/dev/null 2>&1; then
  RUN_DIR="/run/usb-rndis"
  mkdir -p "$RUN_DIR"
  cat > "$RUN_DIR/dnsmasq.conf" <<EOF
interface=${USB_IFACE}
bind-dynamic
dhcp-range=172.16.42.2,172.16.42.2,255.255.255.0,infinite
dhcp-option=3,${LOCAL_IP}
dhcp-option=6,${LOCAL_IP}
no-hosts
no-resolv
EOF
  if [ -f "$RUN_DIR/dnsmasq.pid" ]; then
    kill "$(cat "$RUN_DIR/dnsmasq.pid")" 2>/dev/null || true
  fi
  dnsmasq -C "$RUN_DIR/dnsmasq.conf" --pid-file="$RUN_DIR/dnsmasq.pid" \
    && echo "DHCP server on ${USB_IFACE} -> 172.16.42.2/24"
fi

echo "USB RNDIS ready on $USB_IFACE $LOCAL_IP/24 (UDC=$UDC)"
echo "On laptop: sudo ./scripts/laptop-rndis-connect.sh   # or manual ip addr add 172.16.42.2/24"
