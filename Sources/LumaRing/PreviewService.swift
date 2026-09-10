import AppKit
import ScreenCaptureKit

struct PreviewCandidate {
    let id: CGWindowID
    let pid: pid_t
    let title: String?
    let frame: CGRect
    let layer: Int
}

enum PreviewMatcher {
    static func match(_ window: WindowRecord, candidates: [PreviewCandidate], applicationName: String? = nil) -> CGWindowID? {
        let owned = candidates.filter { $0.pid == window.pid && $0.layer == 0 && $0.frame.width > 0 && $0.frame.height > 0 }
        var titled = owned.filter { !window.title.isEmpty && $0.title == window.title }
        if titled.isEmpty, let applicationName, !applicationName.isEmpty {
            // AX may append " - App" or " - App - Profile" to the capture title.
            // Require the owning app's name and separators; a shared title prefix is not enough.
            titled = owned.filter {
                guard let title = $0.title, !title.isEmpty else { return false }
                let decorated = "\(title) - \(applicationName)"
                return window.title == decorated || window.title.hasPrefix(decorated + " - ")
            }
        }
        // A unique title remains stable when the AX snapshot predates a move or resize.
        if titled.count == 1 { return titled[0].id }
        let pool = titled.isEmpty ? owned : titled
        let framed = pool.filter {
            abs($0.frame.width - window.frame.width) < 3 && abs($0.frame.height - window.frame.height) < 3
                && abs($0.frame.minX - window.frame.minX) < 3 && abs($0.frame.minY - window.frame.minY) < 3
        }
        return framed.count == 1 ? framed[0].id : nil
    }
}

enum PreviewFailure: Error, Equatable {
    case permissionDenied, minimized, unmatched, capture(String, Int)
    init(error: Error) {
        let ns = error as NSError
        self = ns.domain == SCStreamErrorDomain && ns.code == -3801 ? .permissionDenied : .capture(ns.domain, ns.code)
    }
    var message: String {
        switch self {
        case .permissionDenied: return L10n.text("系统拒绝了录屏访问。请在设置中检测预览权限。", "Screen Recording access was denied. Check preview access in settings.")
        case .minimized: return L10n.text("窗口已最小化，点击即可恢复。", "This window is minimized. Click to restore it.")
        case .unmatched: return L10n.text("暂时无法确认这个窗口，仍可点击切换。", "This window could not be matched. You can still click to switch.")
        case .capture(let domain, let code): return L10n.text("预览暂不可用（\(domain) · \(code)），仍可点击切换。", "Preview unavailable (\(domain) · \(code)). You can still click to switch.")
        }
    }
}

/// Single still images, never a running capture stream. At most one capture in flight.
@MainActor final class PreviewService {
    private let cache = NSCache<NSString, NSImage>()
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var busy = false
    private var pending: (WindowRecord, CGSize, UInt64, (Result<NSImage, PreviewFailure>) -> Void)?
    // A denial stops repeated system requests for this session; reopening the ring retries.
    private var denied = false

    init() {
        cache.countLimit = 12
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func load(_ window: WindowRecord, pixelSize: CGSize = CGSize(width: 880, height: 560), completion: @escaping (Result<NSImage, PreviewFailure>) -> Void) {
        generation &+= 1
        let ticket = generation
        task?.cancel()
        pending = nil
        let key = cacheKey(window, pixelSize: pixelSize)
        if let image = cache.object(forKey: key) { completion(.success(image)); return }
        guard !window.minimized else { completion(.failure(.minimized)); return }
        guard !denied else { completion(.failure(.permissionDenied)); return }
        if busy { pending = (window, pixelSize, ticket, completion); return }
        capture(window, pixelSize: pixelSize, ticket: ticket, completion: completion)
    }

    private func capture(_ window: WindowRecord, pixelSize: CGSize, ticket: UInt64, completion: @escaping (Result<NSImage, PreviewFailure>) -> Void) {
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                if let (next, nextSize, nextTicket, callback) = self.pending {
                    self.pending = nil
                    if self.generation == nextTicket { self.capture(next, pixelSize: nextSize, ticket: nextTicket, completion: callback) }
                }
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard !Task.isCancelled, ticket == self.generation else { return }
                Preferences.shared.recordCaptureAccess(true)
                let candidates = content.windows.map {
                    PreviewCandidate(id: $0.windowID, pid: $0.owningApplication?.processID ?? -1,
                                     title: $0.title, frame: $0.frame, layer: $0.windowLayer)
                }
                let applicationName = content.applications.first { $0.processID == window.pid }?.applicationName
                guard let id = PreviewMatcher.match(window, candidates: candidates, applicationName: applicationName),
                      let target = content.windows.first(where: { $0.windowID == id }) else {
                    completion(.failure(.unmatched)); return
                }
                let configuration = SCStreamConfiguration()
                let scale = min(min(1920, max(1, pixelSize.width)) / max(target.frame.width, 1),
                                min(1440, max(1, pixelSize.height)) / max(target.frame.height, 1))
                configuration.width = max(1, Int(target.frame.width * scale))
                configuration.height = max(1, Int(target.frame.height * scale))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.captureResolution = .nominal
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard !Task.isCancelled, ticket == self.generation else { return }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                self.cache.setObject(image, forKey: self.cacheKey(window, pixelSize: pixelSize), cost: cgImage.bytesPerRow * cgImage.height)
                completion(.success(image))
            } catch {
                if ticket == self.generation, !Task.isCancelled {
                    let failure = PreviewFailure(error: error)
                    if failure == .permissionDenied {
                        self.denied = true
                        Preferences.shared.recordCaptureAccess(false)
                    }
                    completion(.failure(failure))
                }
            }
        }
    }

    private func cacheKey(_ window: WindowRecord, pixelSize: CGSize) -> NSString {
        "\(window.id):\(Int(pixelSize.width))x\(Int(pixelSize.height))" as NSString
    }

    func cancelAndClear() {
        cancelPending()
        denied = false
        cache.removeAllObjects()
    }

    func cancelPending() {
        generation &+= 1
        task?.cancel(); task = nil
        pending = nil
    }
}
