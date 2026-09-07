#!/bin/bash
# Build, notarize and sign release assets locally. Never creates a tag or contacts GitHub.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(python3 scripts/configure_bundle.py --print-version)"
NOTES="$PROJECT_DIR/release-notes/v$VERSION.md"
[[ -f "$NOTES" ]] || { echo "Missing release notes: $NOTES" >&2; exit 1; }
if [[ -z "${LUMARING_NOTARY_PROFILE:-}" && ( -z "${APPLE_API_KEY_P8:-}" || -z "${APPLE_API_KEY_ID:-}" || -z "${APPLE_API_ISSUER:-}" ) ]]; then
  echo 'Configure LUMARING_NOTARY_PROFILE or Apple notarization API credentials first.' >&2; exit 1
fi
LUMARING_BUILD_MODE=distribution bash scripts/build.sh
APP="$PROJECT_DIR/dist/LumaRing.app"
ARCHIVE="$PROJECT_DIR/dist/LumaRing-$VERSION-macOS.zip"
PRIVATE_DIR="$(mktemp -d)"
chmod 700 "$PRIVATE_DIR"
trap 'rm -rf "$PRIVATE_DIR"' EXIT
NOTARY_ARGS=()
if [[ -n "${LUMARING_NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$LUMARING_NOTARY_PROFILE")
else
  export LUMARING_NOTARY_KEY_FILE="$PRIVATE_DIR/AuthKey.p8"
  python3 - <<'PY'
import os
from pathlib import Path
path = Path(os.environ['LUMARING_NOTARY_KEY_FILE'])
path.write_text(os.environ['APPLE_API_KEY_P8'])
path.chmod(0o600)
PY
  NOTARY_ARGS=(--key "$LUMARING_NOTARY_KEY_FILE" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
fi
xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait --output-format json > "$PRIVATE_DIR/notary.json"
python3 - "$PRIVATE_DIR/notary.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted; no release assets will be prepared.')
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# Stapling modifies the bundle: archive and sign only after it succeeds.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
ASSETS="$PROJECT_DIR/dist/release-v$VERSION"
[[ ! -e "$ASSETS" ]] || { echo "Release assets already exist: $ASSETS. Move them aside deliberately before retrying." >&2; exit 1; }
mkdir "$ASSETS"
cp "$ARCHIVE" "$ASSETS/"
cp "$NOTES" "$ASSETS/LumaRing-$VERSION-macOS.md"
# Optionally preserve a previously downloaded signed feed. Its existing archive URLs remain unchanged.
if [[ -n "${LUMARING_PREVIOUS_APPCAST:-}" ]]; then
  PUBLIC_KEY="$(python3 -c 'from scripts.configure_bundle import update_configuration; print(update_configuration()["publicEDKey"])')"
  swift scripts/verify-signature.swift "$PUBLIC_KEY" "$LUMARING_PREVIOUS_APPCAST" --feed
  cp "$LUMARING_PREVIOUS_APPCAST" "$ASSETS/appcast.xml"
fi
REPOSITORY="$(python3 -c 'from scripts.configure_bundle import update_configuration; print(update_configuration()["repository"])')"
SPARKLE_BIN="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"
APPCAST_ARGS=(--download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" --embed-release-notes --maximum-deltas 0 --maximum-versions 0 --versions "$VERSION")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  # Standard input keeps the secret out of command arguments and logs.
  python3 -c 'import os,sys; sys.stdout.write(os.environ["SPARKLE_PRIVATE_KEY"])' | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${APPCAST_ARGS[@]}" "$ASSETS"
else
  "$SPARKLE_BIN/generate_appcast" --account local.lumaring.app "${APPCAST_ARGS[@]}" "$ASSETS"
fi
python3 scripts/validate-release.py "$ASSETS" --require-distribution
(cd "$ASSETS" && shasum -a 256 "LumaRing-$VERSION-macOS.zip" appcast.xml > SHA256SUMS)
echo "Release assets ready: $ASSETS"
echo 'No version, tag, commit or GitHub release was changed.'
