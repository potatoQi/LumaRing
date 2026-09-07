#!/bin/bash
# A drag-to-install disk image. No Finder automation, installer or privileged helper.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: make-dmg.sh /path/LumaRing.app /path/output.dmg' >&2; exit 1; }
APP_DIR="$1"
OUTPUT="$2"
[[ -d "$APP_DIR" && "$OUTPUT" == *.dmg ]] || { echo 'Expected an app bundle and a .dmg destination.' >&2; exit 1; }
[[ ! -e "$OUTPUT" ]] || { echo "Refusing to overwrite: $OUTPUT" >&2; exit 1; }
codesign --verify --deep --strict "$APP_DIR"
mkdir -p "$(dirname "$OUTPUT")"
STAGING_DIR="$(mktemp -d "$(dirname "$OUTPUT")/.dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir "$STAGING_DIR/content"
ditto "$APP_DIR" "$STAGING_DIR/content/LumaRing.app"
ln -s /Applications "$STAGING_DIR/content/Applications"
hdiutil create -volname LumaRing -srcfolder "$STAGING_DIR/content" \
  -fs HFS+ -format UDZO "$STAGING_DIR/installer.dmg"
hdiutil verify "$STAGING_DIR/installer.dmg"
mv "$STAGING_DIR/installer.dmg" "$OUTPUT"
