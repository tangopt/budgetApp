import SwiftUI
import BudgetCore

/// Upcoming (iPhone spec §3.2): the next five bills and property obligations over the next 60 days, each with its
/// day and its source (a planned bill, a property cost), so a cost listed by both reads as two sources, not a slip.
struct UpcomingCard: View {
    let items: [HomeSummary.UpcomingItem]

    var body: some View {
        Card(title: "Upcoming") {
            let next = HomeCopy.nextUpcoming(items)
            if next.isEmpty {
                Text("Nothing due in the next \(HomeSummary.upcomingDays) days.")
                    .foregroundStyle(.secondary)
            }
            ForEach(next) { item in
                FigureRow(label: item.title, secondary: HomeCopy.upcomingSource(item)) {
                    if let amount = item.amountMinorUnits {
                        MoneyText(minorUnits: amount, currency: item.currency, role: .due)
                    } else {
                        Text("Amount not known")
                            .mangoFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
