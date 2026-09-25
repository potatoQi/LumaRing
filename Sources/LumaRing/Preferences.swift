import AppKit
import Carbon
import Combine
import LumaRingCore
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
    func matches(_ event: NSEvent) -> Bool {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return matches(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }
    func matches(keyCode: UInt32, modifiers: UInt32) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers
    }
}

enum TrackpadTap: Int, Codable, CaseIterable {
    case disabled = 0, threeFingers = 3, fourFingers = 4
    var label: String {
        switch self {
        case .disabled: return L10n.text("关闭", "Off")
        case .threeFingers: return L10n.text("三指轻点", "Three-finger tap")
        case .fourFingers: return L10n.text("四指轻点", "Four-finger tap")
        }
    }
}

struct Options: Codable {
    static let centerTitleSizeRange = 10...16
    var theme = AppTheme.system
    var ringMaterial = RingMaterialStyle.defaultValue
    var centerTitleSize = 12
    var loggingEnabled = true
    var actionProfiles: [ActionProfile] = []
    private(set) var actionRingApps: Set<String> = []

    var shortcut = Shortcut()
    var actionShortcut: Shortcut?
    var invocationShortcuts: [Shortcut] { [shortcut] + [actionShortcut].compactMap { $0 } }
    var invocationConflict: Bool { actionShortcut.map { shortcut.matches(keyCode: $0.keyCode, modifiers: $0.modifiers) } ?? false }
    var holdToSelect = false
    var trackpadTap = TrackpadTap.disabled
    var threeFingerPinch = false
    var ringSize = 520.0
    var previews = true
    var previewWidth = 840.0
    var previewSize: CGSize { CGSize(width: previewWidth, height: previewWidth * 0.75) }
    var includeMinimized = true
    var sortByName = true
    var excludedBundleIDs: [String] = []
    var appPageSize = 12
    var windowPageSize = RingGeometry.windowPageSize
    var launcherApps: [LauncherApp] = []
    var appContentModes: [String: AppContentMode] = [:]
    func contentMode(for bundleID: String) -> AppContentMode {
        BrowserAdapters.supports(bundleID) ? (appContentModes[bundleID] ?? .windows) : .windows
    }

    func usesActionRing(for bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return actionRingApps.contains(bundleID)
    }

    mutating func rememberActionRing(_ enabled: Bool, for bundleID: String?) {
        guard let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if enabled { actionRingApps.insert(bundleID) }
        else { actionRingApps.remove(bundleID) }
    }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case theme, ringMaterial, centerTitleSize, loggingEnabled, actionProfiles, actionRingApps, shortcut, actionShortcut, holdToSelect, trackpadTap, threeFingerPinch, ringSize, previews, previewWidth, includeMinimized, sortByName, excludedBundleIDs, appPageSize, windowPageSize, appContentModes, launcherApps
    }
    private enum LegacyCodingKeys: String, CodingKey { case fourFingerTap }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = AppTheme(rawValue: (try? c.decode(String.self, forKey: .theme)) ?? "") ?? .system
        ringMaterial = (RingMaterialStyle(rawValue: (try? c.decode(String.self, forKey: .ringMaterial)) ?? "") ?? .defaultValue).resolved
        centerTitleSize = min(Self.centerTitleSizeRange.upperBound, max(Self.centerTitleSizeRange.lowerBound,
            (try? c.decode(Int.self, forKey: .centerTitleSize)) ?? 12))
        loggingEnabled = (try? c.decode(Bool.self, forKey: .loggingEnabled)) ?? true
        actionProfiles = ActionProfile.normalized((try? c.decode([ActionProfile].self, forKey: .actionProfiles)) ?? [])
        actionRingApps = Set(((try? c.decode([String].self, forKey: .actionRingApps)) ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        shortcut = try c.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? Shortcut()
        actionShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .actionShortcut)
        if let value = actionShortcut, !AppAction.validShortcut(value) { actionShortcut = nil }
        holdToSelect = try c.decodeIfPresent(Bool.self, forKey: .holdToSelect) ?? false
        if c.contains(.trackpadTap) {
            trackpadTap = TrackpadTap(rawValue: (try? c.decode(Int.self, forKey: .trackpadTap)) ?? 0) ?? .disabled
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            trackpadTap = (try legacy.decodeIfPresent(Bool.self, forKey: .fourFingerTap) ?? false) ? .fourFingers : .disabled
        }
        threeFingerPinch = try c.decodeIfPresent(Bool.self, forKey: .threeFingerPinch) ?? false
        ringSize = try c.decodeIfPresent(Double.self, forKey: .ringSize) ?? 520
        previews = try c.decodeIfPresent(Bool.self, forKey: .previews) ?? true
        previewWidth = min(960, max(400, try c.decodeIfPresent(Double.self, forKey: .previewWidth) ?? 840))
        includeMinimized = try c.decodeIfPresent(Bool.self, forKey: .includeMinimized) ?? true
        sortByName = try c.decodeIfPresent(Bool.self, forKey: .sortByName) ?? true
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? []
        launcherApps = LauncherApp.unique(try c.decodeIfPresent([LauncherApp].self, forKey: .launcherApps) ?? [])
        let rawModes = try c.decodeIfPresent([String: String].self, forKey: .appContentModes) ?? [:]
        appContentModes = rawModes.mapValues { AppContentMode(rawValue: $0) ?? .windows }
        appPageSize = min(24, max(4, try c.decodeIfPresent(Int.self, forKey: .appPageSize) ?? 12))
        windowPageSize = min(RingGeometry.windowPageSizeRange.upperBound, max(RingGeometry.windowPageSizeRange.lowerBound,
            try c.decodeIfPresent(Int.self, forKey: .windowPageSize) ?? RingGeometry.windowPageSize))
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    @Published var language = AppLanguage.current {
        didSet {
            guard language != oldValue else { return }
            language.save(to: .standard)
            captureMessage = nil
            if shortcutError != nil {
                shortcutError = L10n.text("快捷键被占用，请换一个按键。", "This shortcut is in use. Choose another key.")
            }
            if actionShortcutError != nil {
                actionShortcutError = L10n.text("快捷键被占用，请换一个按键。", "This shortcut is in use. Choose another key.")
            }
            NotificationCenter.default.post(name: .lumaRingLanguageDidChange, object: nil)
        }
    }
    @Published var options: Options {
        didSet {
            if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "options.v1") }
        }
    }
    @Published var shortcutError: String?
    @Published var actionShortcutError: String?
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
        if !UserDefaults.standard.bool(forKey: "simpleDefaults.v4") {
            options.holdToSelect = false
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
        captureMessage = L10n.text("正在检查窗口预览权限…", "Checking window preview access…")
        Task { @MainActor in
            defer { checkingCapture = false }
            do {
                // Use the same API as previews. Legacy CG preflight can disagree with ScreenCaptureKit.
                _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                recordCaptureAccess(true)
                captureMessage = L10n.text("窗口预览权限正常。悬停圆弧中的窗口即可查看。", "Preview access is working. Hover over a window in the arc to preview it.")
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
