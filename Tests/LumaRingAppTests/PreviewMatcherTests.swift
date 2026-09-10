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
    func testBrowserDecorationDisambiguatesOverlappingWindows() {
        let candidates = [
            PreviewCandidate(id: 1, pid: 100, title: "Documentation", frame: frame, layer: 0),
            PreviewCandidate(id: 2, pid: 100, title: "New Tab", frame: frame, layer: 0)]
        for (app, title) in [
            ("Google Chrome", "Documentation - Google Chrome"),
            ("Microsoft Edge", "Documentation - Microsoft Edge - Demo"),
            ("Microsoft Edge", "Documentation - Microsoft Edge")
        ] {
            let target = window(title: title)
            XCTAssertEqual(PreviewMatcher.match(target, candidates: candidates, applicationName: app), 1)
            XCTAssertEqual(PreviewMatcher.match(target, candidates: candidates.reversed(), applicationName: app), 1)
        }
    }
    func testDecoratedTitleStillMatchesAfterMoveAndResize() {
        let candidates = [
            PreviewCandidate(id: 1, pid: 100, title: "Document", frame: CGRect(x: 400, y: 400, width: 800, height: 500), layer: 0),
            PreviewCandidate(id: 2, pid: 100, title: "Other", frame: frame, layer: 0)]
        XCTAssertEqual(PreviewMatcher.match(window(title: "Document - Microsoft Edge - Demo"),
                                           candidates: candidates, applicationName: "Microsoft Edge"), 1)
    }
    func testExactTitleTakesPriorityOverDecoratedTitle() {
        let candidates = [
            PreviewCandidate(id: 1, pid: 100, title: "Document - Google Chrome", frame: frame, layer: 0),
            PreviewCandidate(id: 2, pid: 100, title: "Document", frame: frame, layer: 0)]
        XCTAssertEqual(PreviewMatcher.match(window(title: "Document - Google Chrome"),
                                           candidates: candidates, applicationName: "Google Chrome"), 1)
    }
    func testDuplicateDecoratedTitlesStillRequireUniqueGeometry() {
        let target = window(title: "Document - Microsoft Edge - Demo")
        let a = PreviewCandidate(id: 1, pid: 100, title: "Document", frame: frame, layer: 0)
        let moved = PreviewCandidate(id: 2, pid: 100, title: "Document", frame: frame.offsetBy(dx: 100, dy: 0), layer: 0)
        let overlapping = PreviewCandidate(id: 3, pid: 100, title: "Document", frame: frame, layer: 0)
        XCTAssertEqual(PreviewMatcher.match(target, candidates: [a, moved], applicationName: "Microsoft Edge"), 1)
        XCTAssertNil(PreviewMatcher.match(target, candidates: [a, overlapping], applicationName: "Microsoft Edge"))
    }
    func testSharedPrefixOrAnotherAppNameIsNotTitleEvidence() {
        let candidates = [
            PreviewCandidate(id: 1, pid: 100, title: "Document", frame: frame, layer: 0),
            PreviewCandidate(id: 2, pid: 100, title: "Other", frame: frame, layer: 0)]
        for title in ["Document - Draft", "Documentary - Google Chrome", "Document - Microsoft Edge",
                      "Document - Google Chrome Canary", "Document - Google ChromeProfile"] {
            XCTAssertNil(PreviewMatcher.match(window(title: title), candidates: candidates, applicationName: "Google Chrome"))
        }
        XCTAssertNil(PreviewMatcher.match(window(title: "Document - Google Chrome"), candidates: candidates))
    }
    func testDecoratedTitleNeverCrossesProcessOrLayerBoundaries() {
        let candidates = [
            PreviewCandidate(id: 1, pid: 101, title: "Document", frame: frame, layer: 0),
            PreviewCandidate(id: 2, pid: 100, title: "Document", frame: frame, layer: 3)]
        XCTAssertNil(PreviewMatcher.match(window(title: "Document - Google Chrome"),
                                         candidates: candidates, applicationName: "Google Chrome"))
    }
    func testTitlelessCandidatesDoNotMatchAppDecoration() {
        let candidates = [
            PreviewCandidate(id: 1, pid: 100, title: "", frame: frame, layer: 0),
            PreviewCandidate(id: 2, pid: 100, title: nil, frame: frame, layer: 0)]
        XCTAssertNil(PreviewMatcher.match(window(title: " - Google Chrome"), candidates: candidates, applicationName: "Google Chrome"))
    }
    func testUniqueGeometryRemainsAvailableWhenTitleChanges() {
        let candidate = PreviewCandidate(id: 1, pid: 100, title: "Loading…", frame: frame, layer: 0)
        XCTAssertEqual(PreviewMatcher.match(window(title: "Documentation - Google Chrome"),
                                           candidates: [candidate], applicationName: "Google Chrome"), 1)
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
