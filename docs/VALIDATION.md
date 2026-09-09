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

## Four-finger tap

`TrackpadTests` replays contact frames for taps, swipes/pinches, changing finger counts, staggered landing/release, long holds, timestamp gaps, cancellation, cooldown and independent devices. Fake backends check enable/disable, overlapping sleep/session suspension, stale callback delivery and unavailable hardware without changing system preferences or opening a physical device.

On a local build, enable **Settings → General → Four-finger tap to open the ring**. Lift all fingers once, then tap with four fingers in another foreground app. Verify opening and closing, mouse selection and the existing shortcut in both toggle and held modes. Test ordinary pointer movement, two-finger scrolling, three-finger dragging, four-finger desktop/Mission Control swipes, pinches and palm contact for false activation. Finally test disable during contact, lock/unlock, sleep/wake and external trackpad disconnect/reconnect. The feature is experimental and off by default; physical gesture accuracy cannot be verified through Computer Use.
