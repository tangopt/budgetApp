import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

final class BBVAFundMortgageImportTests: XCTestCase {
    private typealias Import = BBVAFundMortgageImport

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A BBVA account as the history import leaves it: the batch, the Lisbon group's "Mortgage"
    /// category with its learned rule, four instalments, two fund subscriptions and a fee.
    private func makeDB() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            let bbva = try AccountEditing.add(db: db, name: "BBVA", currency: .eur, kind: .cash, openingBalanceEntered: 2_000_000, asOf: day(2022, 12, 31))
            var batch = ImportBatch(accountId: bbva.id!, sourceFileName: Import.bbvaBatchName, importedAt: day(2026, 10, 1))
            try batch.insert(db)
            let group = try CategoryGroups.create(db: db, name: "Lisbon", type: .expense)
            let mortgage = try Categories.create(db: db, name: "Mortgage", type: .expense, groupId: group.id)
            let fees = try Categories.create(db: db, name: "BBVA fees", type: .expense, groupId: group.id)
            try Rules.add(db: db, pattern: "COBR REC TOT", matchType: .contains, categoryId: mortgage.id!, applyToUncategorised: false)
            func row(_ date: Date, _ description: String, _ amount: Int, _ category: Int64?) throws {
                var t = Transaction(importBatchId: batch.id!, accountId: bbva.id!, date: date, rawDescription: description, amountMinorUnits: amount, categoryId: category,
                                    status: category == nil ? .pendingReview : .confirmed, categorizedBy: category == nil ? .none : .rule, fingerprint: UUID().uuidString)
                try t.insert(db)
            }
            try row(day(2023, 1, 2), "COBR. REC. TOT 000 00-000000-0", -90_000, mortgage.id)
            try row(day(2023, 1, 31), "COBR. REC. TOT 000 00-000000-0", -100_000, mortgage.id)
            try row(day(2023, 1, 31), "SUBSCRIÇÃO PERI 5,0000", -5_000, nil)
            try row(day(2023, 2, 28), "Subscricao Peri", -5_000, nil)
            try row(day(2023, 2, 28), "MANUTENCAO CONTA", -800, fees.id)
            try row(day(2023, 3, 1), "COBR. REC. TOT 000 00-000000-0", -100_000, mortgage.id)
            try row(day(2023, 3, 31), "COBR. REC. TOT 000 00-000000-0", -100_000, mortgage.id)
        }
        return manager
    }

    private func breakdown(_ capital: Int, _ interest: Int, receipt: Int, tan: Double) -> Import.Breakdown {
        Import.Breakdown(capitalMinorUnits: capital, interestMinorUnits: interest, receipt: receipt, tan: tan, source: "BBVA instalment notice \(receipt)")
    }

    private func input(januaryOutstanding: Int = 19_910_000) -> Import.Input {
        Import.Input(
            fundOpening: Import.Value(date: day(2022, 12, 31), minorUnits: 500_000, source: "Dec 2022 statement"),
            fundSubscriptionCount: 2,
            fundValues: [Import.Value(date: day(2023, 1, 31), minorUnits: 512_345, source: "Jan statement"),
                         Import.Value(date: day(2023, 2, 28), minorUnits: 510_000, source: "Feb statement"),
                         Import.Value(date: day(2026, 10, 16), minorUnits: 600_000, source: "given")],
            loanOpening: Import.Value(date: day(2022, 12, 31), minorUnits: 20_000_000, source: "Dec 2022 statement"),
            statements: [Import.Statement(year: 2023, month: 1, outstandingMinorUnits: januaryOutstanding, source: "Jan"),
                         // February's counts the instalment value-dated 28 Feb, booked 1 Mar.
                         Import.Statement(year: 2023, month: 2, outstandingMinorUnits: 19_859_500, source: "Feb"),
                         Import.Statement(year: 2023, month: 3, outstandingMinorUnits: 19_809_149, source: "Mar")],
            instalments: [Import.Instalment(date: day(2023, 1, 2), valueDate: day(2022, 12, 31), totalMinorUnits: 90_000, breakdown: breakdown(40_000, 50_000, receipt: 10, tan: 2.5)),
                          Import.Instalment(date: day(2023, 1, 31), valueDate: day(2023, 1, 31), totalMinorUnits: 100_000, breakdown: breakdown(50_000, 50_000, receipt: 11, tan: 3.0)),
                          Import.Instalment(date: day(2023, 3, 1), valueDate: day(2023, 2, 28), totalMinorUnits: 100_000, breakdown: breakdown(50_500, 49_500, receipt: 12, tan: 3.0)),
                          Import.Instalment(date: day(2023, 3, 31), valueDate: day(2023, 3, 31), totalMinorUnits: 100_000, breakdown: nil)])
    }

    private func balance(_ db: Database, _ accountId: Int64, at date: Date? = nil) throws -> Int? {
        NetWorthCalculator.balance(accountId: accountId, at: date, snapshots: try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db),
                                   transactions: try Transaction.filter(Column("accountId") == accountId).fetchAll(db))?.native
    }

    // MARK: Pure parts

    func testResolveEstimatesFromTheLastKnownTAN() throws {
        let resolved = try Import.resolve(input().instalments, openingOutstanding: 20_000_000)
        XCTAssertEqual(resolved.map(\.isEstimated), [false, false, false, true])
        let estimate = resolved[3]
        XCTAssertEqual(estimate.outstandingBeforeMinorUnits, 19_859_500)
        XCTAssertEqual(estimate.tan, 3.0)
        XCTAssertEqual(estimate.interestMinorUnits, 49_649, "198,595.00 × 3% / 12 = 496.4875")
        XCTAssertEqual(estimate.capitalMinorUnits, 50_351)
        XCTAssertTrue(Import.note(for: estimate).contains("estimated — confirm with BBVA notice"))
        XCTAssertTrue(Import.note(for: resolved[1]).contains("Instalment 11, due 2023-01-31: capital €500.00, interest €500.00"))
    }

    func testResolveRefusesABreakdownThatDoesntAddUp() {
        let wrong = Import.Instalment(date: day(2023, 1, 2), valueDate: day(2022, 12, 31), totalMinorUnits: 90_000, breakdown: breakdown(40_000, 49_000, receipt: 10, tan: 2.0))
        XCTAssertThrowsError(try Import.resolve([wrong], openingOutstanding: 1_000_000))
        let noTAN = Import.Instalment(date: day(2023, 1, 2), valueDate: day(2022, 12, 31), totalMinorUnits: 90_000, breakdown: nil)
        XCTAssertThrowsError(try Import.resolve([noTAN], openingOutstanding: 1_000_000))
    }

    func testUKTaxYears() {
        XCTAssertEqual(Import.ukTaxYear(of: day(2024, 4, 5)), 2023)
        XCTAssertEqual(Import.ukTaxYear(of: day(2024, 4, 6)), 2024)
        XCTAssertEqual(Import.ukTaxYear(of: day(2025, 3, 31)), 2024)
    }

    func testParsesTheExtractionJSON() throws {
        let json = """
        {"fund": {"openingDate": "2022-12-31", "opening": "5000.00", "openingSource": "Dec", "subscriptionCount": 2,
                  "values": [{"date": "2023-01-31", "value": "5123.45", "source": "Jan"}]},
         "loan": {"openingDate": "2022-12-31", "opening": "200000.00", "openingSource": "Dec",
                  "statements": [{"month": "2023-01", "outstanding": "199100.00", "source": "Jan"}],
                  "instalments": [{"date": "2023-01-02", "valueDate": "2022-12-31", "total": "900.00", "capital": "400.00", "interest": "500.00",
                                   "fees": "0.00", "taxes": "0.00", "receipt": 10, "tan": "2.500", "source": "notice"},
                                  {"date": "2023-01-31", "valueDate": "2023-01-31", "total": "1000.00"}]}}
        """
        let parsed = try Import.parseInput(json: Data(json.utf8))
        XCTAssertEqual(parsed.fundOpening.minorUnits, 500_000)
        XCTAssertEqual(parsed.loanOpening.minorUnits, 20_000_000)
        XCTAssertEqual(parsed.statements.first?.label, "2023-01")
        XCTAssertEqual(parsed.instalments[0].breakdown, Import.Breakdown(capitalMinorUnits: 40_000, interestMinorUnits: 50_000, receipt: 10, tan: 2.5, source: "notice"))
        XCTAssertNil(parsed.instalments[1].breakdown)
        XCTAssertEqual(parsed.instalments[1].valueDate, day(2023, 1, 31))
        XCTAssertThrowsError(try Import.parseInput(json: Data("{}".utf8)))
    }

    func testRecognisesSubscriptions() {
        XCTAssertTrue(Import.isSubscription("SUBSCRIÇÃO PERI 5,0000"))
        XCTAssertTrue(Import.isSubscription("Subscricao Peri"))
        XCTAssertFalse(Import.isSubscription("SUBSCRIÇÃO FUNDO"))
    }

    // MARK: Apply

    func testImportsTheFundAndTheMortgage() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let bbvaId = try Account.filter(Column("name") == "BBVA").fetchOne(db)!.id!
            let bbvaBefore = try balance(db, bbvaId)
            let report = try Import.apply(db: db, input: input())
            XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("OK") }, report.text)

            let fund = try Account.fetchOne(db, key: report.fundAccountId)!
            XCTAssertEqual([fund.name, fund.currency.rawValue, fund.kind.rawValue], ["BBVA retirement fund", "eur", "investment"])
            XCTAssertTrue(fund.includeInNetWorth)
            XCTAssertNil(fund.sortOrder)
            let loan = try Account.fetchOne(db, key: report.loanAccountId)!
            XCTAssertEqual([loan.name, loan.kind.rawValue], ["BBVA mortgage", "credit"])
            XCTAssertFalse(loan.includeInNetWorth)

            // The fund: opening, two subscriptions, its values as market movements.
            XCTAssertEqual(try balance(db, fund.id!, at: BalanceUpdates.endOfDay(day(2023, 1, 31))), 512_345)
            XCTAssertEqual(try balance(db, fund.id!), 600_000)
            XCTAssertEqual(report.fund.map(\.marketMovementMinorUnits), [7_345, -7_345, 90_000])
            XCTAssertEqual(report.marketMovementByYear[2023], 0)
            XCTAssertEqual(report.marketMovementByYear[2026], 90_000)
            let fundCategory = try TransferCategories.category(db: db, forAccountId: fund.id!)!
            XCTAssertEqual(fundCategory.name, "Transfer: BBVA retirement fund")
            let subscriptions = try Transaction.filter(Column("accountId") == bbvaId).fetchAll(db).filter { Import.isSubscription($0.rawDescription) }
            XCTAssertEqual(subscriptions.map(\.categoryId), [fundCategory.id, fundCategory.id])
            XCTAssertEqual(subscriptions.map(\.status), [.confirmed, .confirmed])

            // The mortgage: falls by the capital only.
            let capital = 40_000 + 50_000 + 50_500 + 50_351
            XCTAssertEqual(try balance(db, loan.id!), -20_000_000 + capital)
            XCTAssertEqual(try balance(db, loan.id!, at: MonthRange.of(year: 2023, month: 1).end), -19_910_000)
            XCTAssertEqual(report.loan.map(\.differenceMinorUnits), [0, 50_500, 0])
            XCTAssertNotNil(report.loan[1].explanation)
            let loanCategory = try TransferCategories.category(db: db, forAccountId: loan.id!)!
            XCTAssertEqual(loanCategory.name, "Transfer: BBVA mortgage")
            let lisbon = try CategoryGroup.filter(Column("name") == "Lisbon").fetchOne(db)!
            XCTAssertEqual(loanCategory.groupId, lisbon.id)
            let interest = try Category.filter(Column("name") == "Mortgage interest").fetchOne(db)!
            XCTAssertNil(try Category.filter(Column("name") == "Mortgage").fetchOne(db))
            let instalments = try Transaction.filter(Column("accountId") == bbvaId).fetchAll(db).filter { $0.rawDescription.hasPrefix("COBR") }
            XCTAssertEqual(Set(instalments.map(\.categoryId)), [loanCategory.id])
            let loanRows = try Transaction.filter(Column("accountId") == loan.id!).order(Column("date"), Column("id")).fetchAll(db)
            let charges = loanRows.filter { $0.categoryId == interest.id }
            XCTAssertEqual(charges.map(\.amountMinorUnits), [-50_000, -50_000, -49_500, -49_649])
            XCTAssertEqual(charges.map(\.date), [day(2023, 1, 2), day(2023, 1, 31), day(2023, 3, 1), day(2023, 3, 31)])
            XCTAssertTrue(charges[3].note?.contains("estimated — confirm with BBVA notice") ?? false)
            XCTAssertEqual(loanRows.filter { $0.amountMinorUnits > 0 }.map(\.amountMinorUnits), [90_000, 100_000, 100_000, 100_000])
            XCTAssertEqual(try TransferLink.active.fetchCount(db), 6)
            XCTAssertEqual(try Rule.fetchOne(db)?.categoryId, loanCategory.id)
            XCTAssertEqual(try balance(db, bbvaId), bbvaBefore)

            // Net worth: the fund only.
            let rate = try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate
            XCTAssertEqual(report.netWorthAfterGBP - report.netWorthBeforeGBP, Int((600_000 * rate).rounded()))
            XCTAssertEqual(report.chargesByTaxYear[2022]?.total, 199_149)
            XCTAssertEqual(report.chargesByTaxYear[2022]?.estimated, 49_649)
        }
    }

    func testRefusesToRunTwice() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in _ = try Import.apply(db: db, input: input()) }
        XCTAssertThrowsError(try manager.dbQueue.write { db in _ = try Import.apply(db: db, input: input()) }) { error in
            guard case Import.ImportError.alreadyApplied = error else { return XCTFail("\(error)") }
        }
    }

    func testAStatementThatDoesntMatchFailsVerification() throws {
        let manager = try makeDB()
        XCTAssertThrowsError(try manager.dbQueue.write { db in _ = try Import.apply(db: db, input: input(januaryOutstanding: 19_909_500)) }) { error in
            guard case Import.ImportError.verificationFailed(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("FAIL"))
        }
        // Rolled back.
        try manager.dbQueue.read { db in
            XCTAssertNil(try Account.filter(Column("name") == "BBVA mortgage").fetchOne(db))
            XCTAssertNotNil(try Category.filter(Column("name") == "Mortgage").fetchOne(db))
        }
    }

    func testRefusesWhenAnInstalmentRowIsMissing() throws {
        let manager = try makeDB()
        var instalments = input().instalments
        instalments.append(Import.Instalment(date: day(2023, 4, 30), valueDate: day(2023, 4, 30), totalMinorUnits: 110_000, breakdown: nil))
        let base = input()
        let extra = Import.Input(fundOpening: base.fundOpening, fundSubscriptionCount: 2, fundValues: base.fundValues, loanOpening: base.loanOpening,
                                 statements: base.statements, instalments: instalments)
        XCTAssertThrowsError(try manager.dbQueue.write { db in _ = try Import.apply(db: db, input: extra) }) { error in
            guard case Import.ImportError.missing = error else { return XCTFail("\(error)") }
        }
    }
}
