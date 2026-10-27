import WidgetKit
import SwiftUI
import BudgetCore
import MangoUI

struct NetWorthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ubberninja.mango.networth", provider: SnapshotProvider()) { entry in
            NetWorthWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetLink.url(for: .home))
        }
        .configurationDisplayName("Net worth")
        .description("Your net worth, as Home shows it.")
        .supportedFamilies([.systemSmall])
    }
}

struct NetWorthWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 4) {
                Text("Net worth").font(.caption).foregroundStyle(.secondary)
                Text(WidgetPresentation.netWorthText(snapshot))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .figureSensitivity(WidgetPresentation.isRedacted(snapshot, isLockScreen: false))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            EmptyWidgetView()
        }
    }
}
