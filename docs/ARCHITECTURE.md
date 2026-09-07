# Architecture

## Data path

`NSWorkspace notifications → ApplicationCatalog → RingController → RingView`

`hover App → WindowService serial worker → batched AX attributes → RequestGate → attached window arc`

`hover window → 280 ms one-shot delay → WindowPreview + PreviewService → ScreenCaptureKit still`

`release invocation chord / mouse click → hide UI → Launch Services reopen → unminimize if needed → AXMain + AXRaise`

## Interaction

The only selection inputs are the registered invocation chord and mouse. Carbon registration handles key press/release; held mode is optional and disabled by default. The controller records whether the panel was opened by the chord, so unrelated releases cannot commit a menu-bar session. Pointer hover is tracked separately from the delayed window-query selection. Releasing before the hover delay selects the actual pointed app, not a previously queried app. Releasing in empty space cancels.

Application pages default to 12 and accept 4–24 entries. Icon sizes adapt to density. Window arcs show up to four entries per page and only exist when multiple eligible windows are present. The default sort order is localized application name; order remains fixed during a selection session. Center controls prioritize window pages when expanded and otherwise page applications, including when accessibility access is unavailable.

No text input filtering, number shortcuts or arrow-key navigation remains. Accessibility actions still expose selection and paging without relying on those shortcuts.

## Geometry and rendering

The transparent backing panel uses a 480-point logical coordinate space; the default visible app disk is approximately 255 points across (520-point panel). The transparent area outside the shapes is not a surface. The disk and arc share a single **fully opaque** white/black CAShapeLayer, follow system appearance and have one combined shadow. There are no visual-effect or glass views.

The arc inner radius exactly equals the app disk outer radius (118). The secondary arc is an annular sector with straight radial sides. Hit testing and arc content clipping share this path. The background uses one continuous exterior contour spanning the disk and sector, eliminating internal seams and pill-shaped end caps, including wraparound directions. Hover keeps an open arc while traversing the selected direction; leaving schedules a cancellable 200 ms collapse.

WindowPreview owns a separate non-activating, mouse-transparent NSPanel with a default preferred size of 840 × 630 points, adjustable from 400 × 300 to 960 × 720 points. PreviewPlacement evaluates available regions on each side, keeps the largest feasible proportional size, then chooses the closest placement. It includes negative display origins and a readable fallback for exceptionally small screens. It never moves the user's window. Images maintain aspect ratio and are sampled for the card’s actual dimensions and screen backing scale, capped at 1920 × 1440 pixels. The preview panel does not take the ring's key status and does not embed the preview in the disk center.

A native 90 ms panel fade respects the system Reduce Motion setting. There is no custom animation preference, frame timer or display link. AppKit redraws only changed content. Material blur and continuous screenshots are absent.

## Ownership and cancellation

One application delegate owns one catalog, hotkey and controller. Panel instances are reused. Outside-click monitors exist only while visible. Sleep/session/display changes dismiss the UI. Closing clears app/window snapshots and image references.

Window queries run on one serial queue with lock-backed cancellation. They have a 180 ms list timeout, 120 ms per-window batch timeout, 1.2-second iteration budget and 128-window cap. Partial responses are marked. Cache lifetime is one second for up to 24 applications and is cleared on dismissal. Both the controller generation and selected PID reject stale results.

PreviewService allows one capture in flight and one latest pending request. Cancelled in-flight system work can finish, but its generation cannot update UI. Matching first requires the same process and normal window layer. A unique exact title survives a stale AX position/size; duplicate titles require unique geometry. Ambiguous matches are rejected. Legacy CG preflight does not block ScreenCaptureKit requests; actual API results update permission state, and denials are distinguished from minimized, unmatched and other capture failures. A denial suppresses repeat requests until the ring is reopened. NSCache has an 8 MiB advisory budget and 12-entry count limit. Dismissal empties it; framework allocations can be released later by macOS.

## Preferences and upgrade

Options implements tolerant decoding so newly added keys cannot reset a user's shortcut, exclusions or chosen size. A one-time v4 migration applies the requested 80 ms hover delay, 520-point logical panel (approximately 255-point disk), 12 applications per page and disabled held mode. Shortcut, exclusions, sorting and preview preferences remain intact. Deleted settings are no longer encoded. Login items remain managed independently by SMAppService.

The app uses a versioned icon resource and explicitly loads its own applicationIconImage. Installation replaces a verified whole bundle instead of merging stale contents. LaunchServices registration can be refreshed for this bundle without flushing global caches or restarting Finder.

## Trust boundaries

Only public APIs. The window and tab paths have no network access. Sparkle is the sole third-party runtime dependency and fetches the configured GitHub update feed and user-selected archives over HTTPS. No private window-server symbols or TCC database editing. Permissions are requested through system UI. Window titles are displayed, not logged; performance logs contain durations only. Captured content stays in memory during normal use.

## Application activation (1.3.2)

Both application selection and window selection use ApplicationActivator. It asks Launch Services to reopen the existing application with activation enabled, without creating a new process or adding Recent Items. For explicit window selection, AX unminimize/main/raise follows activation on the bounded serial worker. An app with exactly one known eligible window can fall back to application activation when its custom window does not implement AXRaise. Multiwindow selection continues to require successful target-window raising. Activation errors reach the existing error UI.

Version 1.4 defaults the invocation chord to Option + Tab. A one-time migration updates the former Control + Option + Space default while retaining custom choices. Preview width is independently Codable, bounded on decode, and defaults to 640 for existing installations.


## Browser adapters (1.5)

`Options.appContentModes[bundleID] → WindowService OR BrowserTabService → shared attached arc`

Only the stable Edge and Chrome bundle IDs are enabled. Unknown adapters and future mode values fall back to windows; each application's mode persists independently of visibility. Default preview width is 840; a one-time v6 migration replaces the previous 640 default while retaining other customized sizes.

BrowserEvents sends structured NSAppleEventDescriptor objects to an already-running PID. It uses no script strings, JavaScript, subprocesses, browser extensions, URL navigation or background screenshots. The `all` selector uses `typeAbsoluteOrdinal` (not an enum), required by Chromium's Cocoa scripting bridge. Bulk ID/title/URL reads are checked against a second ID snapshot and the window ID. Activation resolves stable tab IDs again, including moved tabs; it verifies the tab before writing the active index and verifies the active tab afterward. It restores a minimized window, raises its browser window index, then activates the existing application through Launch Services.

A serial worker has bounded Apple Event waits (at most 700 ms each), a 2-second read / 3-second activation budget and cancellation before each event. The displayed snapshot is capped at 512 tabs across 32 browser windows. Only the selected app is queried. Browser replies are bulk metadata; the cap limits retained/displayed records, not the browser's bulk response size. Closing the ring cancels reads and drops references. Permission prompts use a separate queue so they never block the UI or ordinary window reads. Hover checks permission without prompting; only the explicit connect button can request automation access. Settings refresh permission state on activation, with no timer.

The bundle declares NSAppleEventsUsageDescription and the hardened runtime automation entitlement. Browser titles and URLs stay in memory and are never included in diagnostic logs. Tab hover cards display metadata, and never capture an unrelated active page as the selected background tab.


## Owner-controlled releases and updates (v0.1.0)

VERSION is the sole release version source; build-time stamping writes both bundle version fields without modifying tracked metadata. Prior 1.x labels were unpublished local iterations. The installed legacy build needs one manual migration to 0.1.0 because Sparkle must not perform numeric downgrades.

UpdateService retains one SPUStandardUpdaterController, starts it once after launch, and observes canCheckForUpdates, automaticallyChecksForUpdates and lastUpdateCheckDate through KVO/Combine. Sparkle owns daily scheduling and persistent user choices. No custom polling timer or updater installer is implemented. Automatic installation and system profiling are disabled. Update archives are verified before extraction; the appcast and embedded notes require signatures.

The updater has menu and settings entry points. The public key and repository are committed in Resources/UpdateConfig.json. The matching private key is in the login Keychain under account local.lumaring.app and is never included in an app or source archive.

Release scripts require explicit Developer ID and notarization credentials, sign nested framework code inside-out, staple before archiving, sign the final archive and feed, and verify using the committed public key. The GitHub workflow validates the explicit version tag and creates a draft only; publishing remains an owner action. Local development builds do not use the distribution signing profile and are not substitutes for notarized releases.
