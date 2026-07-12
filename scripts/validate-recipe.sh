#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
test -f "$ROOT/profiles/devices/pipa"
test -f "$ROOT/profiles/overlays/pipa/overlay.txt"
test -f "$ROOT/profiles/overlays/nemomobile/overlay.txt"
grep -q 'nemo-device-pipa' "$ROOT/profiles/devices/pipa"
echo "OK: pipa overlay recipe present (openSUSE / OBS consumer)"
