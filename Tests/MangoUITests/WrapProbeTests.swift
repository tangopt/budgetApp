import XCTest
import CoreGraphics
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

    func testTheReportLeadsWithTheCount() {
        let violation = WrapProbeRegistry.Violation(route: "gallery-light-large", problem: .wrapped, kind: "figure", text: "1,234 days",
                                                    source: "Gallery.swift:10", size: CGSize(width: 40, height: 44),
                                                    ideal: CGSize(width: 80, height: 22), origin: .zero)
        let clean = WrapProbeRegistry.report([], renders: [(name: "gallery-light-large", checked: 12)], window: window)
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "Wrap probe at 393×852 (iPhone)")
        XCTAssertEqual(lines.dropFirst().first, "1 renders, 12 figures checked; 0 violations in 0 renders (wrapped 0, truncated 0, cut off 0)")
        let dirty = WrapProbeRegistry.report([violation], renders: [(name: "gallery-light-large", checked: 12)], window: window)
        XCTAssertTrue(dirty.contains("1 violations in 1 renders (wrapped 1, truncated 0, cut off 0)"))
        XCTAssertTrue(dirty.contains("wrapped  figure  \"1,234 days\""))
        XCTAssertTrue(dirty.contains("Gallery.swift:10"))
    }

    func testTheProbeIsOffUntilTheHarnessTurnsItOn() {
        XCTAssertFalse(WrapProbeRegistry.shared.isActive)
    }
}
