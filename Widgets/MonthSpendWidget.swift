import WidgetKit
import SwiftUI
import BudgetCore
import MangoUI

/// Month spend (step 18; replaces "Left this pay month"): the pay month's spending against its budget and pace.
struct MonthSpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ubberninja.mango.monthspend", provider: SnapshotProvider()) { entry in
            MonthSpendWidgetEntryView(entry: entry)
                .mangoWidgetTheme()
                .widgetURL(WidgetLink.url(for: .month))
        }
        .configurationDisplayName("Month spend")
        .description("Spent so far this pay month against what was expected by today and the budget.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MonthSpendWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot, let figures = snapshot.monthSpend {
            MonthSpendWidgetView(figures: figures, size: MangoWidgetSize(family), redacted: WidgetPresentation.isRedacted(snapshot, isLockScreen: false))
        } else {
            EmptyWidgetView()
        }
    }
}

extension MangoWidgetSize {
    init(_ family: WidgetFamily) {
        switch family {
        case .systemMedium: self = .medium
        case .systemLarge, .systemExtraLarge: self = .large
        default: self = .small
        }
    }
}
