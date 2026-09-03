#!/bin/bash
# Copies LocalLoom to /Applications and clears the quarantine flag.
#
# Note: this does NOT work by double-clicking it inside a downloaded DMG — macOS refuses to
# launch a quarantined .command (error -128). It is here for repo clones and for the
# Homebrew cask postflight. From a DMG, drag the app across and run the one-liner in the
# README instead.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/LocalLoom.app"
[ -d "$SRC" ] || { echo "LocalLoom.app not found next to this script."; exit 1; }

echo "Installing LocalLoom to /Applications…"
rm -rf /Applications/LocalLoom.app
cp -R "$SRC" /Applications/LocalLoom.app
xattr -dr com.apple.quarantine /Applications/LocalLoom.app || true
open /Applications/LocalLoom.app
echo "Done. Grant Screen Recording in System Settings, then quit and reopen LocalLoom."
