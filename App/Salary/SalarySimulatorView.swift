// App/Salary/SalarySimulatorView.swift
import SwiftUI
import Charts
import BudgetCore

/// The salary simulator: two salaries (what you have, an offer) and what each leaves you,
/// with the difference pinned above the forms.
struct SalarySimulatorView: View {
    @Bindable var model: SalaryComparisonViewModel
    /// The Forecast screen's model, for "Try in Forecast…"; nil (the button off) where there is none.
    var forecast: ScenarioLabViewModel? = nil
    /// After a scenario is saved: the shell shows the Forecast screen.
    var openForecast: () -> Void = {}
    @Environment(\.theme) private var theme
    @State private var sheet: TryInForecastViewModel?
    @State private var sheetError: String?

    init(model: SalaryComparisonViewModel, forecast: ScenarioLabViewModel? = nil, openForecast: @escaping () -> Void = {}) {
        self.model = model
        self.forecast = forecast
        self.openForecast = openForecast
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if let edit = model.offerEdit { editingBanner(edit) }
            strip
            ScrollView {
                VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                    HStack(alignment: .top, spacing: ScreenMetrics.spacing) {
                        SalaryColumnView(title: "Current", inputs: $model.current,
                                         result: model.comparison.current, ready: model.ready.current,
                                         usePrefill: model.canUsePrefill ? { model.usePrefill() } : nil)
                        VStack(alignment: .leading, spacing: 8) {
                            SalaryColumnView(title: "New", inputs: $model.offer,
                                             result: model.comparison.offer, ready: model.ready.offer)
                            tryInForecast
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    chart
                }
            }
            Text("An estimate from published UK rates, not tax advice.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(ScreenMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.refreshPrefill() }
        .sheet(item: $sheet) { host in
            TryInForecastSheet(host: host, onSaved: saved)
        }
        .screenToolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(forecastTitle) { openSheet() }
                    .disabled(offerReason != nil)
                    .help(offerReason ?? "Make a forecast scenario with this new salary")
            }
        }
        .navigationTitle("UK Salary Calculator")
    }

    // MARK: Try in Forecast

    private var offerReason: String? {
        if forecast == nil { return "The forecast isn't available here." }
        if model.offer.grossAnnual <= 0 { return "Enter a gross salary for the new salary first." }
        return nil
    }

    /// "Try in Forecast…", or "Update <scenario>…" while editing a job-offer scenario's salaries.
    private var forecastTitle: String {
        model.offerEdit.map { "Update \($0.scenarioName)…" } ?? "Try in Forecast…"
    }

    private func editingBanner(_ edit: SalaryOfferEdit) -> some View {
        InlineBanner(.info, action: {
            HStack(spacing: 8) {
                Button("Stop editing") { model.endOfferEdit(saved: false) }
                Button(forecastTitle) { openSheet() }.disabled(offerReason != nil)
            }
        }, content: {
            Text("Editing the new salary in \(edit.scenarioName). Change the salaries, then update the scenario. Your own figures come back when you stop.")
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        })
    }

    private var tryInForecast: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(forecastTitle) { openSheet() }
                .disabled(offerReason != nil)
            if let reason = offerReason ?? sheetError {
                Text(reason).font(.caption).foregroundStyle(offerReason == nil ? .red : .secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ScreenMetrics.padding)
    }

    private func openSheet() {
        guard let forecast else { return }
        do {
            sheet = try TryInForecastViewModel(offer: model.offer, current: model.current, edit: model.offerEdit, lab: forecast)
            sheetError = nil
        } catch {
            sheetError = "Couldn't read the budget: \(error.localizedDescription)"
        }
    }

    /// A scenario saved: editing (if any) ends with these salaries kept, and the Forecast screen shows it.
    private func saved() {
        model.endOfferEdit(saved: true)
        openForecast()
    }

    // MARK: Comparison strip

    private var strip: some View {
        Panel("New against current", accessory: {
            Button(model.resetTitle) { model.reset() }.buttonStyle(.link).font(.caption)
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
        [("Current", model.comparison.current), ("New", model.comparison.offer)].flatMap { side, result in
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
