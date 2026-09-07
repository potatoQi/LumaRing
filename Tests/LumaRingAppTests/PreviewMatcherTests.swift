import XCTest
import AppKit
import ScreenCaptureKit
@testable import LumaRing

final class PreviewMatcherTests: XCTestCase {
    private let frame = CGRect(x: 20, y: 20, width: 600, height: 400)
    private func window(title: String = "Document") -> WindowRecord {
        WindowRecord(id: "test", pid: 100, title: title, minimized: false, fullscreen: false,
                     frame: frame, element: AXUIElementCreateApplication(100))
    }
    func testMovedWindowKeepsUniqueTitleMatch() {
        let candidates = [PreviewCandidate(id: 1, pid: 100, title: "Document", frame: CGRect(x: 400, y: 400, width: 800, height: 500), layer: 0),
                          PreviewCandidate(id: 2, pid: 200, title: "Document", frame: frame, layer: 0)]
        XCTAssertEqual(PreviewMatcher.match(window(), candidates: candidates), 1)
    }
    func testDuplicateTitlesRequireUniqueGeometry() {
        let a = PreviewCandidate(id: 1, pid: 100, title: "Document", frame: frame, layer: 0)
        let b = PreviewCandidate(id: 2, pid: 100, title: "Document", frame: frame.offsetBy(dx: 100, dy: 0), layer: 0)
        XCTAssertEqual(PreviewMatcher.match(window(), candidates: [a, b]), 1)
        let ambiguous = PreviewCandidate(id: 3, pid: 100, title: "Document", frame: frame, layer: 0)
        XCTAssertNil(PreviewMatcher.match(window(), candidates: [a, ambiguous]))
        XCTAssertNil(PreviewMatcher.match(window(), candidates: []))
    }
    func testWrongAppAndFloatingWindowsAreNeverMatched() {
        XCTAssertNil(PreviewMatcher.match(window(), candidates: [
            PreviewCandidate(id: 1, pid: 101, title: "Document", frame: frame, layer: 0),
            PreviewCandidate(id: 2, pid: 100, title: "Document", frame: frame, layer: 3)]))
    }
    func testPermissionFailureIsDistinctFromCaptureError() {
        XCTAssertEqual(PreviewFailure(error: NSError(domain: SCStreamErrorDomain, code: -3801)), .permissionDenied)
        XCTAssertEqual(PreviewFailure(error: NSError(domain: SCStreamErrorDomain, code: -3802)), .capture(SCStreamErrorDomain, -3802))
    }
    @MainActor func testMinimizedPreviewHasExplicitReason() {
        var target = window()
        target = WindowRecord(id: target.id, pid: target.pid, title: target.title, minimized: true,
                              fullscreen: false, frame: target.frame, element: target.element)
        var failure: PreviewFailure?
        PreviewService().load(target) { if case .failure(let value) = $0 { failure = value } }
        XCTAssertEqual(failure, .minimized)
    }
}
