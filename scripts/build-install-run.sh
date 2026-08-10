#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Scrcpy Helper"
DERIVED="$ROOT/.derivedData"
BUILD_DIR="$DERIVED/Build/Products/Release"
APP_SRC="$BUILD_DIR/$APP_NAME.app"
APP_DST="/Applications/$APP_NAME.app"

echo "==> xcodegen"
xcodegen generate

echo "==> xcodebuild Release"
rm -rf "$DERIVED"
xcodebuild \
  -project ScrcpyHelper.xcodeproj \
  -scheme ScrcpyHelper \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

if [[ ! -d "$APP_SRC" ]]; then
  echo "Build product missing: $APP_SRC" >&2
  exit 1
fi

echo "==> install to $APP_DST"
pkill -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true
sleep 0.3
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$APP_DST"

echo "==> launch"
open "$APP_DST"
echo "Done: $APP_DST"
