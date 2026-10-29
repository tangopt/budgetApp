import SwiftUI
import Charts
import BudgetCore

/// The widget families the step 18 views draw (the extension maps WidgetKit's families onto them; the snapshot harness
/// draws the same views in tiles of these sizes).
public enum MangoWidgetSize: String, CaseIterable, Sendable {
    case small, medium, large

    /// The tile's size on a 393-pt-wide iPhone, margins included.
    public var tileSize: CGSize {
        switch self {
        case .small: CGSize(width: 158, height: 158)
        case .medium: CGSize(width: 338, height: 158)
        case .large: CGSize(width: 338, height: 354)
        }
    }
}

/// Month spend (step 18): the pay month's spending against its budget and against the pace the budget sets. Small: a
/// progress ring. Medium: the figures and a cumulative line, actual against expected. Large: that and the top three
/// categories over budget. One line per figure; the figures shrink before they wrap.
public struct MonthSpendWidgetView: View {
    let figures: MonthSpendFigures
    let size: MangoWidgetSize
    /// Figures hide while the device is locked (`WidgetPresentation.isRedacted`).
    let redacted: Bool

    public init(figures: MonthSpendFigures, size: MangoWidgetSize, redacted: Bool) {
        self.figures = figures
        self.size = size
        self.redacted = redacted
    }

    @Environment(\.phoneTheme) private var theme

    private var overPace: Bool { figures.overPaceMinorUnits >= 100 }
    private var paceColor: Color { overPace ? theme.warning : theme.income }
    /// The ring and the spending line: the accent, or the warning colour over pace.
    private var spendColor: Color { overPace ? theme.warning : Color.accentColor }

    public var body: some View {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    private var title: some View {
        Text("Month spend").mangoFont(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private func money(_ minorUnits: Int) -> String {
        WidgetPresentation.wholeText(minorUnits, currencyCode: figures.currencyCode)
    }

    // MARK: Small

    private var small: some View {
        VStack(spacing: 4) {
            HStack { title; Spacer(minLength: 0) }
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 8)
                Circle().trim(from: 0, to: min(1, figures.spentFraction))
                    .stroke(spendColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // The pace: a tick where the budget says the month stands today.
                Capsule().fill(.primary).frame(width: 2.5, height: 12).offset(y: -35)
                    .rotationEffect(.degrees(360 * min(1, figures.elapsedFraction)))
                Text(money(figures.spentMinorUnits)).mangoFont(MangoType.footnote.weight(.semibold).figure())
            }
            .frame(width: 78, height: 78)
            .privacySensitive(redacted)
            Text(WidgetPresentation.paceText(figures)).mangoFont(PhoneTextStyle.caption2.weight(.medium).figure())
                .foregroundStyle(paceColor).privacySensitive(redacted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Medium

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title
                Text(money(figures.spentMinorUnits)).mangoFont(.figureL).privacySensitive(redacted)
                Text("of \(money(figures.budgetMinorUnits))").mangoFont(PhoneTextStyle.caption.figure()).foregroundStyle(.secondary)
                    .privacySensitive(redacted)
                Spacer(minLength: 0)
                Text(WidgetPresentation.paceText(figures)).mangoFont(PhoneTextStyle.caption.weight(.medium).figure())
                    .foregroundStyle(paceColor).privacySensitive(redacted)
            }
            .frame(width: 112, alignment: .leading)
            chart.privacySensitive(redacted)
        }
    }

    private var chart: some View {
        let days = max(figures.daysInMonth, 1)
        let top = Double(max(figures.budgetMinorUnits, figures.spentMinorUnits, 1)) * 1.08
        let spentPoints = [(0, 0)] + figures.cumulativeSpent.enumerated().map { ($0.offset + 1, $0.element) }
        return Chart {
            ForEach([(0, 0), (days, figures.budgetMinorUnits)], id: \.0) { point in
                LineMark(x: .value("Day", point.0), y: .value("Expected", point.1), series: .value("Series", "Expected"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            ForEach(spentPoints, id: \.0) { point in
                AreaMark(x: .value("Day", point.0), yStart: .value("Floor", 0), yEnd: .value("Spent", point.1))
                    .foregroundStyle(LinearGradient(colors: [spendColor.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", point.0), y: .value("Spent", point.1), series: .value("Series", "Spent"))
                    .foregroundStyle(spendColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if let last = spentPoints.last {
                PointMark(x: .value("Day", last.0), y: .value("Spent", last.1))
                    .foregroundStyle(spendColor).symbolSize(36)
            }
        }
        .chartXScale(domain: 0...days)
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.overlay(alignment: .bottomLeading) { Rectangle().fill(.quaternary).frame(height: 1) } }
    }

    // MARK: Large

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            medium.frame(height: 124)
            Divider()
            Text("Over budget").mangoFont(.caption).foregroundStyle(.secondary)
            if figures.overBudget.isEmpty {
                Text("Nothing over budget").mangoFont(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(Array(figures.overBudget.enumerated()), id: \.offset) { _, row in overRow(row) }
            }
            Spacer(minLength: 0)
        }
    }

    private func overRow(_ row: MonthSpendFigures.CategoryOver) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).mangoFont(.subheadline).lineLimit(1).truncationMode(.middle)
                Text("\(money(row.spentMinorUnits)) of \(money(row.budgetMinorUnits))").mangoFont(PhoneTextStyle.caption2.figure())
                    .foregroundStyle(.secondary).privacySensitive(redacted)
            }
            Spacer(minLength: 4)
            Text(WidgetPresentation.overText(row.overByMinorUnits, currencyCode: figures.currencyCode))
                .mangoFont(PhoneTextStyle.subheadline.weight(.semibold).figure()).foregroundStyle(theme.warning)
                .privacySensitive(redacted)
        }
    }
}
