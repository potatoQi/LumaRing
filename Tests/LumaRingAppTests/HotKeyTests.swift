import AppKit
import Carbon
import XCTest
@testable import LumaRing

final class HotKeyTests: XCTestCase {
    func testHotKeysRouteOnlyTheirOwnEventsAndIgnoreRepeats() {
        let global = HotKey(), actions = HotKey()
        var presses = 0, releases = 0, actionPresses = 0
        global.onPress = { presses += 1 }; global.onRelease = { releases += 1 }
        actions.onPress = { actionPresses += 1 }
        XCTAssertNotEqual(global.id.id, actions.id.id)
        XCTAssertEqual(actions.handle(id: global.id, kind: UInt32(kEventHotKeyPressed)), OSStatus(eventNotHandledErr))
        XCTAssertEqual(global.handle(id: global.id, kind: UInt32(kEventHotKeyPressed)), noErr)
        _ = global.handle(id: global.id, kind: UInt32(kEventHotKeyPressed))
        _ = global.handle(id: global.id, kind: UInt32(kEventHotKeyReleased))
        _ = global.handle(id: global.id, kind: UInt32(kEventHotKeyReleased))
        _ = actions.handle(id: actions.id, kind: UInt32(kEventHotKeyPressed))
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 1); XCTAssertEqual(actionPresses, 1)
        global.unregister()
        _ = global.handle(id: global.id, kind: UInt32(kEventHotKeyReleased))
        XCTAssertEqual(releases, 1)
    }

    func testDirectInvocationPersistsAndConflictsIgnoreDisplayLabels() throws {
        var options = try JSONDecoder().decode(Options.self, from: Data("{}".utf8))
        XCTAssertNil(options.actionShortcut)
        options.actionShortcut = Shortcut(keyCode: 97, modifiers: 0, label: "F6")
        let loaded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(loaded.actionShortcut, options.actionShortcut)
        XCTAssertFalse(loaded.invocationConflict)
        let action = AppAction(name: "Test", shortcut: loaded.actionShortcut)
        XCTAssertTrue(loaded.invocationShortcuts.contains(where: action.conflicts))
        options.actionShortcut = Shortcut(keyCode: options.shortcut.keyCode, modifiers: options.shortcut.modifiers, label: "Different label")
        XCTAssertTrue(options.invocationConflict)
        options.actionShortcut = nil
        XCTAssertEqual(options.invocationShortcuts, [options.shortcut])
    }

    @MainActor func testRecorderAcceptsSingleKeysAndShiftOnlyCombinations() {
        let button = RecorderButton()
        var recorded: Shortcut?
        button.onRecord = { recorded = $0 }
        for (code, label, flags, modifiers) in [
            (UInt16(97), "F6", NSEvent.ModifierFlags(), UInt32(0)),
            (UInt16(0), "a", NSEvent.ModifierFlags(), UInt32(0)),
            (UInt16(0), "a", NSEvent.ModifierFlags.shift, UInt32(shiftKey))
        ] {
            button.performClick(nil)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: label, charactersIgnoringModifiers: label, isARepeat: false, keyCode: code)!
            XCTAssertTrue(button.performKeyEquivalent(with: event))
            XCTAssertEqual(recorded?.keyCode, UInt32(code))
            XCTAssertEqual(recorded?.modifiers, modifiers)
            XCTAssertFalse(button.recording)
        }
    }

    @MainActor func testRecordingSignalsPauseAndResumeOnFocusLoss() {
        let button = RecorderButton()
        var changes: [Bool] = []
        let token = NotificationCenter.default.addObserver(forName: RecorderButton.recordingDidChange, object: nil, queue: .main) {
            changes.append($0.object as! Bool)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        button.performClick(nil)
        button.performClick(nil)
        _ = button.resignFirstResponder()
        XCTAssertEqual(changes, [true, false])
    }

    @MainActor func testRecordingEndsWhenSettingsLosesKeyOrRecorderIsRemoved() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        let button = RecorderButton(frame: CGRect(x: 0, y: 0, width: 150, height: 30))
        window.contentView?.addSubview(button)
        button.savedTitle = "F6"
        button.performClick(nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(button.recording)
        XCTAssertEqual(button.title, "F6")
        button.performClick(nil)
        button.removeFromSuperview()
        XCTAssertFalse(button.recording)
    }
}
