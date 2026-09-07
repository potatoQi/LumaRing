import AppKit
import Carbon
import Combine
import LumaRingCore

enum AppContentMode: String, Codable, CaseIterable {
    case windows, tabs
    var title: String { self == .tabs ? "标签页" : "窗口" }
}

enum BrowserAdapters {
    static let supported: Set<String> = ["com.microsoft.edgemac", "com.google.Chrome"]
    static func supports(_ bundleID: String) -> Bool { supported.contains(bundleID) }
}

struct BrowserTab: Equatable {
    let bundleID: String
    let windowID: String
    let id: String
    let title: String
    let url: String
    let windowIndex: Int
    let index: Int
    let minimized: Bool
}

enum BrowserError: LocalizedError {
    case permission, closed, malformed, timeout, event(Int32, String = "")
    var errorDescription: String? {
        switch self {
        case .permission: return "请在“应用管理”中连接浏览器；若曾拒绝，请在系统设置的“自动化”中允许。"
        case .closed: return "标签页已关闭或正在移动，请重新呼出后再试。"
        case .malformed: return "浏览器返回的数据无法识别，请更新浏览器后重试。"
        case .timeout: return "浏览器响应较慢，请稍后重新呼出。"
        case .event(let code, let step): return "无法读取或切换标签页（\(code) \(step)），请重新连接浏览器。"
        }
    }
}

/// Native Chromium scripting objects, never page scripts or generated AppleScript source.
/// The transport is injectable so descriptor parsing and stable-ID activation are testable.
final class BrowserEvents {
    typealias Descriptor = NSAppleEventDescriptor
    typealias Transport = (Descriptor, TimeInterval) throws -> Descriptor
    static func code(_ value: String) -> FourCharCode {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private let target: Descriptor
    private let send: Transport
    private let cancelled: () -> Bool
    private let deadline: TimeInterval
    init(pid: pid_t, budget: TimeInterval = 2, cancelled: @escaping () -> Bool = { false }, transport: Transport? = nil) {
        target = Descriptor(processIdentifier: pid)
        self.cancelled = cancelled
        deadline = ProcessInfo.processInfo.systemUptime + budget
        send = transport ?? { try $0.sendEvent(options: [.waitForReply, .neverInteract], timeout: $1) }
    }
    static func permission(pid: pid_t, ask: Bool) -> OSStatus {
        let target = Descriptor(processIdentifier: pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }
    static func object(_ kind: String, container: Descriptor = .null(), index: Int? = nil) -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(Descriptor(typeCode: code(kind)), forKeyword: UInt32(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: UInt32(keyAEContainer))
        record.setDescriptor(Descriptor(enumCode: UInt32(formAbsolutePosition)), forKeyword: UInt32(keyAEKeyForm))
        record.setDescriptor(index.map { Descriptor(int32: Int32($0)) } ?? Descriptor(descriptorType: UInt32(typeAbsoluteOrdinal), data: Descriptor(enumCode: UInt32(kAEAll)).data)!, forKeyword: UInt32(keyAEKeyData))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }
    static func property(_ name: String, of container: Descriptor) -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(Descriptor(typeCode: code("prop")), forKeyword: UInt32(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: UInt32(keyAEContainer))
        record.setDescriptor(Descriptor(enumCode: UInt32(formPropertyID)), forKeyword: UInt32(keyAEKeyForm))
        record.setDescriptor(Descriptor(typeCode: code(name)), forKeyword: UInt32(keyAEKeyData))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }
    private func event(_ operation: String, object: Descriptor, value: Descriptor? = nil) throws -> Descriptor {
        let propertyCode = object.forKeyword(UInt32(keyAEKeyData))?.typeCodeValue ?? 0
        let step = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: propertyCode >> $0) }, encoding: .ascii) ?? operation
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard !cancelled(), remaining > 0 else { throw BrowserError.timeout }
        let event = Descriptor(eventClass: Self.code("core"), eventID: Self.code(operation), targetDescriptor: target,
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: keyDirectObject)
        if let value { event.setParam(value, forKeyword: Self.code("data")) }
        let reply: Descriptor
        do { reply = try send(event, min(0.7, remaining)) }
        catch {
            let code = Int32((error as NSError).code)
            if code == -1743 || code == -1744 { throw BrowserError.permission }
            if code == -1712 { throw BrowserError.timeout }
            throw BrowserError.event(code, step)
        }
        let error = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0
        guard error == 0 else {
            if error == -1743 || error == -1744 { throw BrowserError.permission }
            throw BrowserError.event(error, step)
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }
    private func get(_ property: String, _ object: Descriptor) throws -> Descriptor {
        try event("getd", object: Self.property(property, of: object))
    }
    static func text(_ record: Descriptor, _ key: String) -> String? {
        record.forKeyword(code(key))?.stringValue
    }
    static func records(_ descriptor: Descriptor) throws -> [Descriptor] {
        guard descriptor.descriptorType == typeAEList else { throw BrowserError.malformed }
        return (0..<descriptor.numberOfItems).compactMap { descriptor.atIndex($0 + 1) }
    }
    func list(bundleID: String) throws -> (tabs: [BrowserTab], limited: Bool) {
        let windowIDs = try Self.records(get("ID  ", Self.object("cwin"))).compactMap(\.stringValue)
        var tabs: [BrowserTab] = []
        var limited = windowIDs.count > 32
        for (offset, windowID) in windowIDs.prefix(32).enumerated() {
            let object = Self.object("cwin", index: offset + 1)
            let minimized = try get("pmnd", object).booleanValue
            let tabObjects = Self.object("CrTb", container: object)
            let ids = try Self.records(get("ID  ", tabObjects)).compactMap(\.stringValue)
            let titles = try Self.records(get("pnam", tabObjects)).map { $0.stringValue ?? "" }
            let urls = try Self.records(get("URL ", tabObjects)).map { $0.stringValue ?? "" }
            let verifiedIDs = try Self.records(get("ID  ", tabObjects)).compactMap(\.stringValue)
            guard ids == verifiedIDs, ids.count == titles.count, ids.count == urls.count,
                  try get("ID  ", object).stringValue == windowID else { throw BrowserError.closed }
            for index in 0..<min(ids.count, max(0, 512 - tabs.count)) {
                let title = titles[index], url = urls[index]
                tabs.append(BrowserTab(bundleID: bundleID, windowID: windowID, id: ids[index],
                                       title: title.isEmpty ? (url.isEmpty ? "未命名标签页" : url) : title,
                                       url: url, windowIndex: offset + 1, index: index + 1, minimized: minimized))
            }
            if tabs.count >= 512 { limited = true; break }
        }
        return (tabs, limited)
    }
    func activate(_ tab: BrowserTab) throws {
        // Re-resolve IDs on every click. Browser tab indices change when tabs move or close.
        let fresh = try list(bundleID: tab.bundleID).tabs
        guard let current = fresh.first(where: { $0.id == tab.id }) else { throw BrowserError.closed }
        let window = Self.object("cwin", index: current.windowIndex)
        let tabObject = Self.object("CrTb", container: window, index: current.index)
        guard try get("ID  ", window).stringValue == current.windowID,
              try get("ID  ", tabObject).stringValue == tab.id else { throw BrowserError.closed }
        _ = try event("setd", object: Self.property("acTI", of: window), value: Descriptor(int32: Int32(current.index)))
        guard try get("ID  ", Self.property("acTa", of: window)).stringValue == tab.id else { throw BrowserError.closed }
        if current.minimized {
            _ = try event("setd", object: Self.property("pmnd", of: window), value: Descriptor(boolean: false))
        }
        _ = try event("setd", object: Self.property("pidx", of: window), value: Descriptor(int32: 1))
    }
}

@MainActor final class BrowserTabService: ObservableObject {
    static let shared = BrowserTabService()
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var connected: Set<String> = []
    @Published private(set) var connecting: Set<String> = []
    private let queue = DispatchQueue(label: "local.lumaring.browser-tabs", qos: .userInitiated)
    private let authorizationQueue = DispatchQueue(label: "local.lumaring.browser-authorization", qos: .userInitiated)
    private var work: CancellationFlag?

    func refreshAuthorization(_ apps: [NSRunningApplication]) {
        let targets = apps.compactMap { app -> (String, pid_t)? in
            guard let id = app.bundleIdentifier, BrowserAdapters.supports(id),
                  Preferences.shared.options.contentMode(for: id) == .tabs else { return nil }
            return (id, app.processIdentifier)
        }
        queue.async { [weak self] in
            let statuses = targets.map { ($0.0, BrowserEvents.permission(pid: $0.1, ask: false) == noErr) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (id, granted) in statuses where !self.connecting.contains(id) {
                    if granted {
                        self.connected.insert(id)
                        if self.messages[id] == nil { self.messages[id] = "已授权" }
                    } else {
                        self.connected.remove(id)
                        self.messages[id] = "尚未授权，请连接浏览器。"
                    }
                }
            }
        }
    }

    func connect(_ app: NSRunningApplication) {
        guard let identifier = app.bundleIdentifier, BrowserAdapters.supports(identifier), !connecting.contains(identifier) else { return }
        let pid = app.processIdentifier
        connecting.insert(identifier)
        messages[identifier] = "等待浏览器授权…"
        authorizationQueue.async { [weak self] in
            let status = BrowserEvents.permission(pid: pid, ask: true)
            let result: Result<Int, Error> = Result {
                guard status == noErr else { throw BrowserError.permission }
                return try BrowserEvents(pid: pid).list(bundleID: identifier).tabs.count
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.connecting.remove(identifier)
                switch result {
                case .success(let count):
                    self.connected.insert(identifier)
                    self.messages[identifier] = "已连接 · \(count) 个标签页"
                case .failure(let error):
                    self.connected.remove(identifier)
                    self.messages[identifier] = error.localizedDescription
                }
            }
        }
    }
    func load(pid: pid_t, bundleID: String, completion: @escaping (WindowResult) -> Void) {
        work?.cancel()
        let token = CancellationFlag(); work = token
        queue.async {
            guard !token.isCancelled else { return }
            let result: WindowResult
            do {
                guard BrowserAdapters.supports(bundleID), BrowserEvents.permission(pid: pid, ask: false) == noErr else { throw BrowserError.permission }
                let snapshot = try BrowserEvents(pid: pid, cancelled: { token.isCancelled }).list(bundleID: bundleID)
                result = .ready(snapshot.tabs.map { tab in
                    WindowRecord(id: "tab:\(pid):\(tab.id)", pid: pid, title: tab.title, minimized: tab.minimized,
                                 fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(pid), tab: tab)
                }, limited: snapshot.limited)
            } catch { result = .unavailable(error.localizedDescription) }
            DispatchQueue.main.async { if !token.isCancelled { completion(result) } }
        }
    }
    func activate(_ tab: BrowserTab, pid: pid_t, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result {
                guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == tab.bundleID,
                      BrowserEvents.permission(pid: pid, ask: false) == noErr else { throw BrowserError.permission }
                try BrowserEvents(pid: pid, budget: 3).activate(tab)
            }
            DispatchQueue.main.async {
                switch result {
                case .failure: completion(result)
                case .success:
                    ApplicationActivator().activate(pid: pid) { success in
                        completion(success ? .success(()) : .failure(BrowserError.closed))
                    }
                }
            }
        }
    }
    func cancelAndClear() { work?.cancel(); work = nil }
}
