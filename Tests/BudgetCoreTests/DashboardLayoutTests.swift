import XCTest
@testable import BudgetCore

final class DashboardLayoutTests: XCTestCase {
    typealias L = DashboardLayout
    private let money = [DashboardTile.netWorth, DashboardTile.currentMonth, DashboardTile.year, DashboardTile.yearChange,
                         DashboardTile.topCategories, DashboardTile.upcomingBills, DashboardTile.accounts]

    func testDefaultIsEmptyAndStoresNothing() {
        let layout = L()
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(layout.storedString, "")
        XCTAssertEqual(L(storedString: ""), layout)
        XCTAssertEqual(layout.order(.money, natural: money), money)
        XCTAssertEqual(layout.span(DashboardTile.netWorth, in: .money), L.Span(columns: 2, rows: 1))
        XCTAssertEqual(layout.span(DashboardTile.accounts, in: .money), L.Span(columns: 1, rows: 1))
    }

    func testPersistenceRoundTrip() {
        var layout = L()
        layout.setSpan(DashboardTile.netWorth, in: .money, to: .init(columns: 3, rows: 2))
        layout.setColumns(4, in: .property)
        layout.setRowHeight(.tall, in: .money)
        layout.move(DashboardTile.accounts, onto: DashboardTile.netWorth, in: .money, natural: money)
        let restored = L(storedString: layout.storedString)
        XCTAssertEqual(restored, layout)
        XCTAssertEqual(restored.span(DashboardTile.netWorth, in: .money), .init(columns: 3, rows: 2))
        XCTAssertEqual(restored.layout(.property).columns, 4)
        XCTAssertEqual(restored.layout(.money).rowHeight, .tall)
        XCTAssertEqual(restored.order(.money, natural: money).first, DashboardTile.accounts)
    }

    func testGarbageAndOutOfRangeValuesAreSafe() {
        XCTAssertTrue(L(storedString: "not json").isDefault)
        let json = #"{"sections":{"money":{"columns":9,"rowHeight":"huge","spans":{"a":{"columns":7,"rows":0}}},"bogus":{}}}"#
        let layout = L(storedString: json)
        XCTAssertNil(layout.layout(.money).columns)
        XCTAssertEqual(layout.layout(.money).rowHeight, .compact)
        XCTAssertEqual(layout.layout(.money).spans["a"], .init(columns: 3, rows: 1))
    }

    func testResetAndDefaultSpanNotStored() {
        var layout = L()
        layout.setSpan(DashboardTile.accounts, in: .money, to: .init(columns: 2, rows: 1))
        XCTAssertFalse(layout.isDefault)
        layout.setSpan(DashboardTile.accounts, in: .money, to: .init(columns: 1, rows: 1))
        XCTAssertTrue(layout.isDefault)
        layout.setColumns(3, in: .tax)
        layout.reset()
        XCTAssertEqual(layout, L())
    }

    func testOrderingKeepsUnknownNewAndHiddenTiles() {
        var layout = L()
        layout.move(DashboardTile.accounts, onto: DashboardTile.currentMonth, in: .money, natural: money)
        XCTAssertEqual(layout.order(.money, natural: money),
                       [DashboardTile.netWorth, DashboardTile.accounts, DashboardTile.currentMonth, DashboardTile.year,
                        DashboardTile.yearChange, DashboardTile.topCategories, DashboardTile.upcomingBills])
        // A hidden tile drops out; a tile new to the saved order lands at its natural place after the known ones.
        let fewer = money.filter { $0 != DashboardTile.year }
        XCTAssertFalse(layout.order(.money, natural: fewer).contains(DashboardTile.year))
        XCTAssertEqual(layout.order(.money, natural: money + ["extra"]).last, "extra")
        // Moving while a tile is hidden keeps the hidden tile's saved position.
        layout.move(DashboardTile.upcomingBills, onto: DashboardTile.netWorth, in: .money, natural: fewer)
        XCTAssertEqual(layout.order(.money, natural: fewer).first, DashboardTile.upcomingBills)
        XCTAssertTrue(layout.layout(.money).order.contains(DashboardTile.year) || layout.order(.money, natural: money).contains(DashboardTile.year))
    }

    func testMoveOntoSelfOrUnknownDoesNothing() {
        var layout = L()
        layout.move(DashboardTile.accounts, onto: DashboardTile.accounts, in: .money, natural: money)
        layout.move("nope", onto: DashboardTile.accounts, in: .money, natural: money)
        XCTAssertTrue(layout.isDefault)
    }

    func testColumnCount() {
        var layout = L()
        XCTAssertEqual(layout.columnCount(.money, width: 300), 1)
        XCTAssertEqual(layout.columnCount(.money, width: 520), 2)
        XCTAssertEqual(layout.columnCount(.money, width: 1400), 3)
        layout.setColumns(4, in: .money)
        XCTAssertEqual(layout.columnCount(.money, width: 1400), 4)
        XCTAssertEqual(layout.columnCount(.money, width: 500), 3)
        XCTAssertEqual(layout.columnCount(.money, width: 200), 1)
        layout.setColumns(2, in: .money)
        XCTAssertEqual(layout.columnCount(.money, width: 1400), 2)
        layout.setColumns(7, in: .money)
        XCTAssertNil(layout.layout(.money).columns)
    }

    func testPackDefaultMoneyAtThreeColumns() {
        let tiles = money.map { ($0, L().span($0, in: .money)) }
        let placed = L.pack(tiles, columns: 3)
        func at(_ id: String) -> L.Placement { placed.first { $0.tile == id }! }
        XCTAssertEqual(at(DashboardTile.netWorth), .init(tile: DashboardTile.netWorth, column: 0, row: 0, columns: 2, rows: 1))
        XCTAssertEqual(at(DashboardTile.currentMonth).column, 2)
        XCTAssertEqual(at(DashboardTile.year).row, 1)
        XCTAssertEqual(at(DashboardTile.yearChange).row, 1)
        XCTAssertEqual(at(DashboardTile.yearChange).column, 2)
        // Last row: accounts alone grows to fill.
        let last = at(DashboardTile.accounts)
        XCTAssertEqual(last.columns + last.column, 3)
    }

    func testPackNoOverlapAndInBounds() {
        let spans: [L.Span] = [.init(columns: 3, rows: 2), .init(columns: 1, rows: 2), .init(columns: 2, rows: 1), .init(columns: 1, rows: 1),
                               .init(columns: 2, rows: 2), .init(columns: 1, rows: 1), .init(columns: 3, rows: 1)]
        for columns in 1...4 {
            let placed = L.pack(spans.enumerated().map { ("t\($0.offset)", $0.element) }, columns: columns)
            XCTAssertEqual(placed.count, spans.count)
            var seen = Set<String>()
            for p in placed {
                XCTAssertGreaterThanOrEqual(p.column, 0)
                XCTAssertLessThanOrEqual(p.column + p.columns, columns)
                for r in p.row..<(p.row + p.rows) { for c in p.column..<(p.column + p.columns) {
                    XCTAssertTrue(seen.insert("\(r),\(c)").inserted, "overlap at \(r),\(c) with \(columns) columns")
                } }
            }
        }
    }

    func testTallTileLetsNextTilesFillBesideIt() {
        let placed = L.pack([("a", .init(columns: 1, rows: 2)), ("b", .init(columns: 1, rows: 1)), ("c", .init(columns: 1, rows: 1)),
                             ("d", .init(columns: 1, rows: 1))], columns: 2)
        XCTAssertEqual(placed.map(\.row), [0, 0, 1, 2])
        XCTAssertEqual(placed.map(\.column), [0, 1, 1, 0])
        // d is alone on its row: it takes both columns.
        XCTAssertEqual(placed[3].columns, 2)
    }

    func testWideTileCutToGridAndSingleColumn() {
        let placed = L.pack([("a", .init(columns: 3, rows: 1)), ("b", .init(columns: 2, rows: 1))], columns: 1)
        XCTAssertEqual(placed.map(\.row), [0, 1])
        XCTAssertEqual(placed.map(\.columns), [1, 1])
        XCTAssertTrue(L.pack([], columns: 3).isEmpty)
    }

    func testHiddenTileClosesUp() {
        let layout = L()
        let all = layout.placements(.money, natural: money, width: 900)
        let without = layout.placements(.money, natural: money.filter { $0 != DashboardTile.currentMonth }, width: 900)
        XCTAssertEqual(all.first { $0.tile == DashboardTile.year }?.row, 1)
        // Without the month tile, net worth grows into its place and year change still sits beside the year.
        XCTAssertEqual(without.first { $0.tile == DashboardTile.netWorth }?.columns, 3)
        XCTAssertEqual(without.first { $0.tile == DashboardTile.year }?.row, 1)
        XCTAssertEqual(without.first { $0.tile == DashboardTile.yearChange }?.row, 1)
        XCTAssertEqual(without.first { $0.tile == DashboardTile.topCategories }?.row, 2)
        XCTAssertEqual(without.count, all.count - 1)
    }

    func testDraggedSpanSnapsAndClamps() {
        let start = L.Span(columns: 1, rows: 1)
        XCTAssertEqual(L.draggedSpan(from: start, dx: 130, dy: 10, cellWidth: 250, cellHeight: 150, maximumColumns: 3), .init(columns: 2, rows: 1))
        XCTAssertEqual(L.draggedSpan(from: start, dx: 900, dy: 400, cellWidth: 250, cellHeight: 150, maximumColumns: 3), .init(columns: 3, rows: 2))
        XCTAssertEqual(L.draggedSpan(from: start, dx: 900, dy: 0, cellWidth: 250, cellHeight: 150, maximumColumns: 2).columns, 2)
        XCTAssertEqual(L.draggedSpan(from: .init(columns: 2, rows: 2), dx: -900, dy: -900, cellWidth: 250, cellHeight: 150, maximumColumns: 3), .init(columns: 1, rows: 1))
    }
}
