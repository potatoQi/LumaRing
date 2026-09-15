import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from update_homebrew import release_version, updated_cask, verified_digest


class HomebrewTests(unittest.TestCase):
    def setUp(self):
        self.digest = "a" * 64
        self.cask = f'cask "lumaring" do\n  version "0.1.5"\n  sha256 "{self.digest}"\n  app "LumaRing.app"\nend\n'

    def test_update_preserves_other_fields_and_is_idempotent(self):
        updated = updated_cask(self.cask, "0.1.6", "b" * 64)
        self.assertEqual(updated, self.cask.replace('"0.1.5"', '"0.1.6"').replace(self.digest, "b" * 64))
        self.assertEqual(updated_cask(updated, "0.1.6", "b" * 64), updated)

    def test_refuse_downgrade_or_replaced_asset(self):
        for version, digest in [("0.1.4", self.digest), ("0.1.5", "b" * 64)]:
            with self.assertRaises(ValueError):
                updated_cask(self.cask, version, digest)

    def test_reject_invalid_version_hash_and_ambiguous_cask(self):
        for text, version, digest in [
            (self.cask, '0.1.6"; system("bad")', self.digest),
            (self.cask, "0.1.6", "invalid"),
            (self.cask + '  version "0.1.5"\n', "0.1.6", self.digest),
        ]:
            with self.assertRaises(ValueError):
                updated_cask(text, version, digest)

    def test_only_stable_releases(self):
        release = dict(tag_name="v0.1.6", draft=False, prerelease=False)
        self.assertEqual(release_version(release), "0.1.6")
        for changes in [dict(draft=True), dict(prerelease=True), dict(tag_name="v0.1.6-beta"), dict(tag_name="0.1.6")]:
            with self.assertRaises(ValueError):
                release_version(dict(release, **changes))

    def test_download_must_match_unique_checksum_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "app.dmg"
            archive.write_bytes(b"fixture")
            digest = hashlib.sha256(b"fixture").hexdigest()
            checksums = Path(directory) / "SHA256SUMS"
            valid = f"{digest}  app.dmg\n"
            checksums.write_text(valid)
            self.assertEqual(verified_digest(archive, checksums), digest)
            for invalid in [valid.replace(digest, self.digest), valid * 2, ""]:
                checksums.write_text(invalid)
                with self.assertRaises(ValueError):
                    verified_digest(archive, checksums)


if __name__ == "__main__":
    unittest.main()
