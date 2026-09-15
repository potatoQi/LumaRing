"""Sync the latest stable GitHub release into an existing Homebrew cask."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

REPOSITORY = "potatoQi/LumaRing"


def version_tuple(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError(f"Invalid stable version: {value}")
    return tuple(map(int, value.split(".")))


def release_version(release):
    if release["draft"] or release["prerelease"]:
        raise ValueError("Only published stable releases can update Homebrew")
    tag = release["tag_name"]
    if not tag.startswith("v"):
        raise ValueError("Expected a v-prefixed release tag")
    version = tag[1:]
    version_tuple(version)
    return version


def updated_cask(text, version, digest):
    versions = re.findall(r'^  version "([^"]+)"$', text, re.MULTILINE)
    hashes = re.findall(r'^  sha256 "([a-f0-9]{64})"$', text, re.MULTILINE)
    if len(versions) != 1 or len(hashes) != 1:
        raise ValueError("Expected exactly one version and SHA-256 in the cask")
    if not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise ValueError("Invalid SHA-256")
    if version_tuple(version) < version_tuple(versions[0]):
        raise ValueError("Refusing to downgrade the cask")
    if version == versions[0] and digest != hashes[0]:
        raise ValueError("Published asset changed without a new version")
    text = re.sub(r'^  version "[^"]+"$', f'  version "{version}"', text, flags=re.MULTILINE)
    return re.sub(r'^  sha256 "[a-f0-9]{64}"$', f'  sha256 "{digest}"', text, flags=re.MULTILINE)


def verified_digest(archive, checksums):
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    entries = [line.split() for line in checksums.read_text().splitlines()]
    matches = [parts[0] for parts in entries if len(parts) == 2 and parts[1].lstrip("*") == archive.name]
    if matches != [digest]:
        raise ValueError("DMG does not match the published SHA256SUMS")
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cask", type=Path)
    parser.add_argument("--check", action="store_true", help="Validate without writing")
    args = parser.parse_args()
    # Always resolve the latest stable release, including manual retries of old runs.
    release = json.loads(subprocess.check_output([
        "gh", "api", f"repos/{REPOSITORY}/releases/latest",
    ], text=True))
    version = release_version(release)
    filename = f"LumaRing-{version}-macOS.dmg"
    with tempfile.TemporaryDirectory(prefix="lumaring-homebrew-") as directory:
        subprocess.run([
            "gh", "release", "download", release["tag_name"], "--repo", REPOSITORY,
            "--pattern", filename, "--pattern", "SHA256SUMS", "--dir", directory,
        ], check=True)
        root = Path(directory)
        digest = verified_digest(root / filename, root / "SHA256SUMS")
    original = args.cask.read_text()
    updated = updated_cask(original, version, digest)
    if updated == original:
        print(f"Homebrew is already up to date: {version}")
    elif args.check:
        print(f"Validated Homebrew update to {version} (check only)")
    else:
        args.cask.write_text(updated)
        print(f"Updated Homebrew to {version}")


if __name__ == "__main__":
    main()
