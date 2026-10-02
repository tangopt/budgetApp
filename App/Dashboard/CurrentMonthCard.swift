// App/Dashboard/CurrentMonthCard.swift
import SwiftUI
import BudgetCore

struct CurrentMonthCard: View {
    let month: CurrentMonthTracking
    let catchAll: CatchAllAllowance?
    let navigate: (AppScreen) -> Void

    private var monthName: String {
        DashboardFormat.monthYear(MonthRange.of(year: month.year, month: month.month).start)
    }
    private var pace: Double { Double(month.dayOfMonth) / Double(month.daysInMonth) }
    private var hasActuals: Bool { month.monthClass == .blended }

    var body: some View {
        DashboardCard(title: "\(monthName) · day \(month.dayOfMonth) of \(month.daysInMonth)", linkTitle: "Budget", onLink: { navigate(.budgetGrid) }) {
            if !hasActuals {
                Text("No \(monthName) transactions imported yet. Showing expected only.")
                    .font(.caption)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
            }
            row("Income", month.income, tint: .green)
            row("Expenses", month.expenses, tint: month.expenses.actual > month.expenses.expected ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Net").font(.callout.bold())
                    Spacer()
                    Text("Projected month-end \(DashboardFormat.pounds(month.net.projected))").font(.callout).monospacedDigit()
                }
                if hasActuals {
                    Text("So far \(DashboardFormat.pounds(month.net.actual)) · expected \(DashboardFormat.pounds(month.net.expected))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if month.unreviewedCount > 0 {
                Text(unreviewedFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ totals: FlowTotals, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout.bold())
                Spacer()
                if hasActuals {
                    Text("\(DashboardFormat.pounds(totals.actual)) of \(DashboardFormat.pounds(totals.expected))").font(.callout).monospacedDigit()
                } else {
                    Text("expected \(DashboardFormat.pounds(totals.expected))").font(.callout).monospacedDigit()
                }
            }
            if hasActuals {
                PaceMeter(fraction: totals.expected > 0 ? Double(totals.actual) / Double(totals.expected) : (totals.actual > 0 ? 1 : 0), pace: pace, tint: tint)
            }
            Text("Projected month-end \(DashboardFormat.pounds(totals.projected))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var unreviewedFootnote: String {
        var text = "\(month.unreviewedCount) unreviewed transaction\(month.unreviewedCount == 1 ? "" : "s") (\(DashboardFormat.pounds(month.unreviewedOutflowMinorUnits)) out) aren't included."
        if let catchAll, catchAll.monthlyMinorUnits > 0 {
            text += " Your catch-all (\(catchAll.name), \(DashboardFormat.pounds(catchAll.monthlyMinorUnits))/month) stands in for typical unreviewed spending."
        }
        return text
    }
}
