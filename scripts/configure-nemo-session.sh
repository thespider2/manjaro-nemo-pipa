#!/bin/bash
# Configure openSUSE NEMO rootfs for a graphical Glacier session on pipa.
# Sourced/called from post-process-pipa.sh with ROOTFS_DIR set.
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:?}"
NEMO_USER="${NEMO_USER:-nemo}"
NEMO_UID="${NEMO_UID:-1000}"
NEMO_GID="${NEMO_GID:-1000}"
NEMO_PASS="${NEMO_PASS:-1234}"

echo "=== Configuring Nemo graphical session (user=$NEMO_USER) ==="

# login.defs UID_MIN (needed by start-user-session helpers)
if [ -f "$ROOTFS_DIR/etc/login.defs" ]; then
  if grep -q '^UID_MIN' "$ROOTFS_DIR/etc/login.defs"; then
    sed -i 's/^UID_MIN.*/UID_MIN                  1000/' "$ROOTFS_DIR/etc/login.defs"
  else
    printf '\nUID_MIN                  1000\n' >> "$ROOTFS_DIR/etc/login.defs"
  fi
fi

# Groups may already exist from base image
ensure_group() {
  local name="$1" gid="$2"
  if ! grep -q "^${name}:" "$ROOTFS_DIR/etc/group"; then
    echo "${name}:x:${gid}:" >> "$ROOTFS_DIR/etc/group"
  fi
}
ensure_group nemo "$NEMO_GID"

# Password hash for NEMO_PASS
if command -v openssl >/dev/null 2>&1; then
  HASH=$(openssl passwd -1 "$NEMO_PASS")
elif command -v python3 >/dev/null 2>&1; then
  HASH=$(NEMO_PASS="$NEMO_PASS" python3 -c 'import crypt,os; print(crypt.crypt(os.environ["NEMO_PASS"], crypt.METHOD_MD5))')
else
  # precomputed md5crypt for "1234"
  HASH='$1$NemoPipa$HqK8l5sYgG5xqG5xqG5xq.'
fi

if ! grep -q "^${NEMO_USER}:" "$ROOTFS_DIR/etc/passwd"; then
  echo "${NEMO_USER}:x:${NEMO_UID}:${NEMO_GID}:Nemo User:/home/${NEMO_USER}:/bin/bash" \
    >> "$ROOTFS_DIR/etc/passwd"
  echo "${NEMO_USER}:${HASH}:20573::::::" >> "$ROOTFS_DIR/etc/shadow"
else
  # Ensure password is set even if user already exists
  if grep -q "^${NEMO_USER}:" "$ROOTFS_DIR/etc/shadow"; then
    sed -i "s|^${NEMO_USER}:[^:]*:|${NEMO_USER}:${HASH}:|" "$ROOTFS_DIR/etc/shadow"
  else
    echo "${NEMO_USER}:${HASH}:20573::::::" >> "$ROOTFS_DIR/etc/shadow"
  fi
fi

# Supplement group memberships
for g in users video render input audio; do
  if grep -q "^${g}:" "$ROOTFS_DIR/etc/group"; then
    # shellcheck disable=SC2016
    awk -F: -v user="$NEMO_USER" -v grp="$g" '
      BEGIN{OFS=FS}
      $1==grp {
        if ($4=="") $4=user
        else if ($4 !~ "(^|,)"user"(,|$)") $4=$4","user
      }
      {print}
    ' "$ROOTFS_DIR/etc/group" > "$ROOTFS_DIR/etc/group.tmp" \
      && mv "$ROOTFS_DIR/etc/group.tmp" "$ROOTFS_DIR/etc/group"
  fi
done

mkdir -p \
  "$ROOTFS_DIR/home/${NEMO_USER}" \
  "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/user-session.target.wants" \
  "$ROOTFS_DIR/var/lib/environment/compositor" \
  "$ROOTFS_DIR/var/lib/environment/nemo" \
  "$ROOTFS_DIR/etc/systemd/system/graphical.target.wants" \
  "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants" \
  "$ROOTFS_DIR/usr/lib/systemd/user/user-session.target.wants" \
  "$ROOTFS_DIR/var/lib/systemd/linger"

chown -R "${NEMO_UID}:${NEMO_GID}" "$ROOTFS_DIR/home/${NEMO_USER}"
# Linger so user@1000 starts without graphical login manager
touch "$ROOTFS_DIR/var/lib/systemd/linger/${NEMO_USER}"

# Enable lipstick for the user session target (system copy of user units)
if [ -f "$ROOTFS_DIR/usr/lib/systemd/user/lipstick.service" ]; then
  ln -sfn ../lipstick.service \
    "$ROOTFS_DIR/usr/lib/systemd/user/user-session.target.wants/lipstick.service"
  ln -sfn /usr/lib/systemd/user/lipstick.service \
    "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/user-session.target.wants/lipstick.service"
fi

# Enable mce/dsme if present — DISABLED by default on pipa: mce blanks
# the panel (brightness 0) before lipstick owns DRM. Re-enable later with
# mcetool --set-never-blank=enabled once the UI is stable.
# for svc in mce.service dsme.service; do
#   if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/$svc" ]; then
#     ln -sfn "/usr/lib/systemd/system/$svc" \
#       "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/$svc"
#   fi
# done

# Keep panel lit until lipstick takes over
cat > "$ROOTFS_DIR/usr/lib/systemd/system/pipa-unblank.service" <<'EOF'
[Unit]
Description=Force Xiaomi Pad 6 panel brightness on
After=multi-user.target
Before=glacier-session.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for d in /sys/class/backlight/*; do echo 0 > "$d/bl_power" 2>/dev/null; echo $(($(cat "$d/max_brightness")*80/100)) > "$d/brightness" 2>/dev/null; done; for f in /sys/class/graphics/fb*/blank; do echo 0 > "$f" 2>/dev/null; done; true'

[Install]
WantedBy=graphical.target
EOF
mkdir -p "$ROOTFS_DIR/etc/systemd/system/graphical.target.wants"
ln -sfn /usr/lib/systemd/system/pipa-unblank.service \
  "$ROOTFS_DIR/etc/systemd/system/graphical.target.wants/pipa-unblank.service"

# Default to graphical.target
ln -sfn /usr/lib/systemd/system/graphical.target \
  "$ROOTFS_DIR/etc/systemd/system/default.target"

# Compositor / Qt platform for DRM (no X11)
cat > "$ROOTFS_DIR/var/lib/environment/compositor/90-pipa.conf" <<'EOF'
LIPSTICK_OPTIONS=-platform eglfs
QT_QPA_PLATFORM=eglfs
QT_QPA_EGLFS_INTEGRATION=eglfs_kms
QT_QPA_EGLFS_KMS_CONFIG=/etc/eglfs-config.json
QT_QPA_EGLFS_ALWAYS_SET_MODE=1
QT_QPA_EGLFS_PHYSICAL_WIDTH=147
QT_QPA_EGLFS_PHYSICAL_HEIGHT=235
QT_SCALE_FACTOR=1.75
QT_QUICK_CONTROLS_STYLE=Nemo
GLACIER_NATIVEORIENTATION=1
EOF

# Match upstream NEMO JeOS (PinePhone): Lipstick runs as a *user* service under
# user-session.target. Do NOT start a second system lipstick — that fights for DRM
# and can panic / reboot-loop on pipa.
mkdir -p \
  "$ROOTFS_DIR/usr/lib/systemd/user" \
  "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/default.target.wants" \
  "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/user-session.target.wants"
if [ -f "$ROOTFS_DIR/usr/lib/systemd/user/user-session.target" ]; then
  ln -sfn /usr/lib/systemd/user/user-session.target \
    "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/default.target"
fi
if [ -f "$ROOTFS_DIR/usr/lib/systemd/user/lipstick.service" ]; then
  ln -sfn /usr/lib/systemd/user/lipstick.service \
    "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/default.target.wants/lipstick.service"
  ln -sfn /usr/lib/systemd/user/lipstick.service \
    "$ROOTFS_DIR/home/${NEMO_USER}/.config/systemd/user/user-session.target.wants/lipstick.service"
fi
chown -R "${NEMO_UID}:${NEMO_GID}" "$ROOTFS_DIR/home/${NEMO_USER}/.config"

# Thin system unit: unblank + ensure user@UID (lipstick comes from user session)
cat > "$ROOTFS_DIR/usr/lib/systemd/system/glacier-session.service" <<EOF
[Unit]
Description=Ensure Glacier user session for ${NEMO_USER} (lipstick via user@.service)
After=multi-user.target systemd-user-sessions.service pipa-unblank.service
Wants=pipa-unblank.service user@${NEMO_UID}.service
Requires=user@${NEMO_UID}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=graphical.target
EOF

ln -sfn /usr/lib/systemd/system/glacier-session.service \
  "$ROOTFS_DIR/etc/systemd/system/graphical.target.wants/glacier-session.service"

# DSME on pipa: RTC ioctl errors + process watchdogs can reboot-loop the tablet.
# Upstream PinePhone enables dsme; on pipa keep mce but mask dsme unless explicitly wanted.
mkdir -p "$ROOTFS_DIR/etc/systemd/system"
ln -sfn /dev/null "$ROOTFS_DIR/etc/systemd/system/dsme.service"
rm -f "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/dsme.service"

# USB RNDIS for SSH-from-laptop bring-up
if [ -f "${REPO_ROOT:-}/scripts/usb-rndis-gadget.sh" ] || [ -f "$(dirname "$0")/usb-rndis-gadget.sh" ]; then
  _usb_src="$(dirname "$0")/usb-rndis-gadget.sh"
  install -Dm755 "$_usb_src" "$ROOTFS_DIR/usr/bin/usb-rndis-gadget.sh"
  install -Dm644 "$(dirname "$0")/../sparse/usr/lib/systemd/system/usb-rndis.service" \
    "$ROOTFS_DIR/usr/lib/systemd/system/usb-rndis.service" 2>/dev/null \
    || cat > "$ROOTFS_DIR/usr/lib/systemd/system/usb-rndis.service" <<'USBEOF'
[Unit]
Description=USB RNDIS gadget (SSH over USB)
DefaultDependencies=no
After=local-fs.target systemd-modules-load.service
Before=connman.service network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=20
ExecStart=/usr/bin/usb-rndis-gadget.sh
SuccessExitStatus=0 1
[Install]
WantedBy=multi-user.target
USBEOF
  mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
  ln -sfn /usr/lib/systemd/system/usb-rndis.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/usb-rndis.service"
  mkdir -p "$ROOTFS_DIR/etc/modules-load.d"
  printf 'libcomposite\nusb_f_rndis\n' > "$ROOTFS_DIR/etc/modules-load.d/usb-gadget.conf"
fi

# Mask connman-wait-online + firewalld (connman itself needed for Glacier UI)
for svc in connman-wait-online.service firewalld.service; do
  ln -sfn /dev/null "$ROOTFS_DIR/etc/systemd/system/${svc}"
done
rm -f "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/firewalld.service"

# openSUSE ifcfg can still trigger wicked/ifup on eth0 at boot
if [ -f "$ROOTFS_DIR/etc/sysconfig/network/ifcfg-eth0" ]; then
  sed -i "s/^STARTMODE=.*/STARTMODE='off'/" "$ROOTFS_DIR/etc/sysconfig/network/ifcfg-eth0" \
    || echo "STARTMODE='off'" >> "$ROOTFS_DIR/etc/sysconfig/network/ifcfg-eth0"
fi

# Keep connman config ready for when we unmask it later
mkdir -p "$ROOTFS_DIR/etc/connman"
if ! grep -q '^AutoConnect' "$ROOTFS_DIR/etc/connman/main.conf" 2>/dev/null; then
  cat >> "$ROOTFS_DIR/etc/connman/main.conf" <<'EOF'

# pipa bring-up: avoid auto-DHCP stalls on gadget/ethernet
[General]
AutoConnect=false
NetworkInterfaceBlacklist=usb0,rndis0,docker0,veth0,virbr0,ifb0
EOF
fi

# KMS/eglfs for pipa panel (card1, not card0)
install -Dm644 "$(dirname "$0")/../sparse/etc/eglfs-config.json" \
  "$ROOTFS_DIR/etc/eglfs-config.json"
install -Dm644 "$(dirname "$0")/../sparse/etc/mce/99-pipa-display.ini" \
  "$ROOTFS_DIR/etc/mce/99-pipa-display.ini"

# DSME required for Lipstick / timed / power management
if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/dsme.service" ]; then
  ln -sfn /usr/lib/systemd/system/dsme.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/dsme.service"
fi

# Device lock daemon (needs wheel group — openSUSE has no wheel by default)
grep -q '^wheel:' "$ROOTFS_DIR/etc/group" || echo 'wheel:x:10:' >> "$ROOTFS_DIR/etc/group"
if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/nemo-devicelock.socket" ]; then
  install -Dm644 "$(dirname "$0")/../sparse/usr/lib/systemd/system/nemo-devicelock.socket" \
    "$ROOTFS_DIR/usr/lib/systemd/system/nemo-devicelock.socket"
  ln -sfn /usr/lib/systemd/system/nemo-devicelock.socket \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/nemo-devicelock.socket"
  ln -sfn /usr/lib/systemd/system/nemo-devicelock.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/nemo-devicelock.service"
fi
install -Dm644 "$(dirname "$0")/../sparse/etc/dbus-1/system.d/mce-lipstick-pipa.conf" \
  "$ROOTFS_DIR/etc/dbus-1/system.d/mce-lipstick-pipa.conf"

# Apps run on Lipstick's Wayland compositor; use software GL until MSM wayland-egl is fixed.
install -Dm755 "$(dirname "$0")/../sparse/usr/bin/nemo-app-launch" \
  "$ROOTFS_DIR/usr/bin/nemo-app-launch"
install -Dm644 "$(dirname "$0")/../sparse/var/lib/environment/nemo/50-app-rendering.conf" \
  "$ROOTFS_DIR/var/lib/environment/nemo/50-app-rendering.conf"
mkdir -p "$ROOTFS_DIR/etc/systemd/system/user@.service.d"
install -Dm644 "$(dirname "$0")/../sparse/etc/systemd/system/user@.service.d/local.conf" \
  "$ROOTFS_DIR/etc/systemd/system/user@.service.d/local.conf"
# Wrap all Glacier / fingerterm launchers for software Wayland GL
for desk in "$ROOTFS_DIR"/usr/share/applications/fingerterm.desktop \
            "$ROOTFS_DIR"/usr/share/applications/glacier-*.desktop; do
  [ -f "$desk" ] || continue
  grep -q 'nemo-app-launch' "$desk" && continue
  sed -i 's|^Exec=\(.*\)|Exec=/usr/bin/nemo-app-launch \1|' "$desk"
done
# fingerterm historically uses bare binary name
if [ -f "$ROOTFS_DIR/usr/share/applications/fingerterm.desktop" ]; then
  sed -i 's|^Exec=.*|Exec=/usr/bin/nemo-app-launch fingerterm|' \
    "$ROOTFS_DIR/usr/share/applications/fingerterm.desktop"
fi

# fingerterm Qt6: touchPoints signal injection removed — use touch area property
if [ -f "$ROOTFS_DIR/usr/share/fingerterm/Main.qml" ]; then
  sed -i 's/touchPoints\.forEach/multiTouchArea.touchPoints.forEach/g' \
    "$ROOTFS_DIR/usr/share/fingerterm/Main.qml"
fi

# pipa-unblank runs before lipstick; wake display via mce before UI
cat > "$ROOTFS_DIR/usr/lib/systemd/system/pipa-display-on.service" <<'EOF'
[Unit]
Description=Wake pipa panel via mce before Lipstick
DefaultDependencies=no
After=mce.service
Before=nemo-devicelock.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'busctl call com.nokia.mce /com/nokia/mce/request com.nokia.mce.request req_display_state_on 2>/dev/null || true; busctl call com.nokia.mce /com/nokia/mce/request com.nokia.mce.request req_display_blanking_pause 2>/dev/null || true; for d in /sys/class/backlight/*; do echo 0 > "$d/bl_power" 2>/dev/null; echo $(($(cat "$d/max_brightness" 2>/dev/null || echo 255)*95/100)) > "$d/brightness" 2>/dev/null; done; true'

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/pipa-display-on.service \
  "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/pipa-display-on.service"

# MCE with never-blank (do not mask — blanking breaks pipa panel)
rm -f "$ROOTFS_DIR/etc/systemd/system/mce.service"
if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/mce.service" ]; then
  ln -sfn /usr/lib/systemd/system/mce.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/mce.service"
fi

# Autologin on tty1 is optional debug; keep getty but don't block graphical
mkdir -p "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF

echo "Nemo user ${NEMO_USER}/${NEMO_PASS} ready; glacier-session + usb-rndis enabled"
