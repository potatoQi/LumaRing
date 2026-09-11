import AppKit
import Carbon
import Combine
import LumaRingCore

enum AppContentMode: String, Codable {
    case windows, tabs
    var title: String { self == .tabs ? L10n.text("标签页", "Tabs") : L10n.text("窗口", "Windows") }
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
        case .permission: return L10n.text("请在“应用管理”中连接浏览器；若曾拒绝，请在系统设置的“自动化”中允许。", "Connect the browser in App Management. If access was denied, allow it under Automation in System Settings.")
        case .closed: return L10n.text("标签页已关闭或正在移动，请重新呼出后再试。", "This tab was closed or is moving. Reopen the ring and try again.")
        case .malformed: return L10n.text("浏览器返回的数据无法识别，请更新浏览器后重试。", "The browser returned unrecognized data. Update the browser and try again.")
        case .timeout: return L10n.text("浏览器响应较慢，请稍后重新呼出。", "The browser is responding slowly. Reopen the ring in a moment.")
        case .event(let code, let step): return L10n.text("无法读取、切换或关闭标签页（\(code) \(step)），请重新连接浏览器。", "Could not read, switch or close tabs (\(code) \(step)). Reconnect the browser.")
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
    static func identifiedObject(_ kind: String, id: String, container: Descriptor = .null()) -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(Descriptor(typeCode: code(kind)), forKeyword: UInt32(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: UInt32(keyAEContainer))
        record.setDescriptor(Descriptor(enumCode: UInt32(formUniqueID)), forKeyword: UInt32(keyAEKeyForm))
        // Chromium's scripting dictionary declares window and tab IDs as text.
        record.setDescriptor(Descriptor(string: id), forKeyword: UInt32(keyAEKeyData))
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
    private func event(_ operation: String, object: Descriptor?, value: Descriptor? = nil, parameters: [String: Descriptor] = [:]) throws -> Descriptor {
        let propertyCode = object?.forKeyword(UInt32(keyAEKeyData))?.typeCodeValue ?? 0
        let step = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: propertyCode >> $0) }, encoding: .ascii) ?? operation
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard !cancelled(), remaining > 0 else { throw BrowserError.timeout }
        let event = Descriptor(eventClass: Self.code("core"), eventID: Self.code(operation), targetDescriptor: target,
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: keyDirectObject) }
        for (key, parameter) in parameters { event.setParam(parameter, forKeyword: Self.code(key)) }
        if let value { event.setParam(value, forKeyword: Self.code("data")) }
        let reply: Descriptor
        do { reply = try send(event, min(operation == "crel" ? 2 : 0.7, remaining)) }
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
                                       title: title.isEmpty ? (url.isEmpty ? L10n.text("未命名标签页", "Untitled tab") : url) : title,
                                       url: url, windowIndex: offset + 1, index: index + 1, minimized: minimized))
            }
            if tabs.count >= 512 { limited = true; break }
        }
        return (tabs, limited)
    }
    func newWindow() throws {
        // Chromium's installed scripting dictionary exposes core/crel with a
        // cwin object class. No menu text, keystrokes or page JavaScript involved.
        let properties = Descriptor.record()
        properties.setDescriptor(Descriptor(string: "normal"), forKeyword: Self.code("mode"))
        _ = try event("crel", object: nil, parameters: [
            "kocl": Descriptor(typeCode: Self.code("cwin")), "prdt": properties
        ])
    }

    func count(includeMinimized: Bool) throws -> AppItemCount {
        let windows = try Self.records(get("ID  ", Self.object("cwin")))
        var scanned = 0, visible = 0, limited = windows.count > 32
        for value in windows.prefix(32) {
            guard let id = value.stringValue else { throw BrowserError.malformed }
            let window = Self.identifiedObject("cwin", id: id)
            // Chromium exposes a native count command; badges need neither tab
            // IDs nor titles/URLs. Keep the same display cap and minimized filter.
            let result = try event("cnte", object: window, parameters: ["kocl": Descriptor(typeCode: Self.code("CrTb"))])
            guard [typeSInt16, typeSInt32, typeSInt64].contains(result.descriptorType),
                  let integer = result.coerce(toDescriptorType: typeSInt32), integer.descriptorType == typeSInt32,
                  integer.int32Value >= 0 else { throw BrowserError.malformed }
            let count = min(Int(integer.int32Value), 512 - scanned)
            let minimized = includeMinimized ? false : try get("pmnd", window).booleanValue
            if !minimized { visible += count }
            scanned += count
            if scanned >= 512 { limited = true; break }
        }
        return AppItemCount(value: visible, limited: limited)
    }

    private func tabIDs(in windowID: String) throws -> [String]? {
        let window = Self.identifiedObject("cwin", id: windowID)
        do {
            return try Self.records(get("ID  ", Self.object("CrTb", container: window))).map {
                guard let id = $0.stringValue else { throw BrowserError.malformed }
                return id
            }
        } catch BrowserError.event(-1728, _) {
            // A removed source window is expected when its last tab was moved.
            // Permission failures and timeouts must not start another scan.
            return nil
        }
    }

    private func resolve(_ tab: BrowserTab) throws -> (window: Descriptor, index: Int) {
        // The usual path needs only the source window's IDs. Titles, URLs and
        // unrelated windows are irrelevant to selecting or closing this tab.
        if let index = try tabIDs(in: tab.windowID)?.firstIndex(of: tab.id) {
            return (Self.identifiedObject("cwin", id: tab.windowID), index + 1)
        }
        let windows = try Self.records(get("ID  ", Self.object("cwin")))
        for value in windows.prefix(32) {
            guard let windowID = value.stringValue else { throw BrowserError.malformed }
            guard windowID != tab.windowID else { continue }
            if let index = try tabIDs(in: windowID)?.firstIndex(of: tab.id) {
                return (Self.identifiedObject("cwin", id: windowID), index + 1)
            }
        }
        throw BrowserError.closed
    }

    func close(_ tab: BrowserTab) throws {
        let window = try resolve(tab).window
        let target = Self.identifiedObject("CrTb", id: tab.id, container: window)
        guard try get("ID  ", target).stringValue == tab.id else { throw BrowserError.closed }
        // Send the close command to stable IDs, never a tab index. If the tab moves
        // again or disappears, the command fails instead of closing its neighbour.
        _ = try event("clos", object: target)
    }

    func activate(_ tab: BrowserTab) throws {
        // Re-resolve the tab index, but keep the window addressed by stable ID
        // so concurrent window reordering cannot redirect any of these writes.
        let current = try resolve(tab)
        let window = current.window
        let minimized = try get("pmnd", window).booleanValue
        let tabObject = Self.object("CrTb", container: window, index: current.index)
        guard try get("ID  ", tabObject).stringValue == tab.id else { throw BrowserError.closed }
        _ = try event("setd", object: Self.property("acTI", of: window), value: Descriptor(int32: Int32(current.index)))
        guard try get("ID  ", Self.property("acTa", of: window)).stringValue == tab.id else { throw BrowserError.closed }
        if minimized {
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

    func refreshLanguage() {
        messages.removeAll()
        for id in connected { messages[id] = L10n.text("已授权", "Access granted") }
        for id in connecting { messages[id] = L10n.text("等待浏览器授权…", "Waiting for browser access…") }
    }

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
                        if self.messages[id] == nil { self.messages[id] = L10n.text("已授权", "Access granted") }
                    } else {
                        self.connected.remove(id)
                        self.messages[id] = L10n.text("尚未授权，请连接浏览器。", "Access not granted. Connect the browser.")
                    }
                }
            }
        }
    }

    func connect(_ app: NSRunningApplication) {
        guard let identifier = app.bundleIdentifier, BrowserAdapters.supports(identifier), !connecting.contains(identifier) else { return }
        let pid = app.processIdentifier
        connecting.insert(identifier)
        messages[identifier] = L10n.text("等待浏览器授权…", "Waiting for browser access…")
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
                    AppLog.shared.record("connected", category: .browser, fields: ["pid": String(pid), "tabCount": String(count)])
                    self.connected.insert(identifier)
                    self.messages[identifier] = L10n.text("已连接 · \(count) 个标签页", "Connected · \(count) tabs")
                case .failure(let error):
                    AppLog.shared.record("connection_failed", category: .browser, level: .warning, fields: AppLog.errorFields(error))
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
            } catch {
                AppLog.shared.record("query_failed", category: .browser, level: .warning, fields: AppLog.errorFields(error))
                result = .unavailable(error.localizedDescription)
            }
            DispatchQueue.main.async { if !token.isCancelled { completion(result) } }
        }
    }
    func count(pid: pid_t, bundleID: String, includeMinimized: Bool, completion: @escaping (AppItemCount?) -> Void) {
        work?.cancel()
        let token = CancellationFlag(); work = token
        queue.async {
            guard !token.isCancelled else { return }
            let result: AppItemCount?
            if BrowserAdapters.supports(bundleID), BrowserEvents.permission(pid: pid, ask: false) == noErr {
                result = try? BrowserEvents(pid: pid, cancelled: { token.isCancelled }).count(includeMinimized: includeMinimized)
            } else { result = nil }
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
                case .failure(let error):
                    AppLog.shared.record("activation_failed", category: .browser, level: .warning, fields: AppLog.errorFields(error))
                    completion(result)
                case .success:
                    ApplicationActivator().activate(pid: pid) { success in
                        AppLog.shared.record("activate_result", category: .browser, level: success ? .info : .warning,
                                             fields: ["pid": String(pid), "item": AppLog.token(tab.id), "success": String(success)])
                        completion(success ? .success(()) : .failure(BrowserError.closed))
                    }
                }
            }
        }
    }
    func close(_ tab: BrowserTab, pid: pid_t, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result {
                guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == tab.bundleID,
                      BrowserAdapters.supports(tab.bundleID),
                      BrowserEvents.permission(pid: pid, ask: false) == noErr else { throw BrowserError.permission }
                try BrowserEvents(pid: pid, budget: 3).close(tab)
            }
            switch result {
            case .success:
                AppLog.shared.record("close_request_accepted", category: .browser,
                                     fields: ["pid": String(pid), "item": AppLog.token(tab.id)])
            case .failure(let error):
                AppLog.shared.record("close_request_failed", category: .browser, level: .warning, fields: AppLog.errorFields(error))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func cancelAndClear() { work?.cancel(); work = nil }
}
