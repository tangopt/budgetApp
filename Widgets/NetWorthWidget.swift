import WidgetKit
import SwiftUI
import BudgetCore
import MangoUI

struct NetWorthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ubberninja.mango.networth", provider: SnapshotProvider()) { entry in
            NetWorthWidgetView(entry: entry)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .mangoWidgetTheme()
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
                Text("Net worth").mangoFont(.caption).foregroundStyle(.secondary)
                Text(WidgetPresentation.netWorthWholeText(snapshot))
                    .mangoFont(.figureL)
                    .figureSensitivity(WidgetPresentation.isRedacted(snapshot, isLockScreen: false))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            EmptyWidgetView()
        }
    }
}
