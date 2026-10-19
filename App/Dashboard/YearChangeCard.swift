// App/Dashboard/YearChangeCard.swift
import SwiftUI
import BudgetCore

struct YearChangeCard: View {
    let changes: [YearChange]
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        DashboardCard(title: "Net worth change per year", linkTitle: "Accounts", onLink: { navigate(.accounts) }) {
            if changes.isEmpty {
                Text("Needs at least a year of balance history.").font(.callout).foregroundStyle(.secondary)
            } else {
                YearOverYearChart(changes: changes)
                HStack(spacing: 14) {
                    Label("Realised", systemImage: "square.fill").foregroundStyle(theme.yoyGood)
                    Label("Forecast", systemImage: "square.dashed").foregroundStyle(theme.yoyGood.opacity(0.7))
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
                if let first = changes.first, let month = first.partialFromMonth {
                    // Built as a String first: interpolating the Int year straight into a Text
                    // literal goes through LocalizedStringKey and groups it as "2,020".
                    let note = "* \(String(first.year)) measured from \(DashboardFormat.monthYear(MonthRange.of(year: first.year, month: month).start).unbroken) (first data)"
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
