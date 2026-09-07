#!/bin/bash
# Runs only on GitHub's ephemeral runner. Never export signing credentials in logs.
set -euo pipefail
: "${RUNNER_TEMP:?}" "${CERTIFICATE_P12_BASE64:?}" "${CERTIFICATE_PASSWORD:?}"
SIGNING_KEYCHAIN="$RUNNER_TEMP/lumaring-signing.keychain-db"
SIGNING_KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
CERTIFICATE_FILE="$RUNNER_TEMP/lumaring-certificate.p12"
export CERTIFICATE_FILE
python3 - <<'PY'
import base64, os
from pathlib import Path
p = Path(os.environ['CERTIFICATE_FILE'])
p.write_bytes(base64.b64decode(os.environ['CERTIFICATE_P12_BASE64'], validate=True))
p.chmod(0o600)
PY
security create-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security import "$CERTIFICATE_FILE" -P "$CERTIFICATE_PASSWORD" -k "$SIGNING_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
security list-keychains -d user -s "$SIGNING_KEYCHAIN" login.keychain-db
rm -f "$CERTIFICATE_FILE"
