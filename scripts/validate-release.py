#!/usr/bin/env python3
"""Validate an appcast and its archive against the owner-selected version and public key."""
import argparse
import base64
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from configure_bundle import ROOT, read_version, update_configuration
from check_dmg import validate as validate_dmg

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def validate(assets, root=ROOT, check_bundle=False):
    version = read_version(root)
    config = update_configuration(root)
    archive = assets / f'LumaRing-{version}-macOS.zip'
    feed = assets / 'appcast.xml'
    with zipfile.ZipFile(archive) as z:
        info = plistlib.loads(z.read('LumaRing.app/Contents/Info.plist'))
        if any(info.get(key) != version for key in ('CFBundleShortVersionString', 'CFBundleVersion')):
            raise ValueError('Archive version does not match VERSION.')
        if info.get('SUPublicEDKey') != config['publicEDKey']:
            raise ValueError('Archive update key does not match committed public key.')
        if info.get('SUFeedURL') != f"https://github.com/{config['repository']}/releases/latest/download/appcast.xml":
            raise ValueError('Archive feed does not match the configured repository.')
        if not info.get('SURequireSignedFeed') or not info.get('SUVerifyUpdateBeforeExtraction'):
            raise ValueError('Signed feed and pre-extraction verification must remain enabled.')
    tree = ET.parse(feed)
    matches = [item for item in tree.findall('./channel/item') if item.findtext(f'{{{SPARKLE}}}version') == version]
    if len(matches) != 1:
        raise ValueError('Feed must contain exactly one entry for VERSION.')
    entry = matches[0]
    if entry.findtext(f'{{{SPARKLE}}}shortVersionString') != version:
        raise ValueError('Feed display version does not match VERSION.')
    enclosure = entry.find('enclosure')
    expected = f"https://github.com/{config['repository']}/releases/download/v{version}/{archive.name}"
    if enclosure is None or enclosure.get('url') != expected:
        raise ValueError('Archive URL must point to this exact version and repository.')
    if int(enclosure.get('length', '-1')) != archive.stat().st_size:
        raise ValueError('Archive length does not match feed.')
    signature = enclosure.get(f'{{{SPARKLE}}}edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Missing or invalid archive signature.')
    # Verify with the committed PUBLIC key; release verification never needs the private key.
    verifier = ROOT / 'scripts/verify-signature.swift'
    subprocess.run(['swift', str(verifier), config['publicEDKey'], str(archive), signature], check=True)
    subprocess.run(['swift', str(verifier), config['publicEDKey'], str(feed), '--feed'], check=True)
    if check_bundle:
        with tempfile.TemporaryDirectory(prefix='lumaring-release-verify-') as folder:
            subprocess.run(['ditto', '-x', '-k', str(archive), folder], check=True)
            extracted = str(Path(folder) / 'LumaRing.app')
            subprocess.run(['codesign', '--verify', '--deep', '--strict', extracted], check=True)
            validate_dmg(assets / f'LumaRing-{version}-macOS.dmg', Path(extracted))
    return {'version': version, 'archiveSHA256': hashlib.sha256(archive.read_bytes()).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('assets', type=Path)
    parser.add_argument('--check-bundle', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.assets, check_bundle=args.check_bundle), indent=2))
    except (ValueError, OSError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Release validation failed: {error}')
