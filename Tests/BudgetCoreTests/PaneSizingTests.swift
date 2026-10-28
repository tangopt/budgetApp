import XCTest
@testable import BudgetCore

final class PaneSizingTests: XCTestCase {
    func testpanelWidthDefaultsWhenNothingStored() {
        XCTAssertEqual(PaneSizing.panelWidth(stored: 0, defaultWidth: 320, minimum: 280, maximum: 640, available: 1000, pageMinimum: 360), 320)
    }

    func testpanelWidthIsHeldBetweenMinimumAndMaximum() {
        XCTAssertEqual(PaneSizing.panelWidth(stored: 100, defaultWidth: 320, minimum: 280, maximum: 640, available: 1400, pageMinimum: 360), 280)
        XCTAssertEqual(PaneSizing.panelWidth(stored: 900, defaultWidth: 320, minimum: 280, maximum: 640, available: 1400, pageMinimum: 360), 640)
        XCTAssertEqual(PaneSizing.panelWidth(stored: 450, defaultWidth: 320, minimum: 280, maximum: 640, available: 1400, pageMinimum: 360), 450)
    }

    func testpanelLeavesThePageItsMinimum() {
        // 800 available, the page keeps 360: at most 440.
        XCTAssertEqual(PaneSizing.panelWidth(stored: 600, defaultWidth: 320, minimum: 280, maximum: 640, available: 800, pageMinimum: 360), 440)
        // A window too small for both: the panel's minimum wins.
        XCTAssertEqual(PaneSizing.panelWidth(stored: 600, defaultWidth: 320, minimum: 280, maximum: 640, available: 500, pageMinimum: 360), 280)
    }

    func testdraggingLeftWidens() {
        XCTAssertEqual(PaneSizing.draggedPanelWidth(start: 320, translation: -80), 400)
        XCTAssertEqual(PaneSizing.draggedPanelWidth(start: 320, translation: 40), 280)
    }

    func testsplitKeepsBothMinimums() {
        XCTAssertEqual(PaneSizing.splitLeadingWidth(fraction: 0.5, total: 1000, leadingMinimum: 380, trailingMinimum: 400), 500)
        XCTAssertEqual(PaneSizing.splitLeadingWidth(fraction: 0.1, total: 1000, leadingMinimum: 380, trailingMinimum: 400), 380)
        XCTAssertEqual(PaneSizing.splitLeadingWidth(fraction: 0.9, total: 1000, leadingMinimum: 380, trailingMinimum: 400), 600)
        XCTAssertEqual(PaneSizing.splitLeadingWidth(fraction: 0.5, total: 700, leadingMinimum: 380, trailingMinimum: 400), 380)
    }

    func testsplitFractionRoundTripsAndStaysInRange() {
        XCTAssertEqual(PaneSizing.splitFraction(leadingWidth: 500, total: 1000), 0.5)
        XCTAssertEqual(PaneSizing.splitFraction(leadingWidth: 5000, total: 1000), 0.95)
        XCTAssertEqual(PaneSizing.splitFraction(leadingWidth: 0, total: 1000), 0.05)
        XCTAssertEqual(PaneSizing.splitFraction(leadingWidth: 10, total: 0), 0.5)
    }

    func testkeysAreNamedByKind() {
        XCTAssertEqual(PaneSizing.widthKey("property"), "pane.property.width")
        XCTAssertEqual(PaneSizing.splitKey("salary"), "split.salary.fraction")
    }
}
