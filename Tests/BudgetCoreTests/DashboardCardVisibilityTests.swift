import XCTest
@testable import BudgetCore

final class DashboardCardVisibilityTests: XCTestCase {
    func testDefaultShowsAll() {
        for visibility in [DashboardCardVisibility(stored: nil), DashboardCardVisibility(storedString: "")] {
            XCTAssertTrue(DashboardCardVisibility.Card.allCases.allSatisfy(visibility.shows))
            XCTAssertEqual(visibility.stored, [])
        }
    }

    func testRoundTrip() {
        var visibility = DashboardCardVisibility(stored: nil)
        visibility.hidden = [.mortgage, .taxYear]
        XCTAssertFalse(visibility.shows(.taxYear))
        XCTAssertTrue(visibility.shows(.evidence))
        XCTAssertEqual(visibility.stored, ["mortgage", "taxYear"])
        XCTAssertEqual(DashboardCardVisibility(stored: visibility.stored), visibility)
        XCTAssertEqual(DashboardCardVisibility(storedString: visibility.storedString), visibility)
    }

    func testUnknownHiddenIdIgnored() {
        let visibility = DashboardCardVisibility(stored: ["evidence", "futureCard"])
        XCTAssertEqual(visibility.hidden, [.evidence])
        XCTAssertEqual(visibility.stored, ["evidence"])
    }

    func testEveryWidgetCanBeHidden() {
        let visibility = DashboardCardVisibility(stored: DashboardCardVisibility.Card.allCases.map(\.rawValue))
        XCTAssertTrue(DashboardCardVisibility.Card.allCases.allSatisfy { !visibility.shows($0) })
        XCTAssertEqual(visibility.stored.count, DashboardCardVisibility.Card.allCases.count)
        XCTAssertEqual(DashboardCardVisibility.Card(tileID: DashboardTile.mortgage("Flat")), .mortgage)
        XCTAssertEqual(DashboardCardVisibility.Card(tileID: DashboardTile.netWorth), .netWorth)
        XCTAssertNil(DashboardCardVisibility.Card(tileID: "bogus"))
        XCTAssertEqual(DashboardCardVisibility.Card.cards(in: .property), [.propertyMonth, .tenancyCashFlow, .propertyReturn, .mortgage])
        XCTAssertEqual(DashboardCardVisibility.Card.mortgage.title, "Mortgage")
    }
}
