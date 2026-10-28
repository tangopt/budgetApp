// App/Dashboard/MortgageCard.swift
import SwiftUI
import BudgetCore

/// Each mortgage: what is owed, the next instalment and the rate.
struct MortgageCard: View {
    let mortgages: [DashboardReview.MortgageSummary]
    let navigate: (AppScreen) -> Void

    var body: some View {
        DashboardCard(title: "Mortgage", linkTitle: "Property", onLink: { navigate(.property) }) {
            ForEach(mortgages, id: \.propertyName) { mortgage in
                VStack(alignment: .leading, spacing: 4) {
                    if mortgages.count > 1 {
                        Text(mortgage.propertyName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    }
                    line("Owed", mortgage.owedMinorUnits.map { Money.format($0, currency: mortgage.currency) })
                    line("Next instalment", mortgage.nextDue.map { due in
                        "\(DashboardFormat.day(due))" + (mortgage.nextInstalmentMinorUnits.map { " " + Money.format($0, currency: mortgage.currency) } ?? "")
                    })
                    line("Rate", mortgage.ratePercent.map { rate in
                        String(format: "%.2f%%", rate) + (mortgage.nextReview.map { " · review \(DashboardFormat.day($0))" } ?? "")
                    })
                }
                if mortgage.propertyName != mortgages.last?.propertyName { Divider() }
            }
        }
    }

    private func line(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(value ?? "Not set").foregroundStyle(value == nil ? .secondary : .primary).monospacedDigit().figureText()
        }
        .font(.callout)
    }
}
