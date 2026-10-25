import XCTest
import GRDB
@testable import BudgetCore

/// Tax years, splits, attribution rules, the category → expense type map, manual items and
/// HMRC rates (plan phase 3 Task 1). Synthetic people and amounts.
final class TaxSettingsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var personA: Int64 = 0
    private var personB: Int64 = 0
    private var propertyId: Int64 = 0
    private var groupId: Int64 = 0

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            personA = a.id!; personB = b.id!
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            propertyId = property.id!
            _ = try Properties.setOwners(db: db, propertyId: propertyId, [
                PropertyOwner(propertyId: propertyId, personId: personA, shareBasisPoints: 5_000),
                PropertyOwner(propertyId: propertyId, personId: personB, shareBasisPoints: 5_000)
            ])
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            groupId = group.id!
            try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: groupId)
        }
    }

    // MARK: Tax years

    func testEnsureCreatesOnceAndDeadlinesFollowTheYear() throws {
        let year = try db.write { db -> TaxYear in
            let first = try TaxYears.ensure(db: db, startYear: 2024, personId: personA)
            let again = try TaxYears.ensure(db: db, startYear: 2024, personId: personA)
            XCTAssertEqual(first.id, again.id)
            return first
        }
        XCTAssertEqual(year.status, .preparing)
        let deadlines = year.ukTaxYear.deadlines
        XCTAssertEqual(deadlines.paperReturn, Self.date(2025, 10, 31))
        XCTAssertEqual(deadlines.onlineReturnAndBalancingPayment, Self.date(2026, 1, 31))
        XCTAssertEqual(deadlines.secondPaymentOnAccount, Self.date(2026, 7, 31))
        XCTAssertEqual(year.ukTaxYear.monthsInterval, DateInterval(start: Self.date(2024, 4, 1), end: Self.date(2025, 4, 1)))
    }

    func testStatusSavesAndPersonMustExist() throws {
        try db.write { db in
            var year = try TaxYears.ensure(db: db, startYear: 2023, personId: personA)
            year.status = .filed
            year.notes = "  "
            try TaxYears.save(db: db, &year)
            XCTAssertEqual(try TaxYears.year(db: db, startYear: 2023, personId: personA)?.status, .filed)
            XCTAssertNil(try TaxYears.year(db: db, startYear: 2023, personId: personA)?.notes)
            XCTAssertThrowsError(try TaxYears.ensure(db: db, startYear: 2023, personId: 999)) { XCTAssertEqual($0 as? TaxError, .personNotFound) }
        }
    }

    func testTaxYearIsALinkableEntityAndItsLinksGoWithIt() throws {
        try db.write { db in
            let year = try TaxYears.ensure(db: db, startYear: 2024, personId: personA)
            var doc = EvidenceDocument(sha256: "aa", storedRelativePath: "aa/aa.pdf", originalFileName: "SA302.pdf", byteCount: 1, addedAt: Date())
            try doc.insert(db)
            try EvidenceLinks.link(db: db, documentId: doc.id!, to: .taxYear(year.id!))
            XCTAssertThrowsError(try EvidenceLinks.link(db: db, documentId: doc.id!, to: .taxYear(999)))
            _ = try TaxYear.deleteOne(db, key: year.id!)
            XCTAssertEqual(try DocumentLink.fetchCount(db), 0)
        }
    }

    func testEvidenceTitles() throws {
        try db.write { db in
            let year = try TaxYears.ensure(db: db, startYear: 2024, personId: personA)
            var item = TaxManualItem(startYear: 2024, personId: personA, propertyId: nil, expenseType: .otherExpense, label: "Postage",
                                     amountMinorUnits: 500, currency: .gbp)
            try TaxManualItems.save(db: db, &item)
            XCTAssertEqual(try TaxEvidence.title(db: db, entity: .taxYear(year.id!)), "2024/25 · Person A")
            XCTAssertEqual(try TaxEvidence.title(db: db, entity: .taxManualItem(item.id!)), "Postage · 2024/25 · A")
            XCTAssertNil(try TaxEvidence.title(db: db, entity: .taxYear(999)))
        }
    }

    // MARK: Splits

    func testShareFallsBackFromTypeToAllTypesToOwnership() throws {
        try db.write { db in
            XCTAssertEqual(try TaxSplits.share(db: db, startYear: 2024, personId: personA, propertyId: propertyId, expenseType: .insurance),
                           TaxShare(shareBasisPoints: 5_000, origin: .ownership))
            try TaxSplits.set(db: db, startYear: 2024, personId: personA, propertyId: propertyId, expenseType: nil, shareBasisPoints: 6_000)
            try TaxSplits.set(db: db, startYear: 2024, personId: personA, propertyId: propertyId, expenseType: .insurance, shareBasisPoints: 10_000)
            XCTAssertEqual(try TaxSplits.share(db: db, startYear: 2024, personId: personA, propertyId: propertyId, expenseType: .insurance),
                           TaxShare(shareBasisPoints: 10_000, origin: .splitForType))
            XCTAssertEqual(try TaxSplits.share(db: db, startYear: 2024, personId: personA, propertyId: propertyId, expenseType: .councilTax),
                           TaxShare(shareBasisPoints: 6_000, origin: .splitForAllTypes))
            // Other years are untouched; updating keeps one row; nil removes.
            XCTAssertEqual(try TaxSplits.share(db: db, startYear: 2025, personId: personA, propertyId: propertyId, expenseType: .insurance).origin, .ownership)
            try TaxSplits.set(db: db, startYear: 2024, personId: personA, propertyId: propertyId, expenseType: nil, shareBasisPoints: 7_000)
            XCTAssertEqual(try TaxSplits.splits(db: db, startYear: 2024, propertyId: propertyId).count, 2)
            try TaxSplits.set(db: db, startYear: 2024, personId: personA, propertyId: propertyId, expenseType: .insurance, shareBasisPoints: nil)
            XCTAssertEqual(try TaxSplits.share(db: db, startYear: 2024, personId: personA, propertyId: propertyId, expenseType: .insurance),
                           TaxShare(shareBasisPoints: 7_000, origin: .splitForAllTypes))
            XCTAssertThrowsError(try TaxSplits.set(db: db, startYear: 2024, personId: personA, propertyId: propertyId, expenseType: nil, shareBasisPoints: 10_001))
        }
    }

    func testOwnershipShareIsWeightedByDaysOwnedInTheYear() throws {
        try db.write { db in
            // A owns 100% until 5 Oct 2024 (half the year, 183 of 365 days), then 50%.
            _ = try Properties.setOwners(db: db, propertyId: propertyId, [
                PropertyOwner(propertyId: propertyId, personId: personA, shareBasisPoints: 10_000, toDate: Self.date(2024, 10, 5)),
                PropertyOwner(propertyId: propertyId, personId: personA, shareBasisPoints: 5_000, fromDate: Self.date(2024, 10, 6)),
                PropertyOwner(propertyId: propertyId, personId: personB, shareBasisPoints: 5_000, fromDate: Self.date(2024, 10, 6))
            ])
            let a = try TaxSplits.ownershipShare(db: db, startYear: 2024, personId: personA, propertyId: propertyId)
            let b = try TaxSplits.ownershipShare(db: db, startYear: 2024, personId: personB, propertyId: propertyId)
            XCTAssertEqual(a + b, 10_000)
            XCTAssertEqual(b, Int((5_000.0 * 182 / 365).rounded()))
        }
    }

    // MARK: Rules

    func testRulesDefaultSeedAndOverridePerYear() throws {
        try db.write { db in
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .councilTax, startYear: 2024).rule, .previousCalendarYear)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .rentalIncome, startYear: 2024).rule, .byRentPeriod)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .financeCost, startYear: 2024).rule, .byDate)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .serviceCharge, startYear: 2024).rule, .byQuotaMonth)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .insurance, startYear: 2024).rule, .apportionByCover)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .foreignTax, startYear: 2024).rule, .apportionCalendarYear)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .accountancy, startYear: 2024).rule, .byDate)

            XCTAssertEqual(try TaxAttributionRules.seedDefaults(db: db).count, TaxExpenseType.allCases.count)
            XCTAssertEqual(try TaxAttributionRules.seedDefaults(db: db).count, 0)

            try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: nil, rule: .apportionByCover, defaultCoverMonths: 6)
            try TaxAttributionRules.set(db: db, expenseType: .serviceCharge, startYear: 2023, rule: .byDate)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .insurance, startYear: 2024).defaultCoverMonths, 6)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .serviceCharge, startYear: 2023).rule, .byDate)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .serviceCharge, startYear: 2024).rule, .byQuotaMonth)
            XCTAssertEqual(try TaxAttributionRules.all(db: db).count, TaxExpenseType.allCases.count + 1)
            XCTAssertTrue(try TaxAttributionRules.remove(db: db, expenseType: .serviceCharge, startYear: 2023))
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .serviceCharge, startYear: 2023).rule, .byQuotaMonth)
            XCTAssertThrowsError(try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: nil, rule: .apportionByCover, defaultCoverMonths: 0))
        }
    }

    // MARK: Expense type map

    func testSuggestedTypesFromCategoryNames() {
        let cases: [(String, CategoryType, TaxExpenseType)] = [
            ("Rental income", .income, .rentalIncome),
            ("Insurance refund", .income, .notDeductible),
            ("Mortgage interest", .expense, .financeCost),
            ("Condomínio", .expense, .serviceCharge),
            ("Building insurance", .expense, .insurance),
            ("Contents insurance", .expense, .otherExpense),
            ("Life insurance", .expense, .notDeductible),
            ("Seguro de vida", .expense, .notDeductible),
            ("IMI", .expense, .councilTax),
            ("PT tax", .expense, .foreignTax),
            ("PT accountant", .expense, .accountancy),
            ("UK accountant", .expense, .accountancy),
            ("Legal fees", .expense, .legalFees),
            ("Repairs", .expense, .repairs),
            ("Imposto do Selo", .expense, .otherExpense),
            ("Stamp duty", .expense, .otherExpense),
            ("Imposto IRS", .expense, .foreignTax),
            ("Utilities", .expense, .notDeductible),
            ("Bank fees", .expense, .notDeductible),
            ("BBVA fees", .expense, .notDeductible),
            ("Bank charges", .expense, .notDeductible),
            ("Comissões bancárias", .expense, .notDeductible),
            ("Account maintenance", .expense, .notDeductible),
            ("Letting fees", .expense, .lettingFees),
            ("Agency fees", .expense, .lettingFees),
            ("Sundry fees", .expense, .otherExpense),
            ("Mortgage capital", .expense, .notDeductible),
            ("IRS refund", .income, .foreignTax),
            ("Mortgage instalments", .expense, .notDeductible),
            ("Prestação", .expense, .notDeductible),
            ("Loan principal", .expense, .notDeductible),
            ("Other", .expense, .otherExpense)
        ]
        for (name, type, expected) in cases {
            XCTAssertEqual(TaxExpenseTypeMap.suggestedType(forCategoryName: name, type: type), expected, name)
        }
    }

    func testMapEntriesSeedAndOverride() throws {
        try db.write { db in
            var ids: [String: Int64] = [:]
            for (name, type) in [("Rental income", CategoryType.income), ("Life insurance", .expense), ("Repairs", .expense)] {
                var category = Category(name: name, type: type, groupId: groupId)
                try category.insert(db)
                ids[name] = category.id!
            }
            var outside = Category(name: "Groceries", type: .expense)
            try outside.insert(db)

            let entries = try TaxExpenseTypeMap.entries(db: db, propertyId: propertyId)
            XCTAssertEqual(entries.map(\.category.name), ["Life insurance", "Rental income", "Repairs"])
            XCTAssertTrue(entries.allSatisfy { !$0.isStored })
            XCTAssertEqual(try TaxExpenseTypeMap.seed(db: db, propertyId: propertyId).count, 3)
            XCTAssertEqual(try TaxExpenseTypeMap.seed(db: db, propertyId: propertyId).count, 0)

            try TaxExpenseTypeMap.set(db: db, categoryId: ids["Repairs"]!, expenseType: .otherExpense)
            let after = try TaxExpenseTypeMap.entries(db: db, propertyId: propertyId)
            XCTAssertEqual(after.first { $0.category.name == "Repairs" }?.expenseType, .otherExpense)
            XCTAssertEqual(after.first { $0.category.name == "Life insurance" }?.expenseType, .notDeductible)
            try TaxExpenseTypeMap.set(db: db, categoryId: ids["Repairs"]!, expenseType: nil)
            XCTAssertEqual(try TaxExpenseTypeMap.entries(db: db, propertyId: propertyId).first { $0.category.name == "Repairs" }?.isStored, false)
        }
    }

    // MARK: Manual items

    func testManualItemsValidateAndLinkDocuments() throws {
        try db.write { db in
            var item = TaxManualItem(startYear: 2024, personId: personA, propertyId: propertyId, expenseType: .accountancy,
                                     label: "  UK accountant ", amountMinorUnits: 30_000, currency: .gbp, date: Self.date(2025, 1, 10))
            try TaxManualItems.save(db: db, &item)
            XCTAssertEqual(item.label, "UK accountant")
            var blank = item
            blank.id = nil
            blank.label = " "
            XCTAssertThrowsError(try TaxManualItems.save(db: db, &blank)) { XCTAssertEqual($0 as? TaxError, .blankLabel) }
            var negative = item
            negative.id = nil
            negative.amountMinorUnits = -1
            XCTAssertThrowsError(try TaxManualItems.save(db: db, &negative)) { XCTAssertEqual($0 as? TaxError, .negativeAmount) }
            XCTAssertEqual(try TaxManualItems.items(db: db, startYear: 2024, personId: personA).map(\.id), [item.id])
            XCTAssertEqual(try TaxManualItems.items(db: db, startYear: 2024, personId: personB), [])

            var doc = EvidenceDocument(sha256: "bb", storedRelativePath: "bb/bb.pdf", originalFileName: "Invoice.pdf", byteCount: 1, addedAt: Date())
            try doc.insert(db)
            try EvidenceLinks.link(db: db, documentId: doc.id!, to: .taxManualItem(item.id!))
            XCTAssertEqual(try EvidenceLinks.documents(db: db, for: .taxManualItem(item.id!)).count, 1)
            XCTAssertTrue(try TaxManualItems.delete(db: db, id: item.id!))
            XCTAssertEqual(try DocumentLink.fetchCount(db), 0)
        }
    }

    // MARK: HMRC rates

    func testRatesSetReplaceAndValidate() throws {
        try db.write { db in
            try HMRCRates.set(db: db, startYear: 2023, currencyCode: "eur", gbpPerUnit: 0.86, source: .filedReturn, notes: "From the return")
            let rate = try HMRCRates.rate(db: db, startYear: 2023, currencyCode: "EUR")
            XCTAssertEqual(rate?.gbpPerUnit, 0.86)
            XCTAssertEqual(rate?.source, .filedReturn)
            try HMRCRates.set(db: db, startYear: 2023, currencyCode: "EUR", gbpPerUnit: 0.87, source: .manual)
            XCTAssertEqual(try HMRCRate.fetchCount(db), 1)
            XCTAssertEqual(try HMRCRates.rate(db: db, startYear: 2023, currencyCode: "EUR")?.source, .manual)
            XCTAssertThrowsError(try HMRCRates.set(db: db, startYear: 2023, currencyCode: "EURO", gbpPerUnit: 1, source: .manual))
            XCTAssertThrowsError(try HMRCRates.set(db: db, startYear: 2023, currencyCode: "USD", gbpPerUnit: 0, source: .manual))
            XCTAssertTrue(try HMRCRates.remove(db: db, startYear: 2023, currencyCode: "eur"))
        }
    }

    static let sampleFile = """
        Country,Unit Of Currency,Currency Code,Sterling value of Currency Unit £,Currency Units per £1
        Eurozone,Euro,EUR,0.8000,1.2500
        "Korea, South",Won,KRW,0.0006,1700.0000
        USA,Dollar,USD,0.8000,1.2500
        Ecuador,Dollar,USD,0.8000,1.2500
        Nowhere,Nothing,,0,
        """

    func testRatesForbidDisagreeingForms() throws {
        try db.write { db in
            XCTAssertThrowsError(try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.9, unitsPerPound: 1.25, source: .manual))
            let rate = try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.8, unitsPerPound: 1.25, source: .manual)
            XCTAssertEqual(rate.gbp(1_000), 800)
        }
    }

    func testParsesThousandsSeparatorsAndMatchesCodesInAnyCase() throws {
        let rates = try HMRCRateFile.parse("Country,Unit Of Currency,Currency Code,Sterling value of Currency Unit £,Currency Units per £1\nKorea,Won,krw,0.0006,\"1,700.0000\"")
        XCTAssertEqual(rates, [HMRCPublishedRate(currencyCode: "KRW", unitsPerPound: 1700)])
        try db.write { db in
            XCTAssertEqual(try HMRCRates.storePublished(db: db, startYear: 2024, rates: rates, codes: ["krw"]).count, 1)
        }
    }

    func testParsesTheAverageRatesFile() throws {
        let rates = try HMRCRateFile.parse(Self.sampleFile)
        XCTAssertEqual(rates.map(\.currencyCode), ["EUR", "KRW", "USD"])
        XCTAssertEqual(rates[0].unitsPerPound, 1.25)
        XCTAssertEqual(rates[0].gbpPerUnit, 0.8, accuracy: 1e-12)
        XCTAssertThrowsError(try HMRCRateFile.parse("a,b\n1,2"))
        XCTAssertEqual(HMRCRateFile.averageURL(for: UKTaxYear(startYear: 2024)).lastPathComponent, "average_csv_2025-3.csv")
    }

    func testStorePublishedKeepsManualAndFiledRates() throws {
        let rates = try HMRCRateFile.parse(Self.sampleFile)
        try db.write { db in
            try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.85, source: .manual)
            let stored = try HMRCRates.storePublished(db: db, startYear: 2024, rates: rates, codes: ["EUR", "USD"], now: Self.date(2025, 5, 1))
            XCTAssertEqual(stored.map(\.currencyCode), ["USD"])
            XCTAssertEqual(try HMRCRates.rate(db: db, startYear: 2024, currencyCode: "EUR")?.gbpPerUnit, 0.85)
            XCTAssertNil(try HMRCRates.rate(db: db, startYear: 2024, currencyCode: "KRW"))
            let usd = try HMRCRates.rate(db: db, startYear: 2024, currencyCode: "USD")
            XCTAssertEqual(usd?.unitsPerPound, 1.25)
            XCTAssertEqual(usd?.fetchedAt, Self.date(2025, 5, 1))
            let replaced = try HMRCRates.storePublished(db: db, startYear: 2024, rates: rates, codes: ["EUR"], replaceAll: true)
            XCTAssertEqual(replaced.first?.source, .hmrcPublished)
        }
    }

    func testFetcherReadsTheFileAndReturnsNilOnFailure() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let fetcher = HMRCTradeTariffRateFetcher(session: URLSession(configuration: configuration))
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(Self.sampleFile.utf8)
        let rates = await fetcher.fetchAverageRates(for: UKTaxYear(startYear: 2024))
        XCTAssertEqual(rates?.first?.currencyCode, "EUR")
        StubURLProtocol.statusCode = 404
        let missing = await fetcher.fetchAverageRates(for: UKTaxYear(startYear: 2024))
        XCTAssertNil(missing)
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = nil
    }
}
