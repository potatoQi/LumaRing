import AppKit

struct AppItemCount: Equatable {
    let value: Int
    let limited: Bool

    init?(_ result: WindowResult, includeMinimized: Bool) {
        guard case .ready(let records, let limited) = result else { return nil }
        value = records.filter { includeMinimized || !$0.minimized }.count
        self.limited = limited
    }

    var badge: String? { value > 1 ? "\(value)\(limited ? "+" : "")" : nil }
}

/// One pass over the visible page, with independent workers so counts cannot cancel hover queries.
/// Retains only counts; never requests permission or runs while the ring is hidden.
@MainActor final class AppCountService {
    typealias Reader = (AppRecord, AppContentMode, @escaping (WindowResult) -> Void) -> Void
    private let read: Reader
    private let cancelRead: () -> Void
    private var generation = 0

    init(read: @escaping Reader, cancel: @escaping () -> Void) {
        self.read = read
        cancelRead = cancel
    }

    convenience init() {
        let windows = WindowService()
        let tabs = BrowserTabService()
        self.init(read: { app, mode, completion in
            let finish: (WindowResult) -> Void = { result in
                windows.cancelAndClear()
                tabs.cancelAndClear()
                completion(result)
            }
            if mode == .tabs {
                tabs.load(pid: app.pid, bundleID: app.bundleID, completion: finish)
            } else {
                windows.load(pid: app.pid, completion: finish)
            }
        }, cancel: {
            windows.cancelAndClear()
            tabs.cancelAndClear()
        })
    }

    func refresh(apps: [AppRecord], options: Options, completion: @escaping (pid_t, AppItemCount?) -> Void) {
        cancelAndClear()
        readNext(apps[...], options: options, ticket: generation, completion: completion)
    }

    private func readNext(_ apps: ArraySlice<AppRecord>, options: Options, ticket: Int,
                          completion: @escaping (pid_t, AppItemCount?) -> Void) {
        guard ticket == generation, let app = apps.first else { return }
        read(app, options.contentMode(for: app.bundleID)) { [weak self] result in
            guard let self, ticket == self.generation else { return }
            completion(app.pid, AppItemCount(result, includeMinimized: options.includeMinimized))
            self.readNext(apps.dropFirst(), options: options, ticket: ticket, completion: completion)
        }
    }

    func cancelAndClear() {
        generation += 1
        cancelRead()
    }
}
