#!/bin/bash
# Signed-feed integration smoke test with a disposable fixture key. No real private key or network access.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(python3 scripts/configure_bundle.py --print-version)"
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
mkdir "$SMOKE_DIR/assets"
ditto -c -k --sequesterRsrc --keepParent "$SMOKE_DIR/LumaRing.app" "$SMOKE_DIR/assets/LumaRing-$VERSION-macOS.zip"
cp "release-notes/v$VERSION.md" "$SMOKE_DIR/assets/LumaRing-$VERSION-macOS.md"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file "$SMOKE_DIR/test-key" \
  --download-url-prefix "https://github.com/potatoQi/LumaRing/releases/download/v$VERSION/" \
  --embed-release-notes --maximum-deltas 0 "$SMOKE_DIR/assets"
python3 - <<'PY'
import importlib.util, os
from pathlib import Path
spec = importlib.util.spec_from_file_location('release_validation', 'scripts/validate-release.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
root = Path(os.environ['LUMARING_SMOKE_DIR'])
print(module.validate(root / 'assets', root=root))
PY
