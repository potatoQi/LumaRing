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

## Trackpad tap

`GestureInvocationTests` replays residual primary/secondary clicks after invocation and checks that fresh clicks and ordinary invocation still work. `TrackpadTests` and `TapSelectionTests` replay contact frames for taps, swipes/pinches, changing finger counts, staggered landing/release, long holds, timestamp gaps, cancellation, cooldown and independent devices. Fake backends check enable/disable, overlapping sleep/session suspension, stale callback delivery and unavailable hardware without changing system preferences or opening a physical device.

On a local build, choose **Settings → General → Open the ring with trackpad → Three-finger tap / Four-finger tap**. Lift all fingers once, then tap with the selected number of fingers in another foreground app. Verify the other finger count does not open the ring. For three-finger mode, set macOS Look Up to Force Click or Off and check that stationary taps open the ring while inward pinches only minimize. Verify opening and closing, mouse selection and the existing shortcut in both toggle and held modes. Test ordinary pointer movement, two-finger scrolling, three-finger dragging, four-finger desktop/Mission Control swipes, pinches and palm contact for false activation. Finally test disable during contact, lock/unlock, sleep/wake and external trackpad disconnect/reconnect. The feature is experimental and off by default; physical gesture accuracy cannot be verified through Computer Use.

## Three-finger pinch

`PinchTests` covers asymmetric inward contraction (including two adjacent fingers moving together), staggered contacts, release-only completion, cooldown, reversal, swipe/jitter rejection, extra/replaced fingers, invalid frames, lifecycle fencing, independent toggles and preference compatibility. `PinchMinimizerTests` uses injected AX access to verify exact target checks, delayed capture, cancellation, foreground changes and unsupported windows without minimizing user windows. It also verifies direct focused-window lookup by the known foreground PID, no system-wide focus dependency, focus changes during lookup, and rejection of missing focused windows without selecting an arbitrary fallback.

Enable **Settings → General → Three-finger pinch to minimize the window**, grant Accessibility access, and test with a disposable foreground window while the ring is closed. Place three fingers apart, pinch inward, then lift all three. Confirm only that window minimizes and no action happens while fingers remain down. Test three-finger dragging/swiping, ordinary scrolling, outward pinch, app/window changes mid-gesture, fullscreen windows, both gesture toggles independently and together, sleep/lock and external-device reconnection. Regression cases cover wide asymmetric contraction with centroid drift, fast contraction reaching qualification on the first break-touch frame, hover coordinates that must not manufacture contraction, and geometry changes during a confirmed staggered lift. Synthetic three-finger taps remain distinct from fast pinches; new/returning contacts and release timeouts still cancel after confirmation. Center-launcher tests replay stationary click counts 1 through 8 plus count reset after a pause. Physical accuracy and interaction with macOS gesture settings require hands-on testing; automated tests do not establish them.

## Closing and drag to quit

`SecondaryClosingTests` checks sequential closing, retaining the last secondary item, count/page updates, preview clearing and restoration after an uncompleted close. `ClosingTests` checks click versus drag, drag-back and Escape cancellation, the outer margin, release of the invocation shortcut during gestures, stale targets, close-button hit regions across all arc anchors, and exact AX ownership / enabled-button checks. `BrowserTabTests` verifies stable-ID close descriptors for moved tabs and rejects disappeared, changed or cancelled targets. Browser action request-count tests check the normal source-window path: 3 Apple Events to close a tab and 6 to activate a non-minimized tab, with no title/URL reads or queries of unrelated windows. Browser badge tests verify native count descriptors, minimized filtering, both caps, empty/malformed replies and cancellation. For one browser window, a badge needs 2 events when including minimized windows or 3 when filtering them. These are transport-call counts, not measured end-to-end latency. Relocation, a removed source window, concurrent reordering, cancellation, permissions and timeouts are covered. These unit tests do not close user windows or quit user applications.

Before release, use disposable documents and browser tabs to verify normal window close, minimized/full-screen windows, Chrome and Edge tab close (including the last tab), changed tab order, unsupported close controls, and original application save/cancel dialogs. Verify dragging beyond the panel bounds, releasing inside versus outside, Escape cancellation, and held-shortcut release in light/dark appearance and at different ring sizes. A secondary close must leave the ring open and refresh windows/tabs and counts. Close consecutive items including the final single secondary item, close on a final page, and switch apps or dismiss/reopen while a close is pending. Cancel a save dialog and confirm the unclosed item returns. Quit requests still dismiss the ring. With a different app in front, verify background close/quit does not switch to the target. LumaRing must not override application save/confirmation dialogs or force focus back after a user switches apps.

`ApplicationQuitterTests` stalls a fake quit transport while verifying the main queue and another app’s quit request still complete. It also checks duplicate suppression, retry after failure, and refusal to quit the current process or an invalid PID. This tests responsiveness under slow request delivery, not how quickly a third-party application finishes its own shutdown.

Primary-sector tests cover every application count from 1–24, inner/outer radii, all directions, and agreement between filled paths and hit testing. UI tests select just outside the neutral center, exercise central paging and shared-boundary priority, and ensure the center clears highlighting immediately. Snapshot coverage includes light/dark appearances, dense app pages, and expanded secondary arcs.


## App menus and Option quick launch

`AppContextMenuTests` checks conditional mode choices, checked state, captured menu actions, enabled New Window commands, hidden pending/unavailable commands without orphan separators, rejection of unrelated/disabled commands and wrong AX owners, and content reload after a mode change. It also checks one bulk read per visited menu node, compatibility fallback, reuse of a valid command without rediscovery, stale/disabled/foreign command rejection and no retry after an uncertain press. `LauncherTests` checks old-settings migration, persistence and deduplication, invocation-modifier conflicts, secondary/menu/drag exclusion, late window results, disabled primary interaction, same-target mouse release, cancellation on Option release, paging, missing applications, launch failure and optional light/dark snapshots.

For manual validation, configure both running and stopped apps in App Management. Invoke with Option+Tab, release Option, then hold it again; compare with three- and four-finger invocation. Verify the gray primary ring cannot activate or quit an app, outer clicks launch only the selected app, release/Escape cancels, and scrolling pages configured apps. Check that an expanded window/tab arc is never replaced by Option, then test menu navigation and persistence of per-app content mode. Use disposable windows for New Window and Quit, including an unsupported application and an unavailable command. Verify that unavailable New Window commands are absent, and that apps without tab support show only a Windows label in App Management. Browser mode choices and the Connect Browser authorization action must remain functional. Test Chrome New Window with existing browser Automation authorization and with only Accessibility access, from a background app and in both window/tab modes. Verify one normal window is created and a timeout never causes a duplicate retry. Menu-command availability depends on each app's exposed Accessibility tree and language; unit tests do not establish compatibility with every third-party app.


## Secondary sorting and renaming

`WindowNamesTests` verifies natural name sorting and deterministic ties, alias persistence and reset, changed tab titles/positions, duplicate-target isolation, process restart protection, name/color retention across empty, incomplete and failed queries, persistence after store reload, and isolation from newly appearing items. It also covers unavailable process metadata during pruning and store reload, confirmed process-exit cleanup without affecting other unavailable apps, and a disposable subprocess that remains live despite lacking application metadata before being terminated and reaped. It checks that preview matching still uses original titles, preview headings display aliases, secondary menus capture the correct sorted target, and renaming cancels pressed targets while preserving the renamed item's visible page. Paging tests use numbered names to make their expected ordering independent of the host's language.

For manual validation, right-click disposable windows and tabs, rename several with duplicate and numeric names, cancel a rename, clear an alias and reopen the ring. Confirm names survive LumaRing relaunch while the target app stays running, and are reset for new target-app processes. Test title changes, tab movement, background close and both display modes. Give two VS Code windows different names/colors, sleep and wake the Mac with VS Code still running, and confirm both styles survive temporary missing results. This does not promise restoration after the target app restarts or recreates window IDs. Open the Edit floating panel, release Option/the invocation shortcut, click outside, and dismiss/reopen the ring; no stale editor callback should rename a different target or trigger a switch.


`WindowStyleEditorTests` replays the reported pointer-exit regression while editing, checks that late results cannot clear the target, validates color-only persistence/reset, verifies the two-row palette and save/cancel payload, and checks colored sector coverage against secondary hit testing. Optional snapshots cover both appearance modes. Manual checks should move the pointer from the context menu into the floating editor, edit the name and color, save, reopen, cancel another edit and restore the defaults. The ring must remain visible throughout editing and no “Could not save” popover should appear.


## Application logging

`AppLogTests` covers disabled metadata evaluation and file creation, preference persistence, rotation and total byte limits across restart, queued-write cancellation, bounded admission, clearing while enabled/disabled, preservation of unrelated files, concurrent structured writes, oversized-entry rejection and recovery from file errors. A WindowNames integration test traces saved/matched/missing records, unavailable process metadata and confirmed cleanup while asserting that window titles, aliases and original identifiers never enter the log. Error serialization excludes localized messages and userInfo.

In Settings → General → Local Logs, verify the toggle persists after relaunch, the folder opens, usage refreshes when returning to Settings, and Clear Logs preserves both preferences and custom window styles. When enabled, new events can produce new logs after clearing. To investigate VS Code SSH reconnection, customize two disposable windows, open their secondary ring, reconnect/reload one window, then open the ring again. Compare process launch fields and identifier fingerprints before/after the reload with `snapshot`, `process_check` and `pruned` events. Repeat across sleep/wake. These are manual reproduction checks; automated logging tests do not establish the cause of a particular SSH reconnection incident.

## Per-app shortcut actions

Launcher checks cover the shared 150 ms tap/hold boundary, a non-key launcher surface preserving the original editor and selection, action-page restoration, and cancellation when Option is released during a mouse press. On hardware, verify quick left-Option double-taps switch modes without flashing the launcher; holding past the threshold opens favorites in either mode, and release returns to the original page without changing mode memory.

Automated checks cover persistence/manual order, independent per-app mode restoration across launches and default-global behavior, left-only double-tap timing and interruption, balanced modifier/key sequences, exact focus/process identity, window-only compatibility, refusal to downgrade captured controls, rejection of AX timeouts/permission failures and secure controls, cancellation during capture and dispatch validation, held-modifier timeout, paging and matching mouse-down/up targets. An owned AppKit search-field fixture verifies that ActionPanel cannot take key status and retains the editor and selection. Dispatch tests inject a sink and never send keys to user applications.

Manual acceptance: configure actions in Settings → Actions and reorder them; restart LumaRing and verify the order. Set app A to actions and app B to global, alternate between them, and verify each restores its own mode both before and after restarting LumaRing. From a search field, invoke the ring and double-tap left Option; click a context-specific action, checking the original window and insertion point. Test direct action-mode invocation, switching back, right Option, long holds, menu/editor interactions, trackpad release clicks, sleep and app changes. Missing AX window focus must disable actions. Missing/unsupported control focus permits window-level execution; a captured control becoming unavailable must cancel sending. Changed target identity, AX timeouts/permission failures, secure input or held modifiers must cancel sending. Third-party command semantics, physical tap timing and AX-provider behavior still require target-app testing.
