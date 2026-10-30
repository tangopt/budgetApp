import WidgetKit
import SwiftUI
import BudgetCore
import MangoUI

/// Property month (step 18): this month's recharge pipeline for the property, by tenancy name.
struct PropertyMonthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ubberninja.mango.propertymonth", provider: SnapshotProvider()) { entry in
            PropertyMonthWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetLink.url(for: .home))
        }
        .configurationDisplayName("Property month")
        .description("Bills in, statement sent and paid by the tenant, and what is outstanding.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PropertyMonthWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            if let figures = snapshot.propertyMonths?.first {
                PropertyMonthWidgetView(figures: figures, size: MangoWidgetSize(family), redacted: WidgetPresentation.isRedacted(snapshot, isLockScreen: false))
            } else {
                Text("No property this month").mangoFont(.footnote).multilineTextAlignment(.center)
            }
        } else {
            EmptyWidgetView()
        }
    }
}
