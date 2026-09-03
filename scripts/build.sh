#!/bin/bash
# Builds LocalLoom.app into dist/. Usage: scripts/build.sh [--universal]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="LocalLoom"
APP="dist/$APP_NAME.app"
IDENTITY="${LOCALLOOM_IDENTITY:-}"

# Pick a signing identity: env override, then "LocalLoom Dev", then any LocalLoom cert,
# then ad-hoc (works, but every rebuild resets the Screen Recording grant).
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(LocalLoom[^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$IDENTITY" ]; then
  echo "warning: no LocalLoom signing identity found; falling back to ad-hoc signing."
  echo "         Run scripts/make-identity.sh so TCC grants survive rebuilds."
  IDENTITY="-"
fi

echo "==> swift build -c release"
swift build -c release
BIN=".build/release/$APP_NAME"

if [ "${1:-}" = "--universal" ]; then
  echo "==> universal build (swift build --arch is unsupported; two builds + lipo)"
  swift build -c release --triple arm64-apple-macosx15.0 --scratch-path .build/arm64
  swift build -c release --triple x86_64-apple-macosx15.0 --scratch-path .build/x86_64
  mkdir -p .build/universal
  lipo -create -output ".build/universal/$APP_NAME" \
    ".build/arm64/release/$APP_NAME" ".build/x86_64/release/$APP_NAME"
  BIN=".build/universal/$APP_NAME"
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign with identity: $IDENTITY"
codesign --force --options runtime \
  --entitlements Resources/LocalLoom.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep -i designated || true

echo "==> built $APP"
