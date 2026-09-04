#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/icon-source.png (a square PNG with
# transparent corners). Run only when the mark changes; the .icns is committed so a
# plain build never needs this.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Resources/icon-source.png"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$SRC" ] || { echo "error: missing $SRC" >&2; exit 1; }

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

emit() { # emit <pixels> <iconset-name>
  sips -s format png -z "$1" "$1" "$SRC" --out "$ICONSET/icon_$2.png" >/dev/null
}
emit 16   "16x16";    emit 32   "16x16@2x"
emit 32   "32x32";    emit 64   "32x32@2x"
emit 128  "128x128";  emit 256  "128x128@2x"
emit 256  "256x256";  emit 512  "256x256@2x"
emit 512  "512x512";  emit 1024 "512x512@2x"

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "wrote Resources/AppIcon.icns"
