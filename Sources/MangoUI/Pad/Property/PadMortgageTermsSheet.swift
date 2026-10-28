import SwiftUI
import BudgetCore

/// Edit terms (Profile ▸ Mortgage) on the iPad (step 10, Task 16): the Mac's Mortgage terms… fields and checks
/// (`MortgageTermsEditing.Form`) — what the rate follows (a Euribor tenor and the spread, or a fixed rate), how a revision's
/// fixing is chosen, the months it's revised in, the instalments (how many, the first and final days), the amount borrowed
/// and the balloon, how interest is counted and rounded, and a rate given for single periods — with the rate they give now.
/// Saved only with Save, through the device writer (filed years checked): a refusal shows at the top and the form stays.
/// Cancel leaves the stored terms as they were.
struct PadMortgageTermsSheet: View {
    @ObservedObject var model: PadProfileModel
    @ObservedObject var write: PadWriteModel
    @State var form: MortgageTermsEditing.Form
    @State private var newOverrideStart: Date?
    @State private var newOverrideText = ""
    @State private var problem: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme

    private var calendar: Calendar { MonthRange.calendar }
    private var today: Date { model.utcToday }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PadRefusalBanner(message: problem ?? model.mortgageFormMessage)
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                rateSection
                revisionSection
                instalmentSection
                amountsSection
                interestSection
                Section("Rate now") {
                    let preview = form.preview(series: model.series(form.index), today: today)
                    Text((preview ?? "Not worked out yet").figuresUnbroken)
                        .foregroundStyle(preview == nil ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mortgage-rate-now")
                }
                overrideSection
            }
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Mortgage terms")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        problem = nil
                        saving = true
                        Task {
                            let saved = await model.saveMortgage(form)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(!form.canSave || saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    // MARK: Rate

    private var rateSection: some View {
        Section {
            Picker("Rate follows", selection: $form.index) {
                ForEach(InterestIndex.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .frame(minHeight: 44)
            if form.index == .fixed {
                percentField("Fixed rate", text: $form.fixedRateText, prompt: "e.g. 2.500", unit: "% a year")
            } else {
                percentField("Spread", text: $form.spreadText, prompt: "e.g. 1.000", unit: "% spread")
                Picker("Fixing", selection: $form.convention) {
                    Text("Monthly average of the previous month").tag(MortgageFixingConvention.previousMonthAverage)
                    Text("Value business days before").tag(MortgageFixingConvention.businessDaysBefore)
                }
                .frame(minHeight: 44)
                if form.convention == .businessDaysBefore {
                    Stepper(value: $form.businessDays, in: 0...10) {
                        Text("\(form.businessDays) business day\(form.businessDays == 1 ? "" : "s") before").monospacedDigit()
                    }
                    .frame(minHeight: 44)
                }
            }
        } header: {
            Text("Rate")
        } footer: {
            if form.index != .fixed {
                Text(form.convention == .businessDaysBefore
                     ? "The ECB publishes monthly averages only: give the bank's rate for each period below."
                     : "Euribor monthly averages come from the ECB (the Mac fetches them once a day). E.g. the September average for the revision on 1 October.")
            }
        }
    }

    private func percentField(_ title: String, text: Binding<String>, prompt: String, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            TextField(title, text: text, prompt: Text(prompt))
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
            Text(unit).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .frame(minHeight: 44)
    }

    // MARK: Revisions

    private var revisionSection: some View {
        Section {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(1...6, id: \.self) { column in
                            let month = row * 6 + column
                            let isOn = form.months.contains(month)
                            Button {
                                if isOn { form.months.remove(month) } else { form.months.insert(month) }
                            } label: {
                                Text(MortgageTerms.shortMonthName(month))
                                    .mangoFont(.subheadline, weight: .semibold)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(isOn ? Color.white : theme.accent)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isOn ? theme.accent : Color.secondary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Revised on 1 \(MortgageTerms.shortMonthName(month))")
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            Button("Every quarter") { form.months = Set(MortgageTerms.defaultRevisionMonths) }
                .frame(minHeight: 44)
                .accessibilityHint("1 January, 1 April, 1 July and 1 October")
        } header: {
            Text("Rate revised")
        } footer: {
            Text(form.scheduleNote).foregroundStyle(form.months.isEmpty ? theme.expense : .secondary)
        }
    }

    // MARK: Instalments

    private var instalmentSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("Instalments in all")
                Spacer(minLength: 8)
                TextField("Instalments", text: $form.totalText, prompt: Text("e.g. 480"))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
            }
            .frame(minHeight: 44)
            Toggle("First instalment known", isOn: $form.hasFirstDate).frame(minHeight: 44)
            if form.hasFirstDate {
                DatePicker("First due", selection: day($form.firstDate), displayedComponents: .date).frame(minHeight: 44)
            }
            if let derived = form.derivedFinalDate, !form.hasFinalDate {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Final instalment")
                        Text("From the first and their number").mangoFont(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(PhoneDateFormat.day(derived).unbroken).monospacedDigit().lineLimit(1).fixedSize()
                    Button("Set a day") {
                        form.hasFinalDate = true
                        form.finalDate = derived
                    }
                    .buttonStyle(.pad(.secondary, size: .small))
                }
                .frame(minHeight: 44)
            } else {
                Toggle("Final instalment known", isOn: $form.hasFinalDate).frame(minHeight: 44)
                if form.hasFinalDate {
                    DatePicker("Final due", selection: day($form.finalDate, default: form.derivedFinalDate), displayedComponents: .date)
                        .frame(minHeight: 44)
                }
            }
        } header: {
            Text("Instalments")
        } footer: {
            Text("The final one included; the number on the bank's receipt is “Recibo n/total”.")
        }
    }

    private var amountsSection: some View {
        Section {
            amountField("Amount borrowed", text: $form.borrowedText)
            amountField("Balloon", text: $form.balloonText)
        } header: {
            Text("Amounts")
        } footer: {
            Text("Lent at the start (Overview draws the loan from it); balloon: repaid with the final instalment (0: none).")
        }
    }

    private func amountField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            TextField(title, text: text, prompt: Text("0.00"))
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 160)
            Text(model.currency.rawValue.uppercased()).foregroundStyle(.secondary).fixedSize()
        }
        .frame(minHeight: 44)
    }

    private var interestSection: some View {
        Section {
            Picker("Day count", selection: $form.dayCount) {
                Text("30/360").tag(MortgageDayCount.thirty360)
                Text("Actual/360").tag(MortgageDayCount.actual360)
            }
            .frame(minHeight: 44)
            Picker("Rounding", selection: $form.rounding) {
                Text("Nearest cent").tag(MortgageInterestRounding.nearest)
                Text("Cent down").tag(MortgageInterestRounding.down)
            }
            .frame(minHeight: 44)
            if form.index != .fixed {
                Stepper(value: $form.indexDecimals, in: 0...6) {
                    Text("Index rounded to \(form.indexDecimals) dp").monospacedDigit()
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text("Interest")
        } footer: {
            Text("30/360: a month's interest is the rate ÷ 12; Actual/360: the rate × the days ÷ 360. Each month's interest is rounded to the cent.")
        }
    }

    // MARK: Rates given

    private var overrideSection: some View {
        Section {
            ForEach(form.overrides, id: \.periodStart) { given in
                HStack(spacing: 8) {
                    Text("From \(PhoneDateFormat.day(given.periodStart))".figuresUnbroken).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(MortgageRate.percent(given.ratePercent)).monospacedDigit().lineLimit(1).fixedSize()
                    Button { form.removeOverride(start: given.periodStart) } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.red).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove the rate given from \(MortgageTerms.dayText(given.periodStart))")
                }
            }
            let choices = form.overrideChoices(today: today)
            if let first = choices.first {
                Picker("Period", selection: Binding(get: { newOverrideStart ?? first }, set: { newOverrideStart = $0 })) {
                    ForEach(choices, id: \.self) { Text("From \(MortgageTerms.dayText($0))").tag($0) }
                }
                .frame(minHeight: 44)
                HStack(spacing: 8) {
                    TextField("Rate", text: $newOverrideText, prompt: Text("e.g. 3.250"))
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    Text("%").foregroundStyle(.secondary)
                    Button("Add") {
                        if let failure = form.addOverride(start: newOverrideStart ?? first, text: newOverrideText) {
                            problem = failure.message
                        } else {
                            problem = nil
                            newOverrideText = ""
                            newOverrideStart = nil
                        }
                    }
                    .buttonStyle(.pad(.secondary, size: .small))
                    .disabled(newOverrideText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text("Rate given")
        } footer: {
            Text("Only when the bank's notice differs: it wins over the rules for that period.")
        }
    }

    /// A stored day (UTC midnight) as the picker's binding, `default` (else today) while none.
    private func day(_ value: Binding<Date?>, default fallback: Date? = nil) -> Binding<Date> {
        Binding(get: { value.wrappedValue ?? fallback ?? today },
                set: { value.wrappedValue = calendar.startOfDay(for: $0) })
    }
}
