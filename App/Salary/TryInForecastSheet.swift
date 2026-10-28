// App/Salary/TryInForecastSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// "Try in Forecast…" from the salary simulator (and "Update <scenario>…" after "Edit offer…" in the scenario lab):
/// which salary the offer replaces, when it starts, any months without salary, a signing bonus and the
/// scenario's name. Save builds the scenario; the preview line says what the forecast will hold.
struct TryInForecastSheet: View {
    @ObservedObject var host: TryInForecastViewModel
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var bonusText: String
    @State private var errorMessage: String?

    init(host: TryInForecastViewModel, onSaved: @escaping () -> Void) {
        self.host = host
        self.onSaved = onSaved
        _bonusText = State(initialValue: host.model.signingBonus.map { Money.formatInput($0) } ?? "")
    }

    private var bonusInvalid: Bool {
        let text = bonusText.trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && (Money.parseMinorUnits(text).map { $0 < 0 } ?? true)
    }

    var body: some View {
        @Bindable var model = host.model
        SheetScaffold(title: model.isEditing ? "Edit offer" : "Try in Forecast",
                      subtitle: model.subtitle,
                      error: errorMessage, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: model.canSave && !bonusInvalid) { save() }) {
            SheetForm {
                LabeledContent("Scenario name") {
                    if model.isEditing {
                        Text(model.name).lineLimit(1).truncationMode(.middle)
                    } else {
                        TextField("Scenario name", text: $model.name).onChange(of: model.name) { _, _ in errorMessage = nil }
                    }
                }
                LabeledContent("Replaces") {
                    Picker("Replaces", selection: $model.salaryEntryId) {
                        ForEach(host.choices.salaries) { entry in
                            Text(host.label(entry)).lineLimit(1).truncationMode(.middle).tag(Int64?.some(entry.id!))
                        }
                        Text("No salary: add as new income").tag(Int64?.none)
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.salaryEntryId != nil { SheetFormNote(OfferSheetModel.refreshNote) }
                if model.salaryEntryId == nil {
                    LabeledContent("Income category") {
                        Picker("Income category", selection: $model.newIncomeCategoryId) {
                            ForEach(host.choices.incomeCategories) { category in
                                Text(category.name).lineLimit(1).truncationMode(.middle).tag(Int64?.some(category.id!))
                            }
                        }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !model.pensionChoices.isEmpty {
                    LabeledContent("Pension") {
                        Picker("Pension", selection: $model.pensionEntryId) {
                            ForEach(model.pensionChoices) { entry in
                                Text(host.label(entry)).lineLimit(1).truncationMode(.middle).tag(Int64?.some(entry.id!))
                            }
                            Text("Leave as it is").tag(Int64?.none)
                        }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let note = model.pensionNote { SheetFormNote(note) }
                }
                LabeledContent("Starts") {
                    Picker("Starts", selection: $model.startMonth) {
                        ForEach(model.monthOptions(), id: \.self) { month in
                            Text(OfferSheetModel.monthLabel(month)).tag(month)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                LabeledContent("Months without salary") {
                    ValueStepper("Months without salary", value: $model.noticeGapMonths, in: 0...12, text: ValueStepper.months)
                }
                SheetFormNote("A notice period: the old salary ends before the start month and the new one (and any signing bonus) begins this many months later.")
                LabeledContent("Signing bonus") {
                    TextField("Signing bonus", text: $bonusText, prompt: Text("0.00"))
                        .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 120)
                        .onChange(of: bonusText) { _, text in
                            model.signingBonus = Money.parseMinorUnits(text)
                            errorMessage = nil
                        }
                }
                if bonusInvalid { SheetFormNote("Enter an amount like 5,000.00.", isError: true) }
                LabeledContent("In the forecast") {
                    Text(model.preview).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func save() {
        switch host.save() {
        case .saved, .savedButReloadFailed:
            dismiss()
            onSaved()
        case .failed(let message):
            errorMessage = message
        }
    }
}
