import AppKit

struct LauncherApp: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var path: String
    var id: String { bundleID }

    static func read(_ url: URL) -> LauncherApp? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return LauncherApp(bundleID: id, name: name, path: url.path)
    }

    static func unique(_ apps: [LauncherApp]) -> [LauncherApp] {
        var seen = Set<String>()
        return apps.filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
    }
}

struct LauncherRecord {
    let app: LauncherApp
    let icon: NSImage
    let available: Bool
}

@MainActor final class LauncherCatalog {
    private var icons: [String: NSImage] = [:]

    static func resolve(_ app: LauncherApp) -> URL? {
        let stored = URL(fileURLWithPath: app.path)
        if LauncherApp.read(stored)?.bundleID == app.bundleID { return stored }
        guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID),
              LauncherApp.read(found)?.bundleID == app.bundleID else { return nil }
        return found
    }

    func snapshot(_ apps: [LauncherApp]) -> [LauncherRecord] {
        let apps = LauncherApp.unique(apps)
        var used = Set<String>()
        let records = apps.map { app in
            let url = Self.resolve(app)
            let key = url?.path ?? app.path
            used.insert(key)
            let icon = icons[key] ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
            icons[key] = icon
            return LauncherRecord(app: app, icon: icon, available: url != nil)
        }
        icons = icons.filter { used.contains($0.key) }
        return records
    }
}

@MainActor final class ApplicationLauncher {
    typealias Open = (URL, NSWorkspace.OpenConfiguration, @escaping @Sendable (NSRunningApplication?, Error?) -> Void) -> Void
    private let resolve: @MainActor (LauncherApp) -> URL?
    private let open: Open

    init(resolve: @escaping @MainActor (LauncherApp) -> URL? = { LauncherCatalog.resolve($0) },
         open: @escaping Open = { url, configuration, completion in
             NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
         }) {
        self.resolve = resolve; self.open = open
    }

    func launch(_ app: LauncherApp, completion: @escaping (Bool) -> Void) {
        guard let url = resolve(app) else { completion(false); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        open(url, config) { running, error in
            DispatchQueue.main.async {
                completion(error == nil && running?.bundleIdentifier == app.bundleID && running?.isTerminated == false)
            }
        }
    }
}
