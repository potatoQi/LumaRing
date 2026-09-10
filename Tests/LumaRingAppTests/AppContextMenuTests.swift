import XCTest
import AppKit
@testable import LumaRing

final class AppContextMenuTests: XCTestCase {
    @MainActor func testMenuOnlyShowsModeForSupportedAppsAndActionsUseCapturedTarget() async throws {
        _ = NSApplication.shared
        for bundle in ["com.google.Chrome", "test.unsupported"] {
            let app = AppRecord(pid: 100, bundleID: bundle, name: "Test", icon: NSImage())
            var mode: AppContentMode?, quit = false, created = false
            var ready: ((ApplicationWindowCreator.Command?) -> Void)?
            let menu = AppContextMenu.make(app: app, mode: .tabs, discover: { ready = $0 },
                newWindow: { XCTAssertEqual($0.pid, 100); created = true }, changeMode: { mode = $0 }, quit: { quit = true })
            XCTAssertFalse(menu.items[0].isEnabled)
            XCTAssertTrue(menu.items[0].isHidden, "Do not show a checking or disabled New Window placeholder")
            let submenu = menu.items.compactMap(\.submenu).first
            XCTAssertEqual(submenu != nil, BrowserAdapters.supports(bundle))
            if let submenu {
                XCTAssertEqual(submenu.items[1].state, .on)
                submenu.performActionForItem(at: 0)
                XCTAssertEqual(mode, .windows)
            }
            ready?(.init(pid: 100, bundleID: bundle))
            XCTAssertTrue(menu.items[0].isEnabled)
            XCTAssertFalse(menu.items[0].isHidden)
            menu.performActionForItem(at: 0); XCTAssertTrue(created)
            menu.performActionForItem(at: menu.items.count - 1); XCTAssertTrue(quit)
        }
    }

    @MainActor func testUnavailableNewWindowIsHiddenWithoutLeavingAnEmptySeparator() async {
        for bundle in ["test.unsupported", "com.google.Chrome"] {
            let app = AppRecord(pid: 100, bundleID: bundle, name: "Test", icon: NSImage())
            var ready: ((ApplicationWindowCreator.Command?) -> Void)?
            var quit = false
            let menu = AppContextMenu.make(app: app, mode: .windows, discover: { ready = $0 },
                newWindow: { _ in XCTFail("Unavailable action must not run") }, changeMode: { _ in }, quit: { quit = true })
            ready?(nil)
            let visible = menu.items.filter { !$0.isHidden }
            XCTAssertEqual(visible.count, BrowserAdapters.supports(bundle) ? 3 : 1)
            XCTAssertFalse(visible.first!.isSeparatorItem)
            XCTAssertFalse(visible.last!.isSeparatorItem)
            XCTAssertTrue(menu.items[0].isHidden)
            XCTAssertFalse(menu.items[0].isEnabled)
            menu.performActionForItem(at: menu.items.count - 1)
            XCTAssertTrue(quit)
        }
    }
    func testWindowDiscoveryRejectsUnrelatedCommandsDisabledItemsAndWrongOwners() {
        XCTAssertTrue(ApplicationWindowCreator.isNewWindowTitle("New Window…"))
        XCTAssertTrue(ApplicationWindowCreator.isNewWindowTitle("新建窗口"))
        XCTAssertFalse(ApplicationWindowCreator.isNewWindowTitle("New Private Window"))
        XCTAssertFalse(ApplicationWindowCreator.isNewWindowTitle("New Tab"))
        XCTAssertFalse(ApplicationWindowCreator.isNewWindowTitle("New Document"))
        let root = AXUIElementCreateApplication(100)
        let item = AXUIElementCreateApplication(100)
        for enabled in [false, true] {
            let found = ApplicationWindowCreator.find(in: root, pid: 100, read: { node, key in
                if node === root { return key == kAXChildrenAttribute ? [item] as CFArray : nil }
                if key == kAXRoleAttribute { return kAXMenuItemRole as CFString }
                if key == kAXTitleAttribute { return "New Window" as CFString }
                if key == kAXEnabledAttribute { return NSNumber(value: enabled) }
                return nil
            })
            XCTAssertEqual(found != nil, enabled)
        }
        XCTAssertNil(ApplicationWindowCreator.find(in: root, pid: 101, read: { _, _ in XCTFail("Foreign PID must not be queried"); return nil }))
    }

    func testDiscoveryReachesFileMenuBeforeDeepRecentItems() {
        let root = AXUIElementCreateApplication(100), apple = AXUIElementCreateApplication(100)
        let file = AXUIElementCreateApplication(100), recent = AXUIElementCreateApplication(100)
        let fileMenu = AXUIElementCreateApplication(100), create = AXUIElementCreateApplication(100)
        let distractors = (0..<300).map { _ in AXUIElementCreateApplication(100) }
        let result = ApplicationWindowCreator.find(in: root, pid: 100) { node, key in
            if key == kAXChildrenAttribute {
                if node === root { return [apple, file] as CFArray }
                if node === apple { return [recent] as CFArray }
                if node === recent { return distractors as CFArray }
                if node === file { return [fileMenu] as CFArray }
                if node === fileMenu { return [create] as CFArray }
                return nil
            }
            if key == kAXRoleAttribute { return kAXMenuItemRole as CFString }
            if key == kAXTitleAttribute { return (node === create ? "New Window" : "Other") as CFString }
            if key == kAXEnabledAttribute { return NSNumber(value: true) }
            return nil
        }
        XCTAssertTrue(result === create)
    }

    func testMenuDiscoveryBatchesEachNodesAttributesAndSupportsFallback() {
        let root = AXUIElementCreateApplication(100), item = AXUIElementCreateApplication(100)
        var requests = 0
        let read = ApplicationWindowCreator.menuReader(batch: { node in
            requests += 1
            if node === root { return [kAXChildrenAttribute: [item], kAXRoleAttribute: kAXMenuBarRole] }
            return [kAXRoleAttribute: kAXMenuItemRole, kAXTitleAttribute: "New Window", kAXEnabledAttribute: true]
        }, fallback: { _, _ in XCTFail("Successful bulk read needs no individual reads"); return nil })
        XCTAssertTrue(ApplicationWindowCreator.find(in: root, pid: 100, read: read) === item)
        XCTAssertEqual(requests, 2)

        let fallback = ApplicationWindowCreator.menuReader(batch: { _ in nil }, fallback: { node, key in
            if node === root { return key == kAXChildrenAttribute ? [item] as CFArray : nil }
            switch key {
            case kAXRoleAttribute: return kAXMenuItemRole as CFString
            case kAXTitleAttribute: return "New Window" as CFString
            case kAXEnabledAttribute: return kCFBooleanTrue
            default: return nil
            }
        })
        XCTAssertTrue(ApplicationWindowCreator.find(in: root, pid: 100, read: fallback) === item)
    }

    func testCapturedMenuCommandSkipsSearchAndDoesNotRetryFailedPress() {
        let item = AXUIElementCreateApplication(100)
        let command = ApplicationWindowCreator.Command(pid: 100, bundleID: "test.app",
            menuItem: .init(element: item, title: "Basic"))
        for succeeds in [false, true] {
            var reads = 0, presses = 0
            let read = ApplicationWindowCreator.menuReader(batch: { _ in
                reads += 1
                // Terminal's default profile has its own title, not New Window.
                return [kAXRoleAttribute: kAXMenuItemRole, kAXTitleAttribute: "Basic", kAXEnabledAttribute: true]
            })
            let result = ApplicationWindowCreator.pressMenu(command, read: read,
                locate: { XCTFail("Valid captured item must not rescan menus"); return nil },
                press: { XCTAssertTrue($0 === item); presses += 1; return succeeds })
            XCTAssertEqual(result, succeeds)
            XCTAssertEqual(reads, 1); XCTAssertEqual(presses, 1)
        }
    }

    func testChangedDisabledAndForeignCapturedCommandsAreNeverPressed() {
        let item = AXUIElementCreateApplication(100), replacement = AXUIElementCreateApplication(100)
        for (pid, title, enabled) in [(pid_t(100), "New Document", true), (100, "New Window", false), (101, "New Window", true)] {
            var searches = 0, presses = 0
            let command = ApplicationWindowCreator.Command(pid: pid, bundleID: "test.app",
                menuItem: .init(element: item, title: "New Window"))
            let read = ApplicationWindowCreator.menuReader(batch: { _ in
                XCTAssertEqual(pid, 100, "A foreign element must not be queried")
                return [kAXRoleAttribute: kAXMenuItemRole, kAXTitleAttribute: title, kAXEnabledAttribute: enabled]
            })
            XCTAssertTrue(ApplicationWindowCreator.pressMenu(command, read: read,
                locate: { searches += 1; return replacement },
                press: { XCTAssertTrue($0 === replacement); presses += 1; return true }))
            XCTAssertEqual(searches, 1); XCTAssertEqual(presses, 1)
        }
    }
    @MainActor func testChangingModeReloadsSelectionAndUnsupportedAppCannotChange() async {
        let view = RingView()
        let chrome = AppRecord(pid: 100, bundleID: "com.google.Chrome", name: "Chrome", icon: NSImage())
        let other = AppRecord(pid: 101, bundleID: "test.other", name: "Other", icon: NSImage())
        view.reset(apps: [chrome, other], options: Options())
        view.select(chrome)
        var requests: [pid_t] = []
        view.onSelectApp = { requests.append($0.pid) }
        view.changeContentMode(.tabs, for: chrome)
        XCTAssertEqual(view.options.contentMode(for: chrome.bundleID), .tabs)
        XCTAssertEqual(requests, [100]); XCTAssertEqual(view.selectedApp, 100)
        view.changeContentMode(.tabs, for: other)
        XCTAssertEqual(view.options.contentMode(for: other.bundleID), .windows)
        XCTAssertEqual(requests, [100])
    }
}
