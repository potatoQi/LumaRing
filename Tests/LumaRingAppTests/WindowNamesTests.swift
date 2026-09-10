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
        let store = WindowNames(defaults: defaults, process: { _ in owner })
        let target = record("tab:100:1", tab: true)
        XCTAssertTrue(store.update(name: "  Work\n Notes  ", color: nil, for: target))
        var moved = record(target.id, title: "Updated page title", tab: true)
        moved.tab = BrowserTab(bundleID: "test.app", windowID: "w2", id: target.id, title: moved.title,
                               url: "https://example.com/new", windowIndex: 2, index: 4, minimized: false)
        let restored = WindowNames(defaults: defaults, process: { _ in owner })
        let display = values(restored.apply(.ready([moved]), pid: 100, isTab: true))[0]
        XCTAssertEqual(display.displayTitle, "Work Notes")
        XCTAssertEqual(display.title, "Updated page title")
        XCTAssertEqual(display.tab, moved.tab)
        XCTAssertEqual(display.id, moved.id)
        XCTAssertTrue(CFEqual(display.element, moved.element))
        XCTAssertTrue(restored.update(name: " \n ", color: nil, for: moved))
        XCTAssertEqual(values(restored.apply(.ready([moved]), pid: 100, isTab: true))[0].displayTitle, moved.title)
    }
    @MainActor func testPartialQueriesDoNotEraseNamesAndCompleteQueriesOnlyPruneTheirMode() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = owner, window = record("window"), tab = record("tab", tab: true)
        let store = WindowNames(defaults: defaults, process: { _ in owner })
        store.update(name: "Window Alias", color: nil, for: window); store.update(name: "Tab Alias", color: nil, for: tab)
        _ = store.apply(.ready([], limited: true), pid: 100, isTab: false)
        XCTAssertEqual(values(store.apply(.ready([window]), pid: 100, isTab: false))[0].customName, "Window Alias")
        _ = store.apply(.permissionRequired, pid: 100, isTab: false)
        _ = store.apply(.unavailable("test"), pid: 100, isTab: false)
        XCTAssertEqual(values(store.apply(.ready([tab]), pid: 100, isTab: true))[0].customName, "Tab Alias")
        _ = store.apply(.ready([]), pid: 100, isTab: false)
        XCTAssertNil(values(store.apply(.ready([window]), pid: 100, isTab: false))[0].customName)
        XCTAssertEqual(values(store.apply(.ready([tab]), pid: 100, isTab: true))[0].customName, "Tab Alias")
    }
    @MainActor func testDifferentIDsAndProcessRestartsCannotInheritNames() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        var current: WindowNames.Process? = owner
        let store = WindowNames(defaults: defaults, process: { _ in current })
        store.update(name: "Unique", color: nil, for: record("one"))
        let rows = values(store.apply(.ready([record("one"), record("two")]), pid: 100, isTab: false))
        XCTAssertEqual(rows[0].customName, "Unique"); XCTAssertNil(rows[1].customName)
        current = .init(pid: 100, bundleID: "test.app", launched: owner.launched.addingTimeInterval(1))
        XCTAssertFalse(store.update(name: "Stale dialog", color: nil, for: record("one"), expected: owner))
        XCTAssertNil(values(store.apply(.ready([record("one")]), pid: 100, isTab: false))[0].customName)
        store.pruneTerminated()
        current = owner
        XCTAssertNil(values(store.apply(.ready([record("one")]), pid: 100, isTab: false))[0].customName)
        current = nil
        XCTAssertFalse(store.update(name: "Missing app", color: nil, for: record("one")))
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
