import XCTest
import AppKit
import SwiftUI
@testable import LumaRing

final class LocalizationTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "local.lumaring.language-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testMissingAndUnknownLanguagesPreserveChineseDefault() {
        let store = defaults()
        XCTAssertEqual(AppLanguage.load(from: store), .simplifiedChinese)
        store.set("future-language", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.load(from: store), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.allCases.map(\.title), ["English", "简体中文"])
    }

    func testLanguageRoundTripDoesNotRewriteExistingOptions() {
        let store = defaults()
        let original = Data(#"{"shortcut":{"keyCode":15,"modifiers":6144,"label":"R"},"excludedBundleIDs":["test.hidden"]}"#.utf8)
        store.set(original, forKey: "options.v1")
        for language in AppLanguage.allCases {
            language.save(to: store)
            XCTAssertEqual(AppLanguage.load(from: store), language)
            XCTAssertEqual(store.data(forKey: "options.v1"), original)
        }
    }

    func testExplicitTranslationsPreserveDynamicValues() {
        let title = "项目 \"draft\" — café"
        XCTAssertEqual(L10n.text("切换到 \(title)", "Switch to \(title)", language: .english), "Switch to \(title)")
        XCTAssertEqual(L10n.text("切换到 \(title)", "Switch to \(title)", language: .simplifiedChinese), "切换到 \(title)")
    }

    @MainActor func testRuntimeLanguageSwitchRefreshesLabelsAndSettings() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let originalLanguage = preferences.language
        let originalStoredValue = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let originalCaptureMessage = preferences.captureMessage
        let originalShortcutError = preferences.shortcutError
        let options = UserDefaults.standard.data(forKey: "options.v1")
        defer {
            preferences.language = originalLanguage
            UserDefaults.standard.set(originalStoredValue, forKey: AppLanguage.preferenceKey)
            preferences.captureMessage = originalCaptureMessage
            preferences.shortcutError = originalShortcutError
        }
        preferences.language = .simplifiedChinese
        let changed = expectation(forNotification: .lumaRingLanguageDidChange, object: nil)
        preferences.language = .english
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(AppContentMode.tabs.title, "Tabs")
        XCTAssertTrue(BrowserError.permission.localizedDescription.contains("App Management"))
        XCTAssertTrue(PreviewFailure.minimized.message.contains("minimized"))
        let ring = RingView()
        ring.reset(apps: [], options: Options())
        XCTAssertEqual(ring.message, "No apps available")

        // Render only our settings view, never the desktop or user window content.
        let host = NSHostingView(rootView: SettingsView())
        let frame = NSRect(x: 0, y: 0, width: 680, height: 690)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = frame
        host.appearance = NSAppearance(named: .aqua)
        if ProcessInfo.processInfo.environment["LUMARING_LANGUAGE_SNAPSHOTS"] != nil {
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
        }
        for language in AppLanguage.allCases {
            preferences.language = language
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            XCTAssertEqual(preferences.language, AppLanguage.current)
            if let directory = ProcessInfo.processInfo.environment["LUMARING_LANGUAGE_SNAPSHOTS"] {
                let output = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let cg = context.cgContext
                cg.concatenate(cg.ctm.inverted())
                cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                cg.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
                cg.scaleBy(x: CGFloat(bitmap.pixelsWide) / host.bounds.width,
                           y: -CGFloat(bitmap.pixelsHigh) / host.bounds.height)
                host.layer?.render(in: cg)
                NSGraphicsContext.restoreGraphicsState()
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("settings-\(language.rawValue).png"))
            }
        }
        XCTAssertEqual(AppContentMode.tabs.title, "标签页")
        XCTAssertEqual(UserDefaults.standard.data(forKey: "options.v1"), options)
        window.close()
    }
}
