# Validation

Run from the repository root on macOS with Swift installed:

```sh
swift test --disable-keychain --disable-netrc
python3 -m unittest discover -s Tests/ReleaseTools -v
```

The two live-window tests are opt-in. They require the dedicated fixture app and accessibility / screen-recording access for the test runner. Build and open the fixture, minimize one of its ten windows, then run the tests:

```sh
bash scripts/build-fixture.sh
open "work/LumaRing Test Windows.app"
# Minimize one fixture window before continuing.
LUMARING_LIVE_TESTS=1 swift test --disable-keychain --disable-netrc
```

Optional drawing snapshots use `LUMARING_SNAPSHOT_DIR="$PWD/work/snapshots"`. Keep screenshots, logs and local test artifacts under the ignored `work/` directory.

For a disposable bundle and signed-update fixture test:

```sh
LUMARING_SIGN_IDENTITY=- bash scripts/build.sh
codesign --verify --deep --strict dist/LumaRing.app
python3 scripts/check-bundle.py dist/LumaRing.app
bash scripts/smoke-update.sh
```

The build validates the DMG contents. The smoke test uses a temporary test key and checks the DMG, ZIP, signed feed, checksums, overwrite protection and failure cleanup. It does not install or launch the fixture application. These ad-hoc artifacts are for testing only; see [Releasing](RELEASING.md) for the stable signing identity and release procedure.

Before a release, manually verify the invocation shortcut, mouse selection, window and tab modes, previews, saved preferences, first installation and an actual Sparkle update on the intended macOS versions and architectures. Automated tests do not establish these results. Builds and tests must leave `VERSION` unchanged.
