import XCTest
import GRDB
@testable import BudgetCore
import TestSupport
import struct BudgetCore.Transaction

/// Step 10 Task 16: the Mortgage terms form shared by the Mac's sheet and the iPad's — the Mac's checks in its words, the
/// terms it builds, and the save through the device writer, refused with nothing saved when it would move a filed return.
final class MortgageTermsEditingTests: XCTestCase {
    private var db: DatabaseQueue!
    private var propertyId: Int64!
    private let today = MortgageTermsEditingTests.day(2026, 10, 15)

    override func setUpWithError() throws {
        db = try TestDatabase.demo()
        propertyId = try db.read { try XCTUnwrap(Property.order(Column("name")).fetchOne($0)?.id) }
    }

    private func form() throws -> MortgageTermsEditing.Form {
        let (terms, overrides) = try db.read { db in
            (try MortgageTerms.terms(db: db, propertyId: propertyId), try MortgageRate.overrides(db: db, propertyId: propertyId))
        }
        return MortgageTermsEditing.Form(terms: terms, overrides: overrides)
    }

    func testMortgageValidationMatchesMac() throws {
        // Each case the Mac's sheet refuses on Save, in its words, and the rules MortgageTerms.save keeps.
        var form = try form()
        form.index = .euribor3M
        form.spreadText = "1.000"
        form.balloonText = ""
        form.borrowedText = ""
        form.totalText = "480"
        XCTAssertEqual(form.validate(today: today), [], "a whole form saves")

        var amount = form
        amount.balloonText = "12a"
        XCTAssertEqual(amount.validate(today: today).first?.message, MortgageTermsEditing.invalidAmount("12a"))
        var borrowed = form
        borrowed.borrowedText = "abc"
        XCTAssertEqual(borrowed.validate(today: today).first?.message, MortgageTermsEditing.invalidAmount("abc"))
        var spread = form
        spread.spreadText = "one"
        XCTAssertEqual(spread.validate(today: today).first?.message, "“one” isn't a spread: enter a percentage such as 1.000.")
        var fixed = form
        fixed.index = .fixed
        fixed.fixedRateText = "x"
        XCTAssertEqual(fixed.validate(today: today).first?.message, "“x” isn't a rate: enter a percentage such as 1.000.")
        var count = form
        count.totalText = "4o0"
        XCTAssertEqual(count.validate(today: today).first?.message, "“4o0” isn't a number of instalments.")

        // The rules of the terms themselves.
        var noMonths = form
        noMonths.months = []
        XCTAssertFalse(noMonths.canSave)
        XCTAssertEqual(noMonths.validate(today: today).first?.message, "Choose at least one month the rate is revised in.")
        var rate = form
        rate.index = .fixed
        rate.fixedRateText = "60"
        XCTAssertEqual(rate.validate(today: today).first?.message, "Enter a rate between 0% and 50%.")
        var wideSpread = form
        wideSpread.spreadText = "25"
        XCTAssertEqual(wideSpread.validate(today: today).first?.message, "Enter a spread between −5% and 20%.")
        var many = form
        many.totalText = "2000"
        XCTAssertEqual(many.validate(today: today).first?.message,
                       "Enter between 1 and 1,200 instalments (and 0–10 business days, 0–6 decimals).")
        var balloon = form
        balloon.balloonText = "20000"
        balloon.borrowedText = "10000"
        XCTAssertEqual(balloon.validate(today: today).first?.message, "The amount borrowed must be more than the balloon.")
        var dates = form
        dates.hasFirstDate = true
        dates.firstDate = Self.day(2020, 5, 1)
        dates.hasFinalDate = true
        dates.finalDate = Self.day(2019, 5, 1)
        XCTAssertEqual(dates.validate(today: today).first?.message, "The final instalment is before the first.")

        // Every MortgageTermsError has the Mac's words.
        XCTAssertEqual(MortgageTermsEditing.validate(PropertyMortgageTerms(propertyId: propertyId, balloonMinorUnits: -1)).first?.message,
                       "The balloon can't be negative.")
        XCTAssertEqual(MortgageTermsEditing.validate(PropertyMortgageTerms(propertyId: propertyId, fixingBusinessDays: 11)).first?.message,
                       MortgageTermsEditing.message(.invalidCount))
    }

    func testFormBuildsTheTermsAndRoundTrips() throws {
        var form = try form()
        form.index = .euribor6M
        form.spreadText = "1,25"
        form.months = [7, 1]
        form.totalText = "360"
        form.hasFirstDate = true
        form.firstDate = Self.day(2020, 2, 3)
        form.balloonText = "0"
        form.borrowedText = "150000"
        let terms = form.terms(today: today)
        XCTAssertEqual(terms.rateIndex, .euribor6M)
        XCTAssertEqual(terms.spreadPercent, 1.25)
        XCTAssertEqual(terms.revisionMonths, [1, 7])
        XCTAssertEqual(terms.totalInstalments, 360)
        XCTAssertNil(terms.balloonMinorUnits, "0: none")
        XCTAssertEqual(terms.amountBorrowedMinorUnits, 15_000_000)
        XCTAssertEqual(form.derivedFinalDate, MortgageTerms.dueDate(monthsAfter: 359, first: Self.day(2020, 2, 3)))
        // The form read back from those terms gives the same terms.
        XCTAssertEqual(MortgageTermsEditing.Form(terms: terms, overrides: []).terms(today: today), terms)
        // A rate given for a period: offered periods leave out those given; a typo is a problem, not a rate.
        let start = try XCTUnwrap(form.overrideChoices(today: today).first)
        XCTAssertEqual(form.addOverride(start: start, text: "3,1x")?.message, "“3,1x” isn't a rate: enter a percentage such as 3.250.")
        XCTAssertNil(form.addOverride(start: start, text: "3.1"))
        XCTAssertFalse(form.overrideChoices(today: today).contains(start))
        form.removeOverride(start: start)
        XCTAssertTrue(form.overrideChoices(today: today).contains(start))
    }

    func testMortgageSaveThroughWriter() async throws {
        var form = try form()
        form.index = .fixed
        form.fixedRateText = "2.75"
        form.totalText = "300"
        let start = try XCTUnwrap(form.overrideChoices(today: today).first)
        XCTAssertNil(form.addOverride(start: start, text: "3.000"))
        let writer = DeviceWriter(db: db, viewer: { .demoAdmin }, afterWrite: {})
        try await MortgageTermsEditing.save(terms: form.terms(today: today), overrides: form.overrides, writer: writer)
        let (saved, overrides) = try await db.read { [propertyId] db in
            (try MortgageTerms.terms(db: db, propertyId: propertyId!), try MortgageRate.overrides(db: db, propertyId: propertyId!))
        }
        XCTAssertEqual(saved.rateIndex, .fixed)
        XCTAssertEqual(saved.annualRatePercent, 2.75)
        XCTAssertEqual(saved.totalInstalments, 300)
        XCTAssertEqual(overrides.map(\.periodStart), [start])
        XCTAssertEqual(overrides.map(\.ratePercent), [3.0])
    }

    func testMortgageEditChangingFiledYearFigureRefusedNothingSaved() async throws {
        // Today's engine reads the loan's interest from its transactions; a trigger stands in for a figure that follows
        // the rules, so saving the terms moves a cost in the filed 2024/25 year. The save asks; on the device nothing is
        // saved: neither the terms, nor the rates given, nor what the trigger changed.
        let costId = try await filedYearCostId()
        try await db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER mortgageMovesFiledYear AFTER INSERT ON propertyMortgageTerms
                BEGIN UPDATE transaction_ SET amountMinorUnits = amountMinorUnits - 50000 WHERE id = \(costId); END
                """)
            try db.execute(sql: """
                CREATE TEMP TRIGGER mortgageMovesFiledYearOnUpdate AFTER UPDATE ON propertyMortgageTerms
                BEGIN UPDATE transaction_ SET amountMinorUnits = amountMinorUnits - 50000 WHERE id = \(costId); END
                """)
        }
        let before = try await db.read { db in
            (try Row.fetchAll(db, sql: "SELECT * FROM propertyMortgageTerms"), try Row.fetchAll(db, sql: "SELECT * FROM mortgageRateOverride"),
             try Transaction.fetchOne(db, key: costId)?.amountMinorUnits)
        }
        var form = try form()
        form.index = .fixed
        form.fixedRateText = "4.5"
        XCTAssertNil(form.addOverride(start: try XCTUnwrap(form.overrideChoices(today: today).first), text: "4.0"))
        let writer = DeviceWriter(db: db, viewer: { .demoAdmin }, afterWrite: {})
        do {
            try await MortgageTermsEditing.save(terms: form.terms(today: today), overrides: form.overrides, writer: writer)
            XCTFail("a save that moves a filed return is refused")
        } catch let refusal as DeviceWriteRefusal {
            guard case .filedYear(let question) = refusal else { return XCTFail("\(refusal)") }
            XCTAssertEqual(question.years.map(\.label), ["2024/25"])
        }
        let after = try await db.read { db in
            (try Row.fetchAll(db, sql: "SELECT * FROM propertyMortgageTerms"), try Row.fetchAll(db, sql: "SELECT * FROM mortgageRateOverride"),
             try Transaction.fetchOne(db, key: costId)?.amountMinorUnits)
        }
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(after.2, before.2)
    }

    /// A cost in one of the property's expense categories dated in the filed 2024/25 tax year.
    private func filedYearCostId() async throws -> Int64 {
        try await db.read { [propertyId] db in
            let groups = try Properties.categoryGroupIds(db: db, propertyId: propertyId!)
            let categories = try Category.filter(groups.contains(Column("groupId")) && Column("type") == CategoryType.expense.rawValue)
                .fetchAll(db).compactMap(\.id)
            let cost = try Transaction.filter(categories.contains(Column("categoryId")) && Column("date") >= Self.day(2024, 6, 1)
                                              && Column("date") < Self.day(2025, 3, 1)).fetchOne(db)
            return try XCTUnwrap(cost?.id)
        }
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
