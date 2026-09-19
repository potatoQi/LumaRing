import AppKit
import XCTest
import LumaRingCore
@testable import LumaRing

final class RingMaterialTests: XCTestCase {
    func testMaterialPreferenceRoundTripsAndDefaultsWithoutResettingOtherOptions() throws {
        for style in RingMaterialStyle.allCases {
            var options = Options()
            options.ringMaterial = style
            options.centerTitleSize = 14
            options.theme = .dark
            let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(decoded.ringMaterial, style.resolved)
            XCTAssertEqual(decoded.centerTitleSize, 14)
            XCTAssertEqual(decoded.theme, .dark)
        }
        for json in [#"{"ringSize":480}"#, #"{"ringMaterial":"unknown","ringSize":480}"#] {
            let decoded = try JSONDecoder().decode(Options.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.ringMaterial, .defaultValue)
            XCTAssertEqual(decoded.ringSize, 480)
        }
    }

    @MainActor func testSwitchingMaterialsKeepsArtworkAndContour() async throws {
        let surface = RingMaterial(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        let artwork = RingArtwork(frame: surface.bounds)
        surface.content.addSubview(artwork)
        let shape = RingGeometry.surfacePath(windowCount: 3, anchor: 0.7)
        surface.setShape(shape)
        let host = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = surface
        defer { host.contentView = nil }
        for style in [RingMaterialStyle.frosted, .regular, .clear, .regular, .frosted, .clear] {
            surface.setStyle(style)
            surface.layoutSubtreeIfNeeded()
            XCTAssertTrue(artwork.superview === surface.content)
            XCTAssertEqual(artwork.convert(RingGeometry.center, to: surface), RingGeometry.center)
            XCTAssertEqual(surface.layer?.shadowPath, shape)
            let effect = try XCTUnwrap(surface.subviews.first?.subviews.first)
            if #available(macOS 26.0, *), style != .frosted {
                let glass = try XCTUnwrap(effect as? NSGlassEffectView)
                XCTAssertTrue(glass.contentView === surface.content)
                XCTAssertEqual(glass.style, style == .clear ? .clear : .regular)
            } else { XCTAssertTrue(effect is NSVisualEffectView) }
        }
    }

    @MainActor func testChangingContourPreservesArtworkCoordinatesAndDoesNotInterceptClicks() async {
        let surface = RingMaterial(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        surface.setStyle(.regular)
        let artwork = RingArtwork(frame: surface.bounds)
        surface.content.addSubview(artwork)
        let host = NSWindow(contentRect: surface.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = surface
        defer { host.contentView = nil }
        let shapes = [RingGeometry.surfacePath(windowCount: 0, anchor: 0),
                      RingGeometry.surfacePath(windowCount: 4, anchor: 0.7),
                      CGPath(ellipseIn: CGRect(x: 42, y: 42, width: 396, height: 396), transform: nil)]
        for shape in shapes + shapes.reversed() {
            surface.setShape(shape)
            surface.layoutSubtreeIfNeeded()
            XCTAssertEqual(surface.content.bounds, shape.boundingBoxOfPath.integral)
            XCTAssertEqual(artwork.convert(RingGeometry.center, to: surface), RingGeometry.center)
            XCTAssertNil(surface.hitTest(RingGeometry.center))
            XCTAssertEqual(surface.layer?.shadowPath, shape)
        }
        let effect = surface.subviews.first?.subviews.first
        if #available(macOS 26.0, *), let glass = effect as? NSGlassEffectView {
            XCTAssertTrue(glass.contentView === surface.content)
        } else { XCTAssertTrue(effect is NSVisualEffectView) }
    }

    @MainActor func testFrostedFallbackStaysActiveForNonKeyActionPanel() async {
        let frost = RingMaterial.makeFrostedEffect()
        XCTAssertEqual(frost.blendingMode, .behindWindow)
        XCTAssertEqual(frost.state, .active)
        XCTAssertEqual(frost.material, .popover)
    }
}
