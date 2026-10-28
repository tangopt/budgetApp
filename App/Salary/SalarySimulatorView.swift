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
    /// "Edit offer…" from the scenario lab: opens the sheet on this scenario, then clears.
    @Binding var editRequest: OfferEditRequest?
    /// After a scenario is saved: the shell shows the Forecast screen.
    var openForecast: () -> Void = {}
    @Environment(\.theme) private var theme
    @State private var sheet: TryInForecastViewModel?
    @State private var sheetError: String?

    init(model: SalaryComparisonViewModel, forecast: ScenarioLabViewModel? = nil,
         editRequest: Binding<OfferEditRequest?> = .constant(nil), openForecast: @escaping () -> Void = {}) {
        self.model = model
        self.forecast = forecast
        self._editRequest = editRequest
        self.openForecast = openForecast
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            strip
            ScrollView {
                VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                    HStack(alignment: .top, spacing: ScreenMetrics.spacing) {
                        SalaryColumnView(title: "Current", inputs: $model.current,
                                         result: model.comparison.current, ready: model.ready.current,
                                         usePrefill: model.canUsePrefill ? { model.usePrefill() } : nil)
                        VStack(alignment: .leading, spacing: 8) {
                            SalaryColumnView(title: "Offer", inputs: $model.offer,
                                             result: model.comparison.offer, ready: model.ready.offer)
                            tryInForecast
                        }
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
        .onAppear { openPendingEdit() }
        .onChange(of: editRequest) { openPendingEdit() }
        .sheet(item: $sheet) { host in
            TryInForecastSheet(host: host, onSaved: openForecast)
        }
        .navigationTitle("Salary simulator")
    }

    // MARK: Try in Forecast

    private var offerReason: String? {
        if forecast == nil { return "The forecast isn't available here." }
        if model.offer.grossAnnual <= 0 { return "Enter a gross salary for the offer first." }
        return nil
    }

    private var tryInForecast: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Try in Forecast…") { openSheet(edit: nil) }
                .disabled(offerReason != nil)
            if let reason = offerReason ?? sheetError {
                Text(reason).font(.caption).foregroundStyle(offerReason == nil ? .red : .secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ScreenMetrics.padding)
    }

    private func openSheet(edit: OfferEditRequest?) {
        guard let forecast else { return }
        do {
            sheet = try TryInForecastViewModel(offer: model.offer, current: model.current, edit: edit, lab: forecast)
            sheetError = nil
        } catch {
            sheetError = "Couldn't read the budget: \(error.localizedDescription)"
        }
    }

    private func openPendingEdit() {
        guard let request = editRequest else { return }
        editRequest = nil
        model.current = request.spec.current
        model.offer = request.spec.offer
        openSheet(edit: request)
    }

    // MARK: Comparison strip

    private var strip: some View {
        Panel("Offer against current", accessory: {
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
