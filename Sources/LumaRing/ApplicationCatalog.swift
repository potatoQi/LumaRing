import AppKit

struct AppRecord {
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage
}

final class ApplicationCatalog {
    private var tokens: [NSObjectProtocol] = []
    private var recent: [pid_t] = []
    private var records: [pid_t: AppRecord] = [:]
    var onChange: (() -> Void)?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    if name == NSWorkspace.didActivateApplicationNotification, app.processIdentifier != getpid() {
                        self.recent.removeAll { $0 == app.processIdentifier }
                        self.recent.insert(app.processIdentifier, at: 0)
                        self.recent = Array(self.recent.prefix(128))
                    }
                    if name == NSWorkspace.didTerminateApplicationNotification {
                        self.records.removeValue(forKey: app.processIdentifier)
                        self.recent.removeAll { $0 == app.processIdentifier }
                    }
                }
                self.onChange?()
            })
        }
        if let app = NSWorkspace.shared.frontmostApplication { recent = [app.processIdentifier] }
    }

    func snapshot(options: Options) -> [AppRecord] {
        let excluded = Set(options.excludedBundleIDs)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid()
                && !excluded.contains($0.bundleIdentifier ?? "")
        }
        let live = Set(apps.map(\.processIdentifier))
        records = records.filter { live.contains($0.key) }
        let result: [AppRecord] = apps.map { app in
            if let cached = records[app.processIdentifier] { return cached }
            let icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
            let record = AppRecord(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "",
                                   name: app.localizedName ?? L10n.text("应用", "Apps"), icon: icon)
            records[app.processIdentifier] = record
            return record
        }
        return result.sorted { a, b in
            if !options.sortByName {
                let aRank = recent.firstIndex(of: a.pid) ?? Int.max
                let bRank = recent.firstIndex(of: b.pid) ?? Int.max
                if aRank != bRank { return aRank < bRank }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    deinit { tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }
}
