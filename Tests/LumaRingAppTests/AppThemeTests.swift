import AppKit
import XCTest
@testable import LumaRing

final class AppThemeTests: XCTestCase {
    func testExistingPreferencesDefaultToSystemWithoutResettingOptions() throws {
        let data = Data(#"{"ringSize":480,"excludedBundleIDs":["keep.me"],"appPageSize":8}"#.utf8)
        let options = try JSONDecoder().decode(Options.self, from: data)
        XCTAssertEqual(options.theme, .system)
        XCTAssertEqual(options.ringSize, 480)
        XCTAssertEqual(options.excludedBundleIDs, ["keep.me"])
        XCTAssertEqual(options.appPageSize, 8)
    }

    func testThemePersistsWithOtherPreferencesAndUnknownThemeFallsBack() throws {
        for theme in AppTheme.allCases {
            var options = Options()
            options.theme = theme
            options.windowPageSize = 3
            let loaded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(loaded.theme, theme)
            XCTAssertEqual(loaded.windowPageSize, 3)
        }
        let data = Data(#"{"theme":"unknown","ringSize":480}"#.utf8)
        let loaded = try JSONDecoder().decode(Options.self, from: data)
        XCTAssertEqual(loaded.theme, .system)
        XCTAssertEqual(loaded.ringSize, 480)
    }

    @MainActor func testExistingAndNewWindowsInheritThemeAndSystemClearsOverride() async {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView()
        window.contentView = view
        for (theme, expected) in [(AppTheme.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            theme.apply()
            XCTAssertNil(window.appearance)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
            XCTAssertEqual(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
        }
        AppTheme.system.apply()
        XCTAssertNil(app.appearance)
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                       app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
    }
}
