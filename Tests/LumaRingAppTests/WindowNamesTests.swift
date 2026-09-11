import XCTest
import AppKit
import LumaRingCore
@testable import LumaRing

final class WindowNamesTests: XCTestCase {
    private let owner = WindowNames.Process(pid: 100, bundleID: "test.app", launched: Date(timeIntervalSince1970: 1000))
    private func record(_ id: String, title: String = "Document", tab: Bool = false) -> WindowRecord {
        WindowRecord(id: id, pid: 100, title: title, minimized: false, fullscreen: false,
                     frame: CGRect(x: 10, y: 10, width: 600, height: 400), element: AXUIElementCreateApplication(100),
                     tab: tab ? BrowserTab(bundleID: "test.app", windowID: "w1", id: id, title: title,
                                           url: "https://example.com", windowIndex: 1, index: 1, minimized: false) : nil)
    }
    private func suite() -> (UserDefaults, String) {
        let name = "WindowNamesTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
    private func values(_ result: WindowResult) -> [WindowRecord] {
        guard case .ready(let rows, _) = result else { XCTFail("Expected records"); return [] }
        return rows
    }
    func testNaturalSortingAndDuplicateNamesIgnoreReturnedOrder() {
        let records = [record("c", title: "Page 10"), record("b", title: "Page 2"), record("a", title: "Page 2"), record("d", title: "Page 1", tab: true)]
        for input in [records, Array(records.reversed()), [records[2], records[0], records[3], records[1]]] {
            XCTAssertEqual(WindowRecord.sortedByName(input).map(\.id), ["d", "a", "b", "c"])
        }
        var renamed = records[0]; renamed.customName = "Page 0"
        XCTAssertEqual(WindowRecord.sortedByName([records[1], renamed]).first?.id, "c")
    }
    @MainActor func testAliasPersistsAcrossStoreReloadAndTitleChangesWithoutChangingOriginal() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = owner
        let store = WindowNames(defaults: defaults, process: { _ in .running(owner) })
        let target = record("tab:100:1", tab: true)
        XCTAssertTrue(store.update(name: "  Work\n Notes  ", color: nil, for: target))
        var moved = record(target.id, title: "Updated page title", tab: true)
        moved.tab = BrowserTab(bundleID: "test.app", windowID: "w2", id: target.id, title: moved.title,
                               url: "https://example.com/new", windowIndex: 2, index: 4, minimized: false)
        let restored = WindowNames(defaults: defaults, process: { _ in .running(owner) })
        let display = values(restored.apply(.ready([moved]), pid: 100))[0]
        XCTAssertEqual(display.displayTitle, "Work Notes")
        XCTAssertEqual(display.title, "Updated page title")
        XCTAssertEqual(display.tab, moved.tab)
        XCTAssertEqual(display.id, moved.id)
        XCTAssertTrue(CFEqual(display.element, moved.element))
        XCTAssertTrue(restored.update(name: " \n ", color: nil, for: moved))
        XCTAssertEqual(values(restored.apply(.ready([moved]), pid: 100))[0].displayTitle, moved.title)
    }
    @MainActor func testMissingSnapshotsDoNotEraseWindowOrTabStyles() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = owner, window = record("window"), tab = record("tab", tab: true)
        let store = WindowNames(defaults: defaults, process: { _ in .running(owner) })
        store.update(name: "Window Alias", color: .blue, for: window); store.update(name: "Tab Alias", color: .orange, for: tab)
        _ = store.apply(.ready([], limited: true), pid: 100)
        XCTAssertEqual(values(store.apply(.ready([window]), pid: 100))[0].customName, "Window Alias")
        _ = store.apply(.permissionRequired, pid: 100)
        _ = store.apply(.unavailable("test"), pid: 100)
        XCTAssertEqual(values(store.apply(.ready([tab]), pid: 100))[0].customName, "Tab Alias")
        _ = store.apply(.ready([]), pid: 100)
        _ = store.apply(.ready([]), pid: 100)
        let reloaded = WindowNames(defaults: defaults, process: { _ in .running(owner) })
        let restoredWindow = values(reloaded.apply(.ready([window]), pid: 100))[0]
        let restoredTab = values(reloaded.apply(.ready([tab]), pid: 100))[0]
        XCTAssertEqual(restoredWindow.customName, "Window Alias")
        XCTAssertEqual(restoredWindow.customColor, .blue)
        XCTAssertEqual(restoredTab.customName, "Tab Alias")
        XCTAssertEqual(restoredTab.customColor, .orange)
    }
    @MainActor func testTemporarilyOmittedWindowKeepsStyleWhenItReturnsWithChangedTitle() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = owner, first = record("one"), second = record("two")
        let store = WindowNames(defaults: defaults, process: { _ in .running(owner) })
        store.update(name: "Work", color: .blue, for: first)
        store.update(name: "Reference", color: .green, for: second)
        for _ in 0..<3 {
            let visible = values(store.apply(.ready([second]), pid: 100))
            XCTAssertEqual(visible.count, 1, "Retained styles must not resurrect missing windows")
            XCTAssertEqual(visible[0].customColor, .green)
        }
        let reloaded = WindowNames(defaults: defaults, process: { _ in .running(owner) })
        let returned = record("one", title: "Another file — Workspace")
        let rows = values(reloaded.apply(.ready([returned, second, record("new")]), pid: 100))
        XCTAssertEqual(rows[0].customName, "Work")
        XCTAssertEqual(rows[0].customColor, .blue)
        XCTAssertEqual(rows[0].title, returned.title)
        XCTAssertEqual(rows[1].customName, "Reference")
        XCTAssertEqual(rows[1].customColor, .green)
        XCTAssertNil(rows[2].customName)
        XCTAssertNil(rows[2].customColor)
    }
    @MainActor func testDifferentIDsAndProcessRestartsCannotInheritNames() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        var current: WindowNames.Process? = owner
        let store = WindowNames(defaults: defaults, process: { _ in current.map { .running($0) } ?? .unavailable })
        store.update(name: "Unique", color: nil, for: record("one"))
        let rows = values(store.apply(.ready([record("one"), record("two")]), pid: 100))
        XCTAssertEqual(rows[0].customName, "Unique"); XCTAssertNil(rows[1].customName)
        current = .init(pid: 100, bundleID: "test.app", launched: owner.launched.addingTimeInterval(1))
        XCTAssertFalse(store.update(name: "Stale dialog", color: nil, for: record("one"), expected: owner))
        XCTAssertNil(values(store.apply(.ready([record("one")]), pid: 100))[0].customName)
        store.pruneTerminated()
        current = owner
        XCTAssertNil(values(store.apply(.ready([record("one")]), pid: 100))[0].customName)
        current = nil
        XCTAssertFalse(store.update(name: "Missing app", color: nil, for: record("one")))
    }
    @MainActor func testUnavailableProcessLookupDoesNotEraseStylesDuringPruningOrReload() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        var current: WindowNames.Process? = owner
        let first = record("one"), second = record("two")
        let store = WindowNames(defaults: defaults, process: { _ in current.map { .running($0) } ?? .unavailable })
        store.update(name: "Work", color: .blue, for: first)
        store.update(name: "Reference", color: .green, for: second)
        let saved = defaults.data(forKey: "windowStyles.v1")
        current = nil
        store.pruneTerminated()
        XCTAssertEqual(defaults.data(forKey: "windowStyles.v1"), saved)
        let reloaded = WindowNames(defaults: defaults, process: { _ in current.map { .running($0) } ?? .unavailable })
        XCTAssertEqual(defaults.data(forKey: "windowStyles.v1"), saved)
        XCTAssertNil(values(reloaded.apply(.ready([first]), pid: 100))[0].customName)
        current = owner
        let restored = values(reloaded.apply(.ready([first, second]), pid: 100))
        XCTAssertEqual(restored[0].customName, "Work")
        XCTAssertEqual(restored[0].customColor, .blue)
        XCTAssertEqual(restored[1].customName, "Reference")
        XCTAssertEqual(restored[1].customColor, .green)
    }
    @MainActor func testConfirmedProcessExitRemovesOnlyItsStylesFromDisk() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = owner
        let other = WindowNames.Process(pid: 200, bundleID: "other.app", launched: owner.launched)
        var states: [pid_t: WindowNames.ProcessState] = [100: .running(owner), 200: .running(other)]
        let store = WindowNames(defaults: defaults, process: { states[$0] ?? .unavailable })
        store.update(name: "Window", color: .blue, for: record("one"))
        store.update(name: "Tab", color: .green, for: record("tab", tab: true))
        let otherWindow = WindowRecord(id: "other", pid: 200, title: "Other", minimized: false, fullscreen: false,
                                       frame: .zero, element: AXUIElementCreateApplication(200))
        store.update(name: "Keep", color: .orange, for: otherWindow)
        states = [100: .terminated, 200: .unavailable]
        store.pruneTerminated()
        // Reload before restoring fake identities, proving the deletion was persisted.
        let reloaded = WindowNames(defaults: defaults, process: { states[$0] ?? .unavailable })
        states = [100: .running(owner), 200: .running(other)]
        let removed = values(reloaded.apply(.ready([record("one"), record("tab", tab: true)]), pid: 100))
        XCTAssertTrue(removed.allSatisfy { $0.customName == nil && $0.customColor == nil })
        let kept = values(reloaded.apply(.ready([otherWindow]), pid: 200))[0]
        XCTAssertEqual(kept.customName, "Keep")
        XCTAssertEqual(kept.customColor, .orange)
    }
    @MainActor func testLiveProcessWithoutApplicationMetadataIsNotReportedAsTerminated() throws {
        let child = Foundation.Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let pid = child.processIdentifier
        if case .terminated = WindowNames.ProcessState.read(pid) { XCTFail("A live command-line process is not a terminated app") }
        XCTAssertTrue(child.isRunning, "The existence check must not signal or terminate a process")
        child.terminate()
        child.waitUntilExit()
        guard case .terminated = WindowNames.ProcessState.read(pid) else { return XCTFail("A reaped process must be reported as terminated") }
    }
    @MainActor func testRenamedWindowPreviewMatchesOriginalAndShowsAlias() async {
        var target = record("one", title: "Original title")
        target.customName = "My Project"
        let candidate = PreviewCandidate(id: 42, pid: 100, title: "Original title", frame: target.frame.offsetBy(dx: 20, dy: 20), layer: 0)
        XCTAssertEqual(PreviewMatcher.match(target, candidates: [candidate]), 42)
        let preview = WindowPreview()
        preview.show(window: target, image: nil, message: "", anchor: .zero, occupied: .zero,
                     screen: CGRect(x: 0, y: 0, width: 1200, height: 900), preferredSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(preview.view.title, "My Project")
        preview.dismiss()
    }
    @MainActor func testSecondaryContextMenuTargetsSortedRecordAndNeverParentApp() async {
        _ = NSApplication.shared
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        let app = AppRecord(pid: 100, bundleID: "test.app", name: "Test", icon: NSImage())
        view.reset(apps: [app], options: Options()); view.select(app)
        view.setWindows(.ready([record("b", title: "Z"), record("a", title: "A", tab: true)]), for: 100)
        var closed: WindowRecord?, renamed: WindowRecord?
        view.makeAppMenu = { _ in XCTFail("Wrong level"); return NSMenu() }
        view.makeWindowMenu = { AppContextMenu.make(window: $0, close: { closed = $0 }, edit: { renamed = $0 }) }
        for index in 0..<2 {
            let target = view.visibleWindows[index]
            let point = RingGeometry.point(angle: RingGeometry.arcAngle(index: index, count: 2, anchor: .pi / 2), radius: RingGeometry.windowRadius)
            let menu = try! XCTUnwrap(view.contextMenu(at: point))
            XCTAssertEqual(menu.items.count, 2)
            menu.performActionForItem(at: 0); menu.performActionForItem(at: 1)
            XCTAssertEqual(closed?.id, target.id); XCTAssertEqual(renamed?.id, target.id)
            XCTAssertEqual(closed?.tab, target.tab)
        }
        let close = view.closeButtonRect(at: 0)
        XCTAssertNotNil(view.contextMenu(at: CGPoint(x: close.midX, y: close.midY)))
        view.isEditingName = true
        XCTAssertNil(view.contextMenu(at: RingGeometry.point(angle: .pi / 2, radius: 158)))
        view.updateOption(pressed: true); XCTAssertFalse(view.showsLauncher)
    }
    @MainActor func testRenameReordersKeepsNewPageVisibleAndCancelsPressedTarget() async {
        let view = RingView()
        let app = AppRecord(pid: 100, bundleID: "test.app", name: "App", icon: NSImage())
        var options = Options(); options.windowPageSize = 2
        view.reset(apps: [app], options: options); view.select(app)
        view.setWindows(.ready([record("c", title: "C"), record("b", title: "B"), record("a", title: "A")]), for: 100)
        view.onActivateWindow = { _ in XCTFail("Rename cancels an old pointer target") }
        view.beginPointer(at: RingGeometry.point(angle: RingGeometry.arcAngle(index: 0, count: 2, anchor: .pi / 2), radius: 158))
        view.updateWindow("a", name: "Z", color: nil)
        XCTAssertEqual(view.windows.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(view.windowPage, 1)
        XCTAssertFalse(view.isPointerDown)
        view.endPointer(at: RingGeometry.point(angle: .pi / 2, radius: 158))
        view.updateWindow("a", name: "", color: nil)
        XCTAssertEqual(view.windowPage, 0); XCTAssertEqual(view.windows[0].title, "A")
    }
    @MainActor func testRenamePromptStartsWithCurrentAliasAndNormalizesInput() async {
        _ = NSApplication.shared
        var target = record("a"); target.customName = "Project"
        let editor = WindowStyleEditor(record: target)
        XCTAssertEqual(editor.colorButtons.count, 12)
        XCTAssertEqual(editor.nameField.stringValue, "Project")
        XCTAssertEqual(editor.nameField.placeholderString, target.title)
        XCTAssertTrue(editor.window?.initialFirstResponder === editor.nameField)
        XCTAssertNil(WindowRecord.normalizedName("\n \t"))
        XCTAssertEqual(WindowRecord.normalizedName(String(repeating: "中", count: 200))?.count, 120)
    }
}
