#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(python3 scripts/configure_bundle.py --print-version)"
# Fail before compiling if the fixed signing identity is unavailable.
python3 scripts/sign_bundle.py --check
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
# ditto preserves the framework's symlinks; signing proceeds from the inside out.
python3 scripts/sign_bundle.py "$APP_DIR"
# Prepare both downloads before replacing the last successful build.
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$STAGING_DIR/LumaRing-$VERSION-macOS.zip"
bash scripts/make-dmg.sh "$APP_DIR" "$STAGING_DIR/LumaRing-$VERSION-macOS.dmg"
python3 scripts/check_dmg.py "$STAGING_DIR/LumaRing-$VERSION-macOS.dmg" "$APP_DIR"
# Keep incomplete builds away from the last successful artifact.
if [ -d "$PROJECT_DIR/dist/LumaRing.app" ]; then mv "$PROJECT_DIR/dist/LumaRing.app" "$STAGING_DIR/previous.app"; fi
mv "$APP_DIR" "$PROJECT_DIR/dist/LumaRing.app"
mv "$STAGING_DIR/LumaRing-$VERSION-macOS.zip" "$PROJECT_DIR/dist/"
mv "$STAGING_DIR/LumaRing-$VERSION-macOS.dmg" "$PROJECT_DIR/dist/"
echo "Built $VERSION (local package): $PROJECT_DIR/dist/LumaRing.app"
echo "Installer: $PROJECT_DIR/dist/LumaRing-$VERSION-macOS.dmg"
