// Sources/BudgetCore/PayPeriods/PaydaySource.swift
import Foundation
import GRDB

/// Single source of truth for "which transactions are paydays", shared by the Budget
/// grid, the Forecast screen and forecast regeneration after import.
///
/// Only the salary category ("Income", as seeded by `CategorySeeder.incomeNames`) is a
/// payday signal. "Bonus" and "Other income/refunds" are income-type categories too,
/// but they land on arbitrary days and previously split real pay periods into bogus
/// ones (or produced duplicate period start dates when landing on payday itself).
///
/// Within the salary category, the spec's "similar amount within tolerance" filter is
/// applied leniently: credits below half the median salary credit are ignored (e.g. a
/// small refund miscategorised as Income). The tolerance is deliberately one-sided and
/// wide so pay rises, overtime and tax-code changes never drop a real payday.
/// Same-day/near-duplicate dates are collapsed later by `PayPeriodDetector.paydayAnchors`.
public enum PaydaySource {
    public static let salaryCategoryName = "Income"
    static let minimumFractionOfMedianSalary = 0.5

    /// `publishedCloses`: the pay-month closes the other person's devices published for accounts this device
    /// doesn't hold in full (`ActualsSource.publishedCloses`). A calendar month with one takes it, and this
    /// device's own paydays in that month are left out; elsewhere the own paydays stand. Summary rows standing for
    /// the other person's totals (`SharedActuals.isSummary`) are never paydays.
    public static func paydayDates(transactions: [Transaction], categories: [Category], publishedCloses: [Date]) -> [Date] {
        guard !publishedCloses.isEmpty else { return paydayDates(transactions: transactions, categories: categories) }
        let calendar = PayCalendar.calendar
        func month(_ date: Date) -> DateComponents { calendar.dateComponents([.year, .month], from: date) }
        let published = Set(publishedCloses.map(month))
        let own = paydayDates(transactions: transactions, categories: categories).filter { !published.contains(month($0)) }
        return (own + publishedCloses).sorted()
    }

    public static func paydayDates(transactions: [Transaction], categories: [Category]) -> [Date] {
        guard let salaryCategoryId = categories.first(where: { $0.name == salaryCategoryName && $0.type == .income })?.id else {
            return []
        }
        let salaryCredits = transactions.filter {
            $0.categoryId == salaryCategoryId && $0.status == .confirmed && $0.amountMinorUnits > 0 && !SharedActuals.isSummary($0)
        }
        guard !salaryCredits.isEmpty else { return [] }

        let amounts = salaryCredits.map(\.amountMinorUnits).sorted()
        let median = amounts.count % 2 == 1
            ? Double(amounts[amounts.count / 2])
            : Double(amounts[amounts.count / 2 - 1] + amounts[amounts.count / 2]) / 2
        let threshold = median * minimumFractionOfMedianSalary

        return salaryCredits
            .filter { Double($0.amountMinorUnits) >= threshold }
            .map(\.date)
            .sorted()
    }

    public static func paydayDates(db: Database) throws -> [Date] {
        let categories = try Category.filter(Column("name") == salaryCategoryName).fetchAll(db)
        let categoryIds = categories.compactMap(\.id)
        guard !categoryIds.isEmpty else { return [] }
        let transactions = try Transaction
            .filter(categoryIds.contains(Column("categoryId")) && Column("status") == TransactionStatus.confirmed.rawValue)
            .fetchAll(db)
        return paydayDates(transactions: transactions, categories: categories)
    }
}
