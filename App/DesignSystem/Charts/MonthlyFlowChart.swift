// App/DesignSystem/Charts/MonthlyFlowChart.swift
import SwiftUI
import Charts
import BudgetCore

/// Axis and annotation labels for amounts in any currency: "€1.2k", "£500", "-€3k" (the
/// Dashboard's `axisThousands`, for both currencies).
enum MoneyAxis {
    static func symbol(_ currency: Currency) -> String {
        switch currency {
        case .gbp: return "£"
        case .eur: return "€"
        }
    }

    /// `majorUnits` (pounds, euros) compactly.
    static func compact(_ majorUnits: Double, currency: Currency) -> String {
        let sign = majorUnits < -0.5 ? "-" : ""
        let magnitude = abs(majorUnits)
        let locale = Locale(identifier: "en_GB")
        if magnitude >= 1_000 {
            let thousands = (magnitude / 100).rounded() / 10
            return sign + symbol(currency) + thousands.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + "k"
        }
        return sign + symbol(currency) + magnitude.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    /// Minor units compactly.
    static func compact(minorUnits: Int, currency: Currency) -> String {
        compact(Double(minorUnits) / 100, currency: currency)
    }
}

/// One month's money in and out (positive magnitudes) and, optionally, its net.
struct FlowMonth: Identifiable, Equatable {
    /// The first day of the month (a UTC midnight).
    let start: Date
    let inflowMinorUnits: Int
    let outflowMinorUnits: Int
    var netMinorUnits: Int?
    var id: Date { start }
}

/// Money in and out by month (spec §4.1): in as bars above the axis in the income colour, out
/// below in the expense colour, the net as a line in `theme.chartAccent` up to the month of `today`
/// (none for months that haven't started); a dashed "Today" rule; hover for a readout ("Not
/// yet" for a month to come). Labels in the amounts' currency.
struct MonthlyFlowChart: View {
    let months: [FlowMonth]
    let currency: Currency
    var inflowLabel = "In"
    var outflowLabel = "Out"
    var netLabel = "Net"
    var today: Date? = nil
    var height: CGFloat = 220
    @Environment(\.theme) private var theme
    @State private var selectedDate: Date?

    private static let utc = TimeZone(identifier: "UTC")!

    private var selected: FlowMonth? {
        guard let selectedDate else { return nil }
        return months.min { abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate)) }
    }

    /// Whether the month hasn't started yet (with a `today`): no net line or point there, and
    /// "Not yet" in the readout.
    private func isFuture(_ month: FlowMonth) -> Bool {
        guard let today else { return false }
        return month.start > today
    }

    private var showsToday: Bool {
        guard let today, let first = months.first?.start, let last = months.last?.start else { return false }
        return today >= first && today < MonthRange.calendar.date(byAdding: .month, value: 1, to: last)!
    }

    var body: some View {
        Chart {
            ForEach(months) { month in
                BarMark(x: .value("Month", month.start, unit: .month), y: .value("Amount", Double(month.inflowMinorUnits) / 100))
                    .foregroundStyle(by: .value("Series", inflowLabel))
                BarMark(x: .value("Month", month.start, unit: .month), y: .value("Amount", -Double(month.outflowMinorUnits) / 100))
                    .foregroundStyle(by: .value("Series", outflowLabel))
            }
            ForEach(months.filter { $0.netMinorUnits != nil && !isFuture($0) }) { month in
                LineMark(x: .value("Month", month.start, unit: .month), y: .value("Amount", Double(month.netMinorUnits ?? 0) / 100),
                         series: .value("Series", netLabel))
                    .foregroundStyle(by: .value("Series", netLabel))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Month", month.start, unit: .month), y: .value("Amount", Double(month.netMinorUnits ?? 0) / 100))
                    .foregroundStyle(by: .value("Series", netLabel))
                    .symbolSize(18)
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
            if showsToday, let today {
                RuleMark(x: .value("Today", today))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Today").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.start, unit: .month))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout(selected)
                    }
            }
        }
        // Charts lay their labels out apart from the scroll view: no clip check on them.
        .wrapProbeInChart()
        .chartForegroundStyleScale([inflowLabel: theme.income, outflowLabel: theme.expense, netLabel: theme.chartAccent])
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine()
                AxisValueLabel(format: Date.FormatStyle(timeZone: Self.utc).month(.abbreviated), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(MoneyAxis.compact(amount, currency: currency)).figureText() }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXSelection(value: $selectedDate)
        // The months are UTC days: bin, stride and label them in UTC, so a month never takes
        // its neighbour's label across a daylight-saving change.
        .environment(\.calendar, MonthRange.calendar)
        .environment(\.timeZone, Self.utc)
        .frame(height: height)
        .accessibilityLabel("\(inflowLabel), \(outflowLabel.lowercased()) and \(netLabel.lowercased()) by month")
    }

    private func readout(_ month: FlowMonth) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(month.start.formatted(Date.FormatStyle(timeZone: Self.utc).month(.wide).year())).font(.caption2).foregroundStyle(.secondary)
                .figureText()
            if isFuture(month) {
                Text("Not yet").font(.caption).foregroundStyle(.secondary).frame(minWidth: 150, alignment: .leading)
            } else {
                readoutLine(inflowLabel, month.inflowMinorUnits, theme.income, role: .signed)
                readoutLine(outflowLabel, month.outflowMinorUnits, theme.expense, role: .cost)
                if let net = month.netMinorUnits { readoutLine(netLabel, net, theme.chartAccent, role: .signed) }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.windowFill))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private func readoutLine(_ label: String, _ minorUnits: Int, _ color: Color, role: MoneyRole) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2)
            Spacer(minLength: 8)
            MoneyText(minorUnits: minorUnits, currency: currency, font: .caption.bold().monospacedDigit(), role: role)
        }
        .frame(minWidth: 150)
    }
}
