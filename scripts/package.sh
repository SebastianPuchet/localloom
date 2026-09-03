#!/bin/bash
# Builds LocalLoom.app and wraps it in a drag-to-/Applications DMG.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/LocalLoom-$VERSION.dmg"
STAGE="dist/stage"

"$ROOT/scripts/build.sh" "$@"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R dist/LocalLoom.app "$STAGE/LocalLoom.app"
ln -s /Applications "$STAGE/Applications"
# Kept for repo clones and the Homebrew postflight. NOT the advertised DMG path:
# double-clicking a .command inside a quarantined DMG fails with error -128 and never runs.
cp dist/Install.command "$STAGE/Install.command"
chmod +x "$STAGE/Install.command"

# create-dmg is not a dependency; hdiutil is enough.
hdiutil create -volname "LocalLoom" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "==> built $DMG"
