import XCTest
@testable import BudgetCore

final class DashboardStatusTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_792_000_000)
    private func freshness(_ status: DataFreshness.Status) -> DataFreshness {
        DataFreshness(status: status, lastImportAt: day, lastImportFileName: nil, dataThrough: day)
    }

    func testUpToDateShowsTheDataDate() {
        let status = DashboardStatus.make(freshness: freshness(.upToDate), importsWaiting: 0, staleBalances: 0)
        XCTAssertEqual(status, DashboardStatus(kind: .upToDate, message: "Up to date", date: day, destination: .imports))
    }

    func testFilesWaitingComeFirst() {
        let status = DashboardStatus.make(freshness: freshness(.behind(months: 2, days: 70)), importsWaiting: 2, staleBalances: 3)
        XCTAssertEqual(status.message, "Imports waiting (2)")
        XCTAssertEqual(status.kind, .warning)
        XCTAssertEqual(status.destination, .imports)
    }

    func testBehindThenStaleBalances() {
        XCTAssertEqual(DashboardStatus.make(freshness: freshness(.behind(months: 0, days: 1)), importsWaiting: 0, staleBalances: 1).message, "Data is 1 day behind")
        XCTAssertEqual(DashboardStatus.make(freshness: freshness(.behind(months: 3, days: 95)), importsWaiting: 0, staleBalances: 0).message, "Data is 3 months behind")
        let stale = DashboardStatus.make(freshness: freshness(.upToDate), importsWaiting: 0, staleBalances: 2)
        XCTAssertEqual(stale.message, "2 balances out of date")
        XCTAssertEqual(stale.destination, .accounts)
        XCTAssertEqual(stale.kind, .warning)
        XCTAssertEqual(DashboardStatus.make(freshness: freshness(.upToDate), importsWaiting: 0, staleBalances: 1).message, "1 balance out of date")
    }

    func testNothingImported() {
        let none = DataFreshness(status: .noData, lastImportAt: nil, lastImportFileName: nil, dataThrough: nil)
        XCTAssertEqual(DashboardStatus.make(freshness: none, importsWaiting: 0, staleBalances: 0).message, "Nothing imported yet")
    }
}
