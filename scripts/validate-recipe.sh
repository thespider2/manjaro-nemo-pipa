#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
test -f "$ROOT/profiles/devices/pipa"
test -f "$ROOT/profiles/editions/nemomobile"
test -f "$ROOT/profiles/services/nemomobile"
test -f "$ROOT/profiles/overlays/nemomobile/overlay.txt"
test -f "$ROOT/profiles/overlays/pipa/overlay.txt"
grep -q 'nemo-device-pipa' "$ROOT/profiles/devices/pipa"
grep -q 'lipstick-glacier-home' "$ROOT/profiles/editions/nemomobile"
grep -q 'lightdm.service' "$ROOT/profiles/services/nemomobile"
DEST=$(mktemp -d)
trap 'rm -rf "$DEST"' EXIT
DEST="$DEST" "$ROOT/scripts/install-profiles.sh"
test -f "$DEST/devices/pipa"
echo "OK: image recipe validated"
