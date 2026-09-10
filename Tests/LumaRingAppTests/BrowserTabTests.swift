import XCTest
import AppKit
import Carbon
import LumaRingCore
@testable import LumaRing

final class BrowserTabTests: XCTestCase {
    typealias D = NSAppleEventDescriptor
    let edge = "com.microsoft.edgemac"
    func record(_ pairs: [String: D]) -> D {
        let result = D.record()
        for (key, value) in pairs { result.setDescriptor(value, forKeyword: BrowserEvents.code(key)) }
        return result
    }
    func list(_ values: [D]) -> D {
        let result = D.list()
        for (offset, value) in values.enumerated() { result.insert(value, at: offset + 1) }
        return result
    }
    func tab(_ id: String, title: String = "标题\n引号‘’\"", url: String = "https://example.com/?a=1&b=中文") -> D {
        record(["ID  ": D(string: id), "pnam": D(string: title), "URL ": D(string: url)])
    }
    func snapshot(_ tabs: [D], windowID: String = "10", minimized: Bool = false, verifiedID: String? = nil) -> [D] {
        let ids = list(tabs.map { $0.forKeyword(BrowserEvents.code("ID  "))! })
        return [list([D(string: windowID)]), D(boolean: minimized), ids,
                list(tabs.map { $0.forKeyword(BrowserEvents.code("pnam"))! }),
                list(tabs.map { $0.forKeyword(BrowserEvents.code("URL "))! }), ids,
                D(string: verifiedID ?? windowID)]
    }
    func client(_ responses: [D], observe: @escaping (D) -> Void = { _ in }) -> BrowserEvents {
        var cursor = 0
        return BrowserEvents(pid: 42, transport: { event, timeout in
            XCTAssertGreaterThan(timeout, 0); XCTAssertLessThanOrEqual(timeout, 0.7)
            XCTAssertEqual(event.eventClass, BrowserEvents.code("core"))
            observe(event)
            guard cursor < responses.count else { throw BrowserError.malformed }
            let reply = D(eventClass: BrowserEvents.code("aevt"), eventID: BrowserEvents.code("ansr"), targetDescriptor: nil,
                          returnID: 0, transactionID: 0)
            reply.setParam(responses[cursor], forKeyword: keyDirectObject)
            cursor += 1
            return reply
        })
    }
    func testAllElementsUseAbsoluteOrdinalDescriptor() {
        let all = BrowserEvents.object("cwin")
        let key = all.forKeyword(UInt32(keyAEKeyData))!
        XCTAssertEqual(key.descriptorType, UInt32(typeAbsoluteOrdinal))
        XCTAssertEqual(key.data, D(enumCode: UInt32(kAEAll)).data)
        let indexed = BrowserEvents.object("cwin", index: 2)
        XCTAssertEqual(indexed.forKeyword(UInt32(keyAEKeyData))?.int32Value, 2)
    }

    func testNewWindowUsesNativeCreateCommandAndNeverRetriesUncertainResponse() throws {
        for fails in [false, true] {
            var sends = 0
            let browser = BrowserEvents(pid: 42, transport: { event, timeout in
                sends += 1
                XCTAssertEqual(event.eventClass, BrowserEvents.code("core"))
                XCTAssertEqual(event.eventID, BrowserEvents.code("crel"))
                XCTAssertNil(event.paramDescriptor(forKeyword: keyDirectObject))
                XCTAssertEqual(event.paramDescriptor(forKeyword: BrowserEvents.code("kocl"))?.typeCodeValue, BrowserEvents.code("cwin"))
                XCTAssertEqual(event.paramDescriptor(forKeyword: BrowserEvents.code("prdt"))?.forKeyword(BrowserEvents.code("mode"))?.stringValue, "normal")
                XCTAssertGreaterThan(timeout, 0.7); XCTAssertLessThanOrEqual(timeout, 2)
                if fails { throw NSError(domain: NSOSStatusErrorDomain, code: -1712) }
                return D(eventClass: BrowserEvents.code("aevt"), eventID: BrowserEvents.code("ansr"), targetDescriptor: nil, returnID: 0, transactionID: 0)
            })
            if fails { XCTAssertThrowsError(try browser.newWindow()) }
            else { try browser.newWindow() }
            XCTAssertEqual(sends, 1)
        }
    }
    func testModesDefaultAndRoundTripWithUnknownAdapters() throws {
        var options = Options()
        for id in [edge, "com.google.Chrome", "com.apple.finder"] { XCTAssertEqual(options.contentMode(for: id), .windows) }
        options.appContentModes[edge] = .tabs
        options.appContentModes["com.apple.finder"] = .tabs
        let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded.contentMode(for: edge), .tabs)
        XCTAssertEqual(decoded.contentMode(for: "com.google.Chrome"), .windows)
        XCTAssertEqual(decoded.contentMode(for: "com.apple.finder"), .windows)
        let future = try JSONDecoder().decode(Options.self, from: Data(#"{"appContentModes":{"com.microsoft.edgemac":"future"}}"#.utf8))
        XCTAssertEqual(future.contentMode(for: edge), .windows)
    }
    func testBulkReadPreservesUnicodeAndStableIDs() throws {
        let api = client(snapshot([tab("101"), tab("102", title: "", url: "edge://newtab/")]))
        let result = try api.list(bundleID: edge)
        XCTAssertEqual(result.tabs.map(\.id), ["101", "102"])
        XCTAssertEqual(result.tabs[0].title, "标题\n引号‘’\"")
        XCTAssertEqual(result.tabs[0].url, "https://example.com/?a=1&b=中文")
        XCTAssertEqual(result.tabs[1].title, "edge://newtab/")
        XCTAssertEqual(result.tabs.map(\.index), [1, 2])
        XCTAssertFalse(result.limited)
    }
    func testReorderedTabUsesFreshIndexAndVerifiesSelection() throws {
        let stale = BrowserTab(bundleID: edge, windowID: "10", id: "101", title: "A", url: "", windowIndex: 1, index: 1, minimized: false)
        var sets: [(UInt32, Int32)] = []
        let api = client([list([D(string: "102"), D(string: "101")]), D(boolean: false), D(string: "101"), .null(), D(string: "101"), .null()]) { event in
            if event.eventID == BrowserEvents.code("setd") {
                let object = event.paramDescriptor(forKeyword: keyDirectObject)!
                sets.append((object.forKeyword(UInt32(keyAEKeyData))!.typeCodeValue, event.paramDescriptor(forKeyword: BrowserEvents.code("data"))!.int32Value))
            }
        }
        try api.activate(stale)
        XCTAssertEqual(sets.map(\.0), [BrowserEvents.code("acTI"), BrowserEvents.code("pidx")])
        XCTAssertEqual(sets.map(\.1), [2, 1])
    }
    func testTabMovedToAnotherWindowAndMinimizedRestores() throws {
        let stale = BrowserTab(bundleID: edge, windowID: "old", id: "101", title: "A", url: "", windowIndex: 1, index: 9, minimized: false)
        var writes: [UInt32] = []
        let api = client([list([]), list([D(string: "20")]), list([D(string: "101")]), D(boolean: true), D(string: "101"), .null(), D(string: "101"), .null(), .null()]) { event in
            if event.eventID == BrowserEvents.code("setd") {
                writes.append(event.paramDescriptor(forKeyword: keyDirectObject)!.forKeyword(UInt32(keyAEKeyData))!.typeCodeValue)
            }
        }
        try api.activate(stale)
        XCTAssertEqual(writes, ["acTI", "pmnd", "pidx"].map(BrowserEvents.code))
    }
    func testCloseMovedTabUsesStableIDsInsteadOfFreshIndices() throws {
        let stale = BrowserTab(bundleID: edge, windowID: "10", id: "101", title: "A", url: "", windowIndex: 1, index: 1, minimized: false)
        var closes = 0
        let api = client([list([D(string: "102")]), list([D(string: "10"), D(string: "20")]), list([D(string: "102"), D(string: "101")]), D(string: "101"), .null()]) { event in
            XCTAssertNotEqual(event.eventID, BrowserEvents.code("setd"), "Closing must not change the active tab")
            guard event.eventID == BrowserEvents.code("clos") else { return }
            closes += 1
            let target = event.paramDescriptor(forKeyword: keyDirectObject)!
            XCTAssertEqual(target.forKeyword(UInt32(keyAEKeyForm))?.enumCodeValue, UInt32(formUniqueID))
            XCTAssertEqual(target.forKeyword(UInt32(keyAEKeyData))?.stringValue, "101")
            let window = target.forKeyword(UInt32(keyAEContainer))!
            XCTAssertEqual(window.forKeyword(UInt32(keyAEKeyForm))?.enumCodeValue, UInt32(formUniqueID))
            XCTAssertEqual(window.forKeyword(UInt32(keyAEKeyData))?.stringValue, "20")
        }
        try api.close(stale)
        XCTAssertEqual(closes, 1)
    }

    func testNormalCloseAndActivationDoNotReadOtherWindowsOrMetadata() throws {
        let tab = BrowserTab(bundleID: edge, windowID: "10", id: "101", title: "A", url: "", windowIndex: 9, index: 9, minimized: false)
        let cases: [(Bool, [D])] = [
            (true, [list([D(string: "101")]), D(string: "101"), .null()]),
            (false, [list([D(string: "101")]), D(boolean: false), D(string: "101"), .null(), D(string: "101"), .null()])
        ]
        for (closing, responses) in cases {
            var sends = 0
            let api = client(responses) { event in
                sends += 1
                var object = event.paramDescriptor(forKeyword: keyDirectObject)!
                while object.descriptorType == typeObjectSpecifier {
                    let kind = object.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue
                    let key = object.forKeyword(UInt32(keyAEKeyData))!
                    if kind == BrowserEvents.code("prop") {
                        XCTAssertNotEqual(key.typeCodeValue, BrowserEvents.code("pnam"))
                        XCTAssertNotEqual(key.typeCodeValue, BrowserEvents.code("URL "))
                    }
                    if kind == BrowserEvents.code("cwin") {
                        XCTAssertEqual(object.forKeyword(UInt32(keyAEKeyForm))?.enumCodeValue, UInt32(formUniqueID))
                        XCTAssertEqual(key.stringValue, "10", "Window reordering must not redirect the request")
                    }
                    object = object.forKeyword(UInt32(keyAEContainer)) ?? .null()
                }
            }
            if closing { try api.close(tab) } else { try api.activate(tab) }
            XCTAssertEqual(sends, closing ? 3 : 6)
        }
    }

    func testTargetReordersAgainBeforeActivationNeverWrites() {
        let tab = BrowserTab(bundleID: edge, windowID: "10", id: "101", title: "", url: "", windowIndex: 1, index: 1, minimized: false)
        let api = client([list([D(string: "101")]), D(boolean: false), D(string: "102")]) { event in
            XCTAssertNotEqual(event.eventID, BrowserEvents.code("setd"))
        }
        XCTAssertThrowsError(try api.activate(tab))
    }

    func testRemovedSourceWindowCanResolveMovedTabButTimeoutDoesNotScan() throws {
        let tab = BrowserTab(bundleID: edge, windowID: "old", id: "101", title: "", url: "", windowIndex: 1, index: 1, minimized: false)
        for errorCode: Int32 in [-1728, -1712, -1743] {
            var sends = 0
            let responses = [list([D(string: "20")]), list([D(string: "101")]), D(string: "101"), D.null()]
            let api = BrowserEvents(pid: 42, transport: { event, _ in
                sends += 1
                if sends == 1 { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errorCode)) }
                guard sends <= 5 else { XCTFail("Unexpected retry"); throw BrowserError.malformed }
                if event.eventID == BrowserEvents.code("clos") {
                    let target = event.paramDescriptor(forKeyword: keyDirectObject)!
                    XCTAssertEqual(target.forKeyword(UInt32(keyAEContainer))?.forKeyword(UInt32(keyAEKeyData))?.stringValue, "20")
                }
                let reply = D(eventClass: BrowserEvents.code("aevt"), eventID: BrowserEvents.code("ansr"), targetDescriptor: nil, returnID: 0, transactionID: 0)
                reply.setParam(responses[sends - 2], forKeyword: keyDirectObject)
                return reply
            })
            if errorCode == -1728 { try api.close(tab); XCTAssertEqual(sends, 5) }
            else { XCTAssertThrowsError(try api.close(tab)); XCTAssertEqual(sends, 1) }
        }
    }
    func testCloseMissingOrChangedTabNeverClosesNeighbour() {
        let stale = BrowserTab(bundleID: edge, windowID: "10", id: "101", title: "A", url: "", windowIndex: 1, index: 1, minimized: false)
        for responses in [[list([D(string: "102")]), list([D(string: "10")])], [list([D(string: "101")]), D(string: "102")]] {
            let api = client(responses) { event in XCTAssertNotEqual(event.eventID, BrowserEvents.code("clos")) }
            XCTAssertThrowsError(try api.close(stale))
        }
    }
    func testCancelledCloseNeverSendsMutation() {
        let tab = BrowserTab(bundleID: edge, windowID: "10", id: "101", title: "A", url: "", windowIndex: 1, index: 1, minimized: false)
        let api = BrowserEvents(pid: 42, cancelled: { true }, transport: { _, _ in XCTFail("Cancelled close must not send"); return .null() })
        XCTAssertThrowsError(try api.close(tab))
    }
    func testClosedTabNeverSelectsAnotherTab() {
        let stale = BrowserTab(bundleID: edge, windowID: "10", id: "gone", title: "A", url: "", windowIndex: 1, index: 1, minimized: false)
        let api = client([list([D(string: "102")]), list([D(string: "10")])]) { event in
            XCTAssertNotEqual(event.eventID, BrowserEvents.code("setd"))
        }
        XCTAssertThrowsError(try api.activate(stale))
    }
    func testConcurrentWindowReorderRejectsMixedSnapshot() {
        XCTAssertThrowsError(try client(snapshot([tab("102")], verifiedID: "other")).list(bundleID: edge))
    }
    func testMalformedAndCancelledQueriesDoNotSendFurtherEvents() {
        XCTAssertThrowsError(try client([D(string: "wrong")]).list(bundleID: edge))
        let api = BrowserEvents(pid: 42, cancelled: { true }, transport: { _, _ in XCTFail("Cancelled query must not send"); return .null() })
        XCTAssertThrowsError(try api.list(bundleID: edge))
        let expired = BrowserEvents(pid: 42, budget: 0, transport: { _, _ in XCTFail("Expired query must not send"); return .null() })
        XCTAssertThrowsError(try expired.list(bundleID: edge))
    }
    func testPermissionDenialHasActionableMessage() {
        let api = BrowserEvents(pid: 42, transport: { _, _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1743) })
        XCTAssertThrowsError(try api.list(bundleID: edge)) { XCTAssertTrue($0.localizedDescription.contains("应用管理")) }
    }
    func testMetadataLimit() throws {
        let result = try client(snapshot((0..<600).map { tab(String($0)) })).list(bundleID: edge)
        XCTAssertEqual(result.tabs.count, 512)
        XCTAssertTrue(result.limited)
    }

    func testBadgeCountUsesNativeCountAndOnlyReadsMinimizedWhenNeeded() throws {
        for includeMinimized in [false, true] {
            var sends = 0, counts = 0
            var responses = [list([D(string: "10"), D(string: "20")]), D(int32: 4)]
            if !includeMinimized { responses.append(D(boolean: false)) }
            responses.append(D(int32: 2))
            if !includeMinimized { responses.append(D(boolean: true)) }
            let api = client(responses) { event in
                sends += 1
                let object = event.paramDescriptor(forKeyword: keyDirectObject)!
                if event.eventID == BrowserEvents.code("cnte") {
                    counts += 1
                    XCTAssertEqual(event.paramDescriptor(forKeyword: BrowserEvents.code("kocl"))?.typeCodeValue, BrowserEvents.code("CrTb"))
                    XCTAssertEqual(object.forKeyword(UInt32(keyAEKeyForm))?.enumCodeValue, UInt32(formUniqueID))
                } else {
                    XCTAssertEqual(event.eventID, BrowserEvents.code("getd"))
                    let property = object.forKeyword(UInt32(keyAEKeyData))!.typeCodeValue
                    XCTAssertTrue(property == BrowserEvents.code("ID  ") || (!includeMinimized && property == BrowserEvents.code("pmnd")))
                    if property == BrowserEvents.code("ID  ") {
                        XCTAssertEqual(object.forKeyword(UInt32(keyAEContainer))?.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue, BrowserEvents.code("cwin"), "Counts must not request tab IDs")
                    }
                }
            }
            XCTAssertEqual(try api.count(includeMinimized: includeMinimized), AppItemCount(value: includeMinimized ? 6 : 4, limited: false))
            XCTAssertEqual(counts, 2); XCTAssertEqual(sends, includeMinimized ? 3 : 5)
        }
    }

    func testBadgeCountPreservesLimitsRejectsInvalidRepliesAndCancels() throws {
        let result = try client([list([D(string: "10"), D(string: "20")]), D(int32: 600)]).count(includeMinimized: true)
        XCTAssertEqual(result, AppItemCount(value: 512, limited: true))
        let minimized = try client([list([D(string: "10"), D(string: "20")]), D(int32: 600), D(boolean: true)]).count(includeMinimized: false)
        XCTAssertEqual(minimized, AppItemCount(value: 0, limited: true))
        let responses = [list((1...33).map { D(string: String($0)) })] + Array(repeating: D(int32: 1), count: 32)
        XCTAssertEqual(try client(responses).count(includeMinimized: true), AppItemCount(value: 32, limited: true))
        for invalid in [D(int32: -1), D.record()] {
            XCTAssertThrowsError(try client([list([D(string: "10")]), invalid]).count(includeMinimized: true))
        }
        XCTAssertEqual(try client([list([])]).count(includeMinimized: true), AppItemCount(value: 0, limited: false))
        let cancelled = BrowserEvents(pid: 42, cancelled: { true }, transport: { _, _ in XCTFail("Cancelled count must not send"); return .null() })
        XCTAssertThrowsError(try cancelled.count(includeMinimized: true))
    }
    @MainActor func testSingleWindowWithManyTabsExpandsAndPages() async {
        let view = RingView()
        let app = AppRecord(pid: 100, bundleID: edge, name: "Microsoft Edge", icon: NSImage(size: NSSize(width: 32, height: 32)))
        var options = Options(); options.appContentModes[edge] = .tabs
        view.reset(apps: [app], options: options); view.select(app)
        let records = (0..<7).map { index -> WindowRecord in
            let tab = BrowserTab(bundleID: edge, windowID: "10", id: String(index), title: "Page \(index)", url: "", windowIndex: 1, index: index + 1, minimized: false)
            return WindowRecord(id: tab.id, pid: 100, title: tab.title, minimized: false, fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(100), tab: tab)
        }
        view.setWindows(.ready(records), for: 100)
        XCTAssertTrue(view.showsWindowArc)
        XCTAssertEqual(view.message, "7 个标签页")
        XCTAssertEqual(view.visibleWindows.count, 6)
        view.changeWindowPage(1)
        XCTAssertEqual(view.visibleWindows.map(\.id), ["6"])
        for size in RingGeometry.windowPageSizeRange {
            options.windowPageSize = size
            view.reset(apps: [app], options: options); view.select(app)
            view.setWindows(.ready(records), for: 100)
            var seen: [String] = []
            for _ in 0..<RingGeometry.pageCount(total: records.count, size: size) {
                XCTAssertLessThanOrEqual(view.visibleWindows.count, size)
                seen += view.visibleWindows.map(\.id)
                view.changeWindowPage(1)
            }
            XCTAssertEqual(seen, records.map(\.id))
            XCTAssertEqual(view.windowPage, 0)
        }
        view.cancelHover()
    }
}
