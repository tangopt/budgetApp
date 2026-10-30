import SwiftUI
import BudgetCore

/// Coming up (iPhone spec §3.7): the property's obligations over the next `PropertyGlance.comingUpDays` days (IMI,
/// condomínio, insurance, tax, the mortgage), each with its day and expected amount; an estimate says "est.".
/// Drawn by the shared `UpcomingList`.
struct ComingUpList: View {
    let obligations: [PropertyObligation]
    let currency: Currency

    var body: some View {
        Card(title: "Coming up") {
            UpcomingList(entries: obligations.map { UpcomingEntry($0, currency: currency) }, emptyText: PropertyCopy.nothingComingUp)
        }
    }
}
