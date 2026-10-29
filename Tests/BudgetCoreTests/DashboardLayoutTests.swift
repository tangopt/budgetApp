import XCTest
@testable import BudgetCore

final class DashboardLayoutTests: XCTestCase {
    typealias L = DashboardLayout
    private let money = [DashboardTile.netWorth, DashboardTile.currentMonth, DashboardTile.year, DashboardTile.yearChange,
                         DashboardTile.topCategories, DashboardTile.upcomingBills, DashboardTile.accounts]

    func testDefaultRowsAreEvenAndStoreNothing() {
        let layout = L()
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(layout.storedString, "")
        XCTAssertEqual(L(storedString: ""), layout)
        let rows = layout.rows(.money, natural: money)
        XCTAssertEqual(rows.map(\.tiles), [[DashboardTile.netWorth, DashboardTile.currentMonth], [DashboardTile.year, DashboardTile.yearChange],
                                           [DashboardTile.topCategories, DashboardTile.upcomingBills, DashboardTile.accounts]])
        XCTAssertEqual(rows[0].fractions[0], 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(rows[2].fractions[1], 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(rows.map(\.height), [184, 184, 164])
        // Four equal tiles are 2 + 2, five are 3 + 2, one is alone.
        XCTAssertEqual(L.defaultRows(["a", "b", "c", "d"]).map(\.count), [2, 2])
        XCTAssertEqual(L.defaultRows(["a", "b", "c", "d", "e"]).map(\.count), [3, 2])
        XCTAssertEqual(L.defaultRows(["a"]).map(\.count), [1])
        XCTAssertEqual(L.defaultRows([]), [])
    }

    func testDividerDragIsContinuousAndClamped() {
        let start = [0.5, 0.5]
        // 800 wide, 12 spacing: 788 usable. +100 points moves the boundary exactly 100 points.
        let moved = L.draggedFractions(start, divider: 0, delta: 100, width: 800)
        XCTAssertEqual(moved[0] * 788, 394 + 100, accuracy: 1e-6)
        XCTAssertEqual(moved.reduce(0, +), 1, accuracy: 1e-9)
        // Any amount works, not whole columns.
        XCTAssertNotEqual(L.draggedFractions(start, divider: 0, delta: 7.3, width: 800)[0], 0.5)
        // Far drags stop at the minimum width of the neighbour.
        let far = L.draggedFractions(start, divider: 0, delta: 5_000, width: 800)
        XCTAssertEqual(far[1] * 788, L.minimumTileWidth, accuracy: 1e-6)
        let farLeft = L.draggedFractions(start, divider: 0, delta: -5_000, width: 800)
        XCTAssertEqual(farLeft[0] * 788, L.minimumTileWidth, accuracy: 1e-6)
        // Only the dragged pair changes.
        let three = L.draggedFractions([0.2, 0.3, 0.5], divider: 1, delta: 40, width: 800)
        XCTAssertEqual(three[0], 0.2)
        XCTAssertEqual(three[1] + three[2], 0.8, accuracy: 1e-9)
        // A row too narrow for two minimum tiles splits evenly instead of inverting.
        XCTAssertEqual(L.draggedFractions([0.5, 0.5], divider: 0, delta: 30, width: 200), [0.5, 0.5])
        XCTAssertEqual(L.draggedFractions([1], divider: 0, delta: 30, width: 200), [1])
    }

    func testRowHeightDragClamps() {
        XCTAssertEqual(L.draggedHeight(184, delta: 50), 234)
        XCTAssertEqual(L.draggedHeight(184, delta: -500), L.minimumTileHeight)
        XCTAssertEqual(L.draggedHeight(184, delta: 5_000), L.maximumRowHeight)
    }

    func testFramesFollowFractionsAndScaleWithWidth() {
        var layout = L()
        layout.setFractions([0.7, 0.3], row: 0, in: .money, natural: money)
        layout.setHeight(300, row: 0, in: .money, natural: money)
        let rows = layout.rows(.money, natural: money)
        let narrow = L.frames(rows, width: 800), wide = L.frames(rows, width: 1600)
        XCTAssertEqual(narrow[0].width / (800 - 12), 0.7, accuracy: 1e-3)
        XCTAssertEqual(wide[0].width / (1600 - 12), 0.7, accuracy: 1e-3)
        XCTAssertEqual(narrow[0].height, 300)
        XCTAssertEqual(narrow[1].x, narrow[0].width + 12, accuracy: 1e-9)
        XCTAssertEqual(narrow[1].x + narrow[1].width, 800, accuracy: 1e-6)
        XCTAssertEqual(narrow.first { $0.row == 1 }?.y, 312)
        XCTAssertEqual(L.totalHeight(rows), 300 + 184 + 164 + 24)
    }

    func testPersistenceRoundTripKeepsOtherRowsAsTheyWere() {
        var layout = L()
        layout.setFractions([0.7, 0.3], row: 0, in: .money, natural: money)
        layout.setHeight(260, row: 2, in: .money, natural: money)
        let restored = L(storedString: layout.storedString)
        XCTAssertEqual(restored, layout)
        let rows = restored.rows(.money, natural: money)
        XCTAssertEqual(rows[0].fractions[0], 0.7, accuracy: 1e-9)
        XCTAssertEqual(rows[1].fractions[0], 2.0 / 3, accuracy: 1e-3)
        XCTAssertEqual(rows.map(\.height), [184, 184, 260])
        XCTAssertTrue(restored.layout(.property).isEmpty)
    }

    func testGarbageIsSafe() {
        XCTAssertTrue(L(storedString: "not json").isDefault)
        let json = #"{"v":2,"sections":{"money":{"rows":[["netWorth","netWorth","ghost"],[]],"fractions":{"netWorth":-3},"heights":[1e9]},"bogus":{}}}"#
        let rows = L(storedString: json).rows(.money, natural: [DashboardTile.netWorth, DashboardTile.accounts])
        XCTAssertEqual(rows.map(\.tiles), [[DashboardTile.netWorth], [DashboardTile.accounts]])
        XCTAssertEqual(rows[0].fractions, [1])
        XCTAssertEqual(rows[0].height, L.maximumRowHeight)
    }

    func testHiddenAndNewTilesKeepTheRestInPlace() {
        var layout = L()
        layout.setFractions([0.6, 0.4], row: 1, in: .money, natural: money)
        // Year hidden: its row keeps the other tile, which takes the whole row.
        let fewer = money.filter { $0 != DashboardTile.year }
        let rows = layout.rows(.money, natural: fewer)
        XCTAssertEqual(rows[1].tiles, [DashboardTile.yearChange])
        XCTAssertEqual(rows[1].fractions, [1])
        // A tile the saved layout doesn't know lands in a row of its own after the known ones.
        let more = money + [DashboardTile.propertyMonth]
        XCTAssertEqual(layout.rows(.money, natural: more).last?.tiles, [DashboardTile.propertyMonth])
        // A whole row hidden closes up with its height.
        var tall = L()
        tall.setHeight(300, row: 1, in: .money, natural: money)
        let rest = money.filter { $0 != DashboardTile.year && $0 != DashboardTile.yearChange }
        XCTAssertEqual(tall.rows(.money, natural: rest).map(\.height), [184, 164])
    }

    func testMovingTiles() {
        var layout = L()
        layout.setFractions([0.7, 0.3], row: 0, in: .money, natural: money)
        XCTAssertFalse(layout.canMove(DashboardTile.netWorth, .left, in: .money, natural: money))
        XCTAssertFalse(layout.canMove(DashboardTile.netWorth, .up, in: .money, natural: money) == false)
        layout.move(DashboardTile.netWorth, .right, in: .money, natural: money)
        var rows = layout.rows(.money, natural: money)
        XCTAssertEqual(rows[0].tiles, [DashboardTile.currentMonth, DashboardTile.netWorth])
        XCTAssertEqual(rows[0].fractions[0], 0.7, accuracy: 1e-9) // the place keeps its width
        // Down: current month joins the next row at an equal share; others make room.
        layout.move(DashboardTile.currentMonth, .down, in: .money, natural: money)
        rows = layout.rows(.money, natural: money)
        XCTAssertEqual(rows[0].tiles, [DashboardTile.netWorth])
        XCTAssertEqual(rows[0].fractions, [1])
        XCTAssertEqual(rows[1].tiles.count, 3)
        XCTAssertEqual(rows[1].fractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(rows[1].fractions[0], 1.0 / 3, accuracy: 1e-3)
        // Up from the first row of a shared row starts a row of its own; a lone first tile can't go up.
        layout.move(DashboardTile.currentMonth, .up, in: .money, natural: money)
        XCTAssertEqual(layout.rows(.money, natural: money)[0].tiles, [DashboardTile.currentMonth, DashboardTile.netWorth])
        XCTAssertFalse(L().canMove(DashboardTile.accounts, .down, in: .money, natural: [DashboardTile.accounts]))
        var single = L()
        single.move(DashboardTile.accounts, .down, in: .money, natural: [DashboardTile.accounts])
        XCTAssertTrue(single.isDefault)
        var split = L()
        split.move(DashboardTile.currentMonth, .up, in: .money, natural: money)
        XCTAssertEqual(split.rows(.money, natural: money)[0].tiles, [DashboardTile.currentMonth])
        XCTAssertEqual(split.rows(.money, natural: money)[1].tiles, [DashboardTile.netWorth])
    }

    func testDroppingATileWithinIntoAndBetweenRows() {
        // Default Money rows: [netWorth, currentMonth], [year, yearChange], [topCategories, upcomingBills, accounts].
        var layout = L()
        // Within the row: before the first tile; the places keep their widths.
        layout.setFractions([0.7, 0.3], row: 0, in: .money, natural: money)
        layout.move(tile: DashboardTile.currentMonth, to: .row(0, at: 0), in: .money, natural: money)
        var rows = layout.rows(.money, natural: money)
        XCTAssertEqual(rows[0].tiles, [DashboardTile.currentMonth, DashboardTile.netWorth])
        XCTAssertEqual(rows[0].fractions[0], 0.7, accuracy: 1e-9)
        // Dropped where it already is (before itself / after itself): nothing changes.
        XCTAssertFalse(layout.canMove(DashboardTile.currentMonth, to: .row(0, at: 0), in: .money, natural: money))
        XCTAssertFalse(layout.canMove(DashboardTile.currentMonth, to: .row(0, at: 1), in: .money, natural: money))
        XCTAssertTrue(layout.canMove(DashboardTile.currentMonth, to: .row(0, at: 2), in: .money, natural: money))
        // Into another row: an equal share, the others make room, the row it left closes up when emptied.
        layout.move(tile: DashboardTile.accounts, to: .row(0, at: 1), in: .money, natural: money)
        rows = layout.rows(.money, natural: money)
        XCTAssertEqual(rows[0].tiles, [DashboardTile.currentMonth, DashboardTile.accounts, DashboardTile.netWorth])
        XCTAssertEqual(rows[0].fractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(rows[0].fractions[1], 1.0 / 3, accuracy: 1e-3)
        XCTAssertEqual(rows[2].tiles, [DashboardTile.topCategories, DashboardTile.upcomingBills])
        XCTAssertEqual(rows[2].fractions.reduce(0, +), 1, accuracy: 1e-9)
        // Into a new row: below the last, above the first, and between.
        layout.move(tile: DashboardTile.netWorth, to: .newRow(at: 3), in: .money, natural: money)
        rows = layout.rows(.money, natural: money)
        XCTAssertEqual(rows.map(\.tiles), [[DashboardTile.currentMonth, DashboardTile.accounts], [DashboardTile.year, DashboardTile.yearChange],
                                          [DashboardTile.topCategories, DashboardTile.upcomingBills], [DashboardTile.netWorth]])
        XCTAssertEqual(rows[3].fractions, [1])
        XCTAssertEqual(rows[3].height, 184)
        layout.move(tile: DashboardTile.year, to: .newRow(at: 0), in: .money, natural: money)
        rows = layout.rows(.money, natural: money)
        XCTAssertEqual(rows[0].tiles, [DashboardTile.year])
        XCTAssertEqual(rows[1].tiles, [DashboardTile.currentMonth, DashboardTile.accounts])
        XCTAssertEqual(rows[2].tiles, [DashboardTile.yearChange])
        // A lone tile dropped into a new row at its own place changes nothing; to another place it moves its row.
        XCTAssertFalse(layout.canMove(DashboardTile.year, to: .newRow(at: 0), in: .money, natural: money))
        XCTAssertFalse(layout.canMove(DashboardTile.year, to: .newRow(at: 1), in: .money, natural: money))
        layout.move(tile: DashboardTile.year, to: .newRow(at: 3), in: .money, natural: money)
        XCTAssertEqual(layout.rows(.money, natural: money).map(\.tiles).prefix(3).map { $0 }, [[DashboardTile.currentMonth, DashboardTile.accounts], [DashboardTile.yearChange], [DashboardTile.year]])
        // Garbage targets and unknown tiles are ignored; a no-op leaves a default layout default.
        var untouched = L()
        untouched.move(tile: DashboardTile.accounts, to: .row(9, at: 0), in: .money, natural: money)
        untouched.move(tile: "nope", to: .newRow(at: 0), in: .money, natural: money)
        untouched.move(tile: DashboardTile.netWorth, to: .row(0, at: 0), in: .money, natural: money)
        XCTAssertTrue(untouched.isDefault)
        // The moved layout survives saving.
        XCTAssertEqual(L(storedString: layout.storedString).rows(.money, natural: money), layout.rows(.money, natural: money))
    }

    func testDropTargetFollowsThePointer() {
        let rows = L().rows(.money, natural: money) // 3 rows: 184, 184, 164 pt, 12 pt apart; width 600
        let width = 600.0
        func target(_ x: Double, _ y: Double) -> L.Drop? { L.dropTarget(x: x, y: y, rows: rows, width: width) }
        XCTAssertNil(L.dropTarget(x: 10, y: 10, rows: [], width: width))
        XCTAssertEqual(target(100, 2), .newRow(at: 0))
        XCTAssertEqual(target(100, 90), .row(0, at: 0))      // left of netWorth's middle
        XCTAssertEqual(target(590, 90), .row(0, at: 2))      // right of both
        XCTAssertEqual(target(300, 90), .row(0, at: 1))      // between the two middles (netWorth is 2/3 wide: middle 195)
        XCTAssertEqual(target(100, 190), .newRow(at: 1))     // in the gap under row 0
        XCTAssertEqual(target(100, 182), .newRow(at: 1))     // its zone reaches into the row
        XCTAssertEqual(target(100, 202), .newRow(at: 1))     // and into the next
        XCTAssertEqual(target(100, 260), .row(1, at: 0))
        XCTAssertEqual(target(100, 4 + 184 + 12 + 184 + 12 + 160), .newRow(at: 3)) // the bottom edge of the last row
        XCTAssertEqual(target(100, 2000), .newRow(at: 3))
        XCTAssertEqual(target(590, 2 + 184 + 12 + 184 + 12 + 60), .row(2, at: 3))
    }

    func testResetRestoresDefault() {
        var layout = L()
        layout.setHeight(300, row: 0, in: .money, natural: money)
        layout.setHeight(300, row: 0, in: .tax, natural: [DashboardTile.taxYear])
        layout.reset(.money)
        XCTAssertFalse(layout.isDefault)
        layout.reset()
        XCTAssertEqual(layout, L())
        XCTAssertEqual(layout.storedString, "")
    }

    func testLegacyLayoutMigrates() {
        let json = #"{"sections":{"money":{"order":["accounts","netWorth"],"spans":{"netWorth":{"columns":3,"rows":1},"accounts":{"columns":1,"rows":2}},"columns":2,"rowHeight":"tall"},"tax":{"order":[],"spans":{},"rowHeight":"compact"}}}"#
        let layout = L(storedString: json)
        XCTAssertFalse(layout.isDefault)
        XCTAssertTrue(layout.layout(.tax).isEmpty)
        let rows = layout.rows(.money, natural: money)
        XCTAssertEqual(rows[0].tiles.first, DashboardTile.accounts)       // saved order first
        XCTAssertTrue(rows.allSatisfy { $0.height >= 230 })               // Tall rows
        let netWorthRow = rows.first { $0.tiles.contains(DashboardTile.netWorth) }!
        let share = netWorthRow.fractions[netWorthRow.tiles.firstIndex(of: DashboardTile.netWorth)!]
        XCTAssertGreaterThan(share, 0.5)                                   // its 3-column span is the widest
        // Saving after a change writes the fluid format, which reads back the same.
        var changed = layout
        changed.setHeight(200, row: 0, in: .money, natural: money)
        XCTAssertTrue(changed.storedString.contains("\"v\":2"))
        XCTAssertNil(changed.layout(.money).legacy)
        XCTAssertEqual(L(storedString: changed.storedString), changed)
        // An untouched legacy layout round-trips too.
        XCTAssertEqual(L(storedString: layout.storedString), layout)
    }

    func testChartDropsBeforeTheFigureAndListsGrowWithHeight() {
        typealias B = TileBudget
        // Wide and tall enough: beside; narrow but tall: below; small: hidden.
        XCTAssertEqual(B.chartPlan(width: 420, height: 184, maximumLines: 3).placement, .beside)
        XCTAssertEqual(B.chartPlan(width: 260, height: 260, maximumLines: 3).placement, .below)
        XCTAssertEqual(B.chartPlan(width: 260, height: 184, maximumLines: 3).placement, .below)
        XCTAssertEqual(B.chartPlan(width: 260, height: 150, maximumLines: 3).placement, .hidden)
        XCTAssertEqual(B.chartPlan(width: 420, height: 110, maximumLines: 3).placement, .hidden)
        XCTAssertEqual(B.chartPlan(width: 170, height: 100, maximumLines: 3), .init(placement: .hidden, chartHeight: 0, lines: 0))
        XCTAssertEqual(B.chartPlan(width: 420, height: 184, maximumLines: 3).lines, 3)
        XCTAssertEqual(B.chartPlan(width: 420, height: 184, maximumLines: 3).chartHeight, 184 - B.chrome)
        // The chart gets the room beside; below it, what the figure leaves.
        XCTAssertEqual(B.chartPlan(width: 260, height: 260, maximumLines: 0).chartHeight, 260 - B.chrome - B.figure - 6)
        // Lists: 2 rows at the default height, 3 taller, 5 taller still, none at the minimum.
        func rows(_ height: Double) -> Int { var b = B(height: height, reserved: B.figure); return b.count(upTo: 8, cost: B.meterLine) }
        XCTAssertEqual(rows(L.minimumTileHeight), 0)
        XCTAssertEqual(rows(164), 2)
        XCTAssertEqual(rows(190), 3)
        XCTAssertEqual(rows(250), 5)
        XCTAssertEqual(rows(1000), 8)
        // With a "+ n more" line to keep room for: all fit -> all; otherwise one fewer than would fit.
        var all = B(height: 56 + 3 * 20); XCTAssertEqual(all.count(upTo: 3, cost: 20, trailer: 20), 3)
        var some = B(height: 56 + 3 * 20); XCTAssertEqual(some.count(upTo: 5, cost: 20, trailer: 20), 2)
        var b = B(height: 120)
        XCTAssertTrue(b.take(B.figure))
        XCTAssertFalse(b.take(B.meterLine * 3))
    }
}
