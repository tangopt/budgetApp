import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

final class BBVAHistoryImportTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A synthetic two-month statement (not real data): opening €1,000.00.
    private let csv = """
    Date,ValueDate,Description,Amount,Balance,kind,matched_text,detail,source_file
    02/01/2023,31/12/2022,COBR. REC. TOT 076 97-001331-2,-500.00,500.00,mortgage_instalment,COBR. REC. TOT,,a.pdf
    03/01/2023,03/01/2023,0269881 TENANTX,1000.00,1500.00,rent_received,TENANTX,,a.pdf
    10/01/2023,10/01/2023,SEPADD/BBVASEG ADC/111,-20.00,1480.00,life_insurance,SEPADD/BBVASEG,,a.pdf
    11/01/2023,11/01/2023,SEPADD/BBVASEG ADC/222,-30.00,1450.00,building_insurance_mr,SEPADD/BBVASEG,,a.pdf
    12/01/2023,12/01/2023,Conta Revolut 230112EVN1,-100.00,1350.00,transfer_own_accounts,Conta Revolut,,a.pdf
    13/01/2023,13/01/2023,PABLO X 230113SCR1,5.00,1355.00,transfer_own_accounts,PABLO X,,a.pdf
    15/01/2023,15/01/2023,"SUBSCRIÇÃO PERI 6,5960",-50.00,1305.00,investment_subscription,SUBSCRI,,a.pdf
    20/01/2023,20/01/2023,PAGAMENTO - CLASSIC- EXT :0152,-40.00,1265.00,card_payment,PAGAMENTO - CLASSIC,,a.pdf
    02/02/2023,02/02/2023,COBR. REC. TOT 076 97-001331-2,-500.00,765.00,mortgage_instalment,COBR. REC. TOT,,b.pdf
    03/02/2023,03/02/2023,0269882 TENANTX,1000.00,1765.00,rent_received,TENANTX,,b.pdf
    10/02/2023,10/02/2023,SEPADD/BBVASEG ADC/111,-20.00,1745.00,life_insurance,SEPADD/BBVASEG,,b.pdf
    14/02/2023,14/02/2023,Dev2rendas 240214EVN1,-200.00,1545.00,tenant_deposit_return,Dev2rendas,,b.pdf
    15/02/2023,15/02/2023,PG PAGOPT 936,-20.00,1525.00,state_payment_other,PG PAGOPT,,b.pdf
    16/02/2023,16/02/2023,advogada 230216EVN2,-60.00,1465.00,legal_fees,advogad,,b.pdf
    17/02/2023,17/02/2023,IMPOSTO SELO,-1.00,1464.00,bank_fees,IMPOSTO SELO,,b.pdf
    """
    private let summary = """
    period,opening,credits,debits,closing,count,source_file
    2023-01,1000.00,1005.00,-740.00,1265.00,8,a.pdf
    2023-02,1265.00,1000.00,-801.00,1464.00,7,b.pdf
    """

    private func input() throws -> BBVAHistoryImport.Input {
        BBVAHistoryImport.Input(rows: try BBVAHistoryImport.parseClassifiedCSV(csv), months: try BBVAHistoryImport.parseMonthlySummary(summary))
    }

    /// Existing accounts like the real database's: Current (unordered) and Revolut (GBP) with
    /// tied transfer categories in "Own accounts", and Revolut's leg of the 12 Jan transfer.
    private func makeDB() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        try m.dbQueue.write { db in
            let own = try CategoryGroups.create(db: db, name: "Own accounts", type: .transfer)
            for name in ["Transfer: Current", "Transfer: Revolut"] {
                try Categories.create(db: db, name: name, type: .transfer, groupId: own.id)
            }
            try AccountEditing.add(db: db, name: "Lloyds Classic", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: day(2023, 1, 1),
                                   details: AccountDetails(alias: "Current"))
            let revolut = try AccountEditing.add(db: db, name: "Revolut", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: day(2023, 1, 1))
            try db.execute(sql: "UPDATE account SET sortOrder = NULL")
            var batch = ImportBatch(accountId: revolut.id!, sourceFileName: "revolut.csv", importedAt: Date())
            try batch.insert(db)
            var leg = Transaction(importBatchId: batch.id!, accountId: revolut.id!, date: day(2023, 1, 12), rawDescription: "Top up from BBVA",
                                  amountMinorUnits: 8_700, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "r1")
            try leg.insert(db)
        }
        return m
    }

    private func category(_ db: Database, _ name: String) throws -> Category? {
        try Category.filter(Column("name") == name).fetchOne(db)
    }

    private func bbvaTransactions(_ db: Database) throws -> [Transaction] {
        let id = try Int64.fetchOne(db, sql: "SELECT id FROM account WHERE name = 'BBVA'")!
        return try Transaction.filter(Column("accountId") == id).order(Column("date"), Column("id")).fetchAll(db)
    }

    // MARK: Parsing

    func testParsesClassifiedRowsWithQuotedCommasAndSignedCents() throws {
        let rows = try BBVAHistoryImport.parseClassifiedCSV(csv)
        XCTAssertEqual(rows.count, 15)
        XCTAssertEqual(rows[0].date, day(2023, 1, 2))
        XCTAssertEqual(rows[0].amountMinorUnits, -50_000)
        XCTAssertEqual(rows[0].balanceAfterMinorUnits, 50_000)
        XCTAssertEqual(rows[0].kind, "mortgage_instalment")
        XCTAssertEqual(rows[6].description, "SUBSCRIÇÃO PERI 6,5960")
        XCTAssertEqual(rows[6].amountMinorUnits, -5_000)
        let months = try BBVAHistoryImport.parseMonthlySummary(summary)
        XCTAssertEqual(months.map(\.label), ["2023-01", "2023-02"])
        XCTAssertEqual(months.map(\.closingMinorUnits), [126_500, 146_400])
    }

    func testMappingByKind() {
        typealias M = BBVAHistoryImport.Mapping
        XCTAssertEqual(BBVAHistoryImport.mapping(forKind: "insurance_refund"), M.category("Life insurance"))
        XCTAssertEqual(BBVAHistoryImport.mapping(forKind: "insurance_mapfre"), M.category("Building insurance"))
        XCTAssertEqual(BBVAHistoryImport.mapping(forKind: "utilities_water"), M.category("Utilities"))
        XCTAssertEqual(BBVAHistoryImport.mapping(forKind: "legal_fees"), M.category("Legal fees"))
        XCTAssertEqual(BBVAHistoryImport.mapping(forKind: "tenant_deposit_return"), M.depositTransfer)
        XCTAssertEqual(BBVAHistoryImport.mapping(forKind: "card_payment"), M.category("BBVA credit card"))
        XCTAssertEqual(BBVAHistoryImport.mapping(forKind: "transfer_own_accounts"), M.ownAccountTransfer)
        for kind in ["investment_subscription", "state_payment_other", "other"] {
            XCTAssertEqual(BBVAHistoryImport.mapping(forKind: kind), M.uncategorised)
        }
        XCTAssertNil(BBVAHistoryImport.mapping(forKind: "mystery"))
    }

    // MARK: Apply

    func testCreatesAccountWithOpeningBalanceAliasRegionOrderAndTransferCategory() throws {
        let m = try makeDB()
        let report = try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }
        try m.dbQueue.read { db in
            let account = try Account.fetchOne(db, key: report.accountId)!
            XCTAssertEqual(account.name, "BBVA")
            XCTAssertEqual(account.alias, "BBVA PT")
            XCTAssertEqual(account.currency, .eur)
            XCTAssertEqual(account.kind, .cash)
            XCTAssertEqual(account.bankRegion, .europe)
            // No account is ordered: neither is BBVA (alphabetical by display name), and the
            // others are left alone.
            XCTAssertNil(account.sortOrder)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account WHERE sortOrder IS NOT NULL"), 0)
            let ordered = AccountOrdering.sorted(try Account.fetchAll(db)).map(\.name)
            XCTAssertEqual(ordered, ["BBVA", "Lloyds Classic", "Revolut", "Tenant deposit held"])
            let snapshots = try BalanceSnapshot.filter(Column("accountId") == report.accountId).fetchAll(db)
            XCTAssertEqual(snapshots.map(\.balanceMinorUnits), [100_000])
            XCTAssertEqual(snapshots.map(\.date), [day(2023, 1, 1)])
            XCTAssertEqual(snapshots.first?.note, "Opening balance (statement 2023-01)")
            let tied = try TransferCategories.category(db: db, forAccountId: report.accountId)
            XCTAssertEqual(tied?.name, "Transfer: BBVA PT")
            XCTAssertEqual(tied?.groupId, try CategoryGroup.filter(Column("name") == "Own accounts").fetchOne(db)?.id)
        }
    }

    func testGoesAfterOrderedAccountsWithoutRenumberingThem() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in try db.execute(sql: "UPDATE account SET sortOrder = CASE name WHEN 'Revolut' THEN 0 ELSE 1 END") }
        let report = try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }
        XCTAssertEqual(report.sortOrder, 2)
        try m.dbQueue.read { db in
            XCTAssertEqual(AccountOrdering.sorted(try Account.fetchAll(db)).map(\.name), ["Revolut", "Lloyds Classic", "BBVA", "Tenant deposit held"])
        }
    }

    func testCreatesLisbonGroupAndCategories() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in _ = try BBVAHistoryImport.apply(db: db, input: try input()) }
        try m.dbQueue.read { db in
            let group = try CategoryGroup.filter(Column("name") == "Lisbon").fetchOne(db)!
            XCTAssertEqual(group.type, .expense)
            let inGroup = try Category.filter(Column("groupId") == group.id).fetchAll(db)
            XCTAssertEqual(Set(inGroup.map(\.name)), Set(BBVAHistoryImport.categories.map(\.name) + ["Transfer: Tenant deposit held"]))
            XCTAssertEqual(try category(db, "Rental income")?.type, .income)
            XCTAssertEqual(try category(db, "Repairs")?.type, .expense)
            let card = try category(db, "BBVA credit card")!
            XCTAssertEqual(card.type, .transfer)
            XCTAssertFalse(card.isExternalTransfer)
            XCTAssertNil(card.transferAccountId)
        }
    }

    func testRowsAreFiledByKindConfirmedManualInOneBatch() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in _ = try BBVAHistoryImport.apply(db: db, input: try input()) }
        try m.dbQueue.read { db in
            let rows = try bbvaTransactions(db)
            XCTAssertEqual(rows.count, 15)
            XCTAssertEqual(Set(rows.map(\.importBatchId)).count, 1)
            XCTAssertEqual(try ImportBatch.fetchOne(db, key: rows[0].importBatchId)?.sourceFileName, "BBVA extratos 2023-01 to 2026-09")
            XCTAssertEqual(rows[0].date, day(2023, 1, 2))
            let names = Dictionary(try Category.fetchAll(db).map { ($0.id!, $0.name) }, uniquingKeysWith: { a, _ in a })
            let filed = rows.map { $0.categoryId.flatMap { names[$0] } }
            XCTAssertEqual(filed, ["Mortgage", "Rental income", "Life insurance", "Building insurance", "Transfer: Revolut", nil, nil,
                                   "BBVA credit card", "Mortgage", "Rental income", "Life insurance", "Transfer: Tenant deposit held", nil, "Legal fees", "BBVA fees"])
            for row in rows where row.categoryId != nil && row.rawDescription != "Conta Revolut 230112EVN1" {
                XCTAssertEqual(row.status, .confirmed)
                XCTAssertEqual(row.categorizedBy, .manual)
            }
            // Fingerprints as staging computes them.
            let parsed = rows.map { ParsedTransaction(date: $0.date, rawDescription: $0.rawDescription, amountMinorUnits: $0.amountMinorUnits) }
            XCTAssertEqual(rows.map(\.fingerprint), TransactionFingerprint.computeAll(accountId: rows[0].accountId, transactions: parsed))
        }
    }

    func testUncategorisedKindsArePendingReviewAndInUncategorizedScreen() throws {
        let m = try makeDB()
        let report = try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }
        XCTAssertEqual(report.uncategorisedPending, 3)
        XCTAssertEqual(report.unresolvedTransfers, ["PABLO X 230113SCR1"])
        try m.dbQueue.read { db in
            let pending = try bbvaTransactions(db).filter { $0.categoryId == nil }
            XCTAssertEqual(pending.map(\.rawDescription), ["PABLO X 230113SCR1", "SUBSCRIÇÃO PERI 6,5960", "PG PAGOPT 936"])
            XCTAssertTrue(pending.allSatisfy { $0.status == .pendingReview })
            let screen = Set(try UncategorizedTransactions.fetch(db: db).map(\.rawDescription))
            XCTAssertTrue(screen.isSuperset(of: pending.map(\.rawDescription)))
        }
    }

    func testOwnAccountTransferIsLinkedByTheMatcher() throws {
        let m = try makeDB()
        let report = try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }
        XCTAssertEqual(report.links.count, 2)
        XCTAssertEqual(report.links.first?.bbvaDescription, "Conta Revolut 230112EVN1")
        XCTAssertEqual(report.links.first?.otherAccountName, "Revolut")
        XCTAssertEqual(report.links.last?.otherAccountName, "Tenant deposit held")
        try m.dbQueue.read { db in
            let revolutLeg = try Transaction.filter(Column("fingerprint") == "r1").fetchOne(db)!
            XCTAssertEqual(revolutLeg.categoryId, try category(db, "Transfer: BBVA PT")?.id)
            XCTAssertEqual(try TransferLink.filter(Column("inTransactionId") == revolutLeg.id!).fetchCount(db), 1)
        }
    }

    func testLearnsConservativeRules() throws {
        let m = try makeDB()
        let report = try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }
        let learned = Dictionary(report.rulesLearned.map { ($0.pattern, $0.categoryName) }, uniquingKeysWith: { a, _ in a })
        // The life-insurance merchant key also matches the building insurance: the whole
        // description is used instead. Single-row kinds (bank fee here) get none.
        XCTAssertEqual(learned, ["COBR REC TOT": "Mortgage", "TENANTX": "Rental income", "SEPADD/BBVASEG ADC/111": "Life insurance"])
        try m.dbQueue.read { db in
            let rules = try Rule.fetchAll(db)
            XCTAssertEqual(Set(rules.map(\.matchPattern)), Set(learned.keys))
            XCTAssertEqual(rules.first { $0.matchPattern == "TENANTX" }?.categoryId, try category(db, "Rental income")?.id)
        }
    }

    func testRuleCandidatesNeedTwoRowsAndNoOtherCategory() {
        let rows: [(description: String, matchedText: String, categoryName: String?)] = [
            ("MANUTENCAO CONTA JAN 2023", "MANUTENCAO CONTA", "BBVA fees"),
            ("MANUTENCAO CONTA JAN 2024", "MANUTENCAO CONTA", "BBVA fees"),
            ("MANUTENCAO CONTA FEV 2023", "MANUTENCAO CONTA", "BBVA fees"),
            ("SEPADD/EDP COM ADC/1", "SEPADD/EDP", "Utilities"),
            ("PGT SERV 1", "", nil),
            ("PGT SERV 2", "", "Utilities")
        ]
        // The month's key ("MANUTENCAO CONTA JAN", 2 rows) loses to the broader matched text.
        let candidates = BBVAHistoryImport.ruleCandidates(rows: rows, learnFor: ["BBVA fees", "Utilities"])
        XCTAssertEqual(candidates, [BBVAHistoryImport.RuleCandidate(pattern: "MANUTENCAO CONTA", categoryName: "BBVA fees", matchCount: 3)])
    }

    func testVerificationReportsMonthEndBalances() throws {
        let m = try makeDB()
        let report = try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("OK") }, report.verification.joined(separator: "\n"))
        XCTAssertTrue(report.verification.contains { $0.contains("2023-02 end") })
        let mortgage2023 = report.byCategoryYear.first { $0.categoryName == "Mortgage" && $0.year == 2023 }
        XCTAssertEqual(mortgage2023?.count, 2)
        XCTAssertEqual(mortgage2023?.totalMinorUnits, -100_000)
        XCTAssertTrue(report.text.contains("Rules learned: 3"))
        // Every category with rows is in the per-year table.
        for name in ["Building insurance", "BBVA credit card", "Legal fees", "Transfer: Tenant deposit held", "(uncategorised)"] {
            XCTAssertTrue(report.text.contains("  \(name) — "), name)
        }
    }

    func testRefusesInconsistentStatements() throws {
        let m = try makeDB()
        let broken = BBVAHistoryImport.Input(rows: try BBVAHistoryImport.parseClassifiedCSV(csv), months: [
            .init(year: 2023, month: 1, openingMinorUnits: 100_000, closingMinorUnits: 126_500),
            .init(year: 2023, month: 2, openingMinorUnits: 126_500, closingMinorUnits: 146_401)
        ])
        XCTAssertThrowsError(try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: broken) }) { error in
            guard case .badInput = error as? BBVAHistoryImport.ImportError else { return XCTFail("\(error)") }
        }
        try m.dbQueue.read { db in XCTAssertNil(try Account.filter(Column("name") == "BBVA").fetchOne(db)) }
    }

    func testRefusesUnknownKind() throws {
        let m = try makeDB()
        let text = csv.replacingOccurrences(of: "legal_fees", with: "mystery")
        let bad = BBVAHistoryImport.Input(rows: try BBVAHistoryImport.parseClassifiedCSV(text), months: try BBVAHistoryImport.parseMonthlySummary(summary))
        XCTAssertThrowsError(try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: bad) }) { error in
            XCTAssertEqual(error as? BBVAHistoryImport.ImportError, .unknownKinds(["mystery"]))
        }
    }

    func testRefusesRerun() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in _ = try BBVAHistoryImport.apply(db: db, input: try input()) }
        XCTAssertThrowsError(try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }) { error in
            XCTAssertEqual(error as? BBVAHistoryImport.ImportError, .alreadyApplied)
        }
        try m.dbQueue.read { db in XCTAssertEqual(try bbvaTransactions(db).count, 15) }
    }

    func testRefusesExistingAccountNamedBBVA() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            _ = try AccountEditing.add(db: db, name: "bbva", currency: .eur, kind: .cash, openingBalanceEntered: nil, asOf: day(2023, 1, 1))
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }) { error in
            XCTAssertEqual(error as? BBVAHistoryImport.ImportError, .accountNameTaken("bbva"))
        }
    }

    func testNameClashStopsWithoutCreatingAnything() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            try Categories.create(db: db, name: "mortgage", type: .expense, groupId: nil)
            try CategoryGroups.create(db: db, name: "LISBON")
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }) { error in
            XCTAssertEqual(error as? BBVAHistoryImport.ImportError, .nameClash(["group “LISBON”", "category “mortgage”"]))
        }
        try m.dbQueue.read { db in
            XCTAssertNil(try Account.filter(Column("name") == "BBVA").fetchOne(db))
            XCTAssertNil(try category(db, "Rental income"))
        }
    }

    // MARK: Tenant deposit

    private func depositAccount(_ db: Database) throws -> Account {
        try Account.filter(Column("name") == "Tenant deposit held").fetchOne(db)!
    }

    private func depositBalance(_ db: Database) throws -> Int? {
        let id = try depositAccount(db).id!
        return NetWorthCalculator.balance(accountId: id, at: nil, snapshots: try BalanceSnapshot.filter(Column("accountId") == id).fetchAll(db),
                                          transactions: try Transaction.filter(Column("accountId") == id).fetchAll(db))?.native
    }

    func testDepositReturnIsATransferToTheLiabilityWithItsOtherSideLinked() throws {
        let m = try makeDB()
        let opening = BBVAHistoryImport.Input(rows: try input().rows, months: try input().months, depositOpening: (-20_000, day(2023, 1, 5)))
        let report = try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: opening) }
        try m.dbQueue.read { db in
            let account = try depositAccount(db)
            XCTAssertEqual(account.kind, .credit)
            XCTAssertEqual(account.currency, .eur)
            let tied = try TransferCategories.category(db: db, forAccountId: account.id!)!
            XCTAssertEqual(tied.name, "Transfer: Tenant deposit held")
            XCTAssertEqual(tied.groupId, try CategoryGroup.filter(Column("name") == "Lisbon").fetchOne(db)?.id)
            let snapshots = try BalanceSnapshot.filter(Column("accountId") == account.id!).fetchAll(db)
            XCTAssertEqual(snapshots.map(\.balanceMinorUnits), [-20_000])
            XCTAssertEqual(snapshots.map(\.date), [day(2023, 1, 5)])
            let legs = try Transaction.filter(Column("accountId") == account.id!).fetchAll(db)
            XCTAssertEqual(legs.map(\.amountMinorUnits), [20_000])
            XCTAssertEqual(legs.first?.date, day(2023, 2, 14))
            XCTAssertEqual(legs.first?.categoryId, try category(db, "Transfer: BBVA PT")?.id)
            XCTAssertEqual(try TransferLink.filter(Column("inTransactionId") == legs.first!.id!).fetchCount(db), 1)
            XCTAssertEqual(try depositBalance(db), 0)
        }
        XCTAssertEqual(report.deposit.balanceMinorUnits, 0)
        XCTAssertEqual(report.deposit.legs.count, 1)
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("OK") }, report.verification.joined(separator: "\n"))
    }

    func testWithoutOpeningTheLiabilityStartsFromZero() throws {
        let m = try makeDB()
        let report = try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }
        XCTAssertNil(report.deposit.openingMinorUnits)
        try m.dbQueue.read { db in
            XCTAssertTrue(try BalanceSnapshot.filter(Column("accountId") == depositAccount(db).id!).fetchAll(db).isEmpty)
            XCTAssertEqual(try depositBalance(db), 20_000)
        }
    }

    func testSplitsATenantCreditIntoRentAndDeposit() throws {
        let m = try makeDB()
        let split = BBVAHistoryImport.Input(rows: try input().rows, months: try input().months, depositOpening: (0, day(2023, 1, 5)),
                                            depositSplits: [.init(date: day(2023, 2, 3), depositMinorUnits: 30_000)])
        let report = try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: split) }
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("OK") }, report.verification.joined(separator: "\n"))
        XCTAssertEqual(report.rowCount, 16)
        XCTAssertEqual(report.deposit.splits.map(\.depositMinorUnits), [30_000])
        // The rent rule is still learned: the deposit part doesn't count against it.
        XCTAssertTrue(report.rulesLearned.contains { $0.pattern == "TENANTX" && $0.matchCount == 2 })
        try m.dbQueue.read { db in
            let parts = try bbvaTransactions(db).filter { $0.date == day(2023, 2, 3) }
            XCTAssertEqual(parts.map(\.amountMinorUnits), [70_000, 30_000])
            XCTAssertEqual(parts.map(\.categoryId), [try category(db, "Rental income")?.id, try category(db, "Transfer: Tenant deposit held")?.id])
            XCTAssertEqual(parts.map(\.note), ["Rent part of a €1,000.00 credit (rest: deposit)", "Deposit part of a €1,000.00 credit"])
            // Received 300 (owed −300), returned 200 → −100.
            XCTAssertEqual(try depositBalance(db), -10_000)
        }
    }

    func testRefusesBadSplitsAndLateDepositDate() throws {
        let m = try makeDB()
        let rows = try input().rows, months = try input().months
        for bad in [
            BBVAHistoryImport.Input(rows: rows, months: months, depositSplits: [.init(date: day(2023, 1, 4), depositMinorUnits: 100)]),
            BBVAHistoryImport.Input(rows: rows, months: months, depositSplits: [.init(date: day(2023, 1, 3), depositMinorUnits: 100_000)]),
            BBVAHistoryImport.Input(rows: rows, months: months, depositOpening: (-20_000, day(2023, 2, 14)))
        ] {
            XCTAssertThrowsError(try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: bad) }) { error in
                guard case .badInput = error as? BBVAHistoryImport.ImportError else { return XCTFail("\(error)") }
            }
        }
    }

    func testRefusesExistingDepositAccount() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            _ = try AccountEditing.add(db: db, name: "Tenant deposit held", currency: .eur, kind: .credit, openingBalanceEntered: nil, asOf: day(2023, 1, 1))
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try BBVAHistoryImport.apply(db: db, input: try input()) }) { error in
            XCTAssertEqual(error as? BBVAHistoryImport.ImportError, .accountNameTaken("Tenant deposit held"))
        }
    }
}
