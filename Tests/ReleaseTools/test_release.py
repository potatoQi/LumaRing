import base64
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from configure_bundle import configure, read_version
spec = importlib.util.spec_from_file_location('validate_release', ROOT / 'scripts/validate-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'Resources').mkdir()
        (self.root / 'VERSION').write_text('0.1.0\n')
        (self.root / 'Resources/Info.plist').write_bytes((ROOT / 'Resources/Info.plist').read_bytes())
        empty = self.root / 'empty'; empty.write_bytes(b'')
        self.public_key = self.sign(empty)['publicKey']
        (self.root / 'Resources/UpdateConfig.json').write_text(json.dumps({'repository': 'potatoQi/LumaRing', 'publicEDKey': self.public_key}))
        self.assets = self.root / 'assets'; self.assets.mkdir()
        info_path = self.root / 'Info.plist'
        configure(info_path, self.root)
        self.archive = self.assets / 'LumaRing-0.1.0-macOS.zip'
        with zipfile.ZipFile(self.archive, 'w') as z:
            z.writestr('LumaRing.app/Contents/Info.plist', info_path.read_bytes())
        self.feed = self.assets / 'appcast.xml'
        self.write_feed()

    @staticmethod
    def sign(path):
        return json.loads(subprocess.check_output(['swift', str(ROOT / 'Tests/ReleaseTools/sign-fixture.swift'), str(path)], text=True))

    def write_feed(self, version='0.1.0', url=None):
        ns = release.SPARKLE
        ET.register_namespace('sparkle', ns)
        rss = ET.Element('rss', version='2.0')
        channel = ET.SubElement(rss, 'channel')
        item = ET.SubElement(channel, 'item')
        ET.SubElement(item, f'{{{ns}}}version').text = version
        ET.SubElement(item, f'{{{ns}}}shortVersionString').text = version
        ET.SubElement(item, 'description').text = '安全更新：保留用户设置。'
        ET.SubElement(item, 'enclosure', {
            'url': url or 'https://github.com/potatoQi/LumaRing/releases/download/v0.1.0/' + self.archive.name,
            'length': str(self.archive.stat().st_size),
            f'{{{ns}}}edSignature': self.sign(self.archive)['signature']
        })
        raw = ET.tostring(rss, encoding='utf-8', xml_declaration=True) + b'\n'
        self.feed.write_bytes(raw)
        sig = self.sign(self.feed)['signature']
        self.feed.write_bytes(raw + f'<!-- sparkle-signatures:\nedSignature: {sig}\nlength: {len(raw)}\n-->\n'.encode())

    def test_signed_release_and_version_source_unchanged(self):
        before = (self.root / 'VERSION').read_bytes()
        result = release.validate(self.assets, root=self.root)
        self.assertEqual(result['version'], '0.1.0')
        self.assertEqual(before, (self.root / 'VERSION').read_bytes())

    def test_modified_release_notes_rejected(self):
        self.feed.write_bytes(self.feed.read_bytes().replace('安全更新'.encode(), '恶意更新'.encode()))
        with self.assertRaises(subprocess.CalledProcessError):
            release.validate(self.assets, root=self.root)

    def test_archive_mutation_rejected(self):
        data = bytearray(self.archive.read_bytes()); data[-1] ^= 1
        self.archive.write_bytes(data)
        with self.assertRaises(subprocess.CalledProcessError):
            release.validate(self.assets, root=self.root)

    def test_unsigned_feed_rejected(self):
        self.feed.write_bytes(self.feed.read_bytes().split(b'<!-- sparkle-signatures:')[0])
        with self.assertRaises(subprocess.CalledProcessError):
            release.validate(self.assets, root=self.root)

    def test_other_release_or_repository_rejected(self):
        self.write_feed(url='https://github.com/other/app/releases/download/v0.1.0/app.zip')
        with self.assertRaises(ValueError): release.validate(self.assets, root=self.root)
        self.write_feed(version='0.2.0')
        with self.assertRaises(ValueError): release.validate(self.assets, root=self.root)

    def test_missing_entry_or_duplicate_version_rejected(self):
        self.write_feed(version='0.2.0')
        with self.assertRaises(ValueError): release.validate(self.assets, root=self.root)
        self.write_feed()
        raw = self.feed.read_text(); start = raw.index('<item>'); end = raw.index('</item>') + len('</item>')
        self.feed.write_text(raw[:end] + raw[start:end] + raw[end:])
        with self.assertRaises(ValueError): release.validate(self.assets, root=self.root)

    def test_invalid_versions_and_tag_mismatch_rejected(self):
        for value in ['v0.1.0', '0.1', '0.01.0', '0.1.0; echo bad', '0.1.0-beta', '']:
            (self.root / 'VERSION').write_text(value)
            with self.assertRaises(ValueError): read_version(self.root)
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/configure_bundle.py'), '--verify-tag', 'v999.0.0'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_update_policy_and_staged_version(self):
        info = configure(self.root / 'staged.plist', self.root)
        self.assertEqual(info['CFBundleVersion'], '0.1.0')
        self.assertTrue(info['SUEnableAutomaticChecks'])
        self.assertFalse(info['SUAutomaticallyUpdate'])
        self.assertFalse(info['SUAllowsAutomaticUpdates'])
        self.assertFalse(info['SUEnableSystemProfiling'])
        self.assertEqual(info['SUScheduledCheckInterval'], 86400)
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])


if __name__ == '__main__': unittest.main()
