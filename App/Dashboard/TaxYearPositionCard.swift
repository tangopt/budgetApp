// App/Dashboard/TaxYearPositionCard.swift
import SwiftUI
import BudgetCore

/// The current UK tax year: each person's status and estimated balancing figure, and the next payment on account.
struct TaxYearPositionCard: View {
    let tax: DashboardReview.TaxPosition
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        DashboardCard(title: "Tax year \(tax.year.label)", linkTitle: "Tax years", onLink: { navigate(.taxYears) }) {
            ForEach(tax.people) { person in
                HStack {
                    Text(person.name).lineLimit(1).truncationMode(.middle)
                    Text(person.status.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    estimate(person)
                }
                .font(.callout)
                if person.id != tax.people.last?.id { Divider() }
            }
            if let next = tax.nextPaymentOnAccount {
                Divider()
                HStack {
                    Text(next.label).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(DashboardFormat.day(next.date)) · \(DashboardFormat.pounds(next.amountMinorUnits))")
                        .monospacedDigit().figureText()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func estimate(_ person: DashboardReview.TaxPosition.PersonLine) -> some View {
        if let value = person.estimateMinorUnits {
            let refund = value < 0
            Text("\(refund ? "Estimated refund" : "Estimated tax due") \(DashboardFormat.pounds(abs(value)))")
                .monospacedDigit()
                .foregroundStyle(refund ? theme.income : Color.primary)
                .figureText()
        } else {
            Text("Not available yet").foregroundStyle(.secondary).lineLimit(1)
                .help(person.unavailableReason ?? "")
        }
    }
}
