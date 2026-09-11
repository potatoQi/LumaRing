import AppKit

extension WindowRecord {
    static func normalizedName(_ name: String) -> String? {
        let cleaned = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return cleaned.isEmpty ? nil : String(cleaned.prefix(120))
    }
    static func sortedByName(_ records: [WindowRecord]) -> [WindowRecord] {
        records.sorted {
            let comparison = $0.displayTitle.localizedStandardCompare($1.displayTitle)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            // IDs are independent of the system's stacking order and tab positions.
            return $0.id < $1.id
        }
    }
}

/// Aliases belong to a live app process and exact window/tab ID, never its title or URL.
/// Process launch time prevents restored/reused IDs inheriting another session's name.
@MainActor final class WindowNames {
    struct Process: Codable, Hashable {
        let pid: pid_t
        let bundleID: String
        let launched: Date

        var logFields: [String: String] {
            ["pid": String(pid), "bundle": bundleID,
             "launch": String(launched.timeIntervalSinceReferenceDate),
             "launchBits": String(launched.timeIntervalSinceReferenceDate.bitPattern, radix: 16)]
        }
    }
    enum ProcessState {
        case running(Process), unavailable, terminated

        var identity: Process? {
            guard case .running(let process) = self else { return nil }
            return process
        }

        @MainActor static func read(_ pid: pid_t) -> Self {
            guard pid > 0 else { return .unavailable }
            // Signal 0 only checks existence; it does not signal or modify the app.
            // Missing Launch Services metadata is not evidence of process exit.
            if kill(pid, 0) == -1 && errno == ESRCH { return .terminated }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  let date = app.launchDate, let bundleID = app.bundleIdentifier else { return .unavailable }
            return .running(Process(pid: pid, bundleID: bundleID, launched: date))
        }
    }
    private struct Key: Codable, Hashable {
        let process: Process
        let id: String
        let isTab: Bool
    }
    private struct Style: Codable { let name: String?; let color: SectorColor? }
    private struct Entry: Codable { let key: Key; let style: Style }
    private let defaults: UserDefaults
    private let process: @MainActor (pid_t) -> ProcessState
    private let log: AppLog
    private var aliases: [Key: Style] = [:]
    private static let preferenceKey = "windowStyles.v1"

    init(defaults: UserDefaults = .standard, log: AppLog = .shared,
         process: @escaping @MainActor (pid_t) -> ProcessState = { ProcessState.read($0) }) {
        self.defaults = defaults; self.process = process; self.log = log
        if let data = defaults.data(forKey: Self.preferenceKey) {
            if let entries = try? JSONDecoder().decode([Entry].self, from: data) {
                for entry in entries.prefix(2048) { aliases[entry.key] = entry.style }
            } else {
                log.record("load_failed", category: .windowStyles, level: .error, fields: ["bytes": String(data.count)])
            }
        }
        log.record("loaded", category: .windowStyles, fields: ["count": String(aliases.count)])
        pruneTerminated()
    }

    func apply(_ result: WindowResult, pid: pid_t) -> WindowResult {
        guard case .ready(let records, let limited) = result else {
            let reason: String
            if case .permissionRequired = result { reason = "permission" } else { reason = "query_unavailable" }
            log.record("snapshot_unavailable", category: .windowStyles, level: .warning,
                       fields: ["pid": String(pid), "reason": reason])
            return result
        }
        guard let current = process(pid).identity else {
            log.record("snapshot_unavailable", category: .windowStyles, level: .warning,
                       fields: ["pid": String(pid), "reason": "process_identity_unavailable"])
            return result
        }
        log.record("snapshot", category: .windowStyles, level: .debug,
                   fields: snapshotFields(records, limited: limited, current: current))
        // Even a successful snapshot can omit live windows during wake/display
        // changes. Decorating a snapshot must never erase persisted styles.
        // Retain them within the bounded process scope until reset or termination.
        return .ready(records.map { record in
            var decorated = record
            let style = aliases[Key(process: current, id: record.id, isTab: record.tab != nil)]
            decorated.customName = style?.name
            decorated.customColor = style?.color
            return decorated
        }, limited: limited)
    }

    func identity(for pid: pid_t) -> Process? { process(pid).identity }

    @discardableResult func update(name: String, color: SectorColor?, for record: WindowRecord, expected: Process? = nil) -> Bool {
        guard let current = process(record.pid).identity, expected == nil || expected == current else {
            log.record("edit_rejected", category: .windowStyles, level: .warning,
                       fields: ["pid": String(record.pid), "reason": "process_unavailable_or_changed"])
            return false
        }
        let key = Key(process: current, id: record.id, isTab: record.tab != nil)
        let normalized = WindowRecord.normalizedName(name)
        guard aliases[key] != nil || aliases.count < 2048 || (normalized == nil && color == nil) else {
            log.record("edit_rejected", category: .windowStyles, level: .warning, fields: ["reason": "record_limit"])
            return false
        }
        aliases[key] = normalized == nil && color == nil ? nil : Style(name: normalized, color: color)
        save()
        log.record("edited", category: .windowStyles, fields: current.logFields.merging([
            "item": AppLog.token(record.id), "kind": record.tab == nil ? "window" : "tab",
            "hasName": String(normalized != nil), "hasColor": String(color != nil)
        ], uniquingKeysWith: { _, value in value }))
        return true
    }

    func pruneTerminated() {
        let processes = Set(aliases.keys.map(\.process))
        let states = Dictionary(uniqueKeysWithValues: Set(processes.map(\.pid)).map { ($0, process($0)) })
        var terminated = Set<Process>(), replaced = Set<Process>()
        for saved in processes {
            log.record("process_check", category: .windowStyles, level: .debug,
                       fields: processFields(saved, state: states[saved.pid] ?? .unavailable))
            switch states[saved.pid] {
            case .terminated: terminated.insert(saved)
            case .running(let current) where current != saved: replaced.insert(saved)
            default: break // Unknown state must retain both in-memory and persisted styles.
            }
        }
        let oldCount = aliases.count
        aliases = aliases.filter { !terminated.contains($0.key.process) && !replaced.contains($0.key.process) }
        if aliases.count != oldCount {
            log.record("pruned", category: .windowStyles, fields: [
                "removed": String(oldCount - aliases.count), "terminatedScopes": String(terminated.count),
                "replacedScopes": String(replaced.count), "remaining": String(aliases.count)
            ])
            save()
        }
    }
    private func save() {
        let entries = aliases.map { Entry(key: $0.key, style: $0.value) }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.preferenceKey)
            log.record("saved_to_preferences", category: .windowStyles,
                       fields: ["count": String(entries.count), "bytes": String(data.count)])
        } else { log.record("encode_failed", category: .windowStyles, level: .error) }
    }

    private func processFields(_ saved: Process, state: ProcessState) -> [String: String] {
        var fields = saved.logFields
        switch state {
        case .unavailable: fields["state"] = "unavailable_retained"
        case .terminated: fields["state"] = "terminated"
        case .running(let current):
            fields["state"] = current == saved ? "same" : "replaced"
            fields["currentLaunchBits"] = String(current.launched.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            fields["currentBundle"] = current.bundleID
        }
        return fields
    }

    private func snapshotFields(_ records: [WindowRecord], limited: Bool, current: Process) -> [String: String] {
        var fields = current.logFields
        let saved = aliases.keys.filter { $0.process == current }
        fields["limited"] = String(limited)
        fields["visible"] = String(records.count)
        fields["stored"] = String(saved.count)
        fields["matched"] = String(records.filter { aliases[Key(process: current, id: $0.id, isTab: $0.tab != nil)] != nil }.count)
        // ID fingerprints allow before/after comparison without capturing user content.
        fields["windowIDs"] = records.filter { $0.tab == nil }.prefix(128).map { AppLog.token($0.id) }.sorted().joined(separator: ",")
        fields["tabIDs"] = records.filter { $0.tab != nil }.prefix(128).map { AppLog.token($0.id) }.sorted().joined(separator: ",")
        fields["storedIDs"] = saved.map { AppLog.token($0.id) }.sorted().prefix(128).joined(separator: ",")
        fields["idsTruncated"] = String(records.count > 128 || saved.count > 128)
        return fields
    }
}
