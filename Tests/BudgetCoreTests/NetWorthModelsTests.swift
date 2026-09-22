// Tests/BudgetCoreTests/NetWorthModelsTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class NetWorthModelsTests: XCTestCase {
    func testInsertAndFetchBalanceSnapshot() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Investment ISA", currency: .gbp, kind: .investment, trackingMode: .manual)
        try manager.dbQueue.write { db in try account.insert(db) }
        var snapshot = BalanceSnapshot(accountId: account.id!, date: Date(), balanceMinorUnits: 500000, note: "Checked via app")
        try manager.dbQueue.write { db in try snapshot.insert(db) }
        let fetched = try manager.dbQueue.read { db in try BalanceSnapshot.fetchOne(db) }
        XCTAssertEqual(fetched?.balanceMinorUnits, 500000)
    }

    func testExchangeRateSettingDefaultsWhenNoneSet() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let rate = try manager.dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        XCTAssertEqual(rate.eurToGbpRate, 0.87, accuracy: 0.001)
    }

    func testExchangeRateSettingReturnsMostRecentlySaved() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            var rate = ExchangeRateSetting(eurToGbpRate: 0.90, updatedAt: Date())
            try rate.insert(db)
        }
        let rate = try manager.dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        XCTAssertEqual(rate.eurToGbpRate, 0.90, accuracy: 0.001)
    }
}
