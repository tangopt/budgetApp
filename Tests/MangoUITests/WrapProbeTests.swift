import XCTest
import CoreGraphics
import SwiftUI
@testable import MangoUI

/// The wrap probe's verdicts (iPhone spec §4, §6): a figure taller than its one line wrapped; narrower than its
/// ideal width beyond its shrink is truncated; outside the window sideways is cut off.
@MainActor
final class WrapProbeTests: XCTestCase {
    private let window = CGSize(width: 393, height: 852)

    private func probe(_ entries: [(frame: CGRect, ideal: CGSize, scale: CGFloat)]) -> WrapProbeRegistry {
        let registry = WrapProbeRegistry()
        for (index, entry) in entries.enumerated() {
            let id = UUID()
            registry.update(id, kind: "MoneyText", text: "figure \(index)", source: nil, minimumScale: entry.scale, frame: entry.frame)
            registry.update(id, kind: "MoneyText", text: "figure \(index)", source: nil, minimumScale: entry.scale, ideal: entry.ideal)
        }
        return registry
    }

    func testAFigureOnOneLineAtItsWidthPasses() {
        let registry = probe([(CGRect(x: 16, y: 100, width: 120, height: 22), CGSize(width: 120, height: 22), 1)])
        XCTAssertEqual(registry.violations(route: "gallery", window: window), [])
        XCTAssertEqual(registry.checkedCount, 1)
    }

    func testATallerFigureWrapped() {
        let registry = probe([(CGRect(x: 16, y: 100, width: 60, height: 44), CGSize(width: 120, height: 22), 1)])
        XCTAssertEqual(Set(registry.violations(route: "gallery", window: window).map(\.problem)), [.wrapped, .truncated])
    }

    func testShrinkingWithinTheMinimumScaleIsAllowedButNotBeyond() {
        let within = probe([(CGRect(x: 16, y: 100, width: 85, height: 22), CGSize(width: 120, height: 22), 0.7)])
        XCTAssertEqual(within.violations(route: "r", window: window), [])
        let beyond = probe([(CGRect(x: 16, y: 100, width: 70, height: 22), CGSize(width: 120, height: 22), 0.7)])
        XCTAssertEqual(beyond.violations(route: "r", window: window).map(\.problem), [.truncated])
    }

    func testAFigurePastTheWindowEdgeIsCutOff() {
        let registry = probe([(CGRect(x: 330, y: 100, width: 120, height: 22), CGSize(width: 120, height: 22), 1)])
        let found = registry.violations(route: "r", window: window)
        XCTAssertEqual(found.map(\.problem), [.cutOff])
        XCTAssertEqual(found.first?.text, "figure 0")
    }

    func testRemovedAndResetFiguresAreNotChecked() {
        let registry = probe([(CGRect(x: 330, y: 100, width: 120, height: 22), CGSize(width: 120, height: 22), 1)])
        registry.reset()
        XCTAssertEqual(registry.violations(route: "r", window: window), [])
        XCTAssertEqual(registry.checkedCount, 0)
    }

    func testAFigurePastItsCardIsCutOffEvenInsideTheWindow() {
        let registry = WrapProbeRegistry()
        let card = UUID()
        registry.clipRegions[card] = CGRect(x: 32, y: 80, width: 200, height: 300)
        let id = UUID()
        registry.update(id, kind: "MoneyText", text: "£1,234,567.89", source: nil, minimumScale: 1, clipRegion: card,
                        frame: CGRect(x: 150, y: 100, width: 120, height: 22))
        registry.update(id, kind: "MoneyText", text: "£1,234,567.89", source: nil, minimumScale: 1, ideal: CGSize(width: 120, height: 22))
        XCTAssertEqual(registry.violations(route: "r", window: window).map(\.problem), [.cutOff])
        registry.clipRegions[card] = CGRect(x: 16, y: 80, width: 361, height: 300)
        XCTAssertEqual(registry.violations(route: "r", window: window), [])
    }

    func testFiguresBelowTheFoldAreCounted() {
        let registry = probe([(CGRect(x: 16, y: 100, width: 120, height: 22), CGSize(width: 120, height: 22), 1),
                              (CGRect(x: 16, y: 1_100, width: 120, height: 22), CGSize(width: 120, height: 22), 1)])
        XCTAssertEqual(registry.checkedCount, 2)
        XCTAssertEqual(registry.checkedCount(below: 852), 1)
    }

    func testTheReportLeadsWithTheCount() {
        let violation = WrapProbeRegistry.Violation(route: "gallery-light-large", problem: .wrapped, kind: "figure", text: "1,234 days",
                                                    source: "Gallery.swift:10", size: CGSize(width: 40, height: 44),
                                                    ideal: CGSize(width: 80, height: 22), origin: .zero)
        let renders = [WrapProbeRegistry.Render(name: "gallery-light-large", checked: 12, belowFold: 0),
                       WrapProbeRegistry.Render(name: "gallery-light-large-full", checked: 15, belowFold: 3)]
        let clean = WrapProbeRegistry.report([], renders: renders, problems: [], window: window)
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "Wrap probe at 393×852 (iPhone; -full renders 393 wide, full height)")
        XCTAssertEqual(lines.dropFirst().first, "2 renders, 27 figures checked (3 below the fold); 0 violations in 0 renders (wrapped 0, truncated 0, cut off 0); 0 coverage problems")
        XCTAssertTrue(clean.contains("  gallery-light-large-full 15 (3 below the fold)"))
        let dirty = WrapProbeRegistry.report([violation], renders: renders, problems: ["home-light-large: 0 figures checked"], window: window)
        XCTAssertTrue(dirty.contains("1 violations in 1 renders (wrapped 1, truncated 0, cut off 0); 1 coverage problems"))
        XCTAssertTrue(dirty.contains("wrapped  figure  \"1,234 days\""))
        XCTAssertTrue(dirty.contains("Gallery.swift:10"))
        XCTAssertTrue(dirty.contains("home-light-large: 0 figures checked"))
    }

    // MARK: Coverage: a render that checks nothing is a failure

    func testARenderWithNoFiguresIsACoverageProblem() {
        let route = DemoRoute(name: "home") { _ in AnyView(EmptyView()) }
        XCTAssertEqual(route.coverageProblem(render: WrapProbeRegistry.Render(name: "home-light-large", checked: 0, belowFold: 0), full: false),
                       "home-light-large: 0 figures checked (needs at least 1)")
        XCTAssertNil(route.coverageProblem(render: WrapProbeRegistry.Render(name: "home-light-large", checked: 4, belowFold: 0), full: false))
    }

    func testAFoldRouteMustCountItsFigureBelowTheFold() {
        let route = DemoRoute(name: "gallery-fold", figuresBelowFold: 1) { _ in AnyView(EmptyView()) }
        XCTAssertEqual(route.coverageProblem(render: WrapProbeRegistry.Render(name: "gallery-fold-light-large-full", checked: 2, belowFold: 0), full: true),
                       "gallery-fold-light-large-full: 0 figures below the fold (needs at least 1)")
        XCTAssertNil(route.coverageProblem(render: WrapProbeRegistry.Render(name: "gallery-fold-light-large-full", checked: 2, belowFold: 1), full: true))
        // The window-high render can't see below the fold; only the full-height one is held to it.
        XCTAssertNil(route.coverageProblem(render: WrapProbeRegistry.Render(name: "gallery-fold-light-large", checked: 1, belowFold: 0), full: false))
        XCTAssertTrue(DemoRoutes.all.contains { $0.name == "gallery-fold" && $0.figuresBelowFold > 0 })
    }

    func testEveryRouteRendersAtAnAccessibilitySizeAndTheGalleryAtTheLargest() {
        for route in DemoRoutes.all {
            XCTAssertTrue(route.sizes.contains(.accessibility3), route.name)
        }
        XCTAssertTrue(DemoRoutes.all.first { $0.name == "gallery" }?.sizes.contains(.accessibility5) ?? false)
    }

    func testTheProbeIsOffUntilTheHarnessTurnsItOn() {
        XCTAssertFalse(WrapProbeRegistry.shared.isActive)
    }
}
