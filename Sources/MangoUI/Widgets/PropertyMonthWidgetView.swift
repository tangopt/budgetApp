import SwiftUI
import Charts
import BudgetCore

/// Property month (step 18): this month's recharge pipeline for a tenancy, by the tenancy's name. Small: three steps (bills
/// in, statement sent, paid by the tenant) and what is outstanding. Medium: that and a bar per utility, in or still out.
public struct PropertyMonthWidgetView: View {
    let figures: RechargePipelineFigures
    let size: MangoWidgetSize
    let redacted: Bool

    public init(figures: RechargePipelineFigures, size: MangoWidgetSize, redacted: Bool) {
        self.figures = figures
        self.size = size
        self.redacted = redacted
    }

    /// Utilities the medium chart has room for.
    static let chartRows = 4

    public var body: some View {
        // Six rows in a 158-pt tile: the text grows to the default size at most, so nothing runs past the tile.
        Group {
            switch size {
            case .small, .large: pipeline
            case .medium:
                HStack(alignment: .top, spacing: 14) {
                    pipeline.frame(width: 138)
                    utilities.privacySensitive(redacted)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var pipeline: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(figures.tenancyName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            step("Bills", WidgetPresentation.billsText(figures), done: figures.isDone(.billsIn))
            step("Sent", WidgetPresentation.sentText(figures), done: figures.isDone(.statementSent))
            step("Tenant", WidgetPresentation.paidText(figures), done: figures.isDone(.paidByTenant))
            Spacer(minLength: 0)
            Text(WidgetPresentation.outstandingText(figures)).font(.title3.weight(.semibold))
                .figureText(.shrink(minimumScale: 0.5)).privacySensitive(redacted)
            Text("outstanding").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func step(_ label: String, _ value: String, done: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.caption)
                .foregroundStyle(done ? Color.green : Color.secondary)
            Text(label).font(.caption).lineLimit(1)
            Spacer(minLength: 2)
            Text(value).font(.caption2).foregroundStyle(.secondary).figureText(.shrink(minimumScale: 0.6))
        }
    }

    private var utilities: some View {
        let rows = Array(figures.utilities.prefix(Self.chartRows))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Bills this month").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if rows.isEmpty {
                Text("No bills due").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart(Array(rows.enumerated()), id: \.offset) { _, row in
                    BarMark(x: .value("Bill", 1), y: .value("Utility", row.name), height: .fixed(14))
                        .foregroundStyle(row.isIn ? Color.accentColor : Color.secondary.opacity(0.25))
                        .annotation(position: .overlay, alignment: .leading) {
                            Text(row.isIn ? "In" : "Out").font(.caption2.weight(.medium)).padding(.leading, 6)
                                .foregroundStyle(row.isIn ? Color.white : Color.secondary)
                        }
                }
                .chartXScale(domain: 0...1)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { _ in AxisValueLabel().font(.caption2) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
