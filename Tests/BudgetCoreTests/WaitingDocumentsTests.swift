import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Documents first, statements later (step 9 Task 1): a document of a kind paid by debits, with an amount
/// and no linked transaction, waits for its payment for 90 days; the job links its one confident match
/// through the filed-year guard, leaves everything else a suggestion, and never remakes an undone link.
/// Synthetic data only (names, descriptions and amounts are made up).
final class WaitingDocumentsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var account: Int64 = 0
    private var batch: Int64 = 0
    private var utilities: Int64 = 0

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var bank = Account(name: "BBVA Demo", currency: .eur, kind: .cash, trackingMode: .imported)
            try bank.insert(db)
            account = bank.id!
            var importBatch = ImportBatch(accountId: account, sourceFileName: "synthetic.csv", importedAt: Date())
            try importBatch.insert(db)
            batch = importBatch.id!
            var category = Category(name: "Utilities", type: .expense)
            try category.insert(db)
            utilities = category.id!
        }
    }

    // MARK: Helpers

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private static func adding(_ days: Int, to date: Date) -> Date {
        UKTaxYear.utcCalendar.date(byAdding: .day, value: days, to: date)!
    }

    @discardableResult
    private func debit(_ date: Date, _ amount: Int, _ description: String = "EDP COMERCIAL DD 0001", category: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: batch, accountId: account, date: date, rawDescription: description,
                                          amountMinorUnits: amount, categoryId: category ?? utilities, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    @discardableResult
    private func document(_ kind: DocumentKind = .utilityInvoice, date: Date?, amount: Int?, customKind: Int64? = nil,
                          periodStart: Date? = nil, addedAt: Date? = nil) throws -> Int64 {
        try db.write { db in
            let sha = UUID().uuidString
            var document = EvidenceDocument(sha256: sha, storedRelativePath: "x/\(sha).pdf", originalFileName: "\(sha).pdf", byteCount: 1,
                                            kind: kind, docDate: date, periodStart: periodStart, amountMinorUnits: amount, currency: .eur,
                                            addedAt: addedAt ?? date ?? Self.day(2026, 1, 1), customKindId: customKind)
            try document.insert(db)
            return document.id!
        }
    }

    private func links() throws -> [WaitingDocuments.Pair] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT documentId, entityId FROM documentLink WHERE entityType = ? ORDER BY documentId, entityId",
                             arguments: [EvidenceEntityType.transaction.rawValue])
                .map { WaitingDocuments.Pair(documentId: $0[0], transactionId: $0[1]) }
        }
    }

    private func state(_ id: Int64, _ now: Date) throws -> WaitingDocuments.State {
        try db.read { db in try WaitingDocuments.state(db: db, documentId: id, now: now) }
    }

    private func run(_ now: Date) throws -> WaitingDocuments.Outcome {
        try db.write { db in try WaitingDocuments.run(db: db, now: now) }
    }

    private func suggestions(_ id: Int64) throws -> [Int64] {
        try db.read { db in try WaitingDocuments.suggestions(db: db, documentId: id) }.map(\.transactionId)
    }

    // MARK: State

    func testWaitingRules() throws {
        let now = Self.day(2026, 2, 1)
        let waiting = try document(date: Self.day(2026, 1, 10), amount: 6_000)
        let noAmount = try document(date: Self.day(2026, 1, 10), amount: nil)
        let rent = try document(.rentReceipt, date: Self.day(2026, 1, 1), amount: 90_000, periodStart: Self.day(2026, 1, 1))
        let custom = try db.write { db -> Int64 in
            var kind = CustomDocumentKind(name: "Gym pass", area: .other)
            try kind.insert(db)
            return kind.id!
        }
        let customDoc = try document(.other, date: Self.day(2026, 1, 10), amount: 3_000, customKind: custom)
        let advice = try document(.bankDebitAdvice, date: Self.day(2026, 1, 10), amount: 4_000)
        let linked = try document(date: Self.day(2026, 1, 10), amount: 7_000)
        let paid = try debit(Self.day(2026, 1, 20), -7_000)
        try db.write { db in try EvidenceLinks.link(db: db, documentId: linked, to: .transaction(paid)) }
        // A link to something other than a transaction leaves it waiting.
        let onCategory = try document(date: Self.day(2026, 1, 10), amount: 8_000)
        try db.write { db in try EvidenceLinks.link(db: db, documentId: onCategory, to: .category(utilities)) }

        XCTAssertEqual(try state(waiting, now), .waiting)
        XCTAssertEqual(try state(onCategory, now), .waiting)
        for id in [noAmount, rent, customDoc, advice, linked] {
            XCTAssertEqual(try state(id, now), .notApplicable, "document \(id)")
        }
        XCTAssertEqual(try db.read { db in try WaitingDocuments.states(db: db, now: now) }, [waiting: .waiting, onCategory: .waiting])
    }

    func testLapsesAfterNinetyDays() throws {
        let start = Self.day(2026, 1, 10)
        let id = try document(date: start, amount: 6_000)
        try debit(Self.adding(150, to: start), -6_000)
        XCTAssertEqual(try state(id, Self.adding(90, to: start)), .waiting)
        XCTAssertEqual(try state(id, Self.adding(91, to: start)), .lapsed)
        XCTAssertEqual(try db.read { db in try WaitingDocuments.states(db: db, now: Self.adding(91, to: start)) }, [id: .lapsed])
        // A debit that would be confident: the lapsed document still isn't linked.
        try debit(Self.adding(10, to: start), -6_000)
        let outcome = try run(Self.adding(91, to: start))
        XCTAssertEqual(outcome, WaitingDocuments.Outcome())
        XCTAssertEqual(try links(), [])
        XCTAssertFalse(try suggestions(id).isEmpty, "still suggestible by hand")
    }

    // MARK: The job

    func testOneConfidentMatchLinks() throws {
        let id = try document(date: Self.day(2026, 1, 10), amount: 6_000)
        let paid = try debit(Self.day(2026, 1, 25), -6_000)
        try debit(Self.day(2026, 1, 26), -6_100)  // a near amount: not a candidate
        let now = Self.day(2026, 2, 1)
        let outcome = try run(now)
        let pair = WaitingDocuments.Pair(documentId: id, transactionId: paid)
        XCTAssertEqual(outcome.linked, [pair])
        XCTAssertEqual(outcome.suggested, [:])
        XCTAssertEqual(try links(), [pair])
        XCTAssertEqual(try state(id, now), .notApplicable)
    }

    func testTwoEqualBillsOneDebitIsASuggestion() throws {
        let first = try document(date: Self.day(2026, 1, 5), amount: 6_000)
        let second = try document(date: Self.day(2026, 1, 15), amount: 6_000)
        try debit(Self.day(2026, 1, 20), -6_000)
        let outcome = try run(Self.day(2026, 2, 1))
        XCTAssertEqual(outcome.linked, [])
        XCTAssertEqual(outcome.suggested, [first: 1, second: 1])
        XCTAssertEqual(try links(), [])
    }

    func testWeakMatchIsASuggestion() throws {
        let id = try document(date: Self.day(2026, 1, 5), amount: 6_000)
        // 59 days after: outside the utility bill's window (−5…45), within the exact amount's grace.
        let late = try debit(Self.day(2026, 3, 5), -6_000)
        let outcome = try run(Self.day(2026, 3, 10))
        XCTAssertEqual(outcome.linked, [])
        XCTAssertEqual(outcome.suggested, [id: 1])
        XCTAssertEqual(try links(), [])
        XCTAssertEqual(try suggestions(id), [late])
        XCTAssertEqual(try state(id, Self.day(2026, 3, 10)), .waiting)
    }

    /// A legal bill dated in the filed 2024/25 year, its payment of the whole amount 21 days later in 2025/26:
    /// an invoice dates its expenses, so linking would move that payment into the filed return. Refused by
    /// the guard: a suggestion, no link, the return unchanged.
    func testFiledYearLinkBecomesSuggestion() throws {
        let legal = try db.write { db -> Int64 in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var property = Property(name: "Property A", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!,
                                         [PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)])
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: self.account, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            var legal = Category(name: "Legal", type: .expense, groupId: group.id)
            try legal.insert(db)
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            try TaxExpenseTypeMap.set(db: db, categoryId: legal.id!, expenseType: .legalFees)
            for year in [2024, 2025] {
                var rate = HMRCRate(startYear: year, currencyCode: "EUR", gbpPerUnit: 0.85, source: .manual)
                try rate.insert(db)
            }
            return legal.id!
        }
        let paid = try debit(Self.day(2025, 4, 20), -7_995, "PAG ADVOGADOS DEMO 0002", category: legal)
        let bill = try document(.legalInvoice, date: Self.day(2025, 3, 30), amount: 7_995)
        XCTAssertNotNil(EvidenceMatcher.confidentMatch(try db.read { db in try WaitingDocuments.suggestions(db: db, documentId: bill) }),
                        "confident: only the guard stops it")
        let outcome = try run(Self.day(2025, 5, 1))
        XCTAssertEqual(outcome.linked, [])
        XCTAssertEqual(outcome.suggested, [bill: 1])
        XCTAssertEqual(try links(), [])
        XCTAssertEqual(try suggestions(bill), [paid])
        XCTAssertEqual(try state(bill, Self.day(2025, 5, 1)), .waiting)
    }

    func testUndoneLinkIsNotRemade() throws {
        let id = try document(date: Self.day(2026, 1, 10), amount: 6_000)
        let paid = try debit(Self.day(2026, 1, 25), -6_000)
        let now = Self.day(2026, 2, 1)
        let pair = try XCTUnwrap(try run(now).linked.first)
        XCTAssertEqual(pair, WaitingDocuments.Pair(documentId: id, transactionId: paid))
        try db.write { db in try WaitingDocuments.undo(db: db, pair, now: now) }
        XCTAssertEqual(try links(), [])
        XCTAssertEqual(try state(id, now), .waiting)

        let again = try run(Self.day(2026, 2, 2))
        XCTAssertEqual(again.linked, [])
        XCTAssertEqual(try links(), [])
        XCTAssertFalse(try suggestions(id).contains(paid))
        // Undone twice (the row is kept once, its date moved).
        try db.write { db in try WaitingDocuments.undo(db: db, pair, now: Self.day(2026, 2, 3)) }
        XCTAssertEqual(try db.read { db in try AutoLinkDeclined.fetchCount(db) }, 1)
    }

    func testRunTwiceLinksOnce() throws {
        let id = try document(date: Self.day(2026, 1, 10), amount: 6_000)
        let paid = try debit(Self.day(2026, 1, 25), -6_000)
        let now = Self.day(2026, 2, 1)
        XCTAssertEqual(try run(now).linked, [WaitingDocuments.Pair(documentId: id, transactionId: paid)])
        XCTAssertEqual(try run(now), WaitingDocuments.Outcome())
        XCTAssertEqual(try links().count, 1)
    }

    func testTakenDebitIsNotAutoLinked() throws {
        let paid = try debit(Self.day(2026, 1, 25), -6_000)
        let other = try document(date: Self.day(2026, 1, 8), amount: 6_000)
        try db.write { db in try EvidenceLinks.link(db: db, documentId: other, to: .transaction(paid)) }
        let id = try document(date: Self.day(2026, 1, 10), amount: 6_000)
        let outcome = try run(Self.day(2026, 2, 1))
        XCTAssertEqual(outcome.linked, [])
        XCTAssertEqual(outcome.suggested, [id: 1])
        XCTAssertEqual(try links(), [WaitingDocuments.Pair(documentId: other, transactionId: paid)])
    }

    /// The bills tracker has the utility invoice paid (its debit recorded): the document isn't waiting, and
    /// the job gives it the link to that debit; the invoice keeps its debit and its "linked to payment" stage.
    func testUtilityInvoiceKeepsBillsTrackerStage() throws {
        let (propertyId, tenancyId, provider) = try db.write { db -> (Int64, Int64, Int64) in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account, role: .current)
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Room A", contractNumber: "1", startDate: Self.day(2025, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            var power = UtilityProvider(propertyId: property.id!, name: "Example Power", kind: .electricity, bankDescriptionPattern: "EXAMPLE POWER")
            try Recharges.saveProvider(db: db, &power)
            return (property.id!, tenancy.id!, power.id!)
        }
        let paid = try debit(Self.day(2026, 1, 25), -6_000, "EXAMPLE POWER DD 0001")
        let doc = try document(date: Self.day(2026, 1, 10), amount: 6_000)
        let invoiceId = try db.write { db -> Int64 in
            var invoice = UtilityInvoice(providerId: provider, issueDate: Self.day(2026, 1, 10), amountMinorUnits: 6_000, documentId: doc,
                                         transactionId: paid)
            try Recharges.saveInvoice(db: db, &invoice)
            return invoice.id!
        }
        func stage() throws -> UtilityBillStage? {
            try db.read { db in try UtilityBills.read(db: db, propertyId: propertyId, tenancyId: tenancyId) }
                .bills.first { $0.invoice?.id == invoiceId }?.stage
        }
        let now = Self.day(2026, 2, 1)
        XCTAssertEqual(try state(doc, now), .notApplicable)
        XCTAssertEqual(try stage(), .linkedToPayment)

        let outcome = try run(now)
        let pair = WaitingDocuments.Pair(documentId: doc, transactionId: paid)
        XCTAssertEqual(outcome.linked, [pair])
        XCTAssertEqual(try links(), [pair])
        XCTAssertEqual(try stage(), .linkedToPayment)
        XCTAssertEqual(try db.read { db in try UtilityInvoice.fetchOne(db, key: invoiceId) }?.transactionId, paid)
        XCTAssertEqual(try run(now), WaitingDocuments.Outcome())
    }
}
