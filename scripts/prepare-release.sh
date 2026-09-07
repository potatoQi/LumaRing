#!/bin/bash
# Prepare local release assets only. Never tags, pushes, uploads or publishes.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(python3 scripts/configure_bundle.py --print-version)"
NOTES="$PROJECT_DIR/release-notes/v$VERSION.md"
ASSETS="$PROJECT_DIR/dist/release-v$VERSION"
[[ -f "$NOTES" ]] || { echo "Missing release notes: $NOTES" >&2; exit 1; }
[[ ! -e "$ASSETS" ]] || { echo "Release assets already exist: $ASSETS. Move them aside deliberately before retrying." >&2; exit 1; }
bash scripts/build.sh
python3 scripts/check-bundle.py dist/LumaRing.app
ARCHIVE="$PROJECT_DIR/dist/LumaRing-$VERSION-macOS.zip"
# Publish the local folder atomically only after all signatures and bundle checks pass.
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/dist/.release.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir "$STAGING_DIR/assets"
STAGED_ASSETS="$STAGING_DIR/assets"
cp "$ARCHIVE" "$STAGED_ASSETS/"
cp "$NOTES" "$STAGED_ASSETS/LumaRing-$VERSION-macOS.md"
if [[ -n "${LUMARING_PREVIOUS_APPCAST:-}" ]]; then
  PUBLIC_KEY="$(python3 -c 'from scripts.configure_bundle import update_configuration; print(update_configuration()["publicEDKey"])')"
  swift scripts/verify-signature.swift "$PUBLIC_KEY" "$LUMARING_PREVIOUS_APPCAST" --feed
  cp "$LUMARING_PREVIOUS_APPCAST" "$STAGED_ASSETS/appcast.xml"
fi
REPOSITORY="$(python3 -c 'from scripts.configure_bundle import update_configuration; print(update_configuration()["repository"])')"
SPARKLE_BIN="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"
APPCAST_ARGS=(--download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" --embed-release-notes --maximum-deltas 0 --maximum-versions 0 --versions "$VERSION")
if ! "$SPARKLE_BIN/generate_appcast" --account local.lumaring.app "${APPCAST_ARGS[@]}" "$STAGED_ASSETS"; then
  echo 'Update signing failed. Allow Sparkle generate_appcast to access the existing local.lumaring.app key in your login Keychain, then retry. Do not regenerate the key.' >&2
  exit 1
fi
python3 scripts/validate-release.py "$STAGED_ASSETS" --check-bundle
# Embedded notes are inside the signed feed; upload only these three final files.
rm "$STAGED_ASSETS/LumaRing-$VERSION-macOS.md"
(cd "$STAGED_ASSETS" && shasum -a 256 "LumaRing-$VERSION-macOS.zip" appcast.xml > SHA256SUMS)
# A concurrent attempt must not overwrite another completed release folder.
[[ ! -e "$ASSETS" ]] || { echo "Release assets already exist: $ASSETS" >&2; exit 1; }
mv "$STAGED_ASSETS" "$ASSETS"
echo "Release assets ready locally: $ASSETS"
echo 'No version, tag, commit, push, upload or GitHub release was changed.'
