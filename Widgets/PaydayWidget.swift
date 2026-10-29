import WidgetKit
import SwiftUI
import BudgetCore
import MangoUI

struct PaydayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ubberninja.mango.payday", provider: SnapshotProvider()) { entry in
            PaydayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetLink.url(for: .home))
        }
        .configurationDisplayName("Payday in N days")
        .description("The days to payday, on the lock screen.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// The lock screen's circle. The count is not a money figure, but it is hidden while locked unless the setting is on.
struct PaydayWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(spacing: 0) {
                Text("Payday").mangoFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(WidgetPresentation.paydayText(snapshot, on: entry.date))
                    .mangoFont(MangoType.footnote.weight(.semibold).figure())
                    .figureSensitivity(WidgetPresentation.isRedacted(snapshot, isLockScreen: true))
            }
        } else {
            Text("Open Mango").mangoFont(.caption2).multilineTextAlignment(.center)
        }
    }
}
