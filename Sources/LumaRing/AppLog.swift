import CryptoKit
import Foundation

/// Local JSON-lines diagnostics. The serial writer owns disk I/O; the lock only
/// guards admission and cancellation so disabling/clearing also fences queued work.
final class AppLog: @unchecked Sendable {
    enum Level: String, Codable { case debug, info, warning, error }
    enum Category: String, Codable { case app, lifecycle, ring, windowStyles, windows, browser, preview, gestures, updates, actions }
    struct Status: Sendable {
        let bytes: Int
        let writeFailed: Bool
        let dropped: Int
    }
    private struct Entry: Encodable {
        let time: Date
        let uptime: TimeInterval
        let session: String
        let droppedBefore: Int
        let category: Category
        let level: Level
        let event: String
        let fields: [String: String]
    }

    static let shared = AppLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LumaRing", isDirectory: true))
    static let totalByteLimit = 10_000_000
    let directory: URL
    private let queue: DispatchQueue
    private let writer: Writer
    private let lock = NSLock()
    private let session = UUID().uuidString
    private let pendingLimit: Int
    private var enabled = false
    private var generation: UInt64 = 0
    private var pending = 0
    private var dropped = 0
    private var writeFailed = false

    init(directory: URL, fileByteLimit: Int = 2_000_000, fileCount: Int = 5,
         pendingLimit: Int = 256,
         queue: DispatchQueue = DispatchQueue(label: "local.lumaring.logging", qos: .utility, autoreleaseFrequency: .workItem)) {
        self.directory = directory
        self.queue = queue
        self.pendingLimit = max(1, pendingLimit)
        writer = Writer(directory: directory, byteLimit: max(1, fileByteLimit), fileCount: max(1, fileCount))
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        guard value != enabled else { lock.unlock(); return }
        enabled = value
        generation &+= 1
        if !value { queue.async { self.writer.close() } }
        lock.unlock()
        if value { record("logging_enabled", category: .app) }
    }

    /// Fields are evaluated only when enabled and below the queue limit. Callers
    /// must pass metadata only: never document titles, aliases, URLs or error text.
    func record(_ event: String, category: Category, level: Level = .info, fields: @autoclosure () -> [String: String] = [:]) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        guard pending < pendingLimit else { dropped += 1; lock.unlock(); return }
        let ticket = generation
        let droppedBefore = dropped
        pending += 1
        lock.unlock()
        let entry = Entry(time: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                          session: session, droppedBefore: droppedBefore, category: category, level: level, event: event, fields: fields())
        lock.lock()
        guard enabled, generation == ticket else { pending -= 1; lock.unlock(); return }
        queue.async {
            self.lock.lock()
            let allowed = self.enabled && self.generation == ticket
            self.lock.unlock()
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            guard allowed else { return }
            do {
                let written = try self.writer.append(entry)
                self.lock.lock()
                if !written { self.dropped += 1 }
                self.writeFailed = false
                self.lock.unlock()
            } catch {
                self.writer.close()
                self.lock.lock(); self.writeFailed = true; self.dropped += 1; self.lock.unlock()
            }
        }
        lock.unlock()
    }

    /// Deletes only owned log files. Queued pre-clear entries cannot reappear.
    /// Future events can start a new file when logging remains enabled.
    func clear() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            generation &+= 1
            queue.async {
                do {
                    try self.writer.clear()
                    self.lock.lock(); self.writeFailed = false; self.dropped = 0; self.lock.unlock()
                    continuation.resume(returning: true)
                } catch {
                    self.lock.lock(); self.writeFailed = true; self.lock.unlock()
                    continuation.resume(returning: false)
                }
            }
            lock.unlock()
        }
    }

    func status() async -> Status {
        await withCheckedContinuation { continuation in
            queue.async {
                let bytes = self.writer.size()
                self.lock.lock()
                let result = Status(bytes: bytes, writeFailed: self.writeFailed, dropped: self.dropped)
                self.lock.unlock()
                continuation.resume(returning: result)
            }
        }
    }

    func folder() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try self.writer.prepare()
                    continuation.resume(returning: self.directory)
                } catch {
                    self.lock.lock(); self.writeFailed = true; self.lock.unlock()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Best-effort shutdown flush only; a slow/full disk must not prevent quitting.
    func finish() {
        let done = DispatchSemaphore(value: 0)
        queue.async { self.writer.close(); done.signal() }
        _ = done.wait(timeout: .now() + .milliseconds(100))
    }

    /// Correlates technical object identifiers across launches without writing
    /// their original strings. This is a fingerprint, not anonymization of titles.
    static func token(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func errorFields(_ error: Error) -> [String: String] {
        let error = error as NSError
        return ["errorDomain": error.domain, "errorCode": String(error.code)]
    }

    private final class Writer {
        let directory: URL
        let byteLimit: Int
        let fileCount: Int
        let encoder: JSONEncoder
        var handle: FileHandle?
        var bytes = 0
        var prepared = false
        let files = FileManager.default

        init(directory: URL, byteLimit: Int, fileCount: Int) {
            self.directory = directory; self.byteLimit = byteLimit; self.fileCount = fileCount
            encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        func url(_ index: Int) -> URL {
            directory.appendingPathComponent(index == 0 ? "lumaring.log" : "lumaring.\(index).log")
        }
        func prepare() throws {
            guard !prepared else { return }
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            for index in 0..<fileCount where files.fileExists(atPath: url(index).path) {
                let attributes = try files.attributesOfItem(atPath: url(index).path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileWriteUnknown) }
                if (attributes[.size] as? NSNumber)?.intValue ?? 0 > byteLimit { try files.removeItem(at: url(index)) }
            }
            prepared = true
        }
        func append(_ entry: Entry) throws -> Bool {
            var data = try encoder.encode(entry)
            data.append(0x0a)
            guard data.count <= min(byteLimit, 16_384) else { return false }
            try prepare()
            if handle == nil {
                if !files.fileExists(atPath: url(0).path) {
                    guard files.createFile(atPath: url(0).path, contents: nil,
                                           attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                }
                handle = try FileHandle(forWritingTo: url(0))
                bytes = Int(try handle!.seekToEnd())
            }
            if bytes + data.count > byteLimit {
                close()
                if files.fileExists(atPath: url(fileCount - 1).path) { try files.removeItem(at: url(fileCount - 1)) }
                if fileCount > 1 {
                    for index in stride(from: fileCount - 2, through: 0, by: -1) where files.fileExists(atPath: url(index).path) {
                        try files.moveItem(at: url(index), to: url(index + 1))
                    }
                }
                guard files.createFile(atPath: url(0).path, contents: nil,
                                       attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                handle = try FileHandle(forWritingTo: url(0))
                bytes = 0
            }
            do {
                try handle!.write(contentsOf: data)
                bytes += data.count
            } catch { close(); throw error }
            return true
        }
        func close() { try? handle?.close(); handle = nil }
        func clear() throws {
            close()
            for index in 0..<fileCount where files.fileExists(atPath: url(index).path) { try files.removeItem(at: url(index)) }
            bytes = 0; prepared = false
        }
        func size() -> Int {
            (0..<fileCount).reduce(0) { total, index in
                total + (((try? files.attributesOfItem(atPath: url(index).path)[.size]) as? NSNumber)?.intValue ?? 0)
            }
        }
        deinit { close() }
    }
}
