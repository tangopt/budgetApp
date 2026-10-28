// App/Dashboard/PropertyMonthCard.swift
import SwiftUI
import BudgetCore

/// Each running tenancy's month: checklist steps done and whether the rent has come in. Tenancies are named by
/// their reference label, never the tenant.
struct PropertyMonthCard: View {
    let rows: [DashboardReview.PropertyRow]
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        DashboardCard(title: "Property month", linkTitle: "Property", onLink: { navigate(.property) }) {
            ForEach(rows) { row in
                HStack {
                    Text(row.tenancyName).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(row.stepsDone) of \(row.stepsTotal) steps").foregroundStyle(.secondary).figureText()
                    if let rent = rentText(row.rent) {
                        Text("· \(rent.text)").foregroundStyle(rent.tint).figureText()
                    }
                }
                .font(.callout)
                .monospacedDigit()
                if row.id != rows.last?.id { Divider() }
            }
        }
    }

    private func rentText(_ rent: DashboardReview.PropertyRow.Rent) -> (text: String, tint: Color)? {
        switch rent {
        case .received: return ("Rent received", theme.income)
        case .late: return ("Rent late", .orange)
        case .notDueYet: return ("Rent due", .secondary)
        case .notApplicable: return nil
        }
    }
}
