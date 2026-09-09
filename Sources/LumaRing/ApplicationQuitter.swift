import AppKit

/// A normal quit can take time to deliver. Keep it off the event/render thread,
/// and let unrelated applications receive their requests independently.
@MainActor final class ApplicationQuitter {
    struct Target: Hashable, Sendable {
        let pid: pid_t
        let bundleID: String
    }
    enum Outcome: Equatable, Sendable { case requested, alreadyExited, rejected }
    typealias Request = @Sendable (Target) -> Outcome
    private let request: Request
    private let queue = DispatchQueue(label: "local.lumaring.quit", qos: .userInitiated,
                                      attributes: .concurrent, autoreleaseFrequency: .workItem)
    private var inFlight: Set<Target> = []

    init(request: @escaping Request = { ApplicationQuitter.sendQuit($0) }) { self.request = request }

    @discardableResult func quit(_ target: Target, completion: @escaping (Outcome) -> Void) -> Bool {
        guard target.pid > 0, target.pid != getpid(), inFlight.insert(target).inserted else { return false }
        queue.async { [weak self, request] in
            let outcome = request(target)
            DispatchQueue.main.async { [weak self] in
                self?.inFlight.remove(target)
                completion(outcome)
            }
        }
        return true
    }

    nonisolated static func sendQuit(_ target: Target) -> Outcome {
        guard target.pid > 0, target.pid != getpid() else { return .rejected }
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier ?? "" == target.bundleID, !app.isTerminated else { return .alreadyExited }
        // No activation, hide, reopen, forced termination or automatic save response.
        // A successful send does not imply that the application's exit has completed.
        return app.terminate() ? .requested : .rejected
    }
}
