import AppKit
import Carbon
import XCTest
import LumaRingCore
@testable import LumaRing

final class AppActionTests: XCTestCase {
    private let shortcut = Shortcut(keyCode: 3, modifiers: UInt32(cmdKey), label: "F")

    func testProfilesPersistManualOrderAndIgnoreDuplicateIDs() throws {
        var profile = ActionProfile(app: LauncherApp(bundleID: "test.editor", name: "Editor", path: "/Editor.app"), actions: [
            AppAction(id: "a", name: "Find", shortcut: shortcut),
            AppAction(id: "b", name: "Next", shortcut: Shortcut(keyCode: 5, modifiers: UInt32(cmdKey), label: "G"))
        ])
        profile.move("b", by: -1)
        profile.move("b", by: -1)
        profile.move("missing", by: 1)
        var options = Options(); options.actionProfiles = [profile, profile]
        let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded.actionProfiles.count, 1)
        XCTAssertEqual(decoded.actionProfiles[0].actions.map(\.id), ["b", "a"])
        XCTAssertEqual(decoded.actionProfiles[0].actions[1].shortcut, shortcut)
        XCTAssertEqual(try JSONDecoder().decode(Options.self, from: Data("{}".utf8)).actionProfiles, [])
    }

    func testEachAppRestoresItsOwnModeAcrossLaunches() throws {
        var options = Options()
        XCTAssertFalse(options.usesActionRing(for: "test.editor"))
        options.rememberActionRing(true, for: "test.editor")
        options.rememberActionRing(false, for: "test.browser")
        XCTAssertTrue(options.usesActionRing(for: "test.editor"))
        XCTAssertFalse(options.usesActionRing(for: "test.browser"))
        XCTAssertFalse(options.usesActionRing(for: "test.unseen"))

        var reloaded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
        XCTAssertTrue(reloaded.usesActionRing(for: "test.editor"))
        XCTAssertFalse(reloaded.usesActionRing(for: "test.browser"))
        reloaded.rememberActionRing(true, for: "test.browser")
        reloaded.rememberActionRing(false, for: "test.editor")
        let again = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(reloaded))
        XCTAssertFalse(again.usesActionRing(for: "test.editor"))
        XCTAssertTrue(again.usesActionRing(for: "test.browser"))
        XCTAssertEqual(again.actionRingApps, ["test.browser"], "Global mode needs no stored entry")
    }

    func testModeMemoryDefaultsToGlobalAndIgnoresMissingAppIdentity() throws {
        var options = try JSONDecoder().decode(Options.self, from: Data("{}".utf8))
        options.rememberActionRing(true, for: nil)
        options.rememberActionRing(true, for: "")
        options.rememberActionRing(true, for: "  ")
        XCTAssertFalse(options.usesActionRing(for: nil))
        XCTAssertTrue(options.actionRingApps.isEmpty)
        let decoded = try JSONDecoder().decode(Options.self, from: Data(#"{"actionRingApps":["test.editor","test.editor",""]}"#.utf8))
        XCTAssertEqual(decoded.actionRingApps, ["test.editor"])
    }

    func testOnlyNamedValidChordsAreConfigured() {
        XCTAssertFalse(AppAction(name: "Find").configured)
        XCTAssertFalse(AppAction(name: "  \n", shortcut: shortcut).configured)
        XCTAssertFalse(AppAction(name: "Option", shortcut: Shortcut(keyCode: 58, modifiers: 0, label: "Option")).configured)
        XCTAssertFalse(AppAction.validShortcut(Shortcut(keyCode: 128, modifiers: 0, label: "Invalid")))
        XCTAssertFalse(AppAction.validShortcut(Shortcut(keyCode: 3, modifiers: UInt32(alphaLock), label: "F")))
        XCTAssertTrue(AppAction(name: "  Find  ", shortcut: shortcut).configured)
        XCTAssertTrue(AppAction(name: "Play", shortcut: Shortcut(keyCode: 49, modifiers: 0, label: "Space")).configured)
        XCTAssertTrue(AppAction(name: "Find", shortcut: shortcut).conflicts(with: shortcut))
        XCTAssertFalse(AppAction(name: "Find", shortcut: shortcut).conflicts(with: Shortcut()))
    }

    func testDoubleTapRequiresTwoCompleteLeftOptionTaps() {
        var tap = LeftOptionDoubleTap()
        XCTAssertFalse(tap.update(left: true, pressed: false, otherModifiers: false, time: 0)) // invocation release
        XCTAssertFalse(tap.update(left: true, pressed: true, otherModifiers: false, time: 1))
        XCTAssertFalse(tap.update(left: true, pressed: true, otherModifiers: false, time: 1.01)) // duplicate down
        XCTAssertFalse(tap.update(left: true, pressed: false, otherModifiers: false, time: 1.08))
        XCTAssertFalse(tap.update(left: true, pressed: true, otherModifiers: false, time: 1.2))
        XCTAssertTrue(tap.update(left: true, pressed: false, otherModifiers: false, time: 1.28))
        XCTAssertFalse(tap.isDown)
        XCTAssertFalse(tap.update(left: true, pressed: false, otherModifiers: false, time: 1.3))
    }

    func testShortTapBoundarySeparatesHoldsFromModeSwitching() {
        var tap = LeftOptionDoubleTap()
        XCTAssertLessThan(LeftOptionDoubleTap.holdDelay, 0.2)
        XCTAssertFalse(tap.update(left: true, pressed: true, otherModifiers: false, time: 1))
        XCTAssertFalse(tap.update(left: true, pressed: false, otherModifiers: false, time: 1.08))
        XCTAssertFalse(tap.update(left: true, pressed: true, otherModifiers: false, time: 1.2))
        XCTAssertTrue(tap.update(left: true, pressed: false, otherModifiers: false, time: 1.28))

        // A press that crosses the launcher threshold cannot also count as a tap.
        XCTAssertFalse(tap.update(left: true, pressed: true, otherModifiers: false, time: 2))
        XCTAssertFalse(tap.update(left: true, pressed: false, otherModifiers: false, time: 2 + LeftOptionDoubleTap.holdDelay + 0.01))
        XCTAssertFalse(tap.update(left: true, pressed: true, otherModifiers: false, time: 2.3))
        XCTAssertFalse(tap.update(left: true, pressed: false, otherModifiers: false, time: 2.38))
    }

    func testRightOptionChordsLongHoldsAndInterruptedTapsNeverSwitch() {
        for mode in 0..<7 {
            var tap = LeftOptionDoubleTap()
            XCTAssertFalse(tap.update(left: true, pressed: true, otherModifiers: false, time: 1))
            XCTAssertFalse(tap.update(left: true, pressed: false, otherModifiers: false, time: mode == 0 ? 1.5 : 1.08))
            if mode == 1 { tap.reset() } // mouse/key chord
            if mode == 2 { _ = tap.update(left: false, pressed: true, otherModifiers: false, time: 1.1) }
            let down = mode == 3 ? 1.8 : 1.2
            let up = mode == 3 ? 1.9 : (mode == 4 ? 1.6 : (mode == 5 ? 1.1 : 1.28))
            XCTAssertFalse(tap.update(left: true, pressed: true, otherModifiers: mode == 6, time: down))
            XCTAssertFalse(tap.update(left: true, pressed: false, otherModifiers: false, time: up), "mode \(mode)")
        }
    }

    func testKeyboardSequenceBalancesModifiersAndTargetsPhysicalKey() throws {
        let events = try XCTUnwrap(ActionFocusAccess.events(Shortcut(keyCode: 3, modifiers: UInt32(cmdKey | shiftKey), label: "F")))
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [56, 55, 3, 3, 55, 56])
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        XCTAssertEqual(events[2].flags, [.maskCommand, .maskShift])
        XCTAssertEqual(events.last?.flags, [])
    }

    func testFocusRequiresSameProcessWindowAndControlWithoutReadingText() throws {
        let pid: pid_t = 81234, target = AXUIElementCreateApplication(81234), other = AXUIElementCreateApplication(81235)
        let date = Date(timeIntervalSince1970: 12345)
        var mode = 0
        let read: ActionFocusAccess.Read = { _, attribute in
            switch attribute {
            case kAXFocusedWindowAttribute: return (mode == 1 ? other : target, .success)
            case kAXFocusedUIElementAttribute: return (mode == 2 ? other : (mode == 3 ? nil : target), mode == 3 ? .noValue : .success)
            case kAXRoleAttribute: return ((mode == 4 ? kAXApplicationRole : kAXWindowRole) as CFString, .success)
            case kAXSubroleAttribute: return ((mode == 5 ? kAXSecureTextFieldSubrole : kAXStandardWindowSubrole) as CFString, .success)
            default: XCTFail("Must not read text, selection or other attributes: \(attribute)"); return (nil, .attributeUnsupported)
            }
        }
        let focus = try XCTUnwrap(ActionFocusAccess.capture(pid: pid, read: read, foreground: { pid }, launched: { _ in date }))
        XCTAssertTrue(ActionFocusAccess.matches(focus, read: read, foreground: { pid }, launched: { _ in date }))
        for value in 1...5 {
            mode = value
            XCTAssertFalse(ActionFocusAccess.matches(focus, read: read, foreground: { pid }, launched: { _ in date }), "mode \(mode)")
        }
        mode = 3
        let windowFocus = try XCTUnwrap(ActionFocusAccess.capture(pid: pid, read: read, foreground: { pid }, launched: { _ in date }))
        XCTAssertNil(windowFocus.element)
        XCTAssertTrue(ActionFocusAccess.matches(windowFocus, read: read, foreground: { pid }, launched: { _ in date }))
        mode = 0
        XCTAssertFalse(ActionFocusAccess.matches(ActionFocus(pid: pid, launched: date, window: other, element: target), read: read, foreground: { pid }, launched: { _ in date }))
        XCTAssertFalse(ActionFocusAccess.matches(ActionFocus(pid: pid, launched: date, window: target, element: other), read: read, foreground: { pid }, launched: { _ in date }))
        XCTAssertFalse(ActionFocusAccess.matches(focus, read: read, foreground: { 81235 }, launched: { _ in date }))
        XCTAssertFalse(ActionFocusAccess.matches(focus, read: read, foreground: { pid }, launched: { _ in date.addingTimeInterval(1) }))
        XCTAssertNil(ActionFocusAccess.capture(pid: pid, read: read, foreground: { pid }, launched: { _ in nil }))
    }

    func testWindowFocusCompatibilityRejectsFailuresAndChangedTargets() throws {
        let pid: pid_t = 81234, window = AXUIElementCreateApplication(81234)
        let date = Date(timeIntervalSince1970: 12345)
        var controlError = AXError.noValue
        var windowError = AXError.success
        var secure = false
        let read: ActionFocusAccess.Read = { _, attribute in
            switch attribute {
            case kAXFocusedWindowAttribute: return (windowError == .success ? window : nil, windowError)
            case kAXFocusedUIElementAttribute: return (controlError == .success ? window : nil, controlError)
            case kAXRoleAttribute: return (kAXWindowRole as CFString, .success)
            case kAXSubroleAttribute: return ((secure ? kAXSecureTextFieldSubrole : kAXStandardWindowSubrole) as CFString, .success)
            default: XCTFail("Unexpected attribute: \(attribute)"); return (nil, .attributeUnsupported)
            }
        }
        let target = try XCTUnwrap(ActionFocusAccess.capture(pid: pid, read: read, foreground: { pid }, launched: { _ in date }))
        XCTAssertEqual(target.scope, "window")
        for error in [AXError.noValue, .attributeUnsupported, .success] {
            controlError = error
            XCTAssertTrue(ActionFocusAccess.matches(target, read: read, foreground: { pid }, launched: { _ in date }))
        }
        let strict = try XCTUnwrap(ActionFocusAccess.capture(pid: pid, read: read, foreground: { pid }, launched: { _ in date }))
        XCTAssertEqual(strict.scope, "control")
        for error in [AXError.noValue, .attributeUnsupported, .cannotComplete] {
            controlError = error
            XCTAssertFalse(ActionFocusAccess.matches(strict, read: read, foreground: { pid }, launched: { _ in date }))
        }
        controlError = .success
        // A control becoming visible does not invalidate a window-scoped target,
        // but a secure control still prevents dispatch.
        secure = true
        XCTAssertFalse(ActionFocusAccess.matches(target, read: read, foreground: { pid }, launched: { _ in date }))
        secure = false
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .failure] {
            controlError = error
            XCTAssertNil(ActionFocusAccess.capture(pid: pid, read: read, foreground: { pid }, launched: { _ in date }))
            XCTAssertFalse(ActionFocusAccess.matches(target, read: read, foreground: { pid }, launched: { _ in date }))
        }
        controlError = .noValue
        for error in [AXError.noValue, .attributeUnsupported, .cannotComplete, .apiDisabled] {
            windowError = error
            XCTAssertFalse(ActionFocusAccess.matches(target, read: read, foreground: { pid }, launched: { _ in date }))
        }
        windowError = .success
        XCTAssertFalse(ActionFocusAccess.matches(target, read: read, foreground: { pid + 1 }, launched: { _ in date }))
        XCTAssertFalse(ActionFocusAccess.matches(target, read: read, foreground: { pid }, launched: { _ in date.addingTimeInterval(1) }))
        let differentWindow = ActionFocus(pid: pid, launched: date, window: AXUIElementCreateApplication(pid + 1), element: nil)
        XCTAssertFalse(ActionFocusAccess.matches(differentWindow, read: read, foreground: { pid }, launched: { _ in date }))
    }

    @MainActor func testExecutorPostsOnlyWhenFocusMatches() async {
        let target = AXUIElementCreateApplication(81234)
        let focus = ActionFocus(pid: 81234, launched: Date(), window: target, element: target)
        for valid in [false, true] {
            let completed = expectation(description: "completed")
            var count = 0
            let executor = ActionExecutor(matches: { _ in valid }, released: { true }, post: { _, pid in
                XCTAssertEqual(pid, focus.pid); count += 1
            })
            executor.execute(AppAction(name: "Find", shortcut: shortcut), target: focus, invocation: Shortcut()) { sent in
                XCTAssertEqual(sent, valid); XCTAssertEqual(count, valid ? 4 : 0); completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 2)
        }
    }

    @MainActor func testPendingCaptureCannotSurviveCancellationOrReplaceNewSession() async {
        let started = expectation(description: "started"), finished = expectation(description: "finished")
        let gate = DispatchSemaphore(value: 0)
        let target = AXUIElementCreateApplication(81234)
        let executor = ActionExecutor(capture: { pid in
            started.fulfill(); gate.wait(); finished.fulfill()
            return ActionFocus(pid: pid, launched: Date(), window: target, element: target)
        })
        executor.prepare(pid: 81234) { _ in XCTFail("Cancelled capture must not update UI") }
        await fulfillment(of: [started], timeout: 1)
        executor.cancel(); gate.signal()
        await fulfillment(of: [finished], timeout: 1)
        await Task.yield()
        XCTAssertNil(executor.focus)
    }

    @MainActor func testHeldPhysicalModifiersCancelWithoutSendingAnyEvent() async {
        let target = AXUIElementCreateApplication(81234)
        let done = expectation(description: "modifier timeout")
        let executor = ActionExecutor(matches: { _ in XCTFail("Must not query focus while modifiers remain held"); return true },
                                      released: { false }, post: { _, _ in XCTFail("Must not send") })
        executor.execute(AppAction(name: "Find", shortcut: shortcut),
                         target: ActionFocus(pid: 81234, launched: Date(), window: target, element: target), invocation: Shortcut()) {
            XCTAssertFalse($0); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
    }

    @MainActor func testActionSurfaceNeverTakesKeyFocusAndRequiresMatchingDownUp() {
        let panel = ActionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = ActionRingView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(view.acceptsFirstResponder); XCTAssertFalse(view.needsPanelToBecomeKey)
        view.actions = (0..<8).map { AppAction(id: "\($0)", name: "Action \($0)", shortcut: shortcut) }
        var sent: [String] = []; view.onAction = { sent.append($0.id) }
        let first = RingGeometry.point(angle: RingGeometry.angle(index: 0, count: 6), radius: RingGeometry.appRadius)
        let second = RingGeometry.point(angle: RingGeometry.angle(index: 1, count: 6), radius: RingGeometry.appRadius)
        view.begin(at: first); view.end(at: first)
        XCTAssertEqual(sent, []) // focus not captured yet
        view.ready = true
        view.begin(at: first); view.end(at: second)
        XCTAssertEqual(sent, [])
        view.begin(at: first); view.turnPage(1)
        XCTAssertEqual(view.page, 0) // cannot page under pressed mouse
        view.end(at: first)
        XCTAssertEqual(sent, ["0"])
        view.turnPage(1)
        XCTAssertEqual(view.visible.map(\.id), ["6", "7"])
        view.turnPage(1); XCTAssertEqual(view.page, 0)
        XCTAssertNil(view.target(at: RingGeometry.center))
    }
    @MainActor func testActionPanelPreservesSearchFieldResponderAndSelection() throws {
        _ = NSApplication.shared
        let source = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let search = NSSearchField(frame: CGRect(x: 20, y: 20, width: 300, height: 24))
        search.stringValue = "fixture query"
        source.contentView?.addSubview(search)
        source.makeKeyAndOrderFront(nil)
        XCTAssertTrue(source.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor())
        editor.selectedRange = NSRange(location: 3, length: 2)
        let panel = ActionPanel(contentRect: CGRect(x: -10000, y: -10000, width: 480, height: 480), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = ActionRingView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        panel.contentView = view
        defer { panel.orderOut(nil); source.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(source.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 3, length: 2))
        panel.orderOut(nil)
        XCTAssertTrue(source.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 3, length: 2))
    }

    @MainActor func testDismissDuringFocusCheckPreventsSending() async {
        let started = expectation(description: "focus check started"), checked = expectation(description: "focus checked")
        let noSend = expectation(description: "no send or callback"); noSend.isInverted = true
        let gate = DispatchSemaphore(value: 0), target = AXUIElementCreateApplication(81234)
        let executor = ActionExecutor(matches: { _ in started.fulfill(); gate.wait(); checked.fulfill(); return true },
                                      released: { true }, post: { _, _ in noSend.fulfill() })
        executor.execute(AppAction(name: "Find", shortcut: shortcut),
                         target: ActionFocus(pid: 81234, launched: Date(), window: target, element: target), invocation: Shortcut()) { _ in noSend.fulfill() }
        await fulfillment(of: [started], timeout: 1)
        executor.cancel(); gate.signal()
        await fulfillment(of: [checked, noSend], timeout: 0.15)
    }

}
