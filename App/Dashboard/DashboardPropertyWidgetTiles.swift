// App/Dashboard/DashboardPropertyWidgetTiles.swift
import SwiftUI
import Charts
import BudgetCore

// The Property section's two figure widgets: a tenancy's cash flow by month and the property's return for the year.
// Each adapts to its tile: the figure alone, then the figure with a chart, then the figure, chart and a short list.

private enum DashPropertyFormat {
    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Whole units in the currency ("€12,345", "-€800").
    static func whole(_ minorUnits: Int, _ currency: Currency) -> String {
        let rounded = Int((Double(minorUnits) / 100).rounded()) * 100
        let text = Money.format(rounded, currency: currency)
        return text.hasSuffix(".00") ? String(text.dropLast(3)) : text
    }

    /// "€1.2k" on a chart axis.
    static func axis(_ units: Double, _ currency: Currency) -> String {
        let thousands = (units / 100).rounded() / 10
        let body = abs(thousands).formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_GB")))
        return (thousands < 0 ? "-" : "") + String(Money.format(0, currency: currency).dropLast(4)) + body + "k"
    }

    static func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }

    /// How many list rows the tile has room for under its chart, and the footer they take.
    static func listRows(height: CGFloat, maximum: Int) -> Int { max(0, min(maximum, Int((height - 262) / 22))) }
}

// MARK: Tenancy cash flow

/// A property's cash flow by month for the selected year, in its currency: rent and recharges in (up), costs and
/// bills out (down), the net as a line.
struct TenancyCashFlowTile: View {
    let flow: TenancyCashFlow
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let names = flow.tenancyNames.prefix(2).joined(separator: ", ") + (flow.tenancyNames.count > 2 ? " +\(flow.tenancyNames.count - 2)" : "")
        DashTile("Cash flow · \(names)", linkTitle: "Property", onLink: { navigate(.property) }) { size in
            let active = flow.months.filter { $0.received != 0 || $0.paidOut != 0 }
            let rows = DashPropertyFormat.listRows(height: size.height, maximum: min(4, active.count))
            ChartBeside(maximumLines: 2, footer: rows > 0 ? CGFloat(rows) * 22 + 6 : 0) { lines in
                VStack(alignment: .leading, spacing: 4) {
                    TileFigure(value: DashPropertyFormat.whole(flow.totalNet, flow.currency), caption: "net cash flow \(String(flow.year))",
                               tint: flow.totalNet < 0 ? theme.expense : .primary)
                    if lines >= 1 {
                        Text("In \(DashPropertyFormat.whole(flow.totalReceived, flow.currency))").font(.caption).foregroundStyle(theme.income)
                            .figureText(.shrink(minimumScale: 0.8))
                    }
                    if lines >= 2 {
                        Text("Out \(DashPropertyFormat.whole(flow.totalPaidOut, flow.currency))").font(.caption).foregroundStyle(theme.series(1))
                            .figureText(.shrink(minimumScale: 0.8))
                    }
                }
            } chart: { height in
                TenancyCashFlowChart(flow: flow, height: height)
            }
            if rows > 0 {
                VStack(spacing: 2) {
                    ForEach(active.suffix(rows).reversed(), id: \.month) { month in
                        HStack(spacing: 6) {
                            Text(DashPropertyFormat.monthNames[month.month - 1]).frame(width: 30, alignment: .leading)
                            Spacer(minLength: 4)
                            if size.width >= 280 {
                                Text("In \(DashPropertyFormat.whole(month.received, flow.currency))").foregroundStyle(theme.income).figureText()
                                Text("Out \(DashPropertyFormat.whole(month.paidOut, flow.currency))").foregroundStyle(theme.series(1)).figureText()
                            }
                            Text(DashPropertyFormat.whole(month.net, flow.currency)).foregroundStyle(month.net < 0 ? theme.expense : Color.primary).figureText()
                        }
                        .font(.caption)
                        .monospacedDigit()
                    }
                }
            }
        }
    }
}

/// Bars up for what came in (rent, then recharges), bars down for what went out, and the net as a line.
struct TenancyCashFlowChart: View {
    let flow: TenancyCashFlow
    var height: CGFloat = 160
    @Environment(\.theme) private var theme

    private func units(_ minor: Int) -> Double { Double(minor) / 100 }

    var body: some View {
        Chart {
            ForEach(flow.months, id: \.month) { month in
                let name = DashPropertyFormat.monthNames[month.month - 1]
                if month.rent != 0 {
                    BarMark(x: .value("Month", name), y: .value("Rent", units(month.rent))).foregroundStyle(theme.income)
                }
                if month.recharges != 0 {
                    BarMark(x: .value("Month", name), y: .value("Recharges", units(month.recharges))).foregroundStyle(theme.income.opacity(0.55))
                }
                if month.paidOut != 0 {
                    BarMark(x: .value("Month", name), y: .value("Paid out", -units(month.paidOut))).foregroundStyle(theme.series(1))
                }
            }
            ForEach(flow.months.filter { $0.received != 0 || $0.paidOut != 0 }, id: \.month) { month in
                let name = DashPropertyFormat.monthNames[month.month - 1]
                LineMark(x: .value("Month", name), y: .value("Net", units(month.net)), series: .value("Series", "Net"))
                    .foregroundStyle(theme.series(0)).lineStyle(StrokeStyle(lineWidth: 1.5))
                PointMark(x: .value("Month", name), y: .value("Net", units(month.net))).foregroundStyle(theme.series(0)).symbolSize(24)
            }
        }
        .wrapProbeInChart()
        .chartXScale(domain: DashPropertyFormat.monthNames)
        .chartXAxis {
            AxisMarks(values: DashPropertyFormat.monthNames) { value in
                AxisValueLabel { if let name = value.as(String.self) { Text(String(name.prefix(1))) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let units = value.as(Double.self) { Text(DashPropertyFormat.axis(units, flow.currency)).figureText() } }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Rent and recharges received, costs paid out and the net, by month of \(String(flow.year)), in \(flow.currency.rawValue.uppercased())")
    }
}

// MARK: Property return

/// A property's return for the selected year: net rental income so far and projected, yields on its value, and the
/// running total by month against last year's.
struct PropertyReturnTile: View {
    let result: PropertyReturn
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    private var basis: String {
        switch result.valueBasis {
        case .valuation: return "on its valuation"
        case .purchasePrice: return "on its purchase price"
        case nil: return ""
        }
    }

    var body: some View {
        DashTile("Return · \(result.propertyName)", linkTitle: "Property", onLink: { navigate(.property) }) { size in
            let rows = DashPropertyFormat.listRows(height: size.height, maximum: 3)
            ChartBeside(maximumLines: 3, footer: rows > 0 ? CGFloat(rows) * 22 + 6 : 0) { lines in
                VStack(alignment: .leading, spacing: 4) {
                    TileFigure(value: DashPropertyFormat.whole(result.netToDate, result.currency), caption: "net rental income \(String(result.year)) so far",
                               tint: result.netToDate < 0 ? theme.expense : .primary)
                    if lines >= 1, let projected = result.projectedNet {
                        Text("Projected \(DashPropertyFormat.whole(projected, result.currency))").font(.caption).foregroundStyle(.secondary)
                            .figureText(.shrink(minimumScale: 0.8))
                    }
                    if lines >= 2, let net = result.netYield {
                        Text("Net yield \(DashPropertyFormat.percent(net))").font(.caption).foregroundStyle(.secondary).figureText(.shrink(minimumScale: 0.8))
                    }
                    if lines >= 3, let last = result.lastYearNet {
                        Text("\(String(result.year - 1)) dashed: \(DashPropertyFormat.whole(last, result.currency))").font(.caption).foregroundStyle(.secondary)
                            .figureText(.shrink(minimumScale: 0.8))
                    }
                }
            } chart: { height in
                PropertyReturnChart(result: result, height: height)
            }
            if rows > 0 { list(rows: rows, width: size.width) }
        }
    }

    @ViewBuilder
    private func list(rows: Int, width: CGFloat) -> some View {
        VStack(spacing: 2) {
            line("Income", DashPropertyFormat.whole(result.incomeToDate, result.currency), theme.income)
            if rows >= 2 {
                line(result.mortgageInterestToDate > 0 ? "Costs, mortgage interest \(DashPropertyFormat.whole(result.mortgageInterestToDate, result.currency)) incl." : "Costs",
                     DashPropertyFormat.whole(result.costsToDate, result.currency), theme.series(1))
            }
            if rows >= 3 {
                if let gross = result.grossYield { line("Gross yield \(basis)", DashPropertyFormat.percent(gross), .primary) }
                else if let value = result.value { line("Value", DashPropertyFormat.whole(value, result.currency), .primary) }
            }
        }
    }

    private func line(_ label: String, _ figure: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(figure).foregroundStyle(tint).figureText()
        }
        .font(.caption)
        .monospacedDigit()
    }
}

/// The running total of the net by month: this year (to now) against last year's whole year.
struct PropertyReturnChart: View {
    let result: PropertyReturn
    var height: CGFloat = 160
    @Environment(\.theme) private var theme

    private func units(_ minor: Int) -> Double { Double(minor) / 100 }

    var body: some View {
        Chart {
            ForEach(Array(result.lastYearCumulative.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("Month", DashPropertyFormat.monthNames[index]), y: .value("Net", units(value)),
                         series: .value("Series", "\(String(result.year - 1))"))
                    .foregroundStyle(Color.secondary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
            ForEach(Array(result.cumulative.enumerated()), id: \.offset) { index, value in
                if let value {
                    LineMark(x: .value("Month", DashPropertyFormat.monthNames[index]), y: .value("Net", units(value)),
                             series: .value("Series", "\(String(result.year))"))
                        .foregroundStyle(theme.series(0)).lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .wrapProbeInChart()
        .chartXScale(domain: DashPropertyFormat.monthNames)
        .chartXAxis {
            AxisMarks(values: DashPropertyFormat.monthNames) { value in
                AxisValueLabel { if let name = value.as(String.self) { Text(String(name.prefix(1))) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let units = value.as(Double.self) { Text(DashPropertyFormat.axis(units, result.currency)).figureText() } }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Running net rental income by month of \(String(result.year)) against \(String(result.year - 1))")
    }
}
