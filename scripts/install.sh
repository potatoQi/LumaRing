#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/LumaRing.app"
INSTALL_DIR="${LUMARING_INSTALL_DIR:-$HOME/Applications}"
if [ ! -d "$APP_DIR" ]; then
  echo "Run bash scripts/build.sh first." >&2
  exit 1
fi
if pgrep -f '/LumaRing.app/Contents/MacOS/LumaRing' >/dev/null; then
  echo "Please quit LumaRing before installing an update." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_DIR"
mkdir -p "$INSTALL_DIR"
STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.lumaring-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/LumaRing.app"
codesign --verify --deep --strict "$STAGING_DIR/LumaRing.app"
if [ -e "$INSTALL_DIR/LumaRing.app" ]; then
  mv "$INSTALL_DIR/LumaRing.app" "$STAGING_DIR/previous.app"
fi
if ! mv "$STAGING_DIR/LumaRing.app" "$INSTALL_DIR/LumaRing.app"; then
  if [ -e "$STAGING_DIR/previous.app" ]; then
    mv "$STAGING_DIR/previous.app" "$INSTALL_DIR/LumaRing.app"
  fi
  exit 1
fi
# Refresh only this bundle's metadata; do not flush global icon caches or restart Finder.
touch "$INSTALL_DIR/LumaRing.app" "$INSTALL_DIR/LumaRing.app/Contents/Info.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$APP_DIR" || true
  "$LSREGISTER" -f "$INSTALL_DIR/LumaRing.app" || true
fi
echo "Installed: $INSTALL_DIR/LumaRing.app"
open "$INSTALL_DIR/LumaRing.app"
