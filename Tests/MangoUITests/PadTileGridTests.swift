import XCTest
import SwiftUI
@testable import MangoUI

/// `PadTileGrid`'s column maths. Checks used to crash the snapshot run: a flex frame asked the grid for its size at
/// an unbounded width, and `Int(.infinity)` trapped.
final class PadTileGridTests: XCTestCase {
    func testColumnsFitTheWidth() {
        let grid = PadTileGrid(minimumColumnWidth: 190, maximumColumns: .max, spacing: 12, balanced: false)
        XCTAssertEqual(grid.columns(for: 400, count: 6), 2)
        XCTAssertEqual(grid.columns(for: 1000, count: 6), 5)
        XCTAssertEqual(grid.columns(for: 100, count: 6), 1)
    }

    func testBalancedEvensTheRowsOut() {
        let grid = PadTileGrid(minimumColumnWidth: 190, maximumColumns: .max, spacing: 12, balanced: true)
        XCTAssertEqual(grid.columns(for: 1000, count: 6), 3)
    }

    func testAnUnboundedWidthDoesNotTrap() {
        let grid = PadTileGrid(minimumColumnWidth: 190, maximumColumns: 4, spacing: 12, balanced: false)
        XCTAssertEqual(grid.columns(for: .infinity, count: 6), 4)
        XCTAssertEqual(grid.columns(for: .infinity, count: 2), 2)
        XCTAssertEqual(grid.columns(for: .nan, count: 0), 1)
    }
}

/// The bills grid sizes its month columns from the widest figure (fewer columns, never squeezed figures).
final class PadBillsGridSizingTests: XCTestCase {
    func testACellIsNeverNarrowerThanTheMinimumAndGrowsWithTheWidestFigure() {
        XCTAssertEqual(PadBillsGridView.cellWidth(widestFigure: 40, widestLabel: 50), PadBillsGridView.minimumCellWidth)
        XCTAssertEqual(PadBillsGridView.cellWidth(widestFigure: 120, widestLabel: 50), 120 + 16 + 4)
        XCTAssertEqual(PadBillsGridView.cellWidth(widestFigure: 60, widestLabel: 130.2), 131 + 16 + 4)
    }

    func testAWiderFigureShowsFewerMonthsNeverZero() {
        let narrow = PadBillsGridView.columnsFit(width: 800, providerWidth: 120, cellWidth: 92)
        let wide = PadBillsGridView.columnsFit(width: 800, providerWidth: 120, cellWidth: 140)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertEqual(PadBillsGridView.columnsFit(width: 50, providerWidth: 120, cellWidth: 140), 1)
    }
}
