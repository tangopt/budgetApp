import XCTest
@testable import MangoUI

final class PadSidePanelLayoutTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "padSidePanel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testWidthStartsStandardThenRemembersTheDraggedWidth() {
        let defaults = defaults()
        XCTAssertEqual(PadSidePanelLayout.storedWidth(defaults), PadSidePanelLayout.standardWidth)
        PadSidePanelLayout.store(520, defaults)
        XCTAssertEqual(PadSidePanelLayout.storedWidth(defaults), 520)
    }

    func testStoredWidthStaysBetweenMinimumAndMaximum() {
        let defaults = defaults()
        PadSidePanelLayout.store(5000, defaults)
        XCTAssertEqual(PadSidePanelLayout.storedWidth(defaults), PadSidePanelLayout.maximumWidth)
        PadSidePanelLayout.store(10, defaults)
        XCTAssertEqual(PadSidePanelLayout.storedWidth(defaults), PadSidePanelLayout.minimumWidth)
    }

    func testClampLeavesThePageItsMinimumWhenItCan() {
        XCTAssertEqual(PadSidePanelLayout.clamp(700, containerWidth: 1000), 580)
        XCTAssertEqual(PadSidePanelLayout.clamp(700, containerWidth: 1400), 700)
        XCTAssertEqual(PadSidePanelLayout.clamp(100, containerWidth: 1400), 320)
        XCTAssertEqual(PadSidePanelLayout.clamp(900, containerWidth: 2000), 720)
    }

    func testPlacementBesideThenOverThenSheet() {
        XCTAssertEqual(PadSidePanelLayout.placement(containerWidth: 1000, panelWidth: 400), .beside)
        XCTAssertEqual(PadSidePanelLayout.placement(containerWidth: 700, panelWidth: 400), .overlay)
        XCTAssertEqual(PadSidePanelLayout.placement(containerWidth: 500, panelWidth: 400), .sheet)
    }
}
