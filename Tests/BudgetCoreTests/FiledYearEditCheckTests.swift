import XCTest
import GRDB
@testable import BudgetCore

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
            try FiledYearEditCheck.save(db: db, edit: "Edit transaction", scope: .categorising([id(key)], as: id(category)),
                                        resolution: resolution, now: Self.now,
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
        XCTAssertEqual(asked.heading, "Filed returns would change")
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
        // Every year whose return moved is noted, its row created: 2023/24 and 2024/25 carry the loss.
        for year in [2023, 2024] {
            let lines = FiledYearEditCheck.changesAfterFiling(try notes(year))
            XCTAssertEqual(lines.count, 1, "\(year)")
            XCTAssertTrue(lines.first?.contains("SA calculation: property loss carried forward £100.00 → £350.00") == true, "\(lines)")
        }
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
                let ids = try Rules.uncategorisedMatchIds(db: db, pattern: "BUILDER LTD", matchType: .contains)
                return try FiledYearEditCheck.save(db: db, edit: "Rule BUILDER LTD → Repairs", scope: .categorising(ids, as: id("repairs")),
                                                   resolution: resolution, now: Self.now) {
                    try Rules.add(db: db, pattern: "BUILDER LTD", matchType: .contains, categoryId: id("repairs"), applyToUncategorised: true)
                }
            }
        }
        let asked = try XCTUnwrap(question(try addRule(nil)))
        // One question: 2022/23 filed, 2023/24 in the years filed whatever their status (ruling R13),
        // 2024/25 carrying their losses forward.
        XCTAssertEqual(asked.years.map(\.startYear), [2022, 2023, 2024])
        XCTAssertEqual(asked.markTitle, "Mark as not counted for 2022/23, 2023/24 and save")
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
                try FiledYearEditCheck.save(db: db, edit: "Manual item Postage", scope: .from(year: 2022), resolution: resolution, now: Self.now) {
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

    // MARK: Several people, paid years, which sources are marked

    /// Person B owns half; A's 2022/23 is filed, B's paid.
    private func addPersonB() throws {
        try db.write { db in
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            ids["B"] = b.id!
            _ = try Properties.setOwners(db: db, propertyId: id("property"), [
                PropertyOwner(propertyId: id("property"), personId: id("A"), shareBasisPoints: 5_000),
                PropertyOwner(propertyId: id("property"), personId: b.id!, shareBasisPoints: 5_000)
            ])
            var year = TaxYear(startYear: 2022, personId: b.id!, status: .paid)
            try year.insert(db)
        }
    }

    func testSeveralPeopleAreNamedOnTheirLines() throws {
        try addPersonB()
        let asked = try XCTUnwrap(question(try categorise("refund")))
        let year = try XCTUnwrap(asked.years.first)
        XCTAssertEqual(year.people, ["Person A", "Person B"])
        XCTAssertFalse(year.isPaid, "A's is only filed")
        XCTAssertEqual(year.title, "This changes the filed 2022/23 returns of Person A and Person B:")
        XCTAssertTrue(year.lines.contains { $0.text == "Person A · SA106 Land and property abroad box 17 Allowable property expenses £50.00 → £175.00" },
                      "\(year.lines.map(\.text))")
        XCTAssertTrue(year.lines.contains { $0.person == "Person B" })
        XCTAssertEqual(asked.markYears, [2022])
        // Saved anyway: both people's years are noted.
        XCTAssertTrue(isSaved(try categorise("refund", resolution: .saveAnyway)))
        for person in ["A", "B"] {
            let notes = try db.read { db in
                try TaxYear.filter(Column("startYear") == 2022 && Column("personId") == id(person)).fetchOne(db)?.notes
            }
            XCTAssertEqual(FiledYearEditCheck.changesAfterFiling(notes).count, 1, person)
        }
    }

    func testAPaidYearSaysPaid() throws {
        try db.write { db in try db.execute(sql: "UPDATE taxYear SET status = ? WHERE startYear = 2022", arguments: [TaxYearStatus.paid.rawValue]) }
        let asked = try XCTUnwrap(question(try categorise("refund")))
        XCTAssertEqual(asked.years.first?.title, "This changes your paid 2022/23 return:")
        XCTAssertTrue(asked.years.first?.isPaid == true)
        // 2023/24 and 2024/25 are filed (ruling R13), not paid.
        XCTAssertEqual(asked.years.dropFirst().map(\.title), ["This changes your filed 2023/24 return:", "This changes your filed 2024/25 return:"])
        XCTAssertEqual(asked.heading, "Filed and paid returns would change")
    }

    func testOnlyTheSourcesThatMovedAFigureAreMarked() throws {
        let insurance = try db.write { db -> Int64 in
            let group = try XCTUnwrap(Category.fetchOne(db, key: id("repairs"))?.groupId)
            var category = Category(name: "Garden", type: .expense, groupId: group)
            try category.insert(db)
            try TaxExpenseTypeMap.set(db: db, categoryId: category.id!, expenseType: .otherExpense)
            return category.id!
        }
        let before = try figures()
        // One batch: the refund newly counted, the plumber moved to another deductible line (same total).
        func batch(_ resolution: FiledYearEditCheck.Resolution?) throws -> FiledYearEditCheck.Outcome<Void> {
            try db.write { db in
                try FiledYearEditCheck.save(db: db, edit: "Batch", scope: FiledYearEditCheck.Scope(transactionIds: [id("refund"), id("plumber")],
                                                                                                  categoryIds: [id("repairs"), insurance]),
                                            resolution: resolution, now: Self.now) {
                    try TransactionEditing.update(db: db, id: id("refund"), categoryId: id("repairs"), note: nil)
                    try TransactionEditing.update(db: db, id: id("plumber"), categoryId: insurance, note: nil)
                }
            }
        }
        let asked = try XCTUnwrap(question(try batch(nil)))
        XCTAssertEqual(asked.markYears, [2022])
        XCTAssertTrue(isSaved(try batch(.markNotCounted)))
        XCTAssertEqual(try marks().map(\.transactionId), [id("refund")], "the plumber's cost stays claimed")
        XCTAssertEqual(try figures().values.filter { $0.key.field.hasPrefix("SA ") }, before.values.filter { $0.key.field.hasPrefix("SA ") })
    }

    // MARK: Observed databases

    /// With a GRDB observation of the transactions active (as the Property and Tax screens have), an
    /// open-year edit still takes no figures and a filed-year edit still asks.
    func testAnActiveObservationKeepsTheOpenYearShortcut() throws {
        var changes = 0
        let cancellable = ValueObservation.tracking { db in try Transaction.fetchCount(db) + (try TaxManualItem.fetchCount(db)) }
            .start(in: db, scheduling: .immediate, onError: { XCTFail("\($0)") }, onChange: { _ in changes += 1 })
        defer { cancellable.cancel() }
        var snapshots = 0
        XCTAssertTrue(isSaved(try categorise("later", snapshots: &snapshots)))
        XCTAssertEqual(snapshots, 0)
        XCTAssertNotNil(question(try categorise("refund")))
        XCTAssertGreaterThan(changes, 0)
    }

    // MARK: Structure and settings

    func testMovingAPropertyCategoryOutOfItsGroupAsksWithoutMarking() throws {
        let before = try figures()
        func move(_ resolution: FiledYearEditCheck.Resolution?) throws -> FiledYearEditCheck.Outcome<Void> {
            try db.write { db in
                try FiledYearEditCheck.save(db: db, edit: "Categories moved to Ungrouped", scope: try .categories(db: db, ids: [id("repairs")]),
                                            resolution: resolution, now: Self.now) {
                    try Categories.move(db: db, ids: [id("repairs")], toGroupId: nil)
                }
            }
        }
        let asked = try XCTUnwrap(question(try move(nil)))
        XCTAssertEqual(asked.years.first?.startYear, 2022)
        XCTAssertFalse(asked.canMarkNotCounted, "a structure change has no source to mark")
        XCTAssertEqual(try figures(), before)
        XCTAssertTrue(isSaved(try move(.saveAnyway)))
        XCTAssertNotEqual(try figures(), before)
    }

    func testAnEverydayCategoryChangeTakesNoFigures() throws {
        var snapshots = 0
        let outcome = try db.write { db in
            try FiledYearEditCheck.save(db: db, edit: "Category renamed", scope: try .categories(db: db, ids: [id("groceries")]),
                                        resolution: nil, now: Self.now, onSnapshot: { snapshots += 1 }) {
                try Categories.rename(db: db, id: id("groceries"), name: "Food")
            }
        }
        XCTAssertTrue(isSaved(outcome))
        XCTAssertEqual(snapshots, 0)
    }

    func testASplitInAFiledYearAsksAndOneInAnOpenYearTakesNoFigures() throws {
        func split(_ year: Int, snapshots: inout Int) throws -> FiledYearEditCheck.Outcome<Void> {
            var count = 0
            defer { snapshots = count }
            return try db.write { db in
                try FiledYearEditCheck.save(db: db, edit: "Split", scope: .from(year: year), resolution: nil, now: Self.now,
                                            onSnapshot: { count += 1 }) {
                    try TaxSplits.set(db: db, startYear: year, personId: id("A"), propertyId: id("property"), expenseType: nil,
                                      shareBasisPoints: 5_000)
                }
            }
        }
        var snapshots = 0
        XCTAssertNotNil(question(try split(2022, snapshots: &snapshots)))
        XCTAssertTrue(isSaved(try split(2026, snapshots: &snapshots)))
        XCTAssertEqual(snapshots, 0)
    }

    func testHMRCRatesAreNotFetchedForAFiledYear() throws {
        try db.write { db in
            var account = try XCTUnwrap(Account.fetchOne(db))
            account.currency = .eur
            try account.update(db)
        }
        let missing = try db.read { db in try HMRCRates.missing(db: db, today: Self.now) }
        XCTAssertNil(missing[2022], "2022/23 is filed")
        XCTAssertNotNil(missing[2023], "2023/24 isn't stored filed")
    }

    // MARK: Answering without checking again (fix round 2, T-1b)

    func testAnAnswerWhileNothingChangedSavesWithoutTakingTheFiguresAgain() throws {
        let before = try figures()
        var snapshots = 0
        let asked = try XCTUnwrap(question(try categorise("refund", snapshots: &snapshots)))
        XCTAssertGreaterThan(snapshots, 0)
        XCTAssertNotNil(asked.resume)
        snapshots = 0
        let saved = try db.write { db in
            try FiledYearEditCheck.save(db: db, edit: "Edit transaction", scope: .categorising([id("refund")], as: id("repairs")),
                                        resolution: .markNotCounted, answering: asked, now: Self.now, onSnapshot: { snapshots += 1 }) {
                try TransactionEditing.update(db: db, id: id("refund"), categoryId: id("repairs"), note: nil)
            }
        }
        XCTAssertTrue(isSaved(saved))
        XCTAssertEqual(snapshots, 0, "answered from the question")
        XCTAssertEqual(try category("refund"), id("repairs"))
        XCTAssertEqual(try figures(), before)
        XCTAssertEqual(try marks().map(\.transactionId), [id("refund")])
    }

    func testSaveAnywayFromTheQuestionNotesWithoutTakingTheFiguresAgain() throws {
        let asked = try XCTUnwrap(question(try categorise("refund")))
        var snapshots = 0
        let saved = try db.write { db in
            try FiledYearEditCheck.save(db: db, edit: "Edit transaction", scope: .categorising([id("refund")], as: id("repairs")),
                                        resolution: .saveAnyway, answering: asked, now: Self.now, onSnapshot: { snapshots += 1 }) {
                try TransactionEditing.update(db: db, id: id("refund"), categoryId: id("repairs"), note: nil)
            }
        }
        XCTAssertTrue(isSaved(saved))
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(FiledYearEditCheck.changesAfterFiling(try notes()).count, 1)
        XCTAssertEqual(FiledYearEditCheck.changesAfterFiling(try notes(2024)).count, 1)
    }

    func testAnAnswerAfterAnotherWriteIsCheckedAgain() throws {
        let asked = try XCTUnwrap(question(try categorise("refund")))
        // Meanwhile the plumber is taken off Repairs: the question's figures no longer hold.
        try db.write { db in try TransactionEditing.update(db: db, id: id("plumber"), categoryId: id("groceries"), note: nil) }
        var snapshots = 0
        let saved = try db.write { db in
            try FiledYearEditCheck.save(db: db, edit: "Edit transaction", scope: .categorising([id("refund")], as: id("repairs")),
                                        resolution: .saveAnyway, answering: asked, now: Self.now, onSnapshot: { snapshots += 1 }) {
                try TransactionEditing.update(db: db, id: id("refund"), categoryId: id("repairs"), note: nil)
            }
        }
        XCTAssertTrue(isSaved(saved))
        XCTAssertGreaterThan(snapshots, 0, "checked again")
        XCTAssertTrue(try notes()?.contains("box 17 Allowable property expenses — → £250.00") == true, "noted from the figures now")
    }

    // MARK: Each scope helper covers what its write touches (N-6)

    /// `scope` asks exactly as `.everyYear` does for `write` (the same years, or both save).
    private func assertCovers(_ scope: (Database) throws -> FiledYearEditCheck.Scope, _ write: @escaping (Database) throws -> Void,
                              asks: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        func years(_ scope: FiledYearEditCheck.Scope, _ db: Database) throws -> [Int]? {
            var result: [Int]?
            try db.inSavepoint {
                if case .asks(let question) = try FiledYearEditCheck.save(db: db, edit: "Test", scope: scope, now: Self.now, { try write(db) }) {
                    result = question.years.map(\.startYear)
                }
                return .rollback
            }
            return result
        }
        try db.write { db in
            let declared = try years(try scope(db), db)
            let every = try years(.everyYear, db)
            XCTAssertEqual(declared, every, "the declared scope misses what .everyYear finds", file: file, line: line)
            XCTAssertEqual(declared != nil, asks, file: file, line: line)
        }
    }

    func testEachScopeHelperCoversWhatItsWriteTouches() throws {
        // categorising: Set category…, assignments, a rule's filing.
        try assertCovers({ _ in .categorising([self.id("refund")], as: self.id("repairs")) }, { db in
            try TransactionEditing.setCategory(db: db, ids: [self.id("refund")], categoryId: self.id("repairs"), remember: true)
        }, asks: true)
        try assertCovers({ _ in .categorising([self.id("plumber")], as: self.id("groceries")) }, { db in
            try TransactionEditing.setCategory(db: db, ids: [self.id("plumber")], categoryId: self.id("groceries"), remember: false)
        }, asks: true)
        try assertCovers({ db in .categorising(try Rules.uncategorisedMatchIds(db: db, pattern: "BUILDER", matchType: .contains), as: self.id("repairs")) },
                         { db in _ = try Rules.add(db: db, pattern: "BUILDER", matchType: .contains, categoryId: self.id("repairs"), applyToUncategorised: true) },
                         asks: true)
        // transactionEdit: a manual transaction moved from 2029 into a filed year.
        let manual = try db.write { db in
            try ManualTransactions.add(db: db, accountId: try XCTUnwrap(Account.fetchOne(db)?.id), date: Self.date(2029, 6, 1),
                                       description: "SKIP HIRE", amountMinorUnits: -9_000, categoryId: self.id("repairs"), note: nil)
        }
        let moved = TransactionEditChanges(categoryId: id("repairs"), note: nil,
                                           manual: .init(accountId: manual.accountId, date: Self.date(2022, 10, 1), description: "SKIP HIRE",
                                                         amountMinorUnits: -9_000))
        try assertCovers({ _ in .transactionEdit(id: manual.id!, changes: moved) }, { db in
            try TransactionEditing.save(db: db, id: manual.id!, changes: moved)
        }, asks: true)
        try assertCovers({ _ in .transactionEdit(id: self.id("later"), changes: TransactionEditChanges(categoryId: self.id("repairs"), note: "x")) }, { db in
            try TransactionEditing.save(db: db, id: self.id("later"), changes: TransactionEditChanges(categoryId: self.id("repairs"), note: "x"))
        }, asks: false)
        // Deleting a manual transaction in a filed year.
        let filedManual = try db.write { db in
            try ManualTransactions.add(db: db, accountId: manual.accountId, date: Self.date(2022, 12, 1), description: "PAINT",
                                       amountMinorUnits: -4_000, categoryId: self.id("repairs"), note: nil)
        }
        try assertCovers({ _ in FiledYearEditCheck.Scope(transactionIds: [filedManual.id!]) }, { db in
            try ManualTransactions.delete(db: db, id: filedManual.id!)
        }, asks: true)
        // adding.
        try assertCovers({ _ in .adding(date: Self.date(2022, 8, 1), categoryId: self.id("repairs")) }, { db in
            _ = try ManualTransactions.add(db: db, accountId: manual.accountId, date: Self.date(2022, 8, 1), description: "GUTTER",
                                           amountMinorUnits: -3_000, categoryId: self.id("repairs"), note: nil)
        }, asks: true)
        // manualItem: added, then deleted.
        let item = TaxManualItem(startYear: 2022, personId: id("A"), propertyId: id("property"), expenseType: .otherExpense, label: "Postage",
                                 amountMinorUnits: 1_000, currency: .gbp)
        try assertCovers({ _ in .manualItem(id: nil, startYear: 2022) }, { db in var item = item; try TaxManualItems.save(db: db, &item) }, asks: true)
        let stored = try db.write { db -> Int64 in var item = item; try TaxManualItems.save(db: db, &item); return item.id! }
        try assertCovers({ _ in .manualItem(id: stored, startYear: nil) }, { db in _ = try TaxManualItems.delete(db: db, id: stored) }, asks: true)
        // categories: a property's category moved out; an everyday one renamed.
        try assertCovers({ db in try .categories(db: db, ids: [self.id("repairs")]) }, { db in
            try Categories.move(db: db, ids: [self.id("repairs")], toGroupId: nil)
        }, asks: true)
        try assertCovers({ db in try .categories(db: db, ids: [self.id("groceries")]) }, { db in
            try Categories.rename(db: db, id: self.id("groceries"), name: "Food")
        }, asks: false)
        try assertCovers({ db in try .categories(db: db, ids: [self.id("repairs")]) }, { db in
            _ = try CategoryGroups.create(db: db, name: "Elsewhere", type: .expense, moving: [self.id("repairs")])
        }, asks: true)
        // from(year:): a split, a status change, other income, a "not claimed" mark.
        try assertCovers({ _ in .from(year: 2022) }, { db in
            try TaxSplits.set(db: db, startYear: 2022, personId: self.id("A"), propertyId: self.id("property"), expenseType: nil, shareBasisPoints: 5_000)
        }, asks: true)
        try assertCovers({ _ in .from(year: 2022) }, { db in
            try TaxOverview.setStatus(db: db, startYear: 2022, personId: self.id("A"), status: .preparing)
        }, asks: true)
        try assertCovers({ _ in .from(year: 2022) }, { db in
            var income = OtherIncome(startYear: 2022, personId: self.id("A"), kind: .ukInterest, amountMinorUnits: 50_000, currency: .gbp)
            try OtherIncomes.save(db: db, &income)
        }, asks: true)
        try assertCovers({ _ in .from(year: 2022) }, { db in
            try TaxNotClaimedSources.set(db: db, startYear: 2022, reference: .transaction(self.id("plumber")), notClaimed: true)
        }, asks: true)
    }
}
