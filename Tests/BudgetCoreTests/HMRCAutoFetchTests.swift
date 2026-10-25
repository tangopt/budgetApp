import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// A stand-in for HMRC's file: synthetic rates per year (nil: offline or not published).
final class StubHMRCRateFetcher: HMRCRateFetching, @unchecked Sendable {
    var files: [Int: [HMRCPublishedRate]] = [:]
    private(set) var requested: [Int] = []
    /// Runs as a year is asked for (before it answers).
    var onFetch: ((Int) throws -> Void)?

    func fetchAverageRates(for year: UKTaxYear) async -> [HMRCPublishedRate]? {
        requested.append(year.startYear)
        try? onFetch?(year.startYear)
        return files[year.startYear]
    }
}

/// HMRC's average rates fetched automatically for the ended years that lack one: which years
/// and currencies, never replacing a stored rate, quiet failures retried once a day.
/// Synthetic EUR property owned 50/50 by Person A and Person B from May 2022; synthetic rates.
final class HMRCAutoFetchTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private let today = HMRCAutoFetchTests.date(2026, 10, 18)

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func id(_ key: String) -> Int64 { ids[key]! }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            ids["A"] = a.id!; ids["B"] = b.id!
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: a.id!, shareBasisPoints: 5_000, fromDate: Self.date(2022, 5, 1)),
                PropertyOwner(propertyId: property.id!, personId: b.id!, shareBasisPoints: 5_000, fromDate: Self.date(2022, 5, 1))
            ])
            // The filed years' rates are in already.
            try HMRCRates.set(db: db, startYear: 2022, currencyCode: "EUR", gbpPerUnit: 0.85, source: .filedReturn)
            try HMRCRates.set(db: db, startYear: 2023, currencyCode: "EUR", gbpPerUnit: 0.86, source: .manual)
        }
    }

    private static let eur2024 = [HMRCPublishedRate(currencyCode: "EUR", unitsPerPound: 1.25), HMRCPublishedRate(currencyCode: "USD", unitsPerPound: 1.3)]

    private func fetch(_ fetcher: StubHMRCRateFetcher, log: HMRCRateFetchLog, on day: Date? = nil) async throws -> HMRCRates.AutoFetchOutcome {
        try await HMRCRates.fetchMissing(db: db, today: day ?? today, fetcher: fetcher, log: log)
    }

    func testFetchesTheEndedYearsWithoutARateOnly() async throws {
        let missing = try await db.read { db in try HMRCRates.missing(db: db, today: self.today) }
        // 2022/23 and 2023/24 have rates; 2026/27 hasn't ended.
        XCTAssertEqual(missing, [2024: ["EUR"], 2025: ["EUR"]])

        let fetcher = StubHMRCRateFetcher()
        fetcher.files[2024] = Self.eur2024
        let outcome = try await fetch(fetcher, log: HMRCRateFetchMemoryLog())
        XCTAssertEqual(fetcher.requested, [2024, 2025])
        XCTAssertEqual(outcome.fetched.map(\.currencyCode), ["EUR"])
        XCTAssertEqual(outcome.failedYears, [2025])
        try await db.read { db in
            let rate = try HMRCRates.rate(db: db, startYear: 2024, currencyCode: "EUR")
            XCTAssertEqual(rate?.source, .hmrcPublished)
            XCTAssertEqual(rate?.unitsPerPound, 1.25)
            XCTAssertEqual(rate!.gbpPerUnit, 0.8, accuracy: 1e-12)
            XCTAssertEqual(rate?.fetchedAt, self.today)
            XCTAssertEqual(rate?.isFetchedAutomatically, true)
            XCTAssertEqual(rate?.bothWaysText, "€1 = £0.8000 (1.2500 per £1)")
            // A currency nothing uses isn't stored; the filed and manual rates stay.
            XCTAssertNil(try HMRCRates.rate(db: db, startYear: 2024, currencyCode: "USD"))
            XCTAssertEqual(try HMRCRates.rate(db: db, startYear: 2022, currencyCode: "EUR")?.gbpPerUnit, 0.85)
            XCTAssertEqual(try HMRCRates.rate(db: db, startYear: 2023, currencyCode: "EUR")?.source, .manual)
            XCTAssertNil(try HMRCRates.rate(db: db, startYear: 2025, currencyCode: "EUR"))
        }
    }

    func testAFailedYearIsAskedForAgainOnlyAfterADay() async throws {
        let fetcher = StubHMRCRateFetcher()
        let log = HMRCRateFetchMemoryLog()
        _ = try await fetch(fetcher, log: log)
        XCTAssertEqual(fetcher.requested, [2024, 2025])
        // Later the same day: nothing is asked.
        let again = try await fetch(fetcher, log: log, on: today.addingTimeInterval(3_600))
        XCTAssertEqual(again.throttledYears, [2024, 2025])
        XCTAssertEqual(fetcher.requested, [2024, 2025])
        // A day later the file is out.
        fetcher.files[2025] = [HMRCPublishedRate(currencyCode: "EUR", unitsPerPound: 1.2)]
        let tomorrow = try await fetch(fetcher, log: log, on: today.addingTimeInterval(86_400))
        XCTAssertEqual(fetcher.requested, [2024, 2025, 2024, 2025])
        XCTAssertEqual(tomorrow.fetched.map(\.startYear), [2025])
        XCTAssertEqual(tomorrow.failedYears, [2024])
        // Once stored, a year isn't asked for again.
        _ = try await fetch(fetcher, log: log, on: today.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(fetcher.requested.suffix(1), [2024])
    }

    func testARateEnteredMeanwhileIsNeverReplaced() async throws {
        let fetcher = StubHMRCRateFetcher()
        fetcher.files[2024] = Self.eur2024
        fetcher.files[2025] = Self.eur2024
        fetcher.onFetch = { [db] year in
            guard year == 2024 else { return }
            try db.write { db in try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.9, source: .manual) }
        }
        let outcome = try await fetch(fetcher, log: HMRCRateFetchMemoryLog())
        XCTAssertEqual(outcome.fetched.map(\.startYear), [2025])
        try await db.read { db in
            XCTAssertEqual(try HMRCRates.rate(db: db, startYear: 2024, currencyCode: "EUR")?.source, .manual)
            XCTAssertEqual(try HMRCRates.rate(db: db, startYear: 2024, currencyCode: "EUR")?.gbpPerUnit, 0.9)
        }
    }

    func testCurrenciesComeFromThePropertiesTheirAccountsAndTheYearsSources() throws {
        try db.write { db in
            // A GBP property with a EUR account still needs the EUR rate.
            var flat = Property(name: "Property B", country: "UK", currency: .gbp)
            try Properties.save(db: db, &flat)
            _ = try Properties.setOwners(db: db, propertyId: flat.id!, [
                PropertyOwner(propertyId: flat.id!, personId: id("A"), shareBasisPoints: 10_000, fromDate: Self.date(2020, 6, 1))
            ])
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            try Properties.setAccount(db: db, propertyId: flat.id!, accountId: account.id!, role: .current)
        }
        let missing = try db.read { db in try HMRCRates.missing(db: db, today: today) }
        XCTAssertEqual(missing, [2020: ["EUR"], 2021: ["EUR"], 2024: ["EUR"], 2025: ["EUR"]])

        // Someone with only an employment, all in GBP, needs nothing; EUR other income or a
        // EUR manual item needs that year's EUR rate.
        let other = try TestDatabase.migratedManager()
        var personId: Int64 = 0
        try other.dbQueue.write { db in
            var c = Person(name: "Person C")
            try People.save(db: db, &c)
            personId = c.id!
            var job = Employment(startYear: 2023, personId: c.id!, employerName: "Employer A")
            try Employments.save(db: db, &job)
        }
        XCTAssertEqual(try other.dbQueue.read { db in try HMRCRates.missing(db: db, today: today) }, [:])
        try other.dbQueue.write { db in
            var income = OtherIncome(startYear: 2023, personId: personId, kind: .foreignInterest, amountMinorUnits: 1_000, currency: .eur)
            try OtherIncomes.save(db: db, &income)
            var item = TaxManualItem(startYear: 2024, personId: personId, propertyId: nil, expenseType: .otherExpense, label: "Fee",
                                     amountMinorUnits: 1_000, currency: .eur)
            try TaxManualItems.save(db: db, &item)
        }
        XCTAssertEqual(try other.dbQueue.read { db in try HMRCRates.missing(db: db, today: today) }, [2023: ["EUR"], 2024: ["EUR"]])
    }

    func testBeforeSixthAprilTheYearHasNotEnded() throws {
        let missing = try db.read { db in try HMRCRates.missing(db: db, today: Self.date(2026, 4, 5)) }
        XCTAssertEqual(missing, [2024: ["EUR"]])
        XCTAssertEqual(try db.read { db in try HMRCRates.missing(db: db, today: Self.date(2026, 4, 6)) }, [2024: ["EUR"], 2025: ["EUR"]])
    }

    func testTheDefaultsLogKeepsTheAttempts() throws {
        let suite = "HMRCAutoFetchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = HMRCRateFetchDefaultsLog(defaults: defaults)
        XCTAssertNil(log.lastAttempt(startYear: 2025))
        log.recordAttempt(startYear: 2025, at: today)
        XCTAssertEqual(HMRCRateFetchDefaultsLog(defaults: defaults).lastAttempt(startYear: 2025), today)
        XCTAssertNil(log.lastAttempt(startYear: 2024))
    }

    func testAFetchTheUserAskedForIsNotNotedAsAutomatic() throws {
        try db.write { db in
            let stored = try HMRCRates.storePublished(db: db, startYear: 2024, rates: Self.eur2024, codes: ["EUR"])
            XCTAssertEqual(stored.first?.isFetchedAutomatically, false)
        }
    }
}
