#!/usr/bin/env bash
# Install these profiles into manjaro-arm-tools' expected location.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-/usr/share/manjaro-arm-tools/profiles/arm-profiles}"

run() {
  if [[ -w "$(dirname "$DEST")" ]] || [[ -w "$DEST" ]] 2>/dev/null; then
    "$@"
  else
    sudo "$@"
  fi
}

run mkdir -p "$DEST"/{devices,editions,services,overlays}
run install -Dm644 "$ROOT/profiles/devices/pipa" "$DEST/devices/pipa"
run install -Dm644 "$ROOT/profiles/editions/nemomobile" "$DEST/editions/nemomobile"
run install -Dm644 "$ROOT/profiles/services/nemomobile" "$DEST/services/nemomobile"

run rm -rf "$DEST/overlays/nemomobile" "$DEST/overlays/pipa"
# cp -a needs careful sudo
if [[ -w "$DEST/overlays" ]]; then
  cp -a "$ROOT/profiles/overlays/nemomobile" "$DEST/overlays/nemomobile"
  cp -a "$ROOT/profiles/overlays/pipa" "$DEST/overlays/pipa"
else
  sudo cp -a "$ROOT/profiles/overlays/nemomobile" "$DEST/overlays/nemomobile"
  sudo cp -a "$ROOT/profiles/overlays/pipa" "$DEST/overlays/pipa"
fi

echo "Installed pipa + nemomobile profiles into $DEST"
