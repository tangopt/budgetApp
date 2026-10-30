// App/Salary/SalarySimulatorView.swift
import SwiftUI
import BudgetCore

/// The salary simulator: two salaries (what you have, an offer) and what each leaves you,
/// with the difference pinned above the forms. "Try in Forecast…" is the button under the form (the only one).
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
        VStack(alignment: .leading, spacing: 0) {
            if let edit = model.offerEdit {
                editingBanner(edit).padding([.horizontal, .top], ScreenMetrics.padding)
            }
            // The forms on the left, every result on the right; the divider between is dragged
            // and its place remembered on this Mac.
            ResizableSplit(kind: "salary", defaultFraction: 0.5, leadingMinimum: 430, trailingMinimum: 430) {
                SalaryFormView(model: model, forecastTitle: forecastTitle, forecastDisabled: offerReason != nil,
                               forecastMessage: offerReason ?? sheetError, forecastMessageIsError: offerReason == nil && sheetError != nil,
                               tryInForecast: openSheet)
            } trailing: {
                SalaryResultsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.refreshPrefill() }
        .sheet(item: $sheet) { host in
            TryInForecastSheet(host: host, onSaved: saved)
        }
        .navigationTitle("Salary calculator")
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
        // The update button is the one under the form: the screen has one.
        InlineBanner(.info, action: {
            Button("Stop editing") { model.endOfferEdit(saved: false) }
        }, content: {
            Text("Editing the new salary in \(edit.scenarioName). Change the salaries, then update the scenario under the form. Your own figures come back when you stop.")
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        })
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
}
