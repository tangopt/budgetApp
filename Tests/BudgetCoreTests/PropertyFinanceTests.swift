import XCTest
import GRDB
@testable import BudgetCore

/// The property's money summary, obligations calendar, checks and evidence rules (spec
/// 2026-10-16 §1, §7). One synthetic property with a current account, a mortgage, a deposit
/// account and a GBP account.
final class PropertyFinanceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var rate = ExchangeRateSetting(eurToGbpRate: 0.85, updatedAt: Self.date(2025, 1, 1))
            try rate.insert(db)
            var property = Property(name: "Property A", country: "PT", purchasePriceMinorUnits: 20_000_000)
            try Properties.save(db: db, &property)
            let p = property.id!
            ids["property"] = p

            func account(_ name: String, _ currency: Currency, _ kind: AccountKind) throws -> Int64 {
                var account = Account(name: name, currency: currency, kind: kind, trackingMode: .imported)
                try account.insert(db)
                var batch = ImportBatch(accountId: account.id!, sourceFileName: "\(name).csv", importedAt: Date())
                try batch.insert(db)
                ids["batch:\(account.id!)"] = batch.id!
                return account.id!
            }
            let bank = try account("Bank A", .eur, .cash)
            let loan = try account("Loan A", .eur, .credit)
            let deposit = try account("Deposit held", .eur, .credit)
            let pounds = try account("Bank B", .gbp, .cash)
            ids["bank"] = bank; ids["loan"] = loan; ids["deposit"] = deposit; ids["pounds"] = pounds
            try Properties.setAccount(db: db, propertyId: p, accountId: bank, role: .current)
            try Properties.setAccount(db: db, propertyId: p, accountId: loan, role: .mortgage)
            try Properties.setAccount(db: db, propertyId: p, accountId: deposit, role: .deposit)

            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            func category(_ name: String, _ type: CategoryType, inGroup: Bool = true, transferAccount: Int64? = nil) throws -> Int64 {
                var category = Category(name: name, type: type, groupId: inGroup ? group.id : nil, transferAccountId: transferAccount)
                try category.insert(db)
                return category.id!
            }
            ids["rent"] = try category("Rental income", .income)
            ids["interest"] = try category("Mortgage interest", .expense)
            ids["condo"] = try category("Condomínio", .expense)
            ids["imi"] = try category("IMI", .expense)
            ids["insurance"] = try category("Building insurance", .expense)
            ids["utilities"] = try category("Utilities", .expense)
            ids["toLoan"] = try category("Transfer: Loan A", .transfer, inGroup: false, transferAccount: loan)
            ids["fromBank"] = try category("Transfer: Bank A", .transfer, inGroup: false, transferAccount: bank)

            var opening = BalanceSnapshot(accountId: loan, date: Self.date(2024, 12, 31), balanceMinorUnits: -10_000_000, note: nil)
            try opening.insert(db)
            var held = BalanceSnapshot(accountId: deposit, date: Self.date(2024, 12, 31), balanceMinorUnits: -300_000, note: nil)
            try held.insert(db)

            var tenancy = Tenancy(propertyId: p, referenceLabel: "Room Contract AB", contractNumber: "3001", tenantName: "Tenant B",
                                  startDate: Self.date(2025, 1, 1), advanceRentMonths: 1, depositMonths: 2)
            try Tenancies.save(db: db, &tenancy)
            ids["tenancy"] = tenancy.id!
            try Tenancies.setRent(db: db, tenancyId: tenancy.id!, from: Self.date(2025, 1, 1), monthlyAmountMinorUnits: 100_000)
            for (number, start, end, amount) in [("1", (2025, 1, 1), (2025, 1, 31), 100_000), ("2", (2025, 2, 1), (2025, 2, 28), 100_000),
                                                 ("3", (2025, 3, 1), (2025, 3, 31), 100_000), ("4", (2025, 4, 1), (2025, 6, 30), 300_000)] {
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: number, periodStart: Self.date(start.0, start.1, start.2),
                                          periodEnd: Self.date(end.0, end.1, end.2), receiptDate: nil, amountMinorUnits: amount)
                try RentReceipts.save(db: db, &receipt)
                ids["receipt\(number)"] = receipt.id!
            }
        }
        // Rent credits: January exact, February with a 150 recharge.
        try add(bank, Self.date(2025, 1, 2), 100_000, "rent")
        try add(bank, Self.date(2025, 2, 3), 115_000, "rent")
        // Condomínio quarterly; IMI in May; utilities paid in GBP; insurance in March.
        for month in [1, 4, 7, 10] { try add(bank, Self.date(2025, month, 15), -10_000, "condo") }
        try add(bank, Self.date(2025, 5, 20), -30_000, "imi")
        try add(ids["pounds"]!, Self.date(2025, 2, 10), -5_000, "utilities")
        try add(bank, Self.date(2025, 3, 1), -40_000, "insurance")
        // Mortgage: instalments of 500 then 520 from April; 200 interest each.
        for month in 1...6 {
            let amount = month < 4 ? 50_000 : 52_000
            try add(bank, Self.date(2025, month, 5), -amount, "toLoan")
            try add(ids["loan"]!, Self.date(2025, month, 5), amount, "fromBank")
            try add(ids["loan"]!, Self.date(2025, month, 5), -20_000, "interest")
        }
        try db.write { db in _ = try RentReceiptMatching.match(db: db, propertyId: ids["property"]!) }
    }

    private var bank: Int64 { ids["bank"]! }
    private var propertyId: Int64 { ids["property"]! }

    @discardableResult
    private func add(_ account: Int64, _ date: Date, _ amount: Int, _ category: String) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: ids["batch:\(account)"]!, accountId: account, date: date, rawDescription: category,
                                          amountMinorUnits: amount, categoryId: ids[category], status: .confirmed, categorizedBy: .manual,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    // MARK: Summary

    func testCalendarYearSummary() throws {
        let summary = try db.read { db in
            try PropertyFinance.summary(db: db, propertyId: propertyId, period: .calendarYear(2025), today: Self.date(2026, 1, 10))
        }
        let totals = summary.totals
        XCTAssertEqual(summary.eurToGbpRate, 0.85)
        XCTAssertEqual(totals.rentPerReceipts, PropertyAmount(native: 600_000, gbp: 510_000))
        XCTAssertEqual(totals.rentCredits.native, 215_000)
        XCTAssertEqual(totals.recharges.native, 15_000)
        XCTAssertEqual(totals.rentReceived.native, 200_000)
        XCTAssertEqual(totals.income.native, 215_000)
        // Condomínio 400 + interest 1,200 + IMI 300 + insurance 400 + utilities £50 (≈ €58.82).
        XCTAssertEqual(totals.costs.native, 40_000 + 120_000 + 30_000 + 40_000 + 5_882)
        XCTAssertEqual(totals.costs.gbp, 34_000 + 102_000 + 25_500 + 34_000 + 5_000)
        XCTAssertEqual(totals.mortgageInterest.native, 120_000)
        XCTAssertEqual(totals.mortgageCapital.native, 3 * 50_000 + 3 * 52_000 - 120_000)
        XCTAssertEqual(totals.netCashFlow.native, totals.income.native - totals.costs.native - totals.mortgageCapital.native)
        XCTAssertEqual(summary.costsByCategory.map(\.name), ["Mortgage interest", "Building insurance", "Condomínio", "IMI", "Utilities"])
        XCTAssertEqual(summary.outstandingLoan.native, 10_000_000 - (306_000 - 120_000))
        XCTAssertEqual(summary.depositHeld.native, 300_000)
        XCTAssertEqual(summary.grossYield!, 0.03, accuracy: 1e-9)
        XCTAssertEqual(summary.netYield!, Double(totals.income.native - totals.costs.native) / 20_000_000, accuracy: 1e-9)

        // Monthly series: the April–June receipt is spread over its days, exactly.
        XCTAssertEqual(summary.months.count, 12)
        XCTAssertEqual(summary.months.map(\.figures.rentPerReceipts.native).prefix(7), [100_000, 100_000, 100_000, 98_901, 102_198, 98_901, 0])
        XCTAssertEqual(summary.months.map(\.figures.mortgageInterest.native).reduce(0, +), 120_000)
        XCTAssertEqual(summary.months[1].figures.recharges.native, 15_000)
    }

    /// The loan's history, read for many days at once, matches `balance` day by day (before the
    /// opening snapshot, on it, mid-year, at the year's end; the loan and the deposit together).
    func testLoanBalancesMatchBalanceDayByDay() throws {
        let days = [Self.date(2024, 12, 30), Self.date(2024, 12, 31), Self.date(2025, 2, 14), Self.date(2025, 3, 31),
                    Self.date(2025, 7, 1), Self.date(2025, 12, 31)]
        for accountIds in [[ids["loan"]!], [ids["loan"]!, ids["deposit"]!], []] {
            let (many, one) = try db.read { db -> ([PropertyAmount], [PropertyAmount]) in
                let property = try Property.fetchOne(db, key: propertyId)!
                let conversion = try CurrencyConversion.current(db: db)
                return (try PropertyFinance.loanBalances(db: db, property: property, accountIds: accountIds, days: days),
                        try days.map { try PropertyFinance.balance(db: db, property: property, conversion: conversion, accountIds: accountIds, asOf: $0) })
            }
            XCTAssertEqual(many, one, "accounts \(accountIds)")
        }
        let owed = try db.read { db in
            try PropertyFinance.loanBalances(db: db, property: try Property.fetchOne(db, key: propertyId)!, accountIds: [ids["loan"]!],
                                             days: [Self.date(2025, 12, 31)])
        }
        XCTAssertEqual(owed.first?.native, 10_000_000 - (306_000 - 120_000))
    }

    func testCustomAndTaxYearPeriods() throws {
        let custom = DateInterval(start: Self.date(2025, 1, 1), end: Self.date(2025, 5, 1))
        let summary = try db.read { db in try PropertyFinance.summary(db: db, propertyId: propertyId, period: .custom(custom)) }
        XCTAssertEqual(summary.totals.rentPerReceipts.native, 300_000 + 98_901)
        XCTAssertEqual(summary.months.count, 4)
        XCTAssertEqual(summary.outstandingLoan.native, 10_000_000 - (4 * 50_000 + 2_000 - 4 * 20_000))

        let year = PropertyPeriod.ukTaxYear(UKTaxYear(startYear: 2025))
        XCTAssertEqual(year.interval, DateInterval(start: Self.date(2025, 4, 6), end: Self.date(2026, 4, 6)))
        XCTAssertEqual(year.label, "2025/26")
        XCTAssertEqual(PropertyPeriod.calendarYear(2025).label, "2025")
        XCTAssertEqual(PropertyPeriod.custom(custom).label, "2025-01-01 – 2025-04-30")
        let taxYear = try db.read { db in try PropertyFinance.summary(db: db, propertyId: propertyId, period: year) }
        // 6 April – 30 June of the 91-day receipt: 86 days.
        XCTAssertEqual(taxYear.totals.rentPerReceipts.native, Int((300_000.0 * 86 / 91).rounded()))
        XCTAssertEqual(taxYear.months.first?.start, Self.date(2025, 4, 6))
        XCTAssertEqual(taxYear.months.count, 13) // 6–30 April … 1–5 April
    }

    func testApportioningAddsUp() {
        let start = Self.date(2025, 1, 10), last = Self.date(2025, 3, 9)
        let parts = [(Self.date(2025, 1, 1), Self.date(2025, 2, 1)), (Self.date(2025, 2, 1), Self.date(2025, 3, 1)),
                     (Self.date(2025, 3, 1), Self.date(2025, 4, 1))]
            .map { PropertyFinance.apportioned(100_001, start: start, lastDay: last, to: DateInterval(start: $0.0, end: $0.1)) }
        XCTAssertEqual(parts.reduce(0, +), 100_001)
        XCTAssertEqual(PropertyFinance.apportioned(100, start: start, lastDay: last, to: DateInterval(start: Self.date(2024, 1, 1), end: Self.date(2025, 1, 1))), 0)
    }

    // MARK: Calendar

    func testObligationsForTheNextYear() throws {
        // The building insurance receipt covers March 2025 – February 2026.
        try db.write { db in
            let insurance = try Transaction.filter(Column("categoryId") == ids["insurance"]!).fetchOne(db)!
            let sha = UUID().uuidString
            var document = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha.prefix(2))/\(sha).pdf", originalFileName: "policy.pdf",
                                            byteCount: 1, canonicalName: "Policy", kind: .insuranceReceipt, periodStart: Self.date(2025, 3, 1),
                                            periodEnd: Self.date(2026, 2, 28), addedAt: Date())
            try document.insert(db)
            try EvidenceLinks.link(db: db, documentId: document.id!, to: .transaction(insurance.id!))
        }
        try db.write { db in
            var person = Person(name: "Person A", ukUtr: "0000000000")
            try People.save(db: db, &person)
            try Properties.setOwners(db: db, propertyId: propertyId, [PropertyOwner(propertyId: propertyId, personId: person.id!, shareBasisPoints: 10_000)])
        }
        let obligations = try db.read { db in
            try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: Self.date(2026, 1, 1), to: Self.date(2027, 1, 1),
                                             today: Self.date(2025, 7, 31))
        }
        func dates(_ kind: PropertyObligationKind) -> [Date] { obligations.filter { $0.kind == kind }.map(\.date) }
        // One payment of history (May) doesn't say August and November aren't due.
        XCTAssertEqual(dates(.imiInstalment), [Self.date(2026, 5, 31), Self.date(2026, 8, 31), Self.date(2026, 11, 30)])
        XCTAssertEqual(obligations.filter { $0.kind == .imiInstalment }.map(\.expectedMinorUnits), [30_000, nil, nil])
        XCTAssertEqual(dates(.ptIncomeTaxReturn), [Self.date(2026, 6, 30)])
        XCTAssertEqual(dates(.ukSelfAssessmentJanuary), [Self.date(2026, 1, 31)])
        XCTAssertTrue(obligations.first { $0.kind == .ukSelfAssessmentJanuary }!.title.contains("2024/25"))
        XCTAssertEqual(dates(.ukSelfAssessmentJuly), [Self.date(2026, 7, 31)])
        XCTAssertEqual(dates(.mortgageRateReset), [Self.date(2026, 1, 5), Self.date(2026, 4, 5), Self.date(2026, 7, 5), Self.date(2026, 10, 5)])
        XCTAssertEqual(dates(.mortgageInstalment).count, 12)
        XCTAssertEqual(obligations.first { $0.kind == .mortgageInstalment }?.expectedMinorUnits, 52_000)
        let condo = obligations.filter { $0.kind == .recurringCost }
        XCTAssertEqual(condo.map(\.date), [Self.date(2026, 1, 15), Self.date(2026, 4, 15), Self.date(2026, 7, 15), Self.date(2026, 10, 15)])
        XCTAssertEqual(Set(condo.map(\.title)), ["Condomínio"])
        let renewal = obligations.filter { $0.kind == .insuranceRenewal }
        XCTAssertEqual(renewal.map(\.date), [Self.date(2026, 3, 1)])
        XCTAssertFalse(renewal[0].isEstimate)
        XCTAssertEqual(obligations.map(\.date), obligations.map(\.date).sorted())
    }

    func testUKDeadlinesOnlyForUKTaxpayerOwners() throws {
        try db.write { db in
            var person = Person(name: "Person A", ptNif: "000000000")
            try People.save(db: db, &person)
            try Properties.setOwners(db: db, propertyId: propertyId, [PropertyOwner(propertyId: propertyId, personId: person.id!, shareBasisPoints: 10_000)])
        }
        func ukCount() throws -> Int {
            try db.read { db in
                try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: Self.date(2026, 1, 1), to: Self.date(2027, 1, 1),
                                                 today: Self.date(2025, 12, 31))
                    .filter { $0.kind == .ukSelfAssessmentJanuary || $0.kind == .ukSelfAssessmentJuly }.count
            }
        }
        XCTAssertEqual(try ukCount(), 0)
        try db.write { db in _ = try Properties.setOwners(db: db, propertyId: propertyId, []) }
        XCTAssertEqual(try ukCount(), 0) // no owners: no UK deadlines
        try db.write { db in
            var person = try Person.fetchOne(db)!
            try Properties.setOwners(db: db, propertyId: propertyId, [PropertyOwner(propertyId: propertyId, personId: person.id!, shareBasisPoints: 10_000)])
            person.ukUtr = "0000000000"
            try People.save(db: db, &person)
        }
        XCTAssertEqual(try ukCount(), 2)
    }

    // MARK: Checks

    func testChecks() throws {
        let report = try db.read { db in
            try PropertyChecks.run(db: db, propertyId: propertyId, period: PropertyPeriod.calendarYear(2025).interval, today: Self.date(2025, 8, 15))
        }
        // July's window closed on 11 August; August's is still open.
        XCTAssertEqual(report.monthsWithoutReceipt.map(\.month.start), [Self.date(2025, 7, 1)])
        XCTAssertEqual(report.receiptsWithoutCredit.map(\.receiptNumber), ["3", "4"])
        XCTAssertEqual(report.creditsWithoutReceipt, [])
        let deposit = try XCTUnwrap(report.deposit)
        XCTAssertEqual(deposit.heldMinorUnits, 300_000)
        XCTAssertEqual(deposit.expectedDepositMinorUnits, 200_000)
        XCTAssertEqual(deposit.expectedWithAdvanceMinorUnits, 300_000)
        XCTAssertTrue(deposit.matches)
        XCTAssertEqual(deposit.matchedInterpretation, .depositAndAdvanceRent)
        // Two instalments missed: the calendar drops the pattern, the checks keep chasing it.
        XCTAssertEqual(report.missingRecurringCosts.map(\.pattern.title), ["Mortgage instalment"])
        XCTAssertEqual(report.issueCount, 1 + 2 + 1)
        let early = try db.read { db in
            try PropertyChecks.run(db: db, propertyId: propertyId, period: PropertyPeriod.calendarYear(2025).interval, today: Self.date(2025, 8, 1))
        }
        XCTAssertEqual(early.monthsWithoutReceipt, [])
        // The July instalment (due 5 July) is more than 15 days late; condomínio (15 July) isn't due yet.
        XCTAssertEqual(early.missingRecurringCosts.map(\.pattern.title), ["Mortgage instalment"])
        XCTAssertEqual(early.missingRecurringCosts.first?.expectedDate, Self.date(2025, 7, 5))

        // A credit nobody's receipt explains shows up; a deposit short of both expectations too.
        try add(bank, Self.date(2025, 7, 20), 99_999, "rent")
        try add(ids["deposit"]!, Self.date(2025, 7, 1), 100_000, "fromBank")
        let later = try db.read { db in
            try PropertyChecks.run(db: db, propertyId: propertyId, period: PropertyPeriod.calendarYear(2025).interval, today: Self.date(2025, 8, 15))
        }
        XCTAssertEqual(later.creditsWithoutReceipt.map(\.amountMinorUnits), [99_999])
        XCTAssertEqual(later.deposit?.heldMinorUnits, 200_000)
        XCTAssertEqual(later.deposit?.differenceMinorUnits, 0)
        // Within €1 still matches, and says by how much.
        try add(ids["deposit"]!, Self.date(2025, 7, 2), -60, "fromBank")
        let close = try db.read { db in
            try PropertyChecks.run(db: db, propertyId: propertyId, period: PropertyPeriod.calendarYear(2025).interval, today: Self.date(2025, 8, 15))
        }
        XCTAssertEqual(close.deposit?.matchedInterpretation, .depositOnly)
        XCTAssertEqual(close.deposit?.differenceMinorUnits, 60)
        try add(ids["deposit"]!, Self.date(2025, 7, 3), -5_000, "fromBank")
        let off = try db.read { db in
            try PropertyChecks.run(db: db, propertyId: propertyId, period: PropertyPeriod.calendarYear(2025).interval, today: Self.date(2025, 8, 15))
        }
        XCTAssertNil(off.deposit?.matchedInterpretation)
        XCTAssertEqual(off.deposit?.differenceMinorUnits, 5_060)
        XCTAssertEqual(later.deposit?.matchedInterpretation, .depositOnly) // 2 months' deposit, no advance
    }

    // MARK: Evidence

    func testDefaultRulesListEachReceiptAndTenancy() throws {
        let period = PropertyPeriod.calendarYear(2025).interval
        try db.write { db in
            XCTAssertEqual(try PropertyEvidence.seedRules(db: db, propertyId: propertyId).map(\.name),
                           ["Property A: rent receipts", "Property A: tenancy contracts"])
            XCTAssertEqual(try PropertyEvidence.seedRules(db: db, propertyId: propertyId), []) // idempotent

            var items = try MissingEvidence.items(db: db, period: period)
            XCTAssertEqual(items.map(\.title).sorted(), ["Rent receipt 1 · Room Contract AB", "Rent receipt 2 · Room Contract AB",
                                                          "Rent receipt 3 · Room Contract AB", "Rent receipt 4 · Room Contract AB",
                                                          "Tenancy contract · Room Contract AB"])
            let fourth = try XCTUnwrap(items.first { $0.target.entity == .rentReceipt(ids["receipt4"]!) })
            XCTAssertEqual(fourth.expectedPeriod, DateInterval(start: Self.date(2025, 4, 1), end: Self.date(2025, 7, 1)))
            XCTAssertEqual(fourth.expectedAmountMinorUnits, 300_000)
            XCTAssertEqual(fourth.currency, .eur)
            XCTAssertEqual(fourth.usualSource, "Portal das Finanças")

            let sha = UUID().uuidString
            var pdf = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha.prefix(2))/\(sha).pdf", originalFileName: "r1.pdf", byteCount: 1,
                                       canonicalName: "Receipt 1", kind: .rentReceipt, addedAt: Date())
            try pdf.insert(db)
            try EvidenceLinks.link(db: db, documentId: pdf.id!, to: .rentReceipt(ids["receipt1"]!))
            items = try MissingEvidence.items(db: db, period: period)
            XCTAssertEqual(items.first { $0.target.entity == .rentReceipt(ids["receipt1"]!) }?.status, .satisfied)
            XCTAssertEqual(MissingEvidence.progress(items).done, 1)
            // Only receipts meeting the period.
            XCTAssertEqual(try MissingEvidence.items(db: db, period: PropertyPeriod.calendarYear(2026).interval).map(\.title),
                           ["Tenancy contract · Room Contract AB"])

            var bad = EvidenceRequirement(name: "Bad", scope: .recordsOfProperty(propertyId: propertyId, recordType: .account), kinds: [])
            XCTAssertThrowsError(try EvidenceRequirements.save(db: db, &bad)) {
                XCTAssertEqual($0 as? EvidenceRequirementError, .unsupportedRecordType)
            }
            XCTAssertTrue(try Properties.delete(db: db, id: propertyId))
            XCTAssertEqual(try EvidenceRequirement.fetchCount(db), 0)
        }
    }

    // MARK: Page data

    func testReceiptRowsDrillDownTitlesAndRelatedRules() throws {
        try db.write { db in
            let rows = try PropertyPage.receiptRows(db: db, tenancyId: ids["tenancy"]!)
            XCTAssertEqual(rows.map(\.receipt.receiptNumber), ["1", "2", "3", "4"])
            XCTAssertEqual(rows.map(\.isPaid), [true, true, false, false])
            XCTAssertEqual(rows[1].payments.map(\.transaction.amountMinorUnits), [115_000])
            XCTAssertEqual(rows[1].payments.first?.payment.otherMinorUnits, 15_000)

            let year = PropertyPeriod.calendarYear(2025).interval
            XCTAssertEqual(try PropertyPage.transactions(db: db, propertyId: propertyId, period: year, drillDown: .rentCredits).count, 2)
            XCTAssertEqual(try PropertyPage.transactions(db: db, propertyId: propertyId, period: year, drillDown: .costs(categoryId: ids["condo"]!)).count, 4)
            XCTAssertEqual(try PropertyPage.transactions(db: db, propertyId: propertyId, period: year, drillDown: .costs(categoryId: nil)).count, 4 + 1 + 1 + 1 + 6)
            XCTAssertEqual(try PropertyPage.transactions(db: db, propertyId: propertyId, period: year, drillDown: .mortgage).count, 12)
            XCTAssertEqual(try PropertyPage.transactions(db: db, propertyId: propertyId, period: year, drillDown: .mortgageInterest)
                .map(\.amountMinorUnits), Array(repeating: -20_000, count: 6))
            XCTAssertEqual(try PropertyPage.transactions(db: db, propertyId: propertyId, period: year, drillDown: .income).count, 2)

            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            try Properties.setOwners(db: db, propertyId: propertyId, [PropertyOwner(propertyId: propertyId, personId: person.id!, shareBasisPoints: 10_000)])
            let titles = try PropertyEvidence.entityTitles(db: db)
            XCTAssertEqual(titles[.property(propertyId)], "Property A")
            XCTAssertEqual(titles[.person(person.id!)], "Person A")
            XCTAssertEqual(titles[.tenancy(ids["tenancy"]!)], "Room Contract AB (Property A)")
            XCTAssertEqual(try PropertyEvidence.title(db: db, entity: .rentReceipt(ids["receipt2"]!)), "Rent receipt 2 · Room Contract AB")
            XCTAssertNil(try PropertyEvidence.title(db: db, entity: .account(bank)))

            let seeded = try PropertyEvidence.seedRules(db: db, propertyId: propertyId).compactMap(\.id)
            var condo = EvidenceRequirement(name: "Condo", scope: .transactionsInCategory(categoryId: ids["condo"]!), kinds: [])
            try EvidenceRequirements.save(db: db, &condo)
            var instalments = EvidenceRequirement(name: "Instalments", scope: .transactionsMatching(categoryIds: [ids["toLoan"]!], accountIds: [], descriptionContains: nil), kinds: [])
            try EvidenceRequirements.save(db: db, &instalments)
            var deed = EvidenceRequirement(name: "Deed", scope: .single(entity: .property(propertyId)), kinds: [])
            try EvidenceRequirements.save(db: db, &deed)
            var p60 = EvidenceRequirement(name: "P60", scope: .single(entity: EvidenceEntity(type: .taxYear, id: 2025)), kinds: [])
            try EvidenceRequirements.save(db: db, &p60)
            XCTAssertEqual(try PropertyEvidence.relatedRequirementIds(db: db, propertyId: propertyId),
                           Set(seeded + [condo.id!, instalments.id!, deed.id!]))
        }
    }

    // MARK: Review fixes

    func testInterestOutsideThePropertysCategoriesStillLeavesTheCash() throws {
        try db.write { db in
            var other = Category(name: "Loan interest", type: .expense)
            try other.insert(db)
            ids["otherInterest"] = other.id!
        }
        try add(ids["loan"]!, Self.date(2025, 6, 20), -5_000, "otherInterest")
        let summary = try db.read { db in
            try PropertyFinance.summary(db: db, propertyId: propertyId, period: .calendarYear(2025), today: Self.date(2026, 1, 10))
        }
        let totals = summary.totals
        XCTAssertEqual(totals.mortgageInterest.native, 125_000)
        XCTAssertEqual(totals.interestOutsideCosts.native, 5_000)
        let outside = try db.read { db in
            try PropertyPage.transactions(db: db, propertyId: propertyId, period: PropertyPeriod.calendarYear(2025).interval,
                                          drillDown: .mortgageInterestOutsideCosts)
        }
        XCTAssertEqual(outside.map(\.amountMinorUnits), [-5_000])
        XCTAssertEqual(totals.costs.native, 40_000 + 120_000 + 30_000 + 40_000 + 5_882) // unchanged
        XCTAssertEqual(totals.mortgageCapital.native, 306_000 - 125_000)
        XCTAssertEqual(totals.netCashFlow.native, totals.income.native - totals.costs.native - 5_000 - totals.mortgageCapital.native)
        XCTAssertEqual(summary.netYield!, Double(totals.income.native - totals.costs.native - 5_000) / 20_000_000, accuracy: 1e-9)
    }

    func testYieldsCoverTheElapsedOwnedPart() throws {
        try db.write { db in
            var property = try Property.fetchOne(db, key: propertyId)!
            property.purchaseDate = Self.date(2025, 2, 1)
            try Properties.save(db: db, &property)
        }
        let summary = try db.read { db in
            try PropertyFinance.summary(db: db, propertyId: propertyId, period: .calendarYear(2025), today: Self.date(2025, 6, 30))
        }
        // 1 February (purchase) to 30 June: 150 days, February–June rent per receipts.
        XCTAssertEqual(summary.yieldInterval, DateInterval(start: Self.date(2025, 2, 1), end: Self.date(2025, 7, 1)))
        XCTAssertEqual(summary.grossYield!, 500_000.0 / 20_000_000 / (150.0 / 365), accuracy: 1e-9)
        let future = try db.read { db in
            try PropertyFinance.summary(db: db, propertyId: propertyId, period: .calendarYear(2030), today: Self.date(2025, 6, 30))
        }
        XCTAssertNil(future.yieldInterval)
        XCTAssertNil(future.grossYield)
    }

    func testStalePatternsDropAndInsuranceByCadence() throws {
        try db.write { db in
            var contents = Category(name: "Contents insurance", type: .expense, groupId: try CategoryGroup.fetchOne(db)!.id)
            try contents.insert(db)
            ids["contents"] = contents.id!
            var life = Category(name: "Life insurance", type: .expense, groupId: try CategoryGroup.fetchOne(db)!.id)
            try life.insert(db)
            ids["life"] = life.id!
        }
        for month in 1...9 { try add(bank, Self.date(2025, month, 8), -1_500, "contents") } // monthly
        try add(bank, Self.date(2024, 9, 1), -9_000, "life")
        try add(bank, Self.date(2025, 9, 1), -9_000, "life") // yearly, no document
        let obligations = try db.read { db in
            try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: Self.date(2025, 7, 1), to: Self.date(2026, 10, 1),
                                             today: Self.date(2025, 9, 30))
        }
        XCTAssertTrue(obligations.contains { $0.kind == .recurringCost && $0.title == "Contents insurance" })
        XCTAssertFalse(obligations.contains { $0.kind == .insuranceRenewal && $0.categoryId == ids["contents"] })
        XCTAssertEqual(obligations.filter { $0.kind == .insuranceRenewal && $0.categoryId == ids["life"] }.map(\.date), [Self.date(2026, 9, 1)])
        XCTAssertFalse(obligations.contains { $0.kind == .recurringCost && $0.title == "Life insurance" })
        // Building insurance: one payment, no document → no renewal guessed.
        XCTAssertFalse(obligations.contains { $0.kind == .insuranceRenewal && $0.categoryId == ids["insurance"] })

        // Monthly contents insurance last paid 8 September; by 9 November (two months on) it has stopped.
        let patterns = try db.read { db in try PropertyCalendar.recurringPatterns(db: db, propertyId: propertyId, asOf: Self.date(2025, 11, 9)) }
        XCTAssertFalse(patterns.contains { $0.categoryId == ids["contents"] })
        let earlier = try db.read { db in try PropertyCalendar.recurringPatterns(db: db, propertyId: propertyId, asOf: Self.date(2025, 11, 8)) }
        XCTAssertTrue(earlier.contains { $0.categoryId == ids["contents"] })
    }

    // MARK: Review fixes 2

    func testYearlyRenewalsAndCostsSurviveMonthsAfterThePayment() throws {
        try db.write { db in
            var life = Category(name: "Life insurance", type: .expense, groupId: try CategoryGroup.fetchOne(db)!.id)
            try life.insert(db)
            ids["life"] = life.id!
            var licence = Category(name: "Licence", type: .expense, groupId: try CategoryGroup.fetchOne(db)!.id)
            try licence.insert(db)
            ids["licence"] = licence.id!
        }
        try add(bank, Self.date(2024, 9, 1), -9_000, "life")
        try add(bank, Self.date(2025, 9, 1), -9_000, "life")
        try add(bank, Self.date(2024, 3, 10), -2_000, "licence")
        try add(bank, Self.date(2025, 3, 10), -2_000, "licence")
        let obligations = try db.read { db in
            try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: Self.date(2026, 3, 1), to: Self.date(2027, 3, 1),
                                             today: Self.date(2026, 3, 1))
        }
        XCTAssertEqual(obligations.filter { $0.kind == .insuranceRenewal && $0.categoryId == ids["life"] }.map(\.date), [Self.date(2026, 9, 1)])
        XCTAssertEqual(obligations.filter { $0.kind == .recurringCost && $0.categoryId == ids["licence"] }.map(\.date), [Self.date(2026, 3, 10)])
        // A yearly cost can be overdue: the licence due 10 March 2026, checked in April.
        let checks = try db.read { db in
            try PropertyChecks.run(db: db, propertyId: propertyId, period: PropertyPeriod.calendarYear(2026).interval, today: Self.date(2026, 4, 1))
        }
        XCTAssertTrue(checks.missingRecurringCosts.contains { $0.pattern.categoryId == ids["licence"] && $0.expectedDate == Self.date(2026, 3, 10) })
    }

    func testIMISkipsOnlyMonthsTheHistoryCovers() throws {
        // May and November instalments for two years (paid in early December once): no August.
        try add(bank, Self.date(2024, 5, 20), -30_000, "imi")
        try add(bank, Self.date(2024, 12, 2), -30_000, "imi")
        try add(bank, Self.date(2025, 11, 25), -30_000, "imi")
        let obligations = try db.read { db in
            try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: Self.date(2026, 1, 1), to: Self.date(2027, 1, 1),
                                             today: Self.date(2025, 12, 31))
        }
        let imi = obligations.filter { $0.kind == .imiInstalment }
        XCTAssertEqual(imi.map(\.date), [Self.date(2026, 5, 31), Self.date(2026, 11, 30)])
        XCTAssertEqual(imi.map(\.expectedMinorUnits), [30_000, 30_000])
    }
}
