import AppKit
import Carbon
import Combine
import ScreenCaptureKit

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32 = UInt32(kVK_Tab)
    var modifiers: UInt32 = UInt32(optionKey)
    var label: String = "Tab"
    var display: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + label
    }
}

struct Options: Codable {
    var shortcut = Shortcut()
    var holdToSelect = false
    var hoverDelay = 0.08
    var ringSize = 520.0
    var previews = true
    var previewWidth = 840.0
    var previewSize: CGSize { CGSize(width: previewWidth, height: previewWidth * 0.75) }
    var includeMinimized = true
    var sortByName = true
    var excludedBundleIDs: [String] = []
    var appPageSize = 12
    var appContentModes: [String: AppContentMode] = [:]
    func contentMode(for bundleID: String) -> AppContentMode {
        BrowserAdapters.supports(bundleID) ? (appContentModes[bundleID] ?? .windows) : .windows
    }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case shortcut, holdToSelect, hoverDelay, ringSize, previews, previewWidth, includeMinimized, sortByName, excludedBundleIDs, appPageSize, appContentModes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try c.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? Shortcut()
        holdToSelect = try c.decodeIfPresent(Bool.self, forKey: .holdToSelect) ?? false
        hoverDelay = try c.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? 0.08
        ringSize = try c.decodeIfPresent(Double.self, forKey: .ringSize) ?? 520
        previews = try c.decodeIfPresent(Bool.self, forKey: .previews) ?? true
        previewWidth = min(960, max(400, try c.decodeIfPresent(Double.self, forKey: .previewWidth) ?? 840))
        includeMinimized = try c.decodeIfPresent(Bool.self, forKey: .includeMinimized) ?? true
        sortByName = try c.decodeIfPresent(Bool.self, forKey: .sortByName) ?? true
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? []
        let rawModes = try c.decodeIfPresent([String: String].self, forKey: .appContentModes) ?? [:]
        appContentModes = rawModes.mapValues { AppContentMode(rawValue: $0) ?? .windows }
        appPageSize = min(24, max(4, try c.decodeIfPresent(Int.self, forKey: .appPageSize) ?? 12))
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    @Published var options: Options {
        didSet {
            if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "options.v1") }
        }
    }
    @Published var shortcutError: String?
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var screenCaptureGranted = CGPreflightScreenCaptureAccess()

    @Published var checkingCapture = false
    @Published var captureMessage: String?
    private var captureVerified = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: "options.v1"),
           let options = try? JSONDecoder().decode(Options.self, from: data) {
            self.options = options
        } else { options = Options() }
        if !UserDefaults.standard.bool(forKey: "previewDefault.v6") {
            if options.previewWidth == 640 { options.previewWidth = 840 }
            if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "options.v1") }
            UserDefaults.standard.set(true, forKey: "previewDefault.v6")
        }
        // One-time migration; future user choices of the old chord remain valid.
        if !UserDefaults.standard.bool(forKey: "optionTabDefault.v5") {
            if options.shortcut.keyCode == UInt32(kVK_Space),
               options.shortcut.modifiers == UInt32(controlKey | optionKey) {
                options.shortcut = Shortcut()
                if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "options.v1") }
            }
            UserDefaults.standard.set(true, forKey: "optionTabDefault.v5")
        }
        options.hoverDelay = min(0.5, max(0.08, options.hoverDelay))
        if !UserDefaults.standard.bool(forKey: "simpleDefaults.v4") {
            options.holdToSelect = false
            options.hoverDelay = 0.08
            options.ringSize = 520
            options.appPageSize = 12
            UserDefaults.standard.set(true, forKey: "simpleDefaults.v4")
            if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "options.v1") }
        }
        options.ringSize = min(560, max(400, options.ringSize))
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = captureVerified || CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }

    @MainActor func requestCapture() {
        guard !checkingCapture else { return }
        checkingCapture = true
        captureMessage = "正在检查窗口预览权限…"
        Task { @MainActor in
            defer { checkingCapture = false }
            do {
                // Use the same API as previews. Legacy CG preflight can disagree with ScreenCaptureKit.
                _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                recordCaptureAccess(true)
                captureMessage = "窗口预览权限正常。悬停圆弧中的窗口即可查看。"
            } catch {
                let failure = PreviewFailure(error: error)
                if failure == .permissionDenied { recordCaptureAccess(false) }
                captureMessage = failure.message
            }
        }
    }

    func recordCaptureAccess(_ granted: Bool) {
        captureVerified = granted
        screenCaptureGranted = granted
    }

    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
