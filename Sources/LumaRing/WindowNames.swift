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
    }
    private struct Key: Codable, Hashable {
        let process: Process
        let id: String
        let isTab: Bool
    }
    private struct Style: Codable { let name: String?; let color: SectorColor? }
    private struct Entry: Codable { let key: Key; let style: Style }
    private let defaults: UserDefaults
    private let process: @MainActor (pid_t) -> Process?
    private var aliases: [Key: Style] = [:]
    private static let preferenceKey = "windowStyles.v1"

    init(defaults: UserDefaults = .standard,
         process: @escaping @MainActor (pid_t) -> Process? = { pid in
             guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                   let date = app.launchDate else { return nil }
             return Process(pid: pid, bundleID: app.bundleIdentifier ?? "", launched: date)
         }) {
        self.defaults = defaults; self.process = process
        if let data = defaults.data(forKey: Self.preferenceKey),
           let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in entries.prefix(2048) {
                aliases[entry.key] = entry.style
            }
        }
        pruneTerminated()
    }

    func apply(_ result: WindowResult, pid: pid_t, isTab: Bool) -> WindowResult {
        guard case .ready(let records, let limited) = result else { return result }
        guard let current = process(pid) else { return result }
        if !limited {
            let live = Set(records.map(\.id))
            let oldCount = aliases.count
            aliases = aliases.filter { key, _ in
                key.process != current || key.isTab != isTab || live.contains(key.id)
            }
            if aliases.count != oldCount { save() }
        }
        return .ready(records.map { record in
            var decorated = record
            let style = aliases[Key(process: current, id: record.id, isTab: record.tab != nil)]
            decorated.customName = style?.name
            decorated.customColor = style?.color
            return decorated
        }, limited: limited)
    }

    func identity(for pid: pid_t) -> Process? { process(pid) }

    @discardableResult func update(name: String, color: SectorColor?, for record: WindowRecord, expected: Process? = nil) -> Bool {
        guard let current = process(record.pid), expected == nil || expected == current else { return false }
        let key = Key(process: current, id: record.id, isTab: record.tab != nil)
        let normalized = WindowRecord.normalizedName(name)
        guard aliases[key] != nil || aliases.count < 2048 || (normalized == nil && color == nil) else { return false }
        aliases[key] = normalized == nil && color == nil ? nil : Style(name: normalized, color: color)
        save()
        return true
    }

    func pruneTerminated() {
        let processes = Set(aliases.keys.map(\.process))
        let live = Set(processes.filter { process($0.pid) == $0 })
        let oldCount = aliases.count
        aliases = aliases.filter { live.contains($0.key.process) }
        if aliases.count != oldCount { save() }
    }
    private func save() {
        let entries = aliases.map { Entry(key: $0.key, style: $0.value) }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.preferenceKey) }
    }
}
