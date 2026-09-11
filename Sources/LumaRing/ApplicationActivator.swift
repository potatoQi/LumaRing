import AppKit

/// Launch Services delivers the normal reopen event, just like selecting an app in the Dock.
/// A bare NSRunningApplication.activate request does not restore a closed main window.
@MainActor final class ApplicationActivator {
    typealias Open = (URL, NSWorkspace.OpenConfiguration, @escaping (NSRunningApplication?, Error?) -> Void) -> Void
    private let open: Open

    init(open: @escaping Open = { url, configuration, completion in
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
    }) { self.open = open }

    func activate(pid: pid_t, completion: @escaping (Bool) -> Void) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            AppLog.shared.record("activation_unavailable", category: .app, level: .warning, fields: ["pid": String(pid)])
            completion(false); return
        }
        guard let url = app.bundleURL else {
            completion(app.activate(options: [])); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        open(url, configuration) { activated, error in
            DispatchQueue.main.async {
                let success = error == nil && activated?.processIdentifier == pid && activated?.isTerminated == false
                AppLog.shared.record("activation_result", category: .app, level: success ? .info : .warning,
                                     fields: ["pid": String(pid), "success": String(success)])
                completion(success)
            }
        }
    }
}
