// App/Property/MortgageTermsSheet.swift
import SwiftUI
import BudgetCore

/// Mortgage terms… (Profile): when the rate is revised (the months, on their 1st; every
/// quarter by default) and what it follows, and the facts the loan's projection uses — the
/// final instalment's day, the balloon left for it and the rate charged now (else derived
/// from the interest on the loan). Saved with `MortgageTerms.save`.
struct MortgageTermsSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var months: Set<Int>
    @State private var rateNote: String
    @State private var hasFinalDate: Bool
    @State private var finalDate: Date?
    @State private var balloonText: String
    @State private var rateText: String
    @State private var error: String?

    init(viewModel: PropertyViewModel) {
        self.viewModel = viewModel
        let terms = viewModel.snapshot.mortgageTerms ?? PropertyMortgageTerms(propertyId: viewModel.propertyId ?? 0)
        _months = State(initialValue: Set(terms.revisionMonths))
        _rateNote = State(initialValue: terms.rateNote ?? "")
        _hasFinalDate = State(initialValue: terms.finalInstalmentDate != nil)
        _finalDate = State(initialValue: terms.finalInstalmentDate)
        _balloonText = State(initialValue: terms.balloonMinorUnits.map { Money.formatInput($0) } ?? "")
        // As stored: no rounding, so saving unchanged keeps the rate.
        _rateText = State(initialValue: terms.annualRatePercent.map { String($0) } ?? "")
    }

    private var currency: Currency { viewModel.currency }

    var body: some View {
        SheetScaffold(title: "Mortgage terms", subtitle: "The rate's revisions show on the calendar; the loan chart projects the balance with these",
                      error: error, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: !months.isEmpty, action: save)) {
            SheetForm {
                LabeledContent("Rate revised") {
                    VStack(alignment: .leading, spacing: 6) {
                        monthGrid
                        HStack(spacing: 8) {
                            Button("Every quarter") { months = Set(MortgageTerms.defaultRevisionMonths) }
                                .controlSize(.small)
                                .help("1 January, 1 April, 1 July and 1 October")
                            Text(months.isEmpty ? "Choose at least one month" : "On the 1st: " + MortgageTerms.scheduleText(Array(months)))
                                .font(.caption).foregroundStyle(months.isEmpty ? theme.expense : .secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                LabeledContent("Rate follows") {
                    TextField("Rate follows", text: $rateNote, prompt: Text("Optional, e.g. Euribor 3M + 1.00%"))
                }
                LabeledContent("Rate now") {
                    HStack(spacing: 4) {
                        TextField("Rate now", text: $rateText, prompt: Text("e.g. 3.250")).frame(width: 90)
                        Text("% a year").foregroundStyle(.secondary)
                    }
                    .sheetFieldNote("Blank: worked out from the last interest charged on the loan")
                }
                LabeledContent("Final instalment") {
                    HStack(spacing: 10) {
                        NamedCheckbox(title: "Known", isOn: $hasFinalDate)
                        if hasFinalDate {
                            DatePicker("Final instalment", selection: utcOptionalDay($finalDate, default: PropertyDays.utcToday(AppClock.now)),
                                       displayedComponents: .date)
                                .labelsHidden()
                                .fixedSize()
                        }
                    }
                }
                LabeledContent("Balloon") {
                    MoneyField("Balloon", text: $balloonText, currency: currency, width: 140)
                        .sheetFieldNote("Capital left to repay with the final instalment (blank or 0: none)")
                }
            }
        }
    }

    /// Twelve month toggles, two rows of six.
    private var monthGrid: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(1...6, id: \.self) { column in
                        let month = row * 6 + column
                        Toggle(MortgageTerms.shortMonthName(month), isOn: Binding(
                            get: { months.contains(month) },
                            set: { if $0 { months.insert(month) } else { months.remove(month) } }))
                            .toggleStyle(.button)
                            .prominentTint()
                            .controlSize(.small)
                            .frame(minWidth: 44)
                            .accessibilityLabel("Revised on 1 \(MortgageTerms.shortMonthName(month))")
                    }
                }
            }
        }
    }

    private func save() {
        let balloonInput = balloonText.trimmingCharacters(in: .whitespaces)
        let balloon = balloonInput.isEmpty ? nil : Money.parseMinorUnits(balloonInput)
        if !balloonInput.isEmpty, balloon == nil { error = MoneyField.invalidAmountMessage(balloonInput); return }
        let rateInput = rateText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let rate = rateInput.isEmpty ? nil : Double(rateInput)
        if !rateInput.isEmpty, rate == nil { error = "“\(rateText)” isn't a rate: enter a percentage such as 3.25."; return }
        guard let propertyId = viewModel.propertyId else { return }
        let terms = PropertyMortgageTerms(propertyId: propertyId, revisionMonths: Array(months), rateNote: rateNote,
                                          finalInstalmentDate: hasFinalDate ? (finalDate ?? PropertyDays.utcToday(AppClock.now)) : nil,
                                          balloonMinorUnits: balloon == 0 ? nil : balloon, annualRatePercent: rate)
        if let failure = viewModel.saveMortgageTerms(terms) { error = failure } else { dismiss() }
    }
}
