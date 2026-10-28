// App/Salary/SalarySimulatorView.swift
import SwiftUI
import Charts
import BudgetCore

/// The salary simulator: two salaries (what you have, an offer) and what each leaves you,
/// with the difference pinned above the forms.
struct SalarySimulatorView: View {
    @State private var model = SalaryComparisonViewModel()
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            strip
            ScrollView {
                VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                    HStack(alignment: .top, spacing: ScreenMetrics.spacing) {
                        SalaryColumnView(title: "Current", inputs: $model.current,
                                         result: model.comparison.current, ready: model.ready.current)
                        SalaryColumnView(title: "Offer", inputs: $model.offer,
                                         result: model.comparison.offer, ready: model.ready.offer)
                    }
                    chart
                }
            }
            Text("An estimate from published UK rates, not tax advice.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(ScreenMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Salary simulator")
    }

    // MARK: Comparison strip

    private var strip: some View {
        Panel("Offer against current", accessory: {
            Button("Reset") { model.reset() }.buttonStyle(.link).font(.caption)
        }, content: {
            FigureStrip([
                FigureTile(title: "Take-home a month", value: .money(model.comparison.monthlyDifference, .gbp, .signed)),
                FigureTile(title: "Take-home a year", value: .money(model.comparison.annualDifference, .gbp, .signed)),
                FigureTile(title: "Of each extra £1 gross you keep",
                           value: .text(Self.pence(model.comparison.keepPerExtraPound)))
            ])
        })
    }

    private static func pence(_ basisPoints: Int) -> String {
        String(format: "%.0fp", Double(basisPoints) / 100)
    }

    // MARK: Chart

    private struct Bar: Identifiable {
        let side: String, part: String, pounds: Double
        var id: String { side + part }
    }

    private var bars: [Bar] {
        [("Current", model.comparison.current), ("Offer", model.comparison.offer)].flatMap { side, result in
            SalaryBarSegments.segments(result).filter { $0.pence > 0 }.map { Bar(side: side, part: $0.label, pounds: Double($0.pence) / 100) }
        }
    }

    private var chart: some View {
        let parts = ["Take-home", "Income tax", "National Insurance", "Loans", "Pension"]
        let colors = theme.chartSeries
        return Panel("Where the money goes", subtitle: "A year of gross pay, split by what it goes to") {
            Chart(bars) { bar in
                BarMark(x: .value("Pounds", bar.pounds), y: .value("Salary", bar.side))
                    .foregroundStyle(by: .value("Part", bar.part))
            }
            .chartForegroundStyleScale(domain: parts, range: parts.indices.map { colors.isEmpty ? Color.accentColor : colors[$0 % colors.count] })
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let pounds = value.as(Double.self) { Text("£\(Int(pounds / 1000))k").monospacedDigit() }
                    }
                }
            }
            .chartLegend(position: .bottom)
            .frame(height: 130)
        }
    }
}
