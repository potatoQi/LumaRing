#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(python3 scripts/configure_bundle.py --print-version)"
BUILD_MODE="${LUMARING_BUILD_MODE:-development}"
SIGN_IDENTITY="${LUMARING_SIGN_IDENTITY:--}"
if [[ "$BUILD_MODE" != development && "$BUILD_MODE" != distribution ]]; then
  echo 'LUMARING_BUILD_MODE must be development or distribution.' >&2; exit 1
fi
if [[ "$BUILD_MODE" == distribution && "$SIGN_IDENTITY" != 'Developer ID Application:'* ]]; then
  echo 'Distribution requires an explicit Developer ID Application signing identity.' >&2; exit 1
fi
SWIFT_ARCH_ARGS=()
if [ "${LUMARING_UNIVERSAL:-1}" = "1" ]; then SWIFT_ARCH_ARGS=(--arch arm64 --arch x86_64); fi
swift build --disable-keychain --disable-netrc -c release "${SWIFT_ARCH_ARGS[@]}"
BIN_DIR="$(swift build --disable-keychain --disable-netrc -c release "${SWIFT_ARCH_ARGS[@]}" --show-bin-path)"
mkdir -p "$PROJECT_DIR/dist"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/dist/.build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/LumaRing.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_DIR/LumaRing" "$APP_DIR/Contents/MacOS/LumaRing"
python3 scripts/configure_bundle.py --output "$APP_DIR/Contents/Info.plist"
cp Resources/LumaRingIcon-1.3.icns "$APP_DIR/Contents/Resources/LumaRingIcon-1.3.icns"
SPARKLE_DIR="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle"
FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$FRAMEWORK"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Sign nested code from the inside out; ditto preserves the framework's symlinks.
SIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY")
if [[ "$BUILD_MODE" == distribution ]]; then SIGN_OPTIONS+=(--options runtime --timestamp); fi
codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK"
codesign "${SIGN_OPTIONS[@]}" --entitlements Resources/LumaRing.entitlements "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# Keep incomplete builds away from the last successful artifact.
if [ -d "$PROJECT_DIR/dist/LumaRing.app" ]; then mv "$PROJECT_DIR/dist/LumaRing.app" "$STAGING_DIR/previous.app"; fi
mv "$APP_DIR" "$PROJECT_DIR/dist/LumaRing.app"
ditto -c -k --sequesterRsrc --keepParent "$PROJECT_DIR/dist/LumaRing.app" "$PROJECT_DIR/dist/LumaRing-$VERSION-macOS.zip"
echo "Built $VERSION ($BUILD_MODE): $PROJECT_DIR/dist/LumaRing.app"
