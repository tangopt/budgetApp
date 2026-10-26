import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The missing-evidence checklist (spec 2026-10-16 §7): requirements as data, waivers,
/// satisfaction by linked documents, progress by source, Markdown export, default rules.
final class MissingEvidenceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }

    private var bbva: Int64 = 0
    private var mortgage: Int64 = 0
    private var batch: Int64 = 0
    private var lisbon: Int64 = 0
    private var imi: Int64 = 0
    private var condominio: Int64 = 0
    private var repairs: Int64 = 0
    private var mortgageTransfer: Int64 = 0
    private var groceries: Int64 = 0

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var account = Account(name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            bbva = account.id!
            var loan = Account(name: "BBVA mortgage", currency: .eur, kind: .credit, trackingMode: .imported, includeInNetWorth: false)
            try loan.insert(db)
            mortgage = loan.id!
            var importBatch = ImportBatch(accountId: bbva, sourceFileName: "bbva.xlsx", importedAt: Date())
            try importBatch.insert(db)
            batch = importBatch.id!
            var group = CategoryGroup(name: "Lisbon", type: .expense)
            try group.insert(db)
            lisbon = group.id!
            imi = try insertCategory(db, "IMI", .expense, group: lisbon)
            condominio = try insertCategory(db, "Condomínio", .expense, group: lisbon)
            repairs = try insertCategory(db, "Repairs", .expense, group: lisbon)
            groceries = try insertCategory(db, "Groceries", .expense, group: nil)
            var transfer = Category(name: "Transfer: BBVA mortgage", type: .transfer, transferAccountId: mortgage)
            try transfer.insert(db)
            mortgageTransfer = transfer.id!
        }
    }

    private func insertCategory(_ db: Database, _ name: String, _ type: CategoryType, group: Int64?) throws -> Int64 {
        var category = Category(name: name, type: type, groupId: group)
        try category.insert(db)
        return category.id!
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @discardableResult
    private func transaction(_ date: Date, _ amount: Int, category: Int64?, description: String = "Movement", account: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var t = Transaction(importBatchId: batch, accountId: account ?? bbva, date: date, rawDescription: description,
                                amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual,
                                fingerprint: UUID().uuidString)
            try t.insert(db)
            return t.id!
        }
    }

    @discardableResult
    private func document(_ kind: DocumentKind, docDate: Date? = nil, periodStart: Date? = nil, periodEnd: Date? = nil,
                          name: String = "Doc", linkedTo entity: EvidenceEntity? = nil) throws -> Int64 {
        try db.write { db in
            let sha = UUID().uuidString
            var document = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha.prefix(2))/\(sha).pdf", originalFileName: "\(name).pdf",
                                            byteCount: 1, canonicalName: name, kind: kind, docDate: docDate, periodStart: periodStart,
                                            periodEnd: periodEnd, addedAt: Date())
            try document.insert(db)
            if let entity { try EvidenceLinks.link(db: db, documentId: document.id!, to: entity) }
            return document.id!
        }
    }

    @discardableResult
    private func requirement(_ name: String, _ scope: EvidenceRequirementScope, kinds: [DocumentKind], direction: EvidenceTransactionDirection = .outflows,
                             source: String? = nil, from: Date? = nil, to: Date? = nil) throws -> EvidenceRequirement {
        try db.write { db in
            var r = EvidenceRequirement(name: name, scope: scope, kinds: kinds, direction: direction, usualSource: source, activeFrom: from, activeTo: to)
            try EvidenceRequirements.save(db: db, &r)
            return r
        }
    }

    private func items(_ period: DateInterval) throws -> [MissingEvidence.Item] {
        try db.read { try MissingEvidence.items(db: $0, period: period) }
    }

    private let year2025 = UKTaxYear(startYear: 2025)

    // MARK: Tax year

    func testUKTaxYearRunsSixthAprilToFifthApril() {
        XCTAssertEqual(year2025.start, Self.date(2025, 4, 6))
        XCTAssertEqual(year2025.end, Self.date(2026, 4, 6))
        XCTAssertEqual(year2025.lastDay, Self.date(2026, 4, 5))
        XCTAssertEqual(year2025.label, "2025/26")
        XCTAssertEqual(UKTaxYear(startYear: 2099).label, "2099/00")
        XCTAssertEqual(UKTaxYear.containing(Self.date(2025, 4, 5)), UKTaxYear(startYear: 2024))
        XCTAssertEqual(UKTaxYear.containing(Self.date(2025, 4, 6)), year2025)
        XCTAssertEqual(UKTaxYear.containing(Self.date(2026, 1, 31)), year2025)
        XCTAssertEqual(UKTaxYear.containing(Self.date(2026, 4, 5)), year2025)
        XCTAssertTrue(UKTaxYear(startYear: 2024) < year2025)
    }

    func testTaxYearChecklistIncludesBoundaryDays() throws {
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice])
        try transaction(Self.date(2025, 4, 5), -100, category: imi)   // 2024/25
        let first = try transaction(Self.date(2025, 4, 6), -200, category: imi)
        let last = try transaction(Self.date(2026, 4, 5), -300, category: imi)
        try transaction(Self.date(2026, 4, 6), -400, category: imi)   // 2026/27
        let result = try db.read { try MissingEvidence.items(db: $0, taxYear: year2025) }
        XCTAssertEqual(result.map(\.target), [.transaction(first), .transaction(last)])
    }

    // MARK: Scopes

    func testCategoryScopeCoversOutflowsOnlyByDefault() throws {
        let r = try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice, .imiPayment], source: "Portal das Finanças")
        let debit = try transaction(Self.date(2025, 5, 2), -31_250, category: imi, description: "IMI 1a prestacao")
        try transaction(Self.date(2025, 5, 3), 1_000, category: imi, description: "Refund")
        try transaction(Self.date(2025, 5, 4), -500, category: groceries)
        let result = try items(year2025.interval)
        XCTAssertEqual(result.count, 1)
        let item = try XCTUnwrap(result.first)
        XCTAssertEqual(item.target, .transaction(debit))
        XCTAssertEqual(item.requirement.id, r.id)
        XCTAssertEqual(item.expectedDate, Self.date(2025, 5, 2))
        XCTAssertEqual(item.expectedAmountMinorUnits, 31_250)
        XCTAssertEqual(item.currency, .eur)
        XCTAssertEqual(item.expectedKinds, [.imiNotice, .imiPayment])
        XCTAssertEqual(item.title, "IMI 1a prestacao")
        XCTAssertEqual(item.categoryName, "IMI")
        XCTAssertEqual(item.accountName, "BBVA")
        XCTAssertEqual(item.usualSource, "Portal das Finanças")
        XCTAssertEqual(item.status, .missing)
    }

    func testDirectionAnyAndInflows() throws {
        try requirement("Any", .transactionsInCategory(categoryId: imi), kinds: [], direction: .any)
        try requirement("In", .transactionsInCategory(categoryId: imi), kinds: [], direction: .inflows)
        try transaction(Self.date(2025, 5, 2), -100, category: imi)
        try transaction(Self.date(2025, 5, 3), 100, category: imi)
        let result = try items(year2025.interval)
        XCTAssertEqual(result.filter { $0.requirement.name == "Any" }.count, 2)
        XCTAssertEqual(result.filter { $0.requirement.name == "In" }.map(\.expectedDate), [Self.date(2025, 5, 3)])
    }

    func testGroupScopeCoversEveryCategoryInTheGroupIncludingLaterOnes() throws {
        try requirement("Lisbon", .transactionsInCategoryGroup(groupId: lisbon), kinds: [])
        try transaction(Self.date(2025, 5, 2), -100, category: imi)
        try transaction(Self.date(2025, 6, 2), -200, category: condominio)
        try transaction(Self.date(2025, 6, 3), -300, category: groceries)
        let later = try db.write { try insertCategory($0, "Legal fees", .expense, group: lisbon) }
        try transaction(Self.date(2025, 7, 1), -400, category: later)
        XCTAssertEqual(try items(year2025.interval).map(\.expectedAmountMinorUnits), [100, 200, 400])
    }

    func testMatchingScopeCombinesCriteria() throws {
        try requirement("Instalments", .transactionsMatching(categoryIds: [mortgageTransfer], accountIds: [bbva], descriptionContains: "prest"),
                        kinds: [.mortgageNotice])
        let hit = try transaction(Self.date(2025, 5, 2), -90_000, category: mortgageTransfer, description: "COBR PRESTACAO 123")
        try transaction(Self.date(2025, 5, 3), -90_000, category: mortgageTransfer, description: "Other")
        try transaction(Self.date(2025, 5, 4), -90_000, category: imi, description: "prestacao")
        try transaction(Self.date(2025, 5, 5), -90_000, category: mortgageTransfer, description: "prestacao", account: mortgage)
        XCTAssertEqual(try items(year2025.interval).map(\.target), [.transaction(hit)])
    }

    func testMatchingDescriptionEscapesWildcards() throws {
        try requirement("Percent", .transactionsMatching(categoryIds: [], accountIds: [], descriptionContains: "50%"), kinds: [])
        try transaction(Self.date(2025, 5, 2), -1, category: nil, description: "Fee 50% off")
        try transaction(Self.date(2025, 5, 3), -1, category: nil, description: "Fee 500 off")
        XCTAssertEqual(try items(year2025.interval).map(\.title), ["Fee 50% off"])
    }

    func testMatchingWithoutCriteriaIsRejected() throws {
        XCTAssertThrowsError(try requirement("All", .transactionsMatching(categoryIds: [], accountIds: [], descriptionContains: "  "), kinds: [])) {
            XCTAssertEqual($0 as? EvidenceRequirementError, .noMatchingCriteria)
        }
        XCTAssertThrowsError(try requirement("  ", .transactionsInCategory(categoryId: imi), kinds: [])) {
            XCTAssertEqual($0 as? EvidenceRequirementError, .blankName)
        }
        XCTAssertThrowsError(try requirement("Range", .transactionsInCategory(categoryId: imi), kinds: [],
                                             from: Self.date(2025, 1, 1), to: Self.date(2025, 1, 1))) {
            XCTAssertEqual($0 as? EvidenceRequirementError, .invalidActiveRange)
        }
    }

    func testActiveWindowLimitsTransactionsAndSlots() throws {
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [], from: Self.date(2025, 6, 1), to: Self.date(2025, 9, 1))
        try transaction(Self.date(2025, 5, 31), -1, category: imi)
        try transaction(Self.date(2025, 6, 1), -2, category: imi)
        try transaction(Self.date(2025, 8, 31), -3, category: imi)
        try transaction(Self.date(2025, 9, 1), -4, category: imi)
        try requirement("Rent", .periodic(entity: .account(bbva), every: .month), kinds: [.rentReceipt],
                        from: Self.date(2026, 1, 1))
        try requirement("Expired", .single(entity: .account(bbva)), kinds: [], to: Self.date(2025, 4, 6))
        let result = try items(year2025.interval)
        XCTAssertEqual(result.filter { $0.requirement.name == "IMI" }.map(\.expectedAmountMinorUnits), [2, 3])
        // Slots 6 Dec–5 Jan … 6 Mar–5 Apr overlap the window from 1 Jan.
        XCTAssertEqual(result.filter { $0.requirement.name == "Rent" }.map { $0.expectedPeriod!.start },
                       [Self.date(2025, 12, 6), Self.date(2026, 1, 6), Self.date(2026, 2, 6), Self.date(2026, 3, 6)])
        XCTAssertFalse(result.contains { $0.requirement.name == "Expired" })
    }

    // MARK: Satisfaction

    func testTransactionSatisfiedByLinkedDocumentOfExpectedKind() throws {
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice, .imiPayment])
        let a = try transaction(Self.date(2025, 5, 2), -100, category: imi)
        let b = try transaction(Self.date(2025, 6, 2), -100, category: imi)
        let c = try transaction(Self.date(2025, 7, 2), -100, category: imi)
        let notice = try document(.imiPayment, name: "Payment", linkedTo: .transaction(a))
        try document(.bankStatement, linkedTo: .transaction(b))   // wrong kind
        try document(.imiNotice, name: "Unlinked")               // not linked
        let result = try items(year2025.interval)
        XCTAssertEqual(result.map(\.status), [.satisfied, .missing, .missing])
        XCTAssertEqual(result[0].satisfyingDocuments.map(\.id), [notice])
        XCTAssertEqual(result[1].satisfyingDocuments, [])
        XCTAssertEqual(result[2].target, .transaction(c))
    }

    /// One bill paid in two instalments: the document linked to both debits satisfies both.
    func testOneDocumentLinkedToTwoDebitsSatisfiesBothInMissingEvidence() throws {
        try requirement("Repairs", .transactionsInCategory(categoryId: repairs), kinds: [.repairInvoice])
        let first = try transaction(Self.date(2025, 5, 2), -4_000, category: repairs, description: "PAG CANALIZACOES EXEMPLO 0001")
        let second = try transaction(Self.date(2025, 5, 22), -3_995, category: repairs, description: "PAG CANALIZACOES EXEMPLO 0002")
        let bill = try document(.repairInvoice, docDate: Self.date(2025, 5, 2), name: "Repair bill", linkedTo: .transaction(first))
        XCTAssertEqual(try items(year2025.interval).map(\.status), [.satisfied, .missing])
        try db.write { db in _ = try EvidenceLinks.link(db: db, documentId: bill, to: .transaction(second)) }
        let result = try items(year2025.interval)
        XCTAssertEqual(result.map(\.status), [.satisfied, .satisfied])
        XCTAssertEqual(result.map { $0.satisfyingDocuments.map(\.id) }, [[bill], [bill]])
    }

    /// A bank statement linked to three fee debits, under a rule that takes statements: three satisfied.
    func testStatementLinkedToThreeFeeDebitsSatisfiesThree() throws {
        let fees = try db.write { db in try insertCategory(db, "Bank fees", .expense, group: nil) }
        try requirement("Bank fees", .transactionsInCategory(categoryId: fees), kinds: [.bankStatement])
        let debits = try [5, 6, 7].map { month in try transaction(Self.date(2025, month, 3), -250, category: fees, description: "COMISSAO MANUTENCAO") }
        let statement = try document(.bankStatement, docDate: Self.date(2025, 7, 31), name: "Statement", linkedTo: .transaction(debits[0]))
        try db.write { db in
            for id in debits.dropFirst() { _ = try EvidenceLinks.link(db: db, documentId: statement, to: .transaction(id)) }
        }
        let result = try items(year2025.interval)
        XCTAssertEqual(result.map(\.status), [.satisfied, .satisfied, .satisfied])
        XCTAssertEqual(result.map(\.target.entity), debits.map(EvidenceEntity.transaction))
    }

    func testMissingEvidenceSatisfiedByACustomKind() throws {
        let boiler = try db.write { db in try XCTUnwrap(try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id) }
        try db.write { db in
            var r = EvidenceRequirement(name: "Repairs", scope: .transactionsInCategory(categoryId: repairs), kinds: [.repairInvoice],
                                        customKindIds: [boiler])
            try EvidenceRequirements.save(db: db, &r)
        }
        let custom = try transaction(Self.date(2025, 5, 2), -8_000, category: repairs)
        let builtIn = try transaction(Self.date(2025, 6, 2), -5_000, category: repairs)
        let plain = try transaction(Self.date(2025, 7, 2), -6_000, category: repairs)
        let service = try document(.other, name: "Boiler service", linkedTo: .transaction(custom))
        try db.write { db in try db.execute(sql: "UPDATE document SET customKindId = ? WHERE id = ?", arguments: [boiler, service]) }
        try document(.repairInvoice, name: "Repair bill", linkedTo: .transaction(builtIn))
        try document(.other, name: "Unknown kind", linkedTo: .transaction(plain))
        let result = try items(year2025.interval)
        XCTAssertEqual(result.map(\.status), [.satisfied, .satisfied, .missing])
        XCTAssertEqual(result[0].satisfyingDocuments.map(\.id), [service])
        XCTAssertEqual(result[0].expectedKinds, [.repairInvoice])
        XCTAssertEqual(result[0].expectedKindRefs, [.builtIn(.repairInvoice), .custom(boiler)])
        XCTAssertEqual(result[0].expectedKindNames, ["Repair bill", "Boiler service"])
        XCTAssertTrue(MissingEvidence.markdownLine(result[2]).hasSuffix("needs Repair bill or Boiler service"), MissingEvidence.markdownLine(result[2]))
        // Link existing… offers the custom kind's documents too, named by it.
        let loose = try document(.other, docDate: Self.date(2025, 7, 2), name: "Boiler, not linked")
        try db.write { db in try db.execute(sql: "UPDATE document SET customKindId = ? WHERE id = ?", arguments: [boiler, loose]) }
        let summaries = try db.read { try EvidenceDocumentSummary.fetchAll($0) }
        let candidates = MissingEvidence.candidates(for: result[2], documents: summaries)
        XCTAssertEqual(candidates.map(\.documentId), [loose], "the plain Other document isn't of an expected kind")
        XCTAssertEqual(candidates.first?.reasons, ["Boiler service", "Same day"])

        // A custom-only rule: a dropped document of no kind is filed as the custom kind.
        let onlyCustom = try db.write { db -> EvidenceRequirement in
            var r = EvidenceRequirement(name: "Boiler", scope: .transactionsInCategory(categoryId: groceries), kinds: [], customKindIds: [boiler])
            try EvidenceRequirements.save(db: db, &r)
            return r
        }
        try transaction(Self.date(2025, 8, 2), -1_000, category: groceries)
        let item = try XCTUnwrap(try items(year2025.interval).first { $0.requirement.id == onlyCustom.id })
        XCTAssertEqual(item.expectedKinds, [])
        let (filled, what) = MissingEvidence.filledIn(EvidenceDocumentDetails(), for: item)
        XCTAssertEqual(filled.kindRef, .custom(boiler))
        XCTAssertEqual(what, ["kind Boiler service"])
        XCTAssertNil(MissingEvidence.shortfall(of: filled, for: item))
        XCTAssertEqual(MissingEvidence.shortfall(of: EvidenceDocumentDetails(kind: .p60), for: item), "it's filed as P60 and this needs Boiler service")
    }

    /// An id that names no kind (deleted, merged away, or not yet arrived by sync — stored as 0) is as if it
    /// weren't there: a rule left with no kinds accepts any document.
    func testUnknownCustomKindIdsAreIgnored() throws {
        let deadOnly = EvidenceRequirement(name: "Dead", scope: .transactionsInCategory(categoryId: 1), kinds: [], customKindIds: [0])
        XCTAssertTrue(deadOnly.accepts(.builtIn(.other)))
        XCTAssertTrue(deadOnly.accepts(.custom(5)))
        let mixed = EvidenceRequirement(name: "Mixed", scope: .transactionsInCategory(categoryId: 1), kinds: [.repairInvoice], customKindIds: [0])
        XCTAssertTrue(mixed.accepts(.builtIn(.repairInvoice)))
        XCTAssertFalse(mixed.accepts(.builtIn(.other)))
        XCTAssertFalse(mixed.accepts(.custom(0)))

        // A stored rule naming a kind that no longer exists counts any document, like a rule without kinds.
        try db.write { db in
            var r = EvidenceRequirement(name: "Repairs", scope: .transactionsInCategory(categoryId: repairs), kinds: [], customKindIds: [404])
            try EvidenceRequirements.save(db: db, &r)
        }
        let paid = try transaction(Self.date(2025, 5, 2), -8_000, category: repairs)
        try document(.bankDebitAdvice, name: "Advice", linkedTo: .transaction(paid))
        let result = try items(year2025.interval)
        XCTAssertEqual(result.map(\.status), [.satisfied])
        XCTAssertEqual(result[0].requirement.customKindIds, [])
        XCTAssertEqual(result[0].expectedKindRefs, [])
    }

    func testRepairsRuleAcceptsRepairBillsAndOtherButNotABankAdviceAlone() throws {
        try requirement("Repairs", .transactionsInCategory(categoryId: repairs), kinds: EvidenceRequirementDefaults.rule(forCategoryName: "Repairs").kinds)
        let bill = try transaction(Self.date(2025, 5, 2), -7_995, category: repairs)
        let older = try transaction(Self.date(2025, 6, 2), -5_000, category: repairs)
        let adviceOnly = try transaction(Self.date(2025, 7, 2), -6_000, category: repairs)
        try document(.repairInvoice, name: "Repair bill", linkedTo: .transaction(bill))
        try document(.other, name: "Filed before the kind existed", linkedTo: .transaction(older))
        try document(.bankDebitAdvice, name: "Advice", linkedTo: .transaction(adviceOnly))
        XCTAssertEqual(try items(year2025.interval).map(\.status), [.satisfied, .satisfied, .missing])
    }

    func testEmptyKindsAcceptAnyDocument() throws {
        try requirement("Repairs", .transactionsInCategory(categoryId: repairs), kinds: [])
        let t = try transaction(Self.date(2025, 5, 2), -100, category: repairs)
        try document(.other, linkedTo: .transaction(t))
        XCTAssertEqual(try items(year2025.interval).map(\.status), [.satisfied])
    }

    func testPeriodicSlotsFollowThePeriodStart() {
        let months = MissingEvidence.slots(of: year2025.interval, every: .month)
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(months.first, DateInterval(start: Self.date(2025, 4, 6), end: Self.date(2025, 5, 6)))
        XCTAssertEqual(months.last, DateInterval(start: Self.date(2026, 3, 6), end: Self.date(2026, 4, 6)))
        let quarters = MissingEvidence.slots(of: DateInterval(start: Self.date(2025, 1, 1), end: Self.date(2025, 8, 1)), every: .quarter)
        XCTAssertEqual(quarters.map(\.start), [Self.date(2025, 1, 1), Self.date(2025, 4, 1), Self.date(2025, 7, 1)])
        XCTAssertEqual(quarters.last?.end, Self.date(2025, 8, 1))
        XCTAssertEqual(MissingEvidence.slots(of: year2025.interval, every: .year), [year2025.interval])
    }

    func testPeriodicSatisfiedByLinkedDocumentDatedOrCoveringTheSlot() throws {
        let calendarYear = DateInterval(start: Self.date(2025, 1, 1), end: Self.date(2026, 1, 1))
        try requirement("Condomínio", .periodic(entity: .account(bbva), every: .quarter), kinds: [.condominioReceipt], source: "Administrator")
        // Q1 by docDate, Q2 by covered period, Q3 a receipt for one month inside it; Q4 missing.
        try document(.condominioReceipt, docDate: Self.date(2025, 2, 10), linkedTo: .account(bbva))
        try document(.condominioReceipt, docDate: Self.date(2025, 3, 1), periodStart: Self.date(2025, 4, 1), periodEnd: Self.date(2025, 6, 30),
                     linkedTo: .account(bbva))
        try document(.condominioReceipt, periodStart: Self.date(2025, 9, 1), periodEnd: Self.date(2025, 9, 30), linkedTo: .account(bbva))
        try document(.condominioReceipt, docDate: Self.date(2025, 11, 1), linkedTo: .account(mortgage))   // other entity
        try document(.insuranceReceipt, docDate: Self.date(2025, 11, 2), linkedTo: .account(bbva))         // other kind
        let result = try items(calendarYear)
        XCTAssertEqual(result.map(\.status), [.satisfied, .satisfied, .satisfied, .missing])
        XCTAssertEqual(result.map(\.target.entity), Array(repeating: .account(bbva), count: 4))
        XCTAssertEqual(result[3].expectedPeriod, DateInterval(start: Self.date(2025, 10, 1), end: Self.date(2026, 1, 1)))
        XCTAssertEqual(result[3].title, "Condomínio")
    }

    func testDocumentCoverageNeedsHalfOfSlotOrDocument() {
        func doc(_ start: Date?, _ end: Date?, date: Date? = nil) -> EvidenceDocumentSummary {
            EvidenceDocumentSummary(id: 1, sha256: "", storedRelativePath: "", originalFileName: "", byteCount: 0, canonicalName: nil,
                                    kind: .rentReceipt, docDate: date, periodStart: start, periodEnd: end, amountMinorUnits: nil,
                                    currency: nil, persons: [], textStatus: .unknown, sourceFolderId: nil, sourceRelativePath: nil,
                                    sourceModifiedAt: nil, addedAt: Date(), note: nil)
        }
        let april = DateInterval(start: Self.date(2025, 4, 6), end: Self.date(2025, 5, 6))
        let march = DateInterval(start: Self.date(2025, 3, 6), end: Self.date(2025, 4, 6))
        let aprilRent = doc(Self.date(2025, 4, 1), Self.date(2025, 4, 30))
        XCTAssertTrue(MissingEvidence.covers(aprilRent, slot: april))
        XCTAssertFalse(MissingEvidence.covers(aprilRent, slot: march))
        let annual = doc(Self.date(2025, 1, 1), Self.date(2025, 12, 31))
        XCTAssertTrue(MissingEvidence.covers(annual, slot: april))
        XCTAssertTrue(MissingEvidence.covers(annual, slot: year2025.interval))
        XCTAssertFalse(MissingEvidence.covers(annual, slot: UKTaxYear(startYear: 2023).interval))
        XCTAssertTrue(MissingEvidence.covers(doc(nil, nil, date: Self.date(2025, 4, 6)), slot: april))
        XCTAssertFalse(MissingEvidence.covers(doc(nil, nil, date: Self.date(2025, 5, 6)), slot: april))
        XCTAssertFalse(MissingEvidence.covers(doc(nil, nil), slot: april))
    }

    func testSingleSatisfiedByAnyLinkedDocumentOfKind() throws {
        try db.write { db in var property = Property(id: 1, name: "Property A", country: "PT"); try Properties.save(db: db, &property) }
        try requirement("Deed", .single(entity: EvidenceEntity(type: .property, id: 1)), kinds: [.propertyDeed])
        try requirement("P60", .single(entity: EvidenceEntity(type: .taxYear, id: 2025)), kinds: [.p60])
        try document(.propertyDeed, docDate: Self.date(2016, 7, 4), linkedTo: EvidenceEntity(type: .property, id: 1))
        let result = try items(year2025.interval)
        XCTAssertEqual(result.map(\.title), ["Deed", "P60"])
        XCTAssertEqual(result.map(\.status), [.satisfied, .missing])
        XCTAssertNil(result[1].expectedPeriod)
    }

    // MARK: Waivers

    func testWaiversMarkItemsDoneAndCanBeRemoved() throws {
        let r = try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice])
        let rent = try requirement("Rent", .periodic(entity: .account(bbva), every: .month), kinds: [.rentReceipt])
        let t = try transaction(Self.date(2025, 5, 2), -100, category: imi)
        let slot = MissingEvidence.slots(of: year2025.interval, every: .month)[2]
        try db.write { db in
            try EvidenceRequirements.waive(db: db, requirementId: r.id!, target: .transaction(t), note: "Lost")
            try EvidenceRequirements.waive(db: db, requirementId: rent.id!, target: .init(entity: .account(bbva), slot: slot), reason: .other)
            // Re-waiving updates in place.
            let again = try EvidenceRequirements.waive(db: db, requirementId: r.id!, target: .transaction(t), note: "Bank won't reissue")
            XCTAssertEqual(again.note, "Bank won't reissue")
            XCTAssertEqual(try EvidenceRequirements.waivers(db: db, requirementId: r.id!).count, 1)
        }
        var result = try items(year2025.interval)
        let imiItem = try XCTUnwrap(result.first { $0.requirement.id == r.id })
        XCTAssertEqual(imiItem.status, .waived)
        XCTAssertEqual(imiItem.waiver?.reason, .notAvailable)
        XCTAssertEqual(imiItem.waiver?.note, "Bank won't reissue")
        let rentItems = result.filter { $0.requirement.id == rent.id }
        XCTAssertEqual(rentItems.map(\.status).filter { $0 == .waived }.count, 1)
        XCTAssertEqual(rentItems[2].status, .waived)

        // A document satisfies even when waived.
        try document(.imiNotice, linkedTo: .transaction(t))
        result = try items(year2025.interval)
        XCTAssertEqual(result.first { $0.requirement.id == r.id }?.status, .satisfied)

        try db.write { db in
            XCTAssertTrue(try EvidenceRequirements.removeWaiver(db: db, requirementId: rent.id!, target: .init(entity: .account(bbva), slot: slot)))
            XCTAssertFalse(try EvidenceRequirements.removeWaiver(db: db, requirementId: rent.id!, target: .init(entity: .account(bbva), slot: slot)))
        }
        XCTAssertFalse(try items(year2025.interval).contains { $0.status == .waived })
    }

    func testWaiversGoWithTheirRequirementOrTransaction() throws {
        let r = try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [])
        let other = try requirement("Group", .transactionsInCategoryGroup(groupId: lisbon), kinds: [])
        let t = try transaction(Self.date(2025, 5, 2), -100, category: imi)
        try db.write { db in
            try EvidenceRequirements.waive(db: db, requirementId: r.id!, target: .transaction(t))
            try EvidenceRequirements.waive(db: db, requirementId: other.id!, target: .transaction(t))
            XCTAssertThrowsError(try EvidenceRequirements.waive(db: db, requirementId: 999, target: .transaction(t)))
            XCTAssertTrue(try EvidenceRequirements.delete(db: db, id: r.id!))
            XCTAssertEqual(try EvidenceWaiver.fetchCount(db), 1)
            _ = try Transaction.deleteOne(db, key: t)
            XCTAssertEqual(try EvidenceWaiver.fetchCount(db), 0)
        }
    }

    // MARK: Progress and export

    func testProgressBySource() throws {
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [], source: "Portal das Finanças")
        let condo = try requirement("Condo", .transactionsInCategory(categoryId: condominio), kinds: [], source: "Administrator")
        try requirement("Repairs", .transactionsInCategory(categoryId: repairs), kinds: [])
        let a = try transaction(Self.date(2025, 5, 2), -100, category: imi)
        try transaction(Self.date(2025, 5, 3), -100, category: imi)
        let c = try transaction(Self.date(2025, 5, 4), -100, category: condominio)
        try transaction(Self.date(2025, 5, 5), -100, category: repairs)
        try document(.imiNotice, linkedTo: .transaction(a))
        _ = try db.write { try EvidenceRequirements.waive(db: $0, requirementId: condo.id!, target: .transaction(c)) }

        let result = try items(year2025.interval)
        XCTAssertEqual(result.map(\.sourceName), ["Administrator", "Portal das Finanças", "Portal das Finanças", "Other"])
        let overall = MissingEvidence.progress(result)
        XCTAssertEqual(overall, MissingEvidence.Progress(total: 4, satisfied: 1, waived: 1))
        XCTAssertEqual(overall.missing, 2)
        XCTAssertEqual(overall.percentDone, 50)
        XCTAssertEqual(overall.fractionDone, 0.5)
        let groups = MissingEvidence.bySource(result)
        XCTAssertEqual(groups.map(\.source), ["Administrator", "Portal das Finanças", "Other"])
        XCTAssertEqual(groups.map(\.progress.done), [1, 1, 0])
        XCTAssertEqual(groups.map(\.progress.total), [1, 2, 1])
        XCTAssertEqual(MissingEvidence.Progress().percentDone, 100)
        XCTAssertEqual(MissingEvidence.Progress(total: 3, satisfied: 2).percentDone, 66)
    }

    func testMarkdownExport() throws {
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice, .imiPayment], source: "Portal das Finanças")
        let condo = try requirement("Condomínio", .transactionsInCategory(categoryId: condominio), kinds: [.condominioReceipt], source: "Administrator")
        try requirement("Rent", .periodic(entity: .account(bbva), every: .year), kinds: [.rentReceipt], source: "Portal das Finanças")
        let a = try transaction(Self.date(2025, 5, 2), -31_250, category: imi, description: "IMI *1a*")
        try transaction(Self.date(2025, 9, 2), -31_250, category: imi, description: "IMI 2a")
        let c = try transaction(Self.date(2025, 6, 1), -12_000, category: condominio, description: "Quota")
        try document(.imiNotice, name: "20250401 - Lisbon - IMI - Nota 2024", linkedTo: .transaction(a))
        _ = try db.write { try EvidenceRequirements.waive(db: $0, requirementId: condo.id!, target: .transaction(c), note: "Administrator closed") }

        let result = try items(year2025.interval)
        let markdown = MissingEvidence.markdown(items: result, title: "Missing evidence 2025/26", period: year2025.interval)
        XCTAssertEqual(markdown, """
            # Missing evidence 2025/26

            Period 2025-04-06 to 2026-04-05 · 2 of 4 done (50%) · 2 missing

            ## Administrator — 1 of 1 done

            - [x] ~~2025-06-01 · Quota · €120.00 · Condomínio · BBVA~~ — not available: Administrator closed

            ## Portal das Finanças — 1 of 3 done

            - [ ] 2025-04-06 to 2026-04-05 · Rent — needs Rent receipt
            - [x] 2025-05-02 · IMI \\*1a\\* · €312.50 · IMI · BBVA — 20250401 - Lisbon - IMI - Nota 2024
            - [ ] 2025-09-02 · IMI 2a · €312.50 · IMI · BBVA — needs IMI notice or IMI payment

            """)
    }

    func testLinkedTransferIncomingLegNeedsNoEvidence() throws {
        try requirement("Transfers", .transactionsInCategory(categoryId: mortgageTransfer), kinds: [], direction: .any)
        let out = try transaction(Self.date(2025, 5, 2), -90_000, category: mortgageTransfer)
        let incoming = try transaction(Self.date(2025, 5, 2), 90_000, category: mortgageTransfer, account: mortgage)
        let dismissedIn = try transaction(Self.date(2025, 6, 2), 90_000, category: mortgageTransfer, account: mortgage)
        let dismissedOut = try transaction(Self.date(2025, 6, 2), -90_000, category: mortgageTransfer)
        try db.write { db in
            var link = TransferLink(outTransactionId: out, inTransactionId: incoming, origin: .auto)
            try link.insert(db)
            var dismissed = TransferLink(outTransactionId: dismissedOut, inTransactionId: dismissedIn, origin: .auto, isDismissed: true)
            try dismissed.insert(db)
        }
        XCTAssertEqual(Set(try items(year2025.interval).map(\.target)), [.transaction(out), .transaction(dismissedIn), .transaction(dismissedOut)])
    }

    func testExcludedAccountsAreLeftOut() throws {
        try db.write { db in
            var r = EvidenceRequirement(name: "IMI", scope: .transactionsInCategory(categoryId: imi), kinds: [], excludedAccountIds: [mortgage, mortgage])
            try EvidenceRequirements.save(db: db, &r)
            XCTAssertEqual(r.excludedAccountIds, [mortgage])
        }
        let kept = try transaction(Self.date(2025, 5, 2), -1, category: imi)
        try transaction(Self.date(2025, 5, 2), -2, category: imi, account: mortgage)
        XCTAssertEqual(try items(year2025.interval).map(\.target), [.transaction(kept)])
    }

    func testWaiversGoWithDeletedAccountsAndCategories() throws {
        let rent = try requirement("Rent", .single(entity: .account(mortgage)), kinds: [])
        let cat = try requirement("Cat", .single(entity: .category(groceries)), kinds: [])
        try db.write { db in
            try EvidenceRequirements.waive(db: db, requirementId: rent.id!, target: .init(entity: .account(mortgage)))
            try EvidenceRequirements.waive(db: db, requirementId: cat.id!, target: .init(entity: .category(groceries)))
            try EvidenceRequirements.waive(db: db, requirementId: cat.id!, target: .init(entity: .category(imi)))
            _ = try Category.deleteOne(db, key: groceries)
            XCTAssertEqual(try EvidenceWaiver.fetchCount(db), 2)
            try Category.filter(Column("transferAccountId") == mortgage).deleteAll(db)
            _ = try Account.deleteOne(db, key: mortgage)
            XCTAssertEqual(try EvidenceWaiver.fetchAll(db).map(\.entity), [.category(imi)])
        }
    }

    func testMarkdownEscapesStructure() throws {
        try db.write { db in
            var r = EvidenceRequirement(name: "Deed", scope: .single(entity: .account(bbva)), kinds: [.propertyDeed], usualSource: "# Notary | <b>")
            try EvidenceRequirements.save(db: db, &r)
            var t = EvidenceRequirement(name: "IMI", scope: .transactionsInCategory(categoryId: imi), kinds: [], usualSource: "Portal")
            try EvidenceRequirements.save(db: db, &t)
        }
        try transaction(Self.date(2025, 5, 2), -100, category: imi, description: "# Line\r\nwith | pipe <tag>\rend")
        let markdown = MissingEvidence.markdown(items: try items(year2025.interval), title: "# 2025/26 <x>", period: year2025.interval)
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[0], "# \\# 2025/26 \\<x\\>")
        XCTAssertTrue(lines.contains("## \\# Notary \\| \\<b\\> — 0 of 1 done"))
        XCTAssertTrue(lines.contains("- [ ] Deed — needs Property deed"))
        XCTAssertTrue(lines.contains("- [ ] 2025-05-02 · \\# Line with \\| pipe \\<tag\\> end · €1.00 · IMI · BBVA — needs any document"))
        XCTAssertFalse(markdown.contains("\r"))
    }

    func testSeedingWithMortgageAccountAsksOncePerInstalment() throws {
        let interest = try db.write { try insertCategory($0, "Mortgage interest", .expense, group: lisbon) }
        let insurance = try db.write { try insertCategory($0, "Mortgage insurance", .expense, group: lisbon) }
        let added = try db.write { try EvidenceRequirementDefaults.seedPropertyRules(db: $0, categoryGroupId: lisbon, mortgageAccountIds: [mortgage]) }
        let interestRule = try XCTUnwrap(added.first { $0.scope == .transactionsInCategory(categoryId: interest) })
        XCTAssertEqual(interestRule.excludedAccountIds, [mortgage])
        let insuranceRule = try XCTUnwrap(added.first { $0.scope == .transactionsInCategory(categoryId: insurance) })
        XCTAssertEqual(insuranceRule.kinds, [.insuranceReceipt, .insurancePolicy])
        XCTAssertEqual(insuranceRule.excludedAccountIds, [])

        // An instalment: the transfer out of BBVA, and the interest charged on the loan.
        let instalment = try transaction(Self.date(2025, 5, 2), -90_000, category: mortgageTransfer, description: "Prestacao")
        try transaction(Self.date(2025, 5, 2), -20_000, category: interest, description: "Juros", account: mortgage)
        let result = try items(year2025.interval)
        XCTAssertEqual(result.map(\.target), [.transaction(instalment)])
        XCTAssertEqual(result.first?.expectedKinds, [.mortgageNotice, .mortgageReceipt])

        // Without mortgage accounts the interest rule covers every account.
        let plain = try db.write { db -> [EvidenceRequirement] in
            try EvidenceRequirement.deleteAll(db)
            return try EvidenceRequirementDefaults.seedPropertyRules(db: db, categoryGroupId: lisbon)
        }
        XCTAssertEqual(plain.first { $0.scope == .transactionsInCategory(categoryId: interest) }?.excludedAccountIds, [])
    }

    func testItemIdsAreStableAndUnique() throws {
        try requirement("Rent", .periodic(entity: .account(bbva), every: .month), kinds: [])
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [])
        try transaction(Self.date(2025, 5, 2), -1, category: imi)
        let first = try items(year2025.interval).map(\.id)
        XCTAssertEqual(Set(first).count, 13)
        XCTAssertEqual(try items(year2025.interval).map(\.id), first)
    }

    func testRequirementsRoundTripAsData() throws {
        let saved = try requirement("Instalments", .transactionsMatching(categoryIds: [mortgageTransfer], accountIds: [], descriptionContains: " prest "),
                                    kinds: [.mortgageNotice, .mortgageNotice], source: "  BBVA app ", from: Self.date(2023, 1, 1))
        let loaded = try db.read { try EvidenceRequirements.all(db: $0) }
        XCTAssertEqual(loaded, [saved])
        XCTAssertEqual(saved.kinds, [.mortgageNotice])
        XCTAssertEqual(saved.usualSource, "BBVA app")
        XCTAssertEqual(saved.scope, .transactionsMatching(categoryIds: [mortgageTransfer], accountIds: [], descriptionContains: "prest"))
    }

    // MARK: Defaults

    func testDefaultRuleByCategoryName() {
        let rule = EvidenceRequirementDefaults.rule(forCategoryName:)
        XCTAssertEqual(rule("Mortgage interest").kinds, [.mortgageNotice, .mortgageReceipt, .mortgageInterestStatement])
        XCTAssertEqual(rule("IMI").kinds, [.imiNotice, .imiPayment])
        XCTAssertEqual(rule("IMI").usualSource, "Portal das Finanças")
        XCTAssertEqual(rule("Condomínio").kinds, [.condominioReceipt])
        XCTAssertEqual(rule("condominio").kinds, [.condominioReceipt])
        XCTAssertEqual(rule("Building insurance").kinds, [.insuranceReceipt, .insurancePolicy])
        XCTAssertEqual(rule("Life insurance").kinds, [.insuranceReceipt, .insurancePolicy])
        XCTAssertEqual(rule("PT tax").kinds, [.ptIRSAssessment, .ptIRSPaymentNote, .ptIRSPaymentProof])
        XCTAssertEqual(rule("PT accountant").kinds, [.accountantInvoice])
        XCTAssertEqual(rule("Legal fees").kinds, [.legalInvoice, .courtFee])
        XCTAssertEqual(rule("Repairs").kinds, [.repairInvoice, .other])
        XCTAssertEqual(rule("Repairs").usualSource, "Supplier")
        XCTAssertEqual(rule("Repairs and maintenance").kinds, [.repairInvoice, .other])
        XCTAssertEqual(rule("Imposto do Selo"), .init(kinds: [.stampDuty], usualSource: "Portal das Finanças"))
        XCTAssertEqual(rule("Stamp duty").kinds, [.stampDuty])
        XCTAssertEqual(rule("PT tax: imposto do selo").kinds, [.stampDuty])
        XCTAssertEqual(rule("Utilities").kinds, [.utilityInvoice])
        XCTAssertEqual(rule("BBVA fees").kinds, [.bankStatement])
        XCTAssertEqual(rule("Other"), .init(kinds: [], usualSource: nil))
        XCTAssertEqual(rule("Mortgage insurance"), .init(kinds: [.insuranceReceipt, .insurancePolicy], usualSource: "Insurer"))
        XCTAssertEqual(rule("Optimistic").kinds, [])   // "imi" only as a word
    }

    func testSeedPropertyRulesIsIdempotent() throws {
        let added = try db.write { try EvidenceRequirementDefaults.seedPropertyRules(db: $0, categoryGroupId: lisbon, mortgageAccountIds: [mortgage]) }
        XCTAssertEqual(added.map(\.name), ["Lisbon: Condomínio", "Lisbon: IMI", "Lisbon: Repairs", "Lisbon: Mortgage instalments"])
        XCTAssertEqual(added[1].scope, .transactionsInCategory(categoryId: imi))
        XCTAssertEqual(added[1].kinds, [.imiNotice, .imiPayment])
        XCTAssertEqual(added[3].scope, .transactionsMatching(categoryIds: [mortgageTransfer], accountIds: [], descriptionContains: nil))
        XCTAssertEqual(added[3].kinds, [.mortgageNotice, .mortgageReceipt])
        XCTAssertTrue(added.allSatisfy { $0.direction == .outflows && $0.notes == EvidenceRequirementDefaults.seededNote })

        let legal = try db.write { try insertCategory($0, "Legal fees", .expense, group: lisbon) }
        let again = try db.write { try EvidenceRequirementDefaults.seedPropertyRules(db: $0, categoryGroupId: lisbon, mortgageAccountIds: [mortgage]) }
        XCTAssertEqual(again.map(\.scope), [.transactionsInCategory(categoryId: legal)])
        XCTAssertEqual(try db.read { try EvidenceRequirement.fetchCount($0) }, 5)

        // The seeded rules drive the checklist: an instalment and an IMI payment.
        try transaction(Self.date(2025, 5, 2), -90_000, category: mortgageTransfer, description: "Prestacao")
        try transaction(Self.date(2025, 5, 3), -31_250, category: imi)
        try transaction(Self.date(2025, 5, 4), -500, category: groceries)
        let result = try items(year2025.interval)
        XCTAssertEqual(result.map(\.sourceName), ["BBVA app", "Portal das Finanças"])
        XCTAssertEqual(result.map(\.expectedKinds), [[.mortgageNotice, .mortgageReceipt], [.imiNotice, .imiPayment]])
    }

    // MARK: Screen helpers

    func testPropertyRulesPreviewMatchesSeedingAndWritesNothing() throws {
        let preview = try db.read { try EvidenceRequirementDefaults.propertyRules(db: $0, categoryGroupId: lisbon, mortgageAccountIds: [mortgage]) }
        XCTAssertEqual(try db.read { try EvidenceRequirement.fetchCount($0) }, 0)
        let added = try db.write { try EvidenceRequirementDefaults.seedPropertyRules(db: $0, categoryGroupId: lisbon, mortgageAccountIds: [mortgage]) }
        XCTAssertEqual(preview.map(\.name), added.map(\.name))
        XCTAssertEqual(preview.map(\.scope), added.map(\.scope))
        XCTAssertEqual(preview.map(\.kinds), added.map(\.kinds))
        XCTAssertTrue(preview.allSatisfy { $0.id == nil })
        XCTAssertEqual(try db.read { try EvidenceRequirementDefaults.propertyRules(db: $0, categoryGroupId: lisbon, mortgageAccountIds: [mortgage]) }, [])
    }

    func testPickerYearsRunFromEarliestToCurrentLatestFirst() {
        let now = Self.date(2026, 10, 16)
        XCTAssertEqual(UKTaxYear.pickerYears(earliest: UKTaxYear(startYear: 2023), now: now).map(\.label), ["2026/27", "2025/26", "2024/25", "2023/24"])
        XCTAssertEqual(UKTaxYear.pickerYears(earliest: UKTaxYear(startYear: 2030), now: now).map(\.label), ["2026/27"])
        XCTAssertEqual(UKTaxYear.pickerYears(earliest: UKTaxYear(startYear: 2023), now: Self.date(2024, 4, 5)).map(\.startYear), [2023])
        XCTAssertEqual(UKTaxYear(startYear: 2025).next, UKTaxYear(startYear: 2026))
        XCTAssertEqual(UKTaxYear(startYear: 2025).previous, UKTaxYear(startYear: 2024))
    }

    func testCustomPeriodIncludesTheLastDay() {
        let period = MissingEvidence.period(from: Self.date(2025, 1, 1), through: Self.date(2025, 1, 31))
        XCTAssertEqual(period, DateInterval(start: Self.date(2025, 1, 1), end: Self.date(2025, 2, 1)))
        XCTAssertNotNil(MissingEvidence.period(from: Self.date(2025, 1, 1), through: Self.date(2025, 1, 1)))
        XCTAssertNil(MissingEvidence.period(from: Self.date(2025, 1, 2), through: Self.date(2025, 1, 1)))
    }

    func testFilteringByStatusAndText() throws {
        try requirement("Lisbon: IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice], source: "Portal das Finanças")
        try requirement("Lisbon: Condomínio", .transactionsInCategory(categoryId: condominio), kinds: [.condominioReceipt])
        let paid = try transaction(Self.date(2025, 5, 2), -31_250, category: imi, description: "AT IMI 1a prestacao")
        try transaction(Self.date(2025, 6, 2), -12_000, category: condominio, description: "Quota junho")
        try document(.imiNotice, name: "IMI 2025 nota", linkedTo: .transaction(paid))
        let all = try items(year2025.interval)
        XCTAssertEqual(all.count, 2)

        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: true, text: "").map(\.title), ["Quota junho"])
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: false, text: "").count, 2)
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: false, text: "condominio").map(\.title), ["Quota junho"])
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: false, text: "financas imi").map(\.title), ["AT IMI 1a prestacao"])
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: false, text: "nota").map(\.title), ["AT IMI 1a prestacao"])
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: false, text: "120.00").map(\.title), ["Quota junho"])
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: false, text: "receipt").map(\.title), ["Quota junho"])
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: true, text: "imi"), [])
    }

    private func summary(_ id: Int64) throws -> EvidenceDocumentSummary {
        try XCTUnwrap(try db.read { try EvidenceDocumentSummary.fetchOne($0, key: id) })
    }

    func testCandidatesForATransactionRankDateAndAmount() throws {
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice, .imiPayment])
        try transaction(Self.date(2025, 5, 2), -31_250, category: imi)
        let item = try XCTUnwrap(try items(year2025.interval).first)
        let exact = try document(.imiPayment, docDate: Self.date(2025, 5, 2), name: "Exact")
        let near = try document(.imiNotice, docDate: Self.date(2025, 4, 20), name: "Near")
        try db.write { try $0.execute(sql: "UPDATE document SET amountMinorUnits = 31250, currency = ? WHERE id = ?", arguments: [Currency.eur.rawValue, exact]) }
        let far = try document(.imiNotice, docDate: Self.date(2024, 5, 2), name: "Far")
        let wrongKind = try document(.bankStatement, docDate: Self.date(2025, 5, 2), name: "Statement")
        let all = try [exact, near, far, wrongKind].map(summary)

        let candidates = MissingEvidence.candidates(for: item, documents: all)
        XCTAssertEqual(candidates.map(\.documentId), [exact, near])
        XCTAssertEqual(candidates[0].reasons, ["IMI payment", "Same day", "Same amount"])
        XCTAssertEqual(candidates[1].reasons, ["IMI notice", "12 days apart"])
        XCTAssertEqual(MissingEvidence.candidates(for: item, documents: all, excluding: [exact]).map(\.documentId), [near])
    }

    func testCandidatesForPeriodicAndSingleItems() throws {
        try requirement("Condomínio receipts", .periodic(entity: .account(bbva), every: .quarter), kinds: [.condominioReceipt])
        try requirement("Deed", .single(entity: .account(bbva)), kinds: [.propertyDeed])
        let all = try items(year2025.interval)
        let firstQuarter = try XCTUnwrap(all.first { $0.requirement.name == "Condomínio receipts" })
        let deedItem = try XCTUnwrap(all.first { $0.requirement.name == "Deed" })
        let inSlot = try document(.condominioReceipt, periodStart: Self.date(2025, 4, 6), periodEnd: Self.date(2025, 7, 5), name: "Q1")
        let otherSlot = try document(.condominioReceipt, docDate: Self.date(2025, 12, 1), name: "Q3")
        let deed = try document(.propertyDeed, name: "Escritura")
        let summaries = try [inSlot, otherSlot, deed].map(summary)

        let quarter = MissingEvidence.candidates(for: firstQuarter, documents: summaries)
        XCTAssertEqual(quarter.map(\.documentId), [inSlot])
        XCTAssertEqual(quarter.first?.reasons, ["Condomínio receipt", "Covers the period"])
        XCTAssertEqual(MissingEvidence.candidates(for: deedItem, documents: summaries).map(\.documentId), [deed])
    }

    func testDroppedDocumentIsFilledInToCount() throws {
        try requirement("Rent receipts", .periodic(entity: .account(bbva), every: .month), kinds: [.rentReceipt])
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice])
        try transaction(Self.date(2025, 5, 2), -31_250, category: imi)
        let all = try items(year2025.interval)
        let may = try XCTUnwrap(all.first { $0.requirement.name == "Rent receipts" })
        let imiItem = try XCTUnwrap(all.first { $0.requirement.name == "IMI" })

        // Unknown kind and no date: both filled in from the slot's item.
        let blank = MissingEvidence.filledIn(EvidenceDocumentDetails(), for: may)
        XCTAssertEqual(blank.details.kind, .rentReceipt)
        XCTAssertEqual(blank.details.periodStart, Self.date(2025, 4, 6))
        XCTAssertEqual(blank.details.periodEnd, Self.date(2025, 5, 5))
        XCTAssertEqual(blank.filled, ["kind Rent receipt", "period 2025-04-06 to 2025-05-05"])
        XCTAssertNil(MissingEvidence.shortfall(of: blank.details, for: may))

        // What the document states is kept, and named when it won't count.
        let statement = EvidenceDocumentDetails(kind: .bankStatement, docDate: Self.date(2025, 9, 1))
        let kept = MissingEvidence.filledIn(statement, for: may)
        XCTAssertEqual(kept.details, statement)
        XCTAssertEqual(kept.filled, [])
        XCTAssertEqual(MissingEvidence.shortfall(of: statement, for: may), "it's filed as Bank statement and this needs Rent receipt")
        XCTAssertEqual(MissingEvidence.shortfall(of: EvidenceDocumentDetails(kind: .rentReceipt, docDate: Self.date(2025, 9, 1)), for: may),
                       "its date isn't in 2025-04-06 to 2025-05-05")

        // Transactions need only the kind; the date is left alone.
        let forTransaction = MissingEvidence.filledIn(EvidenceDocumentDetails(), for: imiItem)
        XCTAssertEqual(forTransaction.details, EvidenceDocumentDetails(kind: .imiNotice))
        XCTAssertNil(MissingEvidence.shortfall(of: forTransaction.details, for: imiItem))
    }

    func testLinkingFillsInDetailsInOneWrite() throws {
        try requirement("Rent receipts", .periodic(entity: .account(bbva), every: .month), kinds: [.rentReceipt])
        let may = try XCTUnwrap(try items(year2025.interval).first)
        let blank = try document(.other, name: "Scan")
        let outcome = try db.write { try MissingEvidence.link(db: $0, documentId: blank, to: may) }
        XCTAssertEqual(outcome.filled, ["kind Rent receipt", "period 2025-04-06 to 2025-05-05"])
        XCTAssertNil(outcome.shortfall)
        XCTAssertEqual(try summary(blank).kind, .rentReceipt)
        XCTAssertEqual(try items(year2025.interval).first?.status, .satisfied)

        let statement = try document(.bankStatement, docDate: Self.date(2025, 9, 1), name: "Statement")
        let june = try XCTUnwrap(try items(year2025.interval).dropFirst().first)
        let kept = try db.write { try MissingEvidence.link(db: $0, documentId: statement, to: june) }
        XCTAssertEqual(kept.filled, [])
        XCTAssertNotNil(kept.shortfall)
        XCTAssertEqual(try summary(statement).kind, .bankStatement)
    }

    // MARK: The side panel

    func testAttachedDocumentsSayWhyTheyDontCount() throws {
        let insurance = try db.write { db in try insertCategory(db, "Home insurance", .expense, group: lisbon) }
        try requirement("Home insurance", .transactionsInCategory(categoryId: insurance), kinds: [.insuranceReceipt, .insurancePolicy], source: "Insurer")
        let t = try transaction(Self.date(2025, 6, 1), -26_400, category: insurance, description: "SEGUROS HOME POLICY")
        let advice = try document(.bankDebitAdvice, docDate: Self.date(2025, 6, 1), name: "Debit advice", linkedTo: .transaction(t))
        let catalog = DocumentKindCatalog(customKinds: [])

        let missing = try XCTUnwrap(try items(year2025.interval).first)
        XCTAssertEqual(missing.status, .missing)
        XCTAssertEqual(missing.otherDocuments.map(\.id), [advice])
        let attached = MissingEvidence.attached(missing, catalog: catalog)
        XCTAssertEqual(attached.map(\.id), [advice])
        XCTAssertEqual(attached.first?.kindName, "Bank debit advice")
        XCTAssertEqual(attached.first?.shortfall, .wrongKind)
        XCTAssertEqual(attached.first?.explanation, "Attached: Bank debit advice — not one of the kinds this needs")

        // A qualifying document joins it: the item is done, the advice still says why it doesn't count.
        let receipt = try document(.insuranceReceipt, docDate: Self.date(2025, 6, 1), name: "Receipt", linkedTo: .transaction(t))
        let done = try XCTUnwrap(try items(year2025.interval).first)
        XCTAssertEqual(done.status, .satisfied)
        let both = MissingEvidence.attached(done, catalog: catalog)
        XCTAssertEqual(both.map(\.id), [receipt, advice])
        XCTAssertEqual(both.map(\.shortfall), [nil, .wrongKind])
        XCTAssertNil(both[0].explanation)
    }

    func testAttachedDocumentsOfAPeriodicItemAreTheSlotsOwn() throws {
        try requirement("Condomínio", .periodic(entity: .account(bbva), every: .quarter), kinds: [.condominioReceipt])
        // First quarter (6 Apr – 5 Jul 2025): a receipt in it, a statement dated in it, an undated receipt;
        // a receipt of another quarter belongs to that quarter, not to this one.
        let inSlot = try document(.condominioReceipt, docDate: Self.date(2025, 5, 1), name: "Q1 receipt", linkedTo: .account(bbva))
        let statement = try document(.bankStatement, docDate: Self.date(2025, 5, 2), name: "Statement", linkedTo: .account(bbva))
        let undated = try document(.condominioReceipt, name: "Undated receipt", linkedTo: .account(bbva))
        try document(.condominioReceipt, docDate: Self.date(2025, 12, 1), name: "Q3 receipt", linkedTo: .account(bbva))
        try document(.bankStatement, docDate: Self.date(2025, 12, 2), name: "Q3 statement", linkedTo: .account(bbva))

        let first = try XCTUnwrap(try items(year2025.interval).first)
        let attached = MissingEvidence.attached(first, catalog: DocumentKindCatalog(customKinds: []))
        XCTAssertEqual(Set(attached.map(\.id)), [inSlot, statement, undated])
        XCTAssertNil(attached.first { $0.id == inSlot }?.shortfall)
        XCTAssertEqual(attached.first { $0.id == statement }?.shortfall, .wrongKind)
        XCTAssertEqual(attached.first { $0.id == undated }?.shortfall, .notInPeriod)
        XCTAssertEqual(attached.first { $0.id == undated }?.explanation, "Attached: Condomínio receipt — has no date or period in this one")
    }

    func testSuggestionsPutMatchedDocumentsOfAnAcceptedKindFirst() throws {
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice, .imiPayment])
        try transaction(Self.date(2025, 5, 2), -31_250, category: imi)
        let item = try XCTUnwrap(try items(year2025.interval).first)
        let matched = try document(.imiPayment, docDate: Self.date(2025, 5, 3), name: "Matched")
        let near = try document(.imiNotice, docDate: Self.date(2025, 4, 20), name: "Near")
        let wrongKind = try document(.bankDebitAdvice, docDate: Self.date(2025, 5, 2), name: "Advice")
        let linked = try document(.imiNotice, docDate: Self.date(2025, 5, 1), name: "Linked")
        let summaries = try [matched, near, wrongKind, linked].map(summary)
        let fromMatcher = [
            EvidenceMatcher.DocumentSuggestion(documentId: wrongKind, score: 300, reasons: ["Amount €312.50"], amountMatched: true, dateInWindow: true),
            EvidenceMatcher.DocumentSuggestion(documentId: matched, score: 200, reasons: ["Amount €312.50", "1 day after"], amountMatched: true, dateInWindow: true)
        ]
        let suggestions = MissingEvidence.suggestions(for: item, summaries: summaries, matched: fromMatcher, excluding: [linked])
        // The matcher's own (a kind the rule takes), then the checklist's candidates not already shown.
        XCTAssertEqual(suggestions.map(\.documentId), [matched, near])
        XCTAssertEqual(suggestions.first?.reasons, ["Amount €312.50", "1 day after"])
        XCTAssertEqual(MissingEvidence.suggestions(for: item, summaries: summaries, matched: fromMatcher, excluding: [], limit: 1).map(\.documentId), [matched])
    }

    func testFilteringKeepsTheSelectedItemShown() throws {
        try requirement("IMI", .transactionsInCategory(categoryId: imi), kinds: [.imiNotice])
        let paid = try transaction(Self.date(2025, 5, 2), -100, category: imi)
        try transaction(Self.date(2025, 6, 2), -200, category: imi)
        try document(.imiNotice, linkedTo: .transaction(paid))
        let all = try items(year2025.interval)
        let done = try XCTUnwrap(all.first { $0.status == .satisfied })
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: true, text: "").count, 1)
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: true, text: "", keeping: done.id).map(\.id), all.map(\.id))
        // The text still applies to it.
        XCTAssertEqual(MissingEvidence.filtered(all, missingOnly: true, text: "nothing like it", keeping: done.id), [])
    }
}
