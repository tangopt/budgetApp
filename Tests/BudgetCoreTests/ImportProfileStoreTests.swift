// Tests/BudgetCoreTests/ImportProfileStoreTests.swift
import XCTest
@testable import BudgetCore

final class ImportProfileStoreTests: XCTestCase {
    func testSaveThenFindReturnsProfile() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        let store = ImportProfileStore(dbQueue: manager.dbQueue)

        let profile = ImportProfile(accountId: account.id!, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy")
        let saved = try store.save(profile)
        XCTAssertNotNil(saved.id)

        let found = try store.find(accountId: account.id!, format: .csv)
        XCTAssertEqual(found?.csvDateFormat, "dd/MM/yyyy")
    }

    func testFindReturnsNilWhenNoProfileExists() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let store = ImportProfileStore(dbQueue: manager.dbQueue)
        let found = try store.find(accountId: 999, format: .csv)
        XCTAssertNil(found)
    }

    func testSaveUpserts() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        let store = ImportProfileStore(dbQueue: manager.dbQueue)

        // Save first profile
        let profile1 = ImportProfile(accountId: account.id!, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy")
        let saved1 = try store.save(profile1)
        let id1 = saved1.id!

        // Save again with same account+format but different config (should update)
        let profile2 = ImportProfile(accountId: account.id!, format: .csv, csvDelimiter: ";", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "yyyy-MM-dd")
        let saved2 = try store.save(profile2)
        let id2 = saved2.id!

        // Should be same ID (updated, not inserted)
        XCTAssertEqual(id1, id2)

        // Verify the update was applied
        let found = try store.find(accountId: account.id!, format: .csv)
        XCTAssertEqual(found?.csvDateFormat, "yyyy-MM-dd")
        XCTAssertEqual(found?.csvDelimiter, ";")
    }
}
