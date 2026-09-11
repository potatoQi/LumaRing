import XCTest
import AppKit
import LumaRingCore
@testable import LumaRing

final class WindowStyleEditorTests: XCTestCase {
    private func record(_ id: String = "a") -> WindowRecord {
        WindowRecord(id: id, pid: 100, title: "Original", minimized: false, fullscreen: false,
                     frame: .zero, element: AXUIElementCreateApplication(100))
    }
    @MainActor func testPointerExitAndLateResultsCannotClearEditingTarget() async {
        let view = RingView()
        let app = AppRecord(pid: 100, bundleID: "test", name: "Test", icon: NSImage())
        view.reset(apps: [app], options: Options()); view.select(app)
        view.setWindows(.ready([record("a"), record("b")]), for: 100)
        view.isEditingName = true
        let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        view.mouseExited(with: exit)
        view.clearSelection()
        view.updateHover(at: .zero)
        view.setWindows(.ready([]), for: 100)
        XCTAssertEqual(view.windows.map(\.id), ["a", "b"])
        XCTAssertEqual(view.selectedApp, 100)
        XCTAssertTrue(view.showsWindowArc)
        view.isEditingName = false
        view.updateWindow("a", name: "Updated", color: .blue)
        XCTAssertEqual(view.windows.first { $0.id == "a" }?.displayTitle, "Updated")
        XCTAssertEqual(view.windows.first { $0.id == "a" }?.customColor, .blue)
        view.clearSelection(); XCTAssertTrue(view.windows.isEmpty)
    }
    @MainActor func testColorOnlyStylePersistsAndResets() async throws {
        let suite = "StyleEditorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = WindowNames.Process(pid: 100, bundleID: "test", launched: Date(timeIntervalSinceReferenceDate: 100))
        let store = WindowNames(defaults: defaults, process: { _ in .running(owner) })
        func styled(_ store: WindowNames) -> WindowRecord {
            guard case .ready(let records, _) = store.apply(.ready([record()]), pid: 100) else { fatalError() }
            return records[0]
        }
        XCTAssertTrue(store.update(name: "", color: .violet, for: record(), expected: owner))
        let reloaded = WindowNames(defaults: defaults, process: { _ in .running(owner) })
        XCTAssertNil(styled(reloaded).customName)
        XCTAssertEqual(styled(reloaded).customColor, .violet)
        reloaded.update(name: "", color: nil, for: record())
        XCTAssertNil(styled(reloaded).customName); XCTAssertNil(styled(reloaded).customColor)
    }
    @MainActor func testFloatingEditorOffersTwoRowsAndCancelDoesNotSave() async {
        _ = NSApplication.shared
        let editor = WindowStyleEditor(record: record())
        let rows = Dictionary(grouping: editor.colorButtons, by: { $0.frame.minY })
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows.values.allSatisfy { $0.count == 6 })
        XCTAssertTrue(editor.nameField.stringValue.isEmpty, "Color-only changes must not freeze the original title")
        XCTAssertNil(editor.window?.sheetParent)
        var saved: (String, SectorColor?)?, cancelled = false
        editor.onSave = { saved = ($0, $1); return false }
        editor.onCancel = { cancelled = true }
        editor.nameField.stringValue = "Workspace"
        editor.selectColor(.teal)
        XCTAssertEqual(editor.colorButtons.filter { $0.state == .on }.count, 1)
        editor.cancelEditing(); XCTAssertTrue(cancelled); XCTAssertNil(saved)
        editor.saveEditing(); XCTAssertEqual(saved?.0, "Workspace"); XCTAssertEqual(saved?.1, .teal)
        editor.selectColor(nil); XCTAssertTrue(editor.colorButtons.allSatisfy { $0.state == .off })
    }
    func testColoredSectorsMatchSecondaryHitRegions() {
        for count in 2...8 {
            for anchor in [0.0, .pi / 2, .pi, -.pi / 2] {
                for step in 0..<720 {
                    let angle = Double(step) * .pi / 360
                    let point = RingGeometry.point(angle: angle, radius: 158)
                    guard let hit = RingGeometry.arcIndex(at: point, count: count, anchor: anchor) else { continue }
                    // Avoid exact shared edges, where either path may contain the same point.
                    let midpoint = RingGeometry.arcAngle(index: hit, count: count, anchor: anchor)
                    let offset = abs(atan2(sin(angle - midpoint), cos(angle - midpoint)))
                    if abs(offset - RingGeometry.arcStep * 0.5) < 0.00001 { continue }
                    XCTAssertTrue(RingGeometry.windowSectorPath(index: hit, count: count, anchor: anchor).contains(point))
                }
            }
        }
    }
    @MainActor func testEditorAndColoredRingSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMARING_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let editor = WindowStyleEditor(record: record())
        editor.nameField.stringValue = "项目周报"; editor.selectColor(.blue)
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        let app = AppRecord(pid: 100, bundleID: "test", name: "Notes", icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app"))
        view.reset(apps: [app], options: Options()); view.select(app)
        view.setWindows(.ready([record("a"), record("b"), record("c")]), for: 100)
        view.updateWindow("a", name: "项目周报", color: .blue)
        view.updateWindow("b", name: "设计方案", color: .orange)
        view.updateWindow("c", name: "工作笔记", color: .green)
        let host = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = view
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            editor.window?.appearance = NSAppearance(named: theme); view.appearance = NSAppearance(named: theme)
            for (name, content) in [("editor", editor.window!.contentView!), ("ring", view)] {
                content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(theme.rawValue).png"))
            }
        }
        host.contentView = nil
    }
}
