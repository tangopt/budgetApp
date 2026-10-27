import WidgetKit
import SwiftUI
import BudgetCore
import MangoUI

struct LeftThisMonthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ubberninja.mango.left", provider: SnapshotProvider()) { entry in
            LeftThisMonthWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetLink.url(for: .month))
        }
        .configurationDisplayName("Left this pay month")
        .description("What is left to spend this pay month.")
        .supportedFamilies([.systemSmall])
    }
}

struct LeftThisMonthWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 4) {
                Text("Left this pay month").font(.caption).foregroundStyle(.secondary)
                Text(WidgetPresentation.leftText(snapshot))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .figureSensitivity(WidgetPresentation.isRedacted(snapshot, isLockScreen: false))
                Text("Payday: \(WidgetPresentation.paydayText(snapshot, on: entry.date))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .figureSensitivity(WidgetPresentation.isRedacted(snapshot, isLockScreen: false))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            EmptyWidgetView()
        }
    }
}
