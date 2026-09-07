import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from check_dmg import validate


class DiskImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='lumaring-dmg-tests-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.app = cls.root / 'LumaRing.app'
        executable = cls.app / 'Contents/MacOS/LumaRing'
        executable.parent.mkdir(parents=True)
        subprocess.run(['clang', '-x', 'c', '-', '-o', str(executable)],
                       input='int main(void) { return 0; }\n', text=True, check=True)
        (cls.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'local.lumaring.dmg-test',
            'CFBundleExecutable': 'LumaRing', 'CFBundlePackageType': 'APPL',
        }))
        (cls.app / 'Contents/Resources').mkdir()
        (cls.app / 'Contents/Resources/example.txt').write_text('Fixture only.\n')
        (cls.app / 'Contents/Resources/link.txt').symlink_to('example.txt')
        subprocess.run(['codesign', '--force', '--sign', '-', str(cls.app)], check=True)
        cls.dmg = cls.root / 'installer.dmg'
        subprocess.run(['bash', str(ROOT / 'scripts/make-dmg.sh'), str(cls.app), str(cls.dmg)],
                       check=True, stdout=subprocess.DEVNULL)

    def test_drag_target_and_signed_bundle_survive_packaging(self):
        validate(self.dmg, self.app)

    def test_different_app_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=self.root) as folder:
            reference = Path(folder) / 'LumaRing.app'
            shutil.copytree(self.app, reference, symlinks=True)
            (reference / 'Contents/Resources/example.txt').write_text('Different build.\n')
            with self.assertRaisesRegex(ValueError, 'differs'):
                validate(self.dmg, reference)

    def test_existing_installer_cannot_be_overwritten(self):
        before = self.dmg.stat()
        result = subprocess.run(['bash', str(ROOT / 'scripts/make-dmg.sh'),
                                 str(self.app), str(self.dmg)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Refusing to overwrite', result.stderr)
        self.assertEqual(before.st_mtime_ns, self.dmg.stat().st_mtime_ns)

    def test_missing_installer_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'must exist'):
            validate(self.root / 'missing.dmg', self.app)


if __name__ == '__main__':
    unittest.main()
