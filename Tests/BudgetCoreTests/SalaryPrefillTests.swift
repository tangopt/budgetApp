import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

final class SalaryPrefillTests: XCTestCase {
    private var db: DatabaseQueue!
    private var me: Int64!
    private var other: Int64!
    private let today = Date(timeIntervalSince1970: 1_790_000_000) // September 2026

    override func setUpWithError() throws {
        db = try TestDatabase.migrated()
        try db.write { db in
            var a = Person(name: "Person A"); try People.save(db: db, &a); me = a.id!
            var b = Person(name: "Person B"); try People.save(db: db, &b); other = b.id!
        }
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @discardableResult
    private func add(person: Int64, year: Int, source: EmploymentIncomeSource, pay: Int, code: String? = "1257L",
                     periodEnd: Date? = nil, employer: String = "Example Ltd") throws -> Int64 {
        try db.write { db in
            var employment = Employment(startYear: year, personId: person, employerName: employer)
            try Employments.save(db: db, &employment)
            var income = EmploymentIncome(employmentId: employment.id!, source: source, payMinorUnits: pay,
                                          taxDeductedMinorUnits: 0, taxCode: code, periodEnd: periodEnd)
            try Employments.save(db: db, &income)
            return employment.id!
        }
    }

    private func latest(_ person: Int64? = nil) throws -> SalaryInputs? {
        let id = person ?? me!
        return try db.read { try SalaryPrefill.latest(db: $0, personId: id, today: today) }
    }

    func testPrefersLatestP60() throws {
        try add(person: me, year: 2023, source: .p60, pay: 3_500_000, code: "1257L")
        try add(person: me, year: 2024, source: .p60, pay: 4_200_000, code: "1185L")
        let inputs = try XCTUnwrap(latest())
        XCTAssertEqual(inputs.grossAnnual, 4_200_000)
        XCTAssertEqual(inputs.taxCode, "1185L")
        XCTAssertEqual(inputs.region, .englandWalesNI)
        XCTAssertEqual(inputs.pension, .percentOfGross(basisPoints: 0))
        XCTAssertNil(inputs.studentLoan)
        XCTAssertEqual(inputs.bonusAnnual, 0)
    }

    func testPayslipAnnualisedByPeriodEnd() throws {
        // 5 July is the end of tax month 3: 9,000.00 so far is 36,000.00 a year.
        try add(person: me, year: 2026, source: .payslip, pay: 900_000, periodEnd: Self.date(2026, 7, 5))
        XCTAssertEqual(try latest()?.grossAnnual, 3_600_000)
    }

    func testTaxMonths() {
        let year = UKTaxYear(startYear: 2026)
        XCTAssertEqual(SalaryPrefill.taxMonths(upTo: Self.date(2026, 4, 6), in: year), 1)
        XCTAssertEqual(SalaryPrefill.taxMonths(upTo: Self.date(2026, 7, 5), in: year), 3)
        XCTAssertEqual(SalaryPrefill.taxMonths(upTo: Self.date(2026, 7, 31), in: year), 4)
        XCTAssertEqual(SalaryPrefill.taxMonths(upTo: Self.date(2027, 4, 5), in: year), 12)
        XCTAssertEqual(SalaryPrefill.taxMonths(upTo: nil, in: year), 12)
    }

    func testP60BeatsPayslipInTheSameYear() throws {
        try add(person: me, year: 2025, source: .payslip, pay: 900_000, periodEnd: Self.date(2025, 7, 5))
        try add(person: me, year: 2025, source: .p60, pay: 4_000_000)
        XCTAssertEqual(try latest()?.grossAnnual, 4_000_000)
    }

    func testNothingWhenNoIncome() throws {
        XCTAssertNil(try latest())
        try add(person: me, year: 2025, source: .other, pay: 1_000_000)
        try add(person: me, year: 2025, source: .p45, pay: 1_000_000)
        XCTAssertNil(try latest())
    }

    func testScottishCodeSetsScotland() throws {
        try add(person: me, year: 2025, source: .p60, pay: 4_000_000, code: "S1257L")
        XCTAssertEqual(try latest()?.region, .scotland)
        XCTAssertEqual(try latest()?.taxCode, "S1257L")
    }

    func testOtherPersonIgnored() throws {
        try add(person: other, year: 2025, source: .p60, pay: 9_000_000)
        XCTAssertNil(try latest())
        try add(person: me, year: 2024, source: .p60, pay: 3_000_000)
        XCTAssertEqual(try latest()?.grossAnnual, 3_000_000)
        XCTAssertEqual(try latest(other)?.grossAnnual, 9_000_000)
    }
}
