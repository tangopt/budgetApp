import SwiftUI
import BudgetCore

/// Upcoming (iPhone spec §3.2): the next five bills and property obligations over the next 60 days, each with its
/// day and its source (a planned bill, a property cost), so a cost listed by both reads as two sources, not a slip.
/// Drawn by the shared `UpcomingList`.
struct UpcomingCard: View {
    let items: [HomeSummary.UpcomingItem]
    var limit = HomeCopy.upcomingLimit
    /// The iPad: the link to the Calendar, which owns the full list (design review D1).
    var openCalendar: (() -> Void)?

    var body: some View {
        Card(title: "Upcoming") {
            UpcomingList(entries: Array(items.prefix(limit)).map(UpcomingEntry.init),
                         emptyText: "Nothing due in the next \(HomeSummary.upcomingDays) days.")
            if let openCalendar {
                Button("Calendar", action: openCalendar).buttonStyle(.pad(.secondary, size: .small))
            }
        }
    }
}
