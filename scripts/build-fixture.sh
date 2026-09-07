#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
FIXTURE_DIR="$PROJECT_DIR/work/LumaRing Test Windows.app"
mkdir -p "$FIXTURE_DIR/Contents/MacOS"
swiftc scripts/window-fixture.swift -o "$FIXTURE_DIR/Contents/MacOS/WindowFixture"
cat > "$FIXTURE_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowFixture</string>
<key>CFBundleIdentifier</key><string>local.lumaring.fixture</string>
<key>CFBundleName</key><string>LumaRing Test Windows</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$FIXTURE_DIR"
echo "$FIXTURE_DIR"
