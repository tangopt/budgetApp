import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

/// Plan Task 14: an edit that would move a figure on a filed or paid return asks first
/// (`FiledYearEditCheck`). Synthetic data: Person A filed 2022/23; Property A (wholly A's, GBP) has
/// rent and a repair that year on its bank account, an uncategorised refund-like debit in 2022/23
/// (the 2026-10-24 incident's shape), builders' debits in 2022/23 and 2023/24, a debit in the open
/// 2025/26 and one in 2029.
final class FiledYearEditCheckTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private static let now = date(2026, 10, 25)

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func id(_ key: String) -> Int64 { ids[key]! }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        ids = try db.write { db in
            var ids: [String: Int64] = [:]
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            ids["A"] = person.id!
            var year = TaxYear(startYear: 2022, personId: person.id!, status: .filed)
            try year.insert(db)
            var property = Property(name: "Property A", country: "PT", currency: .gbp)
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)
            ])
            var account = Account(name: "Bank A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Self.date(2025, 1, 1))
            try batch.insert(db)
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("repairs", "Repairs", .expense)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            var everyday = CategoryGroup(name: "Everyday")
            try everyday.insert(db)
            var groceries = Category(name: "Groceries", type: .expense, groupId: everyday.id)
            try groceries.insert(db)
            ids["groceries"] = groceries.id!
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            for (key, day, description, amount, category) in [
                ("rentRow", Self.date(2022, 6, 1), "TENANT RENT", 500_000, ids["rent"]),
                ("plumber", Self.date(2022, 7, 1), "PLUMBER", -10_000, ids["repairs"]),
                ("refund", Self.date(2022, 9, 1), "CARD 1234 SHOP", -25_000, nil),
                ("builder22", Self.date(2022, 11, 1), "BUILDER LTD", -30_000, nil),
                ("builder23", Self.date(2023, 11, 1), "BUILDER LTD", -40_000, nil),
                ("open", Self.date(2025, 8, 1), "HANDYMAN", -5_000, nil),
                ("later", Self.date(2029, 3, 1), "HARDWARE", -2_000, nil)
            ] {
                var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: day, rawDescription: description,
                                    amountMinorUnits: amount, categoryId: category, status: category == nil ? .pendingReview : .confirmed,
                                    categorizedBy: category == nil ? .none : .manual, fingerprint: "fp-\(key)")
                try t.insert(db)
                ids[key] = t.id!
            }
            return ids
        }
    }

    // MARK: Helpers

    private func figures() throws -> TaxFigures.Snapshot {
        try db.read { db in try TaxFigures.snapshot(db: db) }
    }

    private func category(_ key: String) throws -> Int64? {
        try db.read { db in try Transaction.fetchOne(db, key: id(key))?.categoryId }
    }

    /// Sets `key`'s category to Repairs (Edit transaction's save) through the check.
    private func categorise(_ key: String, as category: String = "repairs", resolution: FiledYearEditCheck.Resolution? = nil,
                            snapshots: UnsafeMutablePointer<Int>? = nil) throws -> FiledYearEditCheck.Outcome<Void> {
        try db.write { db in
            try FiledYearEditCheck.save(db: db, edit: "Edit transaction", resolution: resolution, now: Self.now,
                                        onSnapshot: { snapshots?.pointee += 1 }) {
                try TransactionEditing.update(db: db, id: id(key), categoryId: id(category), note: nil)
            }
        }
    }

    private func question<T>(_ outcome: FiledYearEditCheck.Outcome<T>, file: StaticString = #filePath, line: UInt = #line) -> FiledYearEditCheck.Question? {
        if case .asks(let question) = outcome { return question }
        XCTFail("expected a question, saved instead", file: file, line: line)
        return nil
    }

    private func isSaved<T>(_ outcome: FiledYearEditCheck.Outcome<T>) -> Bool {
        if case .saved = outcome { return true }
        return false
    }

    private func marks() throws -> [TaxNotClaimed] {
        try db.read { db in try TaxNotClaimed.order(Column("startYear")).fetchAll(db) }
    }

    private func notes(_ year: Int = 2022) throws -> String? {
        try db.read { db in try TaxYear.filter(Column("startYear") == year).fetchOne(db)?.notes }
    }

    // MARK: The question

    func testCategorisingIntoADeductibleLineAsksWithTheBoxDifferenceAndCancelWritesNothing() throws {
        let before = try figures()
        let asked = try XCTUnwrap(question(try categorise("refund")))
        // 2022/23's boxes, and the loss it carries forward into 2023/24 and 2024/25 (filed whatever
        // their status, ruling R13).
        XCTAssertEqual(asked.years.map(\.startYear), [2022, 2023, 2024])
        XCTAssertEqual(asked.yearsLabel, "2022/23, 2023/24 and 2024/25")
        XCTAssertEqual(asked.years[1].lines.map(\.text), ["SA calculation: property loss carried forward £100.00 → £350.00"])
        // Only 2022/23 is marked: the later years carry its figures.
        XCTAssertEqual(asked.markYears, [2022])
        XCTAssertEqual(asked.markTitle, "Mark as not counted for 2022/23 and save")
        XCTAssertTrue(asked.canMarkNotCounted)
        let year = try XCTUnwrap(asked.years.first)
        XCTAssertEqual(year.title, "This changes your filed 2022/23 return:")
        XCTAssertFalse(year.lines.isEmpty)
        XCTAssertTrue(year.lines.allSatisfy { $0.person == nil && !$0.box.hasPrefix("SA ") })
        // The expenses box moves by the debit: £100.00 → £350.00.
        XCTAssertTrue(year.lines.map(\.text).contains("SA106 Land and property abroad box 17 Allowable property expenses £100.00 → £350.00"),
                      "lines: \(year.lines.map(\.text))")
        // Cancel: nothing was written.
        XCTAssertNil(try category("refund"))
        XCTAssertEqual(try figures(), before)
        XCTAssertTrue(try marks().isEmpty)
        XCTAssertNil(try notes())
    }

    func testMarkAsNotCountedSavesTheEditAndLeavesTheFiguresIdentical() throws {
        let before = try figures()
        XCTAssertTrue(isSaved(try categorise("refund", resolution: .markNotCounted)))
        XCTAssertEqual(try category("refund"), id("repairs"))
        XCTAssertEqual(try figures(), before)
        let mark = try XCTUnwrap(try marks().first)
        XCTAssertEqual(mark.startYear, 2022)
        XCTAssertEqual(mark.transactionId, id("refund"))
        XCTAssertEqual(mark.notes, "Not counted: Edit transaction on 2026-10-25, after the 2022/23 return was filed")
        // Saved: the same edit asks nothing now.
        XCTAssertTrue(isSaved(try categorise("refund")))
    }

    func testSaveAnywayChangesTheFiguresAndTheYearShowsAsDiffering() throws {
        let before = try figures()
        XCTAssertTrue(isSaved(try categorise("refund", resolution: .saveAnyway)))
        XCTAssertEqual(try category("refund"), id("repairs"))
        let after = try figures()
        XCTAssertNotEqual(after, before)
        let moved = FiledYearSyncCheck.protectedImpacts(before: before, after: after)
        XCTAssertEqual(moved.map(\.startYear), [2022], "the stored year (the snapshot's)")
        XCTAssertTrue(try marks().isEmpty)
        let changes = FiledYearEditCheck.changesAfterFiling(try notes())
        XCTAssertEqual(changes.count, 1, "on 2022/23's notes (the only year stored)")
        let change = try XCTUnwrap(changes.first)
        XCTAssertTrue(change.hasPrefix("Changed after filing on 2026-10-25 (Edit transaction): "), change)
        XCTAssertTrue(change.contains("£100.00 → £350.00"), change)
        // The year's row carries it (the return shows it as differing from the filed one).
        let row = try db.read { db in try TaxOverview.rows(db: db, now: Self.now) }.first { $0.year.startYear == 2022 }
        XCTAssertEqual(row?.changedAfterFiling, [change])
    }

    func testTakingACostOffAFiledLineCantBeMarkedNotCounted() throws {
        let before = try figures()
        let asked = try XCTUnwrap(question(try categorise("plumber", as: "groceries")))
        XCTAssertEqual(asked.years.map(\.startYear), [2022, 2023, 2024])
        XCTAssertFalse(asked.canMarkNotCounted)
        XCTAssertThrowsError(try categorise("plumber", as: "groceries", resolution: .markNotCounted)) { error in
            XCTAssertEqual(error as? FiledYearEditCheck.Failure, .notCountedStillChanges(years: ["2022/23", "2023/24", "2024/25"]))
        }
        XCTAssertEqual(try category("plumber"), id("repairs"))
        XCTAssertEqual(try figures(), before)
        XCTAssertTrue(try marks().isEmpty)
    }

    // MARK: Open years

    func testOpenYearsNeverAsk() throws {
        // 2025/26 is open: its repair is checked against the years it could reach, and moves none.
        XCTAssertTrue(isSaved(try categorise("open")))
        XCTAssertEqual(try category("open"), id("repairs"))
        // 2029/30: no filed year within reach, so no figures are taken at all.
        var snapshots = 0
        XCTAssertTrue(isSaved(try categorise("later", snapshots: &snapshots)))
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(try category("later"), id("repairs"))
        // A filed-year transaction put in a category no property has: no figures taken either.
        XCTAssertTrue(isSaved(try categorise("refund", as: "groceries", snapshots: &snapshots)))
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(try category("refund"), id("groceries"))
        XCTAssertTrue(try marks().isEmpty)
    }

    // MARK: Batches

    func testARuleAppliedToTheUncategorisedAsksOneQuestionForTheBatch() throws {
        let before = try figures()
        func addRule(_ resolution: FiledYearEditCheck.Resolution?) throws -> FiledYearEditCheck.Outcome<Rule> {
            try db.write { db in
                try FiledYearEditCheck.save(db: db, edit: "Rule BUILDER LTD → Repairs", resolution: resolution, now: Self.now) {
                    try Rules.add(db: db, pattern: "BUILDER LTD", matchType: .contains, categoryId: id("repairs"), applyToUncategorised: true)
                }
            }
        }
        let asked = try XCTUnwrap(question(try addRule(nil)))
        // One question: 2022/23 filed, 2023/24 in the years filed whatever their status (ruling R13),
        // 2024/25 carrying their losses forward.
        XCTAssertEqual(asked.years.map(\.startYear), [2022, 2023, 2024])
        XCTAssertEqual(asked.markTitle, "Mark as not counted for 2022/23 and 2023/24 and save")
        XCTAssertTrue(asked.canMarkNotCounted)
        XCTAssertEqual(try db.read { db in try Rule.fetchCount(db) }, 0, "cancel: not even the rule is kept")
        XCTAssertNil(try category("builder22"))

        XCTAssertTrue(isSaved(try addRule(.markNotCounted)))
        XCTAssertEqual(try category("builder22"), id("repairs"))
        XCTAssertEqual(try category("builder23"), id("repairs"))
        XCTAssertEqual(try figures(), before)
        XCTAssertEqual(try marks().map { "\($0.startYear) \($0.transactionId!)" }, ["2022 \(id("builder22"))", "2023 \(id("builder23"))"])
    }

    func testAManualTaxItemInAFiledYearAsks() throws {
        let item = { (resolution: FiledYearEditCheck.Resolution?) throws -> FiledYearEditCheck.Outcome<Void> in
            try self.db.write { db in
                try FiledYearEditCheck.save(db: db, edit: "Manual item Postage", resolution: resolution, now: Self.now) {
                    var item = TaxManualItem(startYear: 2022, personId: self.id("A"), propertyId: self.id("property"), expenseType: .otherExpense,
                                             label: "Postage", amountMinorUnits: 1_000, currency: .gbp, isWholeProperty: false)
                    try TaxManualItems.save(db: db, &item)
                }
            }
        }
        let before = try figures()
        let asked = try XCTUnwrap(question(try item(nil)))
        XCTAssertEqual(asked.years.first?.startYear, 2022)
        XCTAssertEqual(asked.markYears, [2022])
        XCTAssertEqual(try db.read { db in try TaxManualItem.fetchCount(db) }, 0)
        XCTAssertTrue(isSaved(try item(.markNotCounted)))
        XCTAssertEqual(try figures(), before)
        XCTAssertEqual(try marks().map(\.startYear), [2022])
    }

    // MARK: What tax figures read

    /// `unreadTables` are never read by `TaxFigures.snapshot` (on the demo database, every statement
    /// it runs).
    func testTheTablesTreatedAsUnreadAreNotReadByTheTaxFigures() throws {
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("FiledEditDemo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        let demo = try DatabaseManager(path: nil)
        try demo.migrate()
        try DemoDatabase.build(dbQueue: demo.dbQueue, evidenceRoot: evidence)
        try demo.dbQueue.write { db in
            var sqls = Set<String>()
            db.trace(options: .statement) { event in
                if case .statement(let statement) = event { sqls.insert(statement.sql) }
            }
            defer { db.trace(options: []) }
            let snapshot = try TaxFigures.snapshot(db: db)
            XCTAssertFalse(snapshot.values.isEmpty)
            XCTAssertGreaterThan(sqls.count, 10)
            for sql in sqls {
                guard let statement = try? db.makeStatement(sql: sql) else { continue }
                let region = statement.databaseRegion
                for table in FiledYearEditCheck.unreadTables {
                    XCTAssertFalse(region.isModified(byEventsOfKind: .insert(tableName: table)), "\(sql) reads \(table)")
                }
            }
        }
    }
}
