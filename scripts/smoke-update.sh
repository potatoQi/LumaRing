#!/bin/bash
# Signed-feed integration smoke test with a disposable fixture key. No real private key or network access.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(python3 scripts/configure_bundle.py --print-version)"
mkdir -p "$PROJECT_DIR/work"
SMOKE_DIR="$(mktemp -d "$PROJECT_DIR/work/update-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR"' EXIT
chmod 700 "$SMOKE_DIR"
export LUMARING_SMOKE_DIR="$SMOKE_DIR"
ditto dist/LumaRing.app "$SMOKE_DIR/LumaRing.app"
python3 - <<'PY'
from pathlib import Path
import base64, os, plistlib, json, subprocess
root = Path(os.environ['LUMARING_SMOKE_DIR'])
key = root / 'test-key'
key.write_text(base64.b64encode(bytes([7]) * 32).decode()); key.chmod(0o600)
public = json.loads(subprocess.check_output(['swift', 'Tests/ReleaseTools/sign-fixture.swift', str(key)],text=True))['publicKey']
p = root / 'LumaRing.app/Contents/Info.plist'
info = plistlib.loads(p.read_bytes()); info['SUPublicEDKey'] = public
p.write_bytes(plistlib.dumps(info))
(root / 'Resources').mkdir()
(root / 'VERSION').write_bytes(Path('VERSION').read_bytes())
(root / 'Resources/UpdateConfig.json').write_text(json.dumps({'repository':'potatoQi/LumaRing','publicEDKey':public}))
PY
# The fixture app is never launched or installed. Resigning just restores its bundle seal after changing the fixture key.
codesign --force --sign - --entitlements Resources/LumaRing.entitlements "$SMOKE_DIR/LumaRing.app"
# Exercise the real local release pipeline in an isolated fixture project.
mkdir -p "$SMOKE_DIR/dist" "$SMOKE_DIR/scripts" "$SMOKE_DIR/release-notes" "$SMOKE_DIR/.build/artifacts/sparkle/Sparkle/bin"
mv "$SMOKE_DIR/LumaRing.app" "$SMOKE_DIR/dist/LumaRing.app"
ditto -c -k --sequesterRsrc --keepParent "$SMOKE_DIR/dist/LumaRing.app" "$SMOKE_DIR/dist/LumaRing-$VERSION-macOS.zip"
cp scripts/{prepare-release.sh,configure_bundle.py,check-bundle.py,validate-release.py,verify-signature.swift} "$SMOKE_DIR/scripts/"
cp "release-notes/v$VERSION.md" "$SMOKE_DIR/release-notes/"
# Reuse the already built fixture bundle; only fixture key access is substituted.
cat > "$SMOKE_DIR/scripts/build.sh" <<'BUILD'
#!/bin/bash
exit 0
BUILD
export LUMARING_SMOKE_GENERATOR="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
cat > "$SMOKE_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" <<'GENERATOR'
#!/bin/bash
set -euo pipefail
[[ "$1" == --account && "$2" == local.lumaring.app ]]
shift 2
exec "$LUMARING_SMOKE_GENERATOR" --ed-key-file "$LUMARING_SMOKE_DIR/test-key" "$@"
GENERATOR
chmod +x "$SMOKE_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
bash "$SMOKE_DIR/scripts/prepare-release.sh"
(cd "$SMOKE_DIR/dist/release-v$VERSION" && shasum -a 256 -c SHA256SUMS)
[[ "$(find "$SMOKE_DIR/dist/release-v$VERSION" -type f | wc -l | tr -d ' ')" == 3 ]]
# A second invocation must refuse to replace a completed release.
if bash "$SMOKE_DIR/scripts/prepare-release.sh" > "$SMOKE_DIR/retry.log" 2>&1; then
  echo 'Existing release was unexpectedly overwritten.' >&2; exit 1
fi
# Signing failure must clean staging and leave no apparent release to upload.
mv "$SMOKE_DIR/dist/release-v$VERSION" "$SMOKE_DIR/completed"
cat > "$SMOKE_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" <<'FAILURE'
#!/bin/bash
exit 1
FAILURE
if bash "$SMOKE_DIR/scripts/prepare-release.sh" > "$SMOKE_DIR/failure.log" 2>&1; then
  echo 'Signing failure was unexpectedly accepted.' >&2; exit 1
fi
[[ ! -e "$SMOKE_DIR/dist/release-v$VERSION" ]]
[[ -z "$(find "$SMOKE_DIR/dist" -name '.release.*' -print -quit)" ]]
cmp VERSION "$SMOKE_DIR/VERSION"
echo 'Local release pipeline, signed archive/feed, bundle, checksums, overwrite protection and failed-signing cleanup verified.'
