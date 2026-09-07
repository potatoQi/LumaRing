# LumaRing maintenance

- The owner alone chooses the release version. Never change `VERSION`, increment a build number, create a version tag, or publish a release unless the owner explicitly asks for that exact version/release.
- `VERSION` is the only version source. Builds, tests and ordinary commits must not modify it. Both bundle version fields and archive names are derived from it.
- Keep window switching, mouse interaction, existing permissions and preferences compatible.
- Use Sparkle for updates. Never implement an unverified download-and-replace updater, remove signature verification, or silently install updates.
- Do not commit private signing keys, credentials, local test artifacts or user window/tab metadata.
- Run `swift test` and `python3 -m unittest discover -s Tests/ReleaseTools -v` for release/update changes, and validate a bundled build when changing packaging.
- Before pushing, tagging or publishing, follow the owner's current authorization. A local commit does not authorize a push or Release.
