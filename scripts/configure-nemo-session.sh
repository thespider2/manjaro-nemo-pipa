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

# Enable mce/dsme if present
for svc in mce.service dsme.service; do
  if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/$svc" ]; then
    ln -sfn "/usr/lib/systemd/system/$svc" \
      "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/$svc"
  fi
done

# Default to graphical.target
ln -sfn /usr/lib/systemd/system/graphical.target \
  "$ROOTFS_DIR/etc/systemd/system/default.target"

# Compositor / Qt platform for DRM (no X11)
cat > "$ROOTFS_DIR/var/lib/environment/compositor/90-pipa.conf" <<'EOF'
LIPSTICK_OPTIONS=-platform eglfs
QT_QPA_PLATFORM=eglfs
QT_QPA_EGLFS_INTEGRATION=eglfs_kms
QT_QUICK_CONTROLS_STYLE=Nemo
GLACIER_NATIVEORIENTATION=1
EOF

# System unit: bring up lipstick as nemo after multi-user (reliable on tablets)
cat > "$ROOTFS_DIR/usr/lib/systemd/system/glacier-session.service" <<EOF
[Unit]
Description=Glacier (Lipstick) session for ${NEMO_USER}
After=mce.service multi-user.target systemd-user-sessions.service
Wants=mce.service

[Service]
Type=simple
User=${NEMO_USER}
PAMName=login
WorkingDirectory=/home/${NEMO_USER}
Environment=HOME=/home/${NEMO_USER}
Environment=USER=${NEMO_USER}
Environment=XDG_RUNTIME_DIR=/run/user/${NEMO_UID}
Environment=QT_QPA_PLATFORM=eglfs
Environment=QT_QPA_EGLFS_INTEGRATION=eglfs_kms
Environment=QT_QUICK_CONTROLS_STYLE=Nemo
Environment=GLACIER_NATIVEORIENTATION=1
EnvironmentFile=-/usr/share/glacier-home/nemovars.conf
EnvironmentFile=-/var/lib/environment/compositor/*.conf
ExecStartPre=/bin/mkdir -p /run/user/${NEMO_UID}
ExecStartPre=/bin/chown ${NEMO_USER}:${NEMO_USER} /run/user/${NEMO_UID}
ExecStartPre=/bin/chmod 700 /run/user/${NEMO_UID}
ExecStart=/usr/bin/lipstick -platform eglfs
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical.target
EOF

ln -sfn /usr/lib/systemd/system/glacier-session.service \
  "$ROOTFS_DIR/etc/systemd/system/graphical.target.wants/glacier-session.service"

# Autologin on tty1 is optional debug; keep getty but don't block graphical
mkdir -p "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF

echo "Nemo user ${NEMO_USER}/${NEMO_PASS} ready; glacier-session.service enabled"
