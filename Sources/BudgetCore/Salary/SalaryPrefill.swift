import Foundation
import GRDB

/// The "Current" salary read from one person's own P60 or payslip. It reads that person's employment rows only: the
/// caller passes the signed-in person (never another household member), and nothing is written back.
public enum SalaryPrefill {
    /// The latest tax year with a P60 or payslip, a P60 before a payslip within it. A P60 is the year's pay; a payslip's
    /// year-to-date pay is annualised by the tax months it covers (`periodEnd`, 6 April to 5 April). Pension and student
    /// loan aren't on those forms: they stay off. nil when the person has neither.
    public static func latest(db: Database, personId: Int64, today: Date) throws -> SalaryInputs? {
        let employments = try Employment.filter(Column("personId") == personId).fetchAll(db)
        var best: (year: Int, rank: Int, open: Int, key: Int, inputs: SalaryInputs)?
        for employment in employments {
            guard let id = employment.id else { continue }
            let incomes = try EmploymentIncome.filter(Column("employmentId") == id).fetchAll(db)
            for income in incomes where income.source == .p60 || income.source == .payslip {
                guard let gross = annualPay(income, in: employment) else { continue }
                var inputs = SalaryInputs.typicalCurrent(today: today)
                inputs.grossAnnual = gross
                inputs.region = .englandWalesNI
                if let code = income.taxCode?.trimmingCharacters(in: .whitespaces), !code.isEmpty { inputs.taxCode = code.uppercased() }
                // Later year first; a P60 over a payslip; the job still going; then the P60's pay or the payslip's date.
                let rank = income.source == .p60 ? 1 : 0
                let open = employment.endDate == nil ? 1 : 0
                let key = income.source == .p60 ? income.payMinorUnits : Int((income.periodEnd ?? .distantPast).timeIntervalSince1970)
                let candidate = (year: employment.startYear, rank: rank, open: open, key: key, inputs: inputs)
                if let current = best {
                    if (candidate.year, candidate.rank, candidate.open, candidate.key) > (current.year, current.rank, current.open, current.key) { best = candidate }
                } else {
                    best = candidate
                }
            }
        }
        return best?.inputs
    }

    /// A year of pay in pence; nil when there is none.
    private static func annualPay(_ income: EmploymentIncome, in employment: Employment) -> Int? {
        guard income.payMinorUnits > 0 else { return nil }
        switch income.source {
        case .p60:
            return income.payMinorUnits
        case .payslip:
            let months = taxMonths(upTo: income.periodEnd, in: UKTaxYear(startYear: employment.startYear))
            return SalaryCalculator.roundHalfUp(income.payMinorUnits * 12, months)
        default:
            return nil
        }
    }

    /// Whole tax months (1...12) from 6 April to `date`: the 5th closes a month. A payslip without a date counts as a year.
    static func taxMonths(upTo date: Date?, in year: UKTaxYear) -> Int {
        guard let date else { return 12 }
        let calendar = UKTaxYear.utcCalendar
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let months = (parts.year! * 12 + parts.month!) - (year.startYear * 12 + 4) + (parts.day! > 5 ? 1 : 0)
        return min(12, max(1, months))
    }
}
