import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import TestSupport

final class BBVAFundMortgageImportTests: XCTestCase {
    typealias Import = BBVAFundMortgageImport

    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A BBVA account as the history import leaves it: the batch, the Lisbon group's "Mortgage"
    /// category with its learned rule, four instalments, two fund subscriptions and a fee.
    func makeDB() throws -> DatabaseManager {
        let manager = try TestDatabase.migratedManager()
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

    func breakdown(_ capital: Int, _ interest: Int, receipt: Int, tan: Double) -> Import.Breakdown {
        Import.Breakdown(capitalMinorUnits: capital, interestMinorUnits: interest, receipt: receipt, tan: tan, source: "BBVA instalment notice \(receipt)")
    }

    func input(januaryOutstanding: Int = 19_910_000) -> Import.Input {
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
                          Import.Instalment(date: day(2023, 3, 31), valueDate: day(2023, 3, 31), totalMinorUnits: 100_000, breakdown: nil)],
            remainingPaymentsAfterLastNotice: 275,
            confirmedOutstanding: Import.ConfirmedOutstanding(date: day(2023, 4, 10), outstandingMinorUnits: 19_809_149, source: "BBVA, 10 Apr 2023"))
    }

    private func balance(_ db: Database, _ accountId: Int64, at date: Date? = nil) throws -> Int? {
        NetWorthCalculator.balance(accountId: accountId, at: date, snapshots: try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db),
                                   transactions: try Transaction.filter(Column("accountId") == accountId).fetchAll(db))?.native
    }

    // MARK: Pure parts

    /// A noticed instalment on €100,000 at 3% with 120 payments left after it and a €20,000
    /// final balloon (the payment: €822.49), then two more of the same total and one after a
    /// rate rise.
    private var balloonInstalments: [Import.Instalment] {
        [Import.Instalment(date: day(2025, 10, 31), valueDate: day(2025, 10, 31), totalMinorUnits: 82_249, breakdown: breakdown(57_249, 25_000, receipt: 1, tan: 3.0)),
         Import.Instalment(date: day(2025, 12, 1), valueDate: day(2025, 11, 30), totalMinorUnits: 82_249, breakdown: nil),
         Import.Instalment(date: day(2025, 12, 31), valueDate: day(2025, 12, 31), totalMinorUnits: 82_249, breakdown: nil),
         Import.Instalment(date: day(2026, 2, 2), valueDate: day(2026, 1, 31), totalMinorUnits: 90_000, breakdown: nil)]
    }

    private func resolveBalloon(confirmed: Int? = nil) throws -> Import.Resolution {
        try Import.resolve(balloonInstalments, openingOutstanding: 10_000_000, remainingAfterLastNotice: 120, balloon: 2_000_000, confirmedOutstanding: confirmed)
    }

    func testAnnuityHelpers() throws {
        XCTAssertEqual(Import.annuityPayment(balance: 10_000_000, annualRate: 3.0, payments: 120, balloon: 2_000_000).rounded(), 82_249)
        XCTAssertEqual(Import.annuityPayment(balance: 10_000_000, annualRate: 3.0, payments: 120).rounded(), 96_561, "no balloon: the plain annuity")
        XCTAssertEqual(try XCTUnwrap(Import.impliedRate(balance: 10_000_000, payment: 82_249, payments: 120, balloon: 2_000_000)), 3.0, accuracy: 0.001)
        XCTAssertNil(Import.impliedRate(balance: 10_000_000, payment: 1_000, payments: 120, balloon: 2_000_000), "can't repay")
    }

    func testResolveDerivesEachRatePeriodFromTheInstalmentAmount() throws {
        let resolution = try resolveBalloon()
        let items = resolution.instalments
        XCTAssertEqual(items.map(\.isEstimated), [false, true, true, true])
        XCTAssertEqual(items.compactMap(\.remainingPayments), [119, 118, 117], "payments left after each")
        XCTAssertEqual(resolution.periods.map(\.count), [2, 1])
        XCTAssertEqual(resolution.periods[0].rate, 3.0, accuracy: 0.001, "same payment, same rate")
        XCTAssertGreaterThan(resolution.periods[1].rate, 3.0)
        // Interest = balance × TAN / 12, half-even to the cent; capital the rest.
        let before = 10_000_000 - 57_249
        XCTAssertEqual(items[1].outstandingBeforeMinorUnits, before)
        XCTAssertEqual(items[1].interestMinorUnits, Int((Double(before) * resolution.periods[0].rate / 1200).rounded(.toNearestOrEven)))
        XCTAssertEqual(items[1].capitalMinorUnits + items[1].interestMinorUnits, 82_249)
        XCTAssertEqual(items[3].tan, resolution.periods[1].rate)
        XCTAssertEqual(resolution.residualMinorUnits, 0)
        XCTAssertEqual(resolution.remainingAfterLast, 117)
        // The model reproduces the notice.
        XCTAssertEqual(resolution.noticesChecked, 1)
        XCTAssertEqual(resolution.noticePaymentMaxError, 0)
        XCTAssertEqual(resolution.noticeInterestMaxError, 0)
        let note = Import.note(for: items[1])
        XCTAssertTrue(note.contains("Interest derived: TAN ≈ 3.000%"), note)
        XCTAssertTrue(Import.note(for: items[0]).contains("Instalment 1, due 2025-10-31: capital €572.49, interest €250.00"))

        // Without the balloon the amount can't repay the loan in time; without a count, refused.
        XCTAssertThrowsError(try Import.resolve(balloonInstalments, openingOutstanding: 10_000_000, remainingAfterLastNotice: 120))
        XCTAssertThrowsError(try Import.resolve(balloonInstalments, openingOutstanding: 10_000_000, balloon: 2_000_000))
    }

    func testAConfirmedBalanceMovesTheResidualIntoTheLastDerivedInterest() throws {
        let plain = try resolveBalloon()
        let confirmed = plain.outstandingAfterMinorUnits + 37
        let resolution = try resolveBalloon(confirmed: confirmed)
        XCTAssertEqual(resolution.residualMinorUnits, 37)
        XCTAssertEqual(resolution.outstandingAfterMinorUnits, confirmed)
        XCTAssertEqual(resolution.instalments[3].interestMinorUnits, plain.instalments[3].interestMinorUnits + 37)
        XCTAssertEqual(resolution.instalments[3].capitalMinorUnits, plain.instalments[3].capitalMinorUnits - 37)
        XCTAssertEqual(resolution.instalments[2], plain.instalments[2])
        XCTAssertTrue(Import.note(for: resolution.instalments[3]).contains("€0.37 residual"))
        // Nothing derived to absorb it: refused.
        XCTAssertThrowsError(try Import.resolve(Array(balloonInstalments.prefix(1)), openingOutstanding: 10_000_000, confirmedOutstanding: 1))
    }

    func testResolveRefusesABreakdownThatDoesntAddUp() {
        let wrong = Import.Instalment(date: day(2023, 1, 2), valueDate: day(2022, 12, 31), totalMinorUnits: 90_000, breakdown: breakdown(40_000, 49_000, receipt: 10, tan: 2.0))
        XCTAssertThrowsError(try Import.resolve([wrong], openingOutstanding: 1_000_000))
        let noNotice = Import.Instalment(date: day(2023, 1, 2), valueDate: day(2022, 12, 31), totalMinorUnits: 90_000, breakdown: nil)
        XCTAssertThrowsError(try Import.resolve([noNotice], openingOutstanding: 1_000_000))
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
        XCTAssertEqual(parsed.balloonMinorUnits, 0)
        XCTAssertNil(parsed.remainingPaymentsAfterLastNotice)
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
            XCTAssertTrue(charges[3].note?.contains("Interest derived: TAN ≈ ") ?? false)
            // The confirmed outstanding is recorded with nothing to adjust.
            XCTAssertEqual(try Account.fetchOne(db, key: loan.id!)?.balanceConfirmedAt, day(2023, 4, 10))
            XCTAssertEqual(try balance(db, loan.id!, at: BalanceUpdates.endOfDay(day(2023, 4, 10))), -19_809_149)
            XCTAssertTrue(loanRows.allSatisfy { $0.categoryId != nil && $0.categoryId != (try? BuiltInCategories.category(db: db, role: .balanceAdjustment).id) })
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
                                 statements: base.statements, instalments: instalments, remainingPaymentsAfterLastNotice: 275)
        XCTAssertThrowsError(try manager.dbQueue.write { db in _ = try Import.apply(db: db, input: extra) }) { error in
            guard case Import.ImportError.missing = error else { return XCTFail("\(error)") }
        }
    }
}
