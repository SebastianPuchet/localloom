#!/bin/bash
# curl -fsSL <url>/install.sh | bash
# Files fetched by the shell are never quarantined, so this is the only genuinely
# one-step install. Set LOCALLOOM_DMG_URL to point at a release asset.
set -euo pipefail
URL="${LOCALLOOM_DMG_URL:-}"
[ -n "$URL" ] || { echo "Set LOCALLOOM_DMG_URL to the LocalLoom .dmg URL."; exit 1; }

TMP="$(mktemp -d)"
trap 'hdiutil detach "$TMP/mnt" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

echo "Downloading LocalLoom…"
curl -fsSL "$URL" -o "$TMP/LocalLoom.dmg"
mkdir -p "$TMP/mnt"
hdiutil attach "$TMP/LocalLoom.dmg" -nobrowse -quiet -mountpoint "$TMP/mnt"
rm -rf /Applications/LocalLoom.app
cp -R "$TMP/mnt/LocalLoom.app" /Applications/LocalLoom.app
xattr -dr com.apple.quarantine /Applications/LocalLoom.app || true
open /Applications/LocalLoom.app
echo "Installed. Grant Screen Recording in System Settings, then quit and reopen LocalLoom."
