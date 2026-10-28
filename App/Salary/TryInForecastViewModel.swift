// App/Salary/TryInForecastViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

/// What the offer sheet can pick from (`ScenarioLabViewModel.offerChoices`).
struct OfferChoices {
    var salaries: [ForecastEntry] = []
    var pensions: [OfferPensionCandidate] = []
    var incomeCategories: [Category] = []
    var categoryNames: [Int64: String] = [:]
}

/// The "Try in Forecast…" sheet's host: the pure state (`OfferSheetModel`), the budget entries' labels and the
/// save through the Forecast screen's write path.
@MainActor
final class TryInForecastViewModel: ObservableObject, Identifiable {
    let model: OfferSheetModel
    let choices: OfferChoices
    private let lab: ScenarioLabViewModel

    /// `offer`/`current`: the simulator's salaries (in edit mode too: the person has just edited them there).
    init(offer: SalaryInputs, current: SalaryInputs, edit: SalaryOfferEdit?, lab: ScenarioLabViewModel) throws {
        let choices = try lab.offerChoices()
        self.choices = choices
        self.lab = lab
        model = OfferSheetModel(offer: offer, current: current, candidates: choices.salaries, pensionCandidates: choices.pensions,
                                editing: edit.map { ($0.scenarioId, $0.spec) }, scenarioName: edit?.scenarioName,
                                newIncomeCategoryId: choices.incomeCategories.first?.id)
    }

    /// "Salary, £2,000.00 a month from Jan 2026".
    func label(_ entry: ForecastEntry) -> String {
        let name = choices.categoryNames[entry.categoryId] ?? "Entry"
        return "\(name), \(Money.format(abs(entry.amountMinorUnits), currency: .gbp)) a month from \(OfferSheetModel.monthLabel(entry.startDate))"
    }

    /// Builds (or rebuilds) the scenario. Refusals come back in words for the sheet.
    func save() -> SaveOutcome {
        let spec = model.spec()
        let name = model.trimmedName
        let outcome: SaveOutcome
        if let id = model.editingScenarioId {
            outcome = lab.rebuildOffer(scenarioId: id, spec: spec)
        } else {
            outcome = lab.createOffer(name: name, spec: spec)
        }
        if case .failed(let message) = outcome { return .failed(message) }
        return outcome
    }
}
