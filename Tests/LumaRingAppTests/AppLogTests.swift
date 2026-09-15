import AppKit
import XCTest
@testable import LumaRing

final class AppLogTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LumaRing-LogTests-\(UUID().uuidString)")
    }
    private func cleanup(_ log: AppLog, _ directory: URL) {
        log.setEnabled(false); log.finish()
        try? FileManager.default.removeItem(at: directory)
    }
    private func rows(_ directory: URL) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }.flatMap { url in
                try Data(contentsOf: url).split(separator: 0x0a).map {
                    try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
                }
            }
    }

    func testDisabledDoesNotEvaluateFieldsOrCreateFilesAndSettingPersists() async throws {
        let folder = directory()
        let log = AppLog(directory: folder)
        defer { cleanup(log, folder) }
        var evaluated = false
        func fields() -> [String: String] { evaluated = true; return [:] }
        log.record("ignored", category: .app, fields: fields())
        let status = await log.status()
        XCTAssertFalse(evaluated)
        XCTAssertEqual(status.bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.directory.path))
        let old = try JSONDecoder().decode(Options.self, from: Data(#"{"ringSize":480}"#.utf8))
        XCTAssertTrue(old.loggingEnabled)
        for enabled in [false, true] {
            var options = old; options.loggingEnabled = enabled
            let loaded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(loaded.loggingEnabled, enabled)
            XCTAssertEqual(loaded.ringSize, 480)
        }
    }

    func testRotationStaysWithinLimitAndRetainsNewestAcrossRestart() async throws {
        let folder = directory()
        let log = AppLog(directory: folder, fileByteLimit: 1024, fileCount: 3)
        defer { cleanup(log, folder) }
        log.setEnabled(true)
        for index in 0..<40 { log.record("sample", category: .app, fields: ["index": String(index)]) }
        let status = await log.status()
        XCTAssertLessThanOrEqual(status.bytes, 3072)
        XCTAssertFalse(status.writeFailed)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertLessThanOrEqual(files.count, 3)
        for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1024) }
        let entries = try rows(folder)
        let indices = entries.compactMap { ($0["fields"] as? [String: String])?["index"] }
        XCTAssertTrue(indices.contains("39"))
        XCTAssertFalse(indices.contains("0"))
        log.setEnabled(false)
        _ = await log.status()
        let restarted = AppLog(directory: folder, fileByteLimit: 1024, fileCount: 3)
        defer { restarted.setEnabled(false); restarted.finish() }
        restarted.setEnabled(true)
        restarted.record("after_restart", category: .app)
        let restartedStatus = await restarted.status()
        XCTAssertLessThanOrEqual(restartedStatus.bytes, 3072)
        XCTAssertTrue(try rows(folder).contains { $0["event"] as? String == "after_restart" })
    }

    func testDisableDiscardsQueuedEntriesAndBoundsPendingMemory() async throws {
        let folder = directory(), queue = DispatchQueue(label: "AppLogTests.paused")
        let log = AppLog(directory: folder, pendingLimit: 4, queue: queue)
        defer { cleanup(log, folder) }
        queue.suspend()
        log.setEnabled(true)
        for index in 0..<30 { log.record("queued", category: .app, fields: ["index": String(index)]) }
        log.setEnabled(false)
        queue.resume()
        let status = await log.status()
        XCTAssertEqual(status.bytes, 0)
        XCTAssertEqual(status.dropped, 27)
        XCTAssertTrue(try rows(folder).isEmpty)
        log.setEnabled(true)
        log.record("new", category: .app)
        _ = await log.status()
        XCTAssertFalse(try rows(folder).contains { $0["event"] as? String == "queued" })
        XCTAssertTrue(try rows(folder).contains { $0["event"] as? String == "new" })
    }

    func testClearRemovesOldEntriesPreservesUnrelatedFilesAndAllowsNewLogging() async throws {
        let folder = directory()
        let log = AppLog(directory: folder)
        defer { cleanup(log, folder) }
        log.setEnabled(true)
        for _ in 0..<80 { log.record("before_clear", category: .app) }
        // Clearing cancels queued entries; wait for the files this test intends to clear.
        let beforeClear = await log.status()
        XCTAssertGreaterThan(beforeClear.bytes, 0)
        let cleared = await log.clear()
        XCTAssertTrue(cleared)
        XCTAssertTrue(try rows(log.directory).isEmpty)
        let sentinel = log.directory.appendingPathComponent("keep.txt")
        try Data("unrelated".utf8).write(to: sentinel)
        log.record("after_clear", category: .app)
        _ = await log.status()
        XCTAssertEqual(try rows(log.directory).map { $0["event"] as? String }, ["after_clear"])
        log.setEnabled(false)
        let clearedWhileOff = await log.clear()
        XCTAssertTrue(clearedWhileOff)
        let status = await log.status()
        XCTAssertEqual(status.bytes, 0)
        XCTAssertEqual(try String(contentsOf: sentinel), "unrelated")
    }

    func testConcurrentWritersProduceCompleteStructuredLinesAndOversizeIsDropped() async throws {
        let folder = directory()
        let log = AppLog(directory: folder)
        defer { cleanup(log, folder) }
        log.setEnabled(true)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            log.record("concurrent", category: .browser, level: .warning,
                       fields: ["index": String(index), "escaped": "one\ntwo"])
        }
        log.record("oversize", category: .app, fields: ["value": String(repeating: "x", count: 20_000)])
        let status = await log.status()
        XCTAssertFalse(status.writeFailed)
        XCTAssertEqual(status.dropped, 1)
        let entries = try rows(log.directory).filter { $0["event"] as? String == "concurrent" }
        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(Set(entries.compactMap { ($0["fields"] as? [String: String])?["index"] }).count, 100)
        for entry in entries {
            XCTAssertNotNil(entry["time"])
            XCTAssertNotNil(entry["uptime"])
            XCTAssertNotNil(entry["session"])
            XCTAssertEqual(entry["level"] as? String, "warning")
            XCTAssertEqual(entry["category"] as? String, "browser")
            XCTAssertEqual((entry["fields"] as? [String: String])?["escaped"], "one\ntwo")
        }
    }

    func testWriteFailureIsReportedWithoutThrowingIntoAppAndCanRecover() async throws {
        let folder = directory()
        try Data("not a directory".utf8).write(to: folder)
        let log = AppLog(directory: folder)
        defer { cleanup(log, folder) }
        log.setEnabled(true)
        var status = await log.status()
        XCTAssertTrue(status.writeFailed)
        try FileManager.default.removeItem(at: folder)
        log.record("recovered", category: .app)
        status = await log.status()
        XCTAssertFalse(status.writeFailed)
        XCTAssertTrue(try rows(folder).contains { $0["event"] as? String == "recovered" })
        let error = NSError(domain: "test.domain", code: 42, userInfo: [NSLocalizedDescriptionKey: "private title", NSFilePathErrorKey: "/private/document"])
        XCTAssertEqual(AppLog.errorFields(error), ["errorDomain": "test.domain", "errorCode": "42"])
    }

    @MainActor func testWindowStyleLogsExplainMissingIDsAndPruningWithoutUserContent() async throws {
        let folder = directory()
        let log = AppLog(directory: folder)
        defer { cleanup(log, folder) }
        let suite = "AppLogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = WindowNames.Process(pid: 100, bundleID: "test.app", launched: Date(timeIntervalSince1970: 1000))
        var state = WindowNames.ProcessState.running(owner)
        log.setEnabled(true)
        let store = WindowNames(defaults: defaults, log: log, process: { _ in state })
        let target = WindowRecord(id: "technical-original-id", pid: 100, title: "PRIVATE_WINDOW_TITLE", minimized: false,
                                  fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(100))
        store.update(name: "PRIVATE_CUSTOM_NAME", color: .blue, for: target)
        _ = store.apply(.ready([target]), pid: 100)
        _ = store.apply(.ready([]), pid: 100)
        state = .unavailable; store.pruneTerminated()
        state = .terminated; store.pruneTerminated()
        let status = await log.status()
        XCTAssertFalse(status.writeFailed)
        let entries = try rows(log.directory)
        let snapshots = entries.filter { $0["event"] as? String == "snapshot" }.compactMap { $0["fields"] as? [String: String] }
        XCTAssertEqual(snapshots.map { $0["matched"] }, ["1", "0"])
        XCTAssertEqual(snapshots.map { $0["stored"] }, ["1", "1"])
        XCTAssertTrue(entries.contains { $0["event"] as? String == "pruned" })
        XCTAssertTrue(entries.contains { ($0["fields"] as? [String: String])?["state"] == "unavailable_retained" })
        let text = String(decoding: try JSONSerialization.data(withJSONObject: entries), as: UTF8.self)
        for secret in ["PRIVATE_WINDOW_TITLE", "PRIVATE_CUSTOM_NAME", "technical-original-id"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(text.contains(AppLog.token(target.id)))
    }
}
