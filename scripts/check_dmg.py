#!/usr/bin/env python3
"""Mount a local installer read-only and verify it contains the exact reference app."""
import argparse
import hashlib
import os
import stat
import subprocess
import tempfile
from pathlib import Path


def bundle_manifest(app):
    manifest = {}
    for path in app.rglob('*'):
        name = str(path.relative_to(app))
        if path.is_symlink():
            manifest[name] = ('link', os.readlink(path))
        elif path.is_file():
            manifest[name] = ('file', hashlib.sha256(path.read_bytes()).hexdigest(),
                              stat.S_IMODE(path.stat().st_mode))
        elif path.is_dir():
            manifest[name] = ('directory',)
    return manifest


def validate(dmg, reference_app):
    if not dmg.is_file() or not reference_app.is_dir():
        raise ValueError('DMG and reference app must exist.')
    with tempfile.TemporaryDirectory(prefix='lumaring-dmg-verify-') as folder:
        mount = Path(folder) / 'mount'
        mount.mkdir()
        subprocess.run(['hdiutil', 'attach', str(dmg.resolve()), '-readonly', '-nobrowse',
                        '-noautoopen', '-mountpoint', str(mount)], check=True, stdout=subprocess.DEVNULL)
        try:
            applications = mount / 'Applications'
            if not applications.is_symlink() or os.readlink(applications) != '/Applications':
                raise ValueError('Installer must include the /Applications drag target.')
            app = mount / 'LumaRing.app'
            if app.is_symlink() or not app.is_dir():
                raise ValueError('Installer must contain LumaRing.app.')
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
            if bundle_manifest(app) != bundle_manifest(reference_app):
                raise ValueError('DMG app differs from the reference app.')
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)
    print('DMG drag target, app signature, contents and symlinks verified.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dmg', type=Path)
    parser.add_argument('reference_app', type=Path)
    args = parser.parse_args()
    validate(args.dmg, args.reference_app)
