#!/usr/bin/env python3
import plistlib
import sys
from pathlib import Path
from configure_bundle import read_version, update_configuration
app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleVersion'] == info['CFBundleShortVersionString'] == read_version()
assert info['SUPublicEDKey'] == update_configuration()['publicEDKey']
assert info['SUEnableAutomaticChecks'] is True
assert info['SUAutomaticallyUpdate'] is False and info['SUAllowsAutomaticUpdates'] is False
assert info['SUScheduledCheckInterval'] == 86400
assert info['SURequireSignedFeed'] is True and info['SUVerifyUpdateBeforeExtraction'] is True
framework = app / 'Contents/Frameworks/Sparkle.framework'
assert (framework / 'Sparkle').is_symlink()
assert (framework / 'Versions/Current').is_symlink()
for helper in ['Autoupdate', 'Updater.app', 'XPCServices/Downloader.xpc', 'XPCServices/Installer.xpc']:
    assert (framework / 'Versions/B' / helper).exists(), helper
print('Bundle version, update policy, helpers and symlinks verified.')
