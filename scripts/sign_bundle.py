#!/usr/bin/env python3
"""Use an explicit, stable Keychain identity; never create or replace keys."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def resolve_identity(requested, listing):
    if requested == '-':
        return '-', 'ad-hoc (explicit test build)'
    identities = re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "([^"\n]+)"\s*$', listing, re.M)
    matches = [(fingerprint.upper(), name) for fingerprint, name in identities
               if requested.upper() == fingerprint.upper() or requested == name]
    if len(matches) != 1:
        raise ValueError(
            f'Expected one available signing identity for {requested!r}; found {len(matches)}. '
            'Restore the existing certificate and private key to your Keychain. '
            'Do not regenerate the release identity. See docs/RELEASING.md. '
            'For a disposable test build only, explicitly set LUMARING_SIGN_IDENTITY=-.'
        )
    return matches[0]


def sign_bundle(app, identity, name):
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    options = ['--force', '--sign', identity]
    if name.startswith('Developer ID Application:'):
        options += ['--options', 'runtime', '--timestamp']
    # Preserve Sparkle entitlements and sign nested code from the inside out.
    for helper in ('Downloader.xpc', 'Installer.xpc'):
        subprocess.run(['codesign', *options, '--preserve-metadata=entitlements',
                        str(framework / 'Versions/B/XPCServices' / helper)], check=True)
    for target in (framework / 'Versions/B/Autoupdate',
                   framework / 'Versions/B/Updater.app', framework):
        subprocess.run(['codesign', *options, str(target)], check=True)
    subprocess.run(['codesign', *options, '--entitlements',
                    str(ROOT / 'Resources/LumaRing.entitlements'), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check identity without signing anything')
    parser.add_argument('app', nargs='?', type=Path)
    args = parser.parse_args()
    if not args.check and args.app is None:
        parser.error('Provide an app bundle, or --check')
    default = json.loads((ROOT / 'Resources/SigningIdentity.json').read_text())
    requested = os.environ.get('LUMARING_SIGN_IDENTITY', default['sha1'])
    listing = '' if requested == '-' else subprocess.check_output(
        ['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    identity, name = resolve_identity(requested, listing)
    print(f'Code signing: {name} [{identity}]', flush=True)
    if identity == '-':
        print('Warning: ad-hoc test builds do not preserve permission identity across builds.', file=sys.stderr)
    if not args.check:
        sign_bundle(args.app.resolve(), identity, name)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
