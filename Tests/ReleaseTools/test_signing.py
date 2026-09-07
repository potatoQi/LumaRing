import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('sign_bundle', ROOT / 'scripts/sign_bundle.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningIdentityTests(unittest.TestCase):
    first = 'A' * 40
    second = 'B' * 40
    listing = f'  1) {first} "LumaRing Local Signing"\n  2) {second} "Other App"\n  2 valid identities found\n'

    def test_fingerprint_selects_pinned_identity(self):
        self.assertEqual(signing.resolve_identity(self.first.lower(), self.listing),
                         (self.first, 'LumaRing Local Signing'))

    def test_missing_identity_never_falls_back_to_another_key_or_adhoc(self):
        for requested in ('C' * 40, '', 'LumaRing', 'Local Signing'):
            with self.subTest(requested=requested), self.assertRaises(ValueError):
                signing.resolve_identity(requested, self.listing)

    def test_duplicate_names_require_fingerprint(self):
        listing = self.listing.replace('Other App', 'LumaRing Local Signing')
        with self.assertRaises(ValueError):
            signing.resolve_identity('LumaRing Local Signing', listing)
        self.assertEqual(signing.resolve_identity(self.first, listing)[0], self.first)

    def test_developer_id_name_remains_available(self):
        name = 'Developer ID Application: Example (TESTTEAM)'
        listing = f'  1) {self.first} "{name}"\n'
        self.assertEqual(signing.resolve_identity(name, listing), (self.first, name))

    def test_invalid_certificate_is_not_selected(self):
        listing = f'  1) {self.first} "LumaRing Local Signing" (CSSMERR_TP_NOT_TRUSTED)\n'
        with self.assertRaises(ValueError):
            signing.resolve_identity(self.first, listing)

    def test_adhoc_requires_explicit_dash(self):
        self.assertEqual(signing.resolve_identity('-', '')[0], '-')
        with self.assertRaises(ValueError):
            signing.resolve_identity(self.first, '')


if __name__ == '__main__':
    unittest.main()
