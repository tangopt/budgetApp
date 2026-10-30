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
