import SwiftUI
import BudgetCore

/// Upcoming (iPhone spec §3.2): the next five bills and property obligations over the next 60 days, each with its
/// day and its source (a planned bill, a property cost), so a cost listed by both reads as two sources, not a slip.
/// Drawn by the shared `UpcomingList`.
struct UpcomingCard: View {
    let items: [HomeSummary.UpcomingItem]

    var body: some View {
        Card(title: "Upcoming") {
            UpcomingList(entries: HomeCopy.nextUpcoming(items).map(UpcomingEntry.init),
                         emptyText: "Nothing due in the next \(HomeSummary.upcomingDays) days.")
        }
    }
}
