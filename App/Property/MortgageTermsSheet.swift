// App/Property/MortgageTermsSheet.swift
import SwiftUI
import BudgetCore

/// Mortgage terms… (Profile): the loan's rules, from which `MortgageRate` works out each
/// revision's rate and instalment — what the rate follows (a Euribor tenor and the spread, or a
/// fixed rate), how a revision's fixing is chosen, when it's revised (the months, on their 1st;
/// every quarter by default), the instalments (how many, the first one's day, the balloon left
/// for the final one), how interest is counted and rounded — and a rate given for single
/// periods (when the bank's notice says otherwise), which always wins. A live line shows the
/// rate these rules give now. Saved with `MortgageTerms.save` and `MortgageRate.setOverride`.
struct MortgageTermsSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var index: InterestIndex
    @State private var spreadText: String
    @State private var fixedRateText: String
    @State private var convention: MortgageFixingConvention
    @State private var businessDays: Int
    @State private var months: Set<Int>
    @State private var totalText: String
    @State private var hasFirstDate: Bool
    @State private var firstDate: Date?
    @State private var hasFinalDate: Bool
    @State private var finalDate: Date?
    @State private var balloonText: String
    @State private var borrowedText: String
    @State private var dayCount: MortgageDayCount
    @State private var rounding: MortgageInterestRounding
    @State private var indexDecimals: Int
    @State private var overrides: [MortgageRateOverride]
    @State private var newOverrideStart: Date?
    @State private var newOverrideText = ""
    @State private var series: MortgageRate.Series
    @State private var error: String?

    /// The figures the terms keep from before (a note, and the fixed rate's column).
    private let stored: PropertyMortgageTerms

    init(viewModel: PropertyViewModel) {
        self.viewModel = viewModel
        let terms = viewModel.snapshot.mortgageTerms ?? PropertyMortgageTerms(propertyId: viewModel.propertyId ?? 0)
        stored = terms
        let index = terms.rateIndex ?? .euribor3M
        _index = State(initialValue: index)
        _spreadText = State(initialValue: terms.spreadPercent.map { String($0) } ?? "")
        // As stored: no rounding, so saving unchanged keeps the rate.
        _fixedRateText = State(initialValue: terms.annualRatePercent.map { String($0) } ?? "")
        _convention = State(initialValue: terms.fixingConvention)
        _businessDays = State(initialValue: terms.fixingBusinessDays)
        _months = State(initialValue: Set(terms.revisionMonths))
        _totalText = State(initialValue: terms.totalInstalments.map(String.init) ?? "")
        _hasFirstDate = State(initialValue: terms.firstInstalmentDate != nil)
        _firstDate = State(initialValue: terms.firstInstalmentDate)
        _hasFinalDate = State(initialValue: terms.finalInstalmentDate != nil)
        _finalDate = State(initialValue: terms.finalInstalmentDate)
        _balloonText = State(initialValue: terms.balloonMinorUnits.map { Money.formatInput($0) } ?? "")
        _borrowedText = State(initialValue: terms.amountBorrowedMinorUnits.map { Money.formatInput($0) } ?? "")
        _dayCount = State(initialValue: terms.dayCount)
        _rounding = State(initialValue: terms.interestRounding)
        _indexDecimals = State(initialValue: terms.indexDecimals)
        _overrides = State(initialValue: viewModel.snapshot.rateOverrides)
        _series = State(initialValue: viewModel.rateSeries(index))
    }

    private var currency: Currency { viewModel.currency }
    private var today: Date { PropertyDays.utcToday(AppClock.now) }

    var body: some View {
        SheetScaffold(title: "Mortgage terms", subtitle: "The loan's rules: the rate and the instalment are worked out from them at each revision",
                      error: error, width: SheetMetrics.listWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: !months.isEmpty, action: save)) {
            SheetForm {
                rateRows
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
                instalmentRows
                LabeledContent("Interest") {
                    HStack(spacing: 8) {
                        Picker("Day count", selection: $dayCount) {
                            Text("30/360").tag(MortgageDayCount.thirty360)
                            Text("Actual/360").tag(MortgageDayCount.actual360)
                        }
                        .fixedSize()
                        .help("30/360: a month's interest is the rate ÷ 12; Actual/360: the rate × the days ÷ 360")
                        Picker("Rounding", selection: $rounding) {
                            Text("Nearest cent").tag(MortgageInterestRounding.nearest)
                            Text("Cent down").tag(MortgageInterestRounding.down)
                        }
                        .fixedSize()
                        .help("How each month's interest is rounded to the cent")
                        if index != .fixed {
                            Stepper(value: $indexDecimals, in: 0...6) {
                                Text("index to \(indexDecimals) dp").monospacedDigit().figureText()
                            }
                            .labelsHidden()
                            .fixedSize()
                            .help("The index is rounded to this many decimals before the spread is added")
                            .accessibilityLabel("Decimals the index is rounded to")
                            Text("index to \(indexDecimals) dp").monospacedDigit().foregroundStyle(.secondary).figureText()
                                .accessibilityHidden(true)
                        }
                    }
                }
                LabeledContent("Rate now") {
                    Text((previewText ?? "Not worked out yet").figuresUnbroken)
                        .foregroundStyle(previewText == nil ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                overrideRows
            }
        }
        .onChange(of: index) { _, index in series = viewModel.rateSeries(index) }
    }

    // MARK: Rate

    @ViewBuilder
    private var rateRows: some View {
        LabeledContent("Rate follows") {
            HStack(spacing: 6) {
                Picker("Index", selection: $index) {
                    ForEach(InterestIndex.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
                if index == .fixed {
                    TextField("Fixed rate", text: $fixedRateText, prompt: Text("e.g. 2.500")).frame(width: 80)
                    Text("% a year").foregroundStyle(.secondary)
                } else {
                    Text("+").foregroundStyle(.secondary)
                    TextField("Spread", text: $spreadText, prompt: Text("e.g. 1.000")).frame(width: 80)
                    Text("% spread").foregroundStyle(.secondary)
                }
            }
            .sheetFieldNote(index == .fixed ? nil : "Euribor monthly averages come from the ECB, fetched once a day")
        }
        if index != .fixed {
            LabeledContent("Fixing") {
                HStack(spacing: 8) {
                    Picker("Fixing", selection: $convention) {
                        Text("Monthly average of the previous month").tag(MortgageFixingConvention.previousMonthAverage)
                        Text("Value business days before").tag(MortgageFixingConvention.businessDaysBefore)
                    }
                    .fixedSize()
                    if convention == .businessDaysBefore {
                        Stepper(value: $businessDays, in: 0...10) {
                            Text("\(businessDays) day\(businessDays == 1 ? "" : "s")").monospacedDigit().figureText()
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Business days before the revision")
                        Text("\(businessDays) business day\(businessDays == 1 ? "" : "s") before").monospacedDigit().figureText()
                            .accessibilityHidden(true)
                    }
                }
                .sheetFieldNote(convention == .businessDaysBefore
                                ? "The ECB publishes monthly averages only: give the bank's rate for each period below"
                                : "E.g. the September average for the revision on 1 October")
            }
        }
    }

    // MARK: Instalments

    @ViewBuilder
    private var instalmentRows: some View {
        LabeledContent("Instalments") {
            HStack(spacing: 10) {
                TextField("Instalments", text: $totalText, prompt: Text("e.g. 480")).frame(width: 70)
                Text("in all, first due").foregroundStyle(.secondary).lineLimit(1)
                NamedCheckbox(title: "Known", isOn: $hasFirstDate)
                if hasFirstDate {
                    DatePicker("First instalment", selection: utcOptionalDay($firstDate, default: today), displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                }
            }
            .sheetFieldNote("The final one included; the number on the bank's receipt is “Recibo n/total”")
        }
        LabeledContent("Final instalment") {
            if let derived = derivedFinalDate, !hasFinalDate {
                HStack(spacing: 8) {
                    DateText(date: derived)
                    Text("from the first and their number").foregroundStyle(.secondary).lineLimit(1)
                    Button("Set a day") { hasFinalDate = true; finalDate = derived }
                        .controlSize(.small)
                        .help("Give the final instalment's day instead")
                }
            } else {
                HStack(spacing: 10) {
                    NamedCheckbox(title: "Known", isOn: $hasFinalDate)
                    if hasFinalDate {
                        DatePicker("Final instalment", selection: utcOptionalDay($finalDate, default: derivedFinalDate ?? today),
                                   displayedComponents: .date)
                            .labelsHidden()
                            .fixedSize()
                    }
                }
            }
        }
        // One row for both amounts (the sheet stays within a 1100×700 window).
        LabeledContent("Amount borrowed") {
            HStack(spacing: 10) {
                MoneyField("Amount borrowed", text: $borrowedText, currency: currency, width: 120)
                Text("balloon").foregroundStyle(.secondary).lineLimit(1)
                MoneyField("Balloon", text: $balloonText, currency: currency, width: 120)
            }
            .sheetFieldNote("Lent at the start (Overview draws the loan from it); balloon: repaid with the final instalment (0: none)")
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

    // MARK: Overrides

    /// The revision days a rate can be given for: the last four and the next two.
    private var overrideChoices: [Date] {
        let calendar = MonthRange.calendar
        let dates = MortgageTerms.revisionDates(months: Array(months.isEmpty ? Set(MortgageTerms.defaultRevisionMonths) : months),
                                                from: calendar.date(byAdding: .year, value: -2, to: today)!,
                                                to: calendar.date(byAdding: .year, value: 1, to: today)!)
        // The period in force first, then the next ones, then the earlier ones.
        let past = Array(dates.filter { $0 <= today }.suffix(4).reversed())
        let next = Array(dates.filter { $0 > today }.prefix(2))
        let given = Set(overrides.map(\.periodStart))
        return (past.prefix(1) + next + past.dropFirst()).filter { !given.contains($0) }
    }

    @ViewBuilder
    private var overrideRows: some View {
        LabeledContent("Rate given") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(overrides, id: \.periodStart) { given in
                    HStack(spacing: 8) {
                        Text("From").foregroundStyle(.secondary)
                        DateText(date: given.periodStart)
                        Text(MortgageRate.percent(given.ratePercent)).monospacedDigit().figureText()
                        Button { overrides.removeAll { $0.periodStart == given.periodStart } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .help("Use the rate the rules give for this period")
                            .accessibilityLabel("Remove the rate given from \(MortgageTerms.dayText(given.periodStart))")
                    }
                }
                let choices = overrideChoices
                if !choices.isEmpty {
                    HStack(spacing: 6) {
                        Picker("Period", selection: Binding(get: { newOverrideStart ?? choices.first! }, set: { newOverrideStart = $0 })) {
                            ForEach(choices, id: \.self) { Text("From \(MortgageTerms.dayText($0))").tag($0) }
                        }
                        .fixedSize()
                        TextField("Rate", text: $newOverrideText, prompt: Text("e.g. 3.250")).frame(width: 80)
                        Text("%").foregroundStyle(.secondary)
                        Button("Add") { addOverride(start: newOverrideStart ?? choices.first!) }
                            .controlSize(.small)
                            .disabled(newOverrideText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .sheetFieldNote("Only when the bank's notice differs: it wins over the rules for that period")
        }
    }

    private func addOverride(start: Date) {
        guard let rate = percentValue(newOverrideText), let propertyId = viewModel.propertyId else {
            error = "“\(newOverrideText)” isn't a rate: enter a percentage such as 3.250."
            return
        }
        overrides.append(MortgageRateOverride(propertyId: propertyId, periodStart: start, ratePercent: rate))
        overrides.sort { $0.periodStart < $1.periodStart }
        newOverrideText = ""
        newOverrideStart = nil
        error = nil
    }

    // MARK: Preview and save

    private var derivedFinalDate: Date? {
        guard hasFirstDate, let first = firstDate, let total = Int(totalText.trimmingCharacters(in: .whitespaces)), total >= 1 else { return nil }
        return MortgageTerms.dueDate(monthsAfter: total - 1, first: first)
    }

    /// The terms as the fields stand (nil while a field doesn't read).
    private var draft: PropertyMortgageTerms? {
        guard let propertyId = viewModel.propertyId else { return nil }
        let spread = percentValue(spreadText)
        let fixed = percentValue(fixedRateText)
        let total = Int(totalText.trimmingCharacters(in: .whitespaces))
        let balloonInput = balloonText.trimmingCharacters(in: .whitespaces)
        let balloon = balloonInput.isEmpty ? nil : Money.parseMinorUnits(balloonInput)
        let borrowedInput = borrowedText.trimmingCharacters(in: .whitespaces)
        let borrowed = borrowedInput.isEmpty ? nil : Money.parseMinorUnits(borrowedInput)
        return PropertyMortgageTerms(propertyId: propertyId, revisionMonths: Array(months), rateNote: stored.rateNote,
                                     finalInstalmentDate: hasFinalDate ? (finalDate ?? derivedFinalDate ?? today) : nil,
                                     balloonMinorUnits: balloon == 0 ? nil : balloon,
                                     annualRatePercent: index == .fixed ? fixed : nil, rateIndex: index,
                                     spreadPercent: index == .fixed ? stored.spreadPercent : spread,
                                     fixingConvention: convention, fixingBusinessDays: businessDays, dayCount: dayCount,
                                     totalInstalments: total, firstInstalmentDate: hasFirstDate ? (firstDate ?? today) : nil,
                                     indexDecimals: indexDecimals, interestRounding: rounding,
                                     amountBorrowedMinorUnits: borrowed == 0 ? nil : borrowed)
    }

    /// The rate these rules give today.
    private var previewText: String? {
        guard let terms = draft, !months.isEmpty,
              let start = MortgageRate.periodStart(containing: today, months: Array(months)) ?? (index == .fixed ? today : nil),
              let rate = MortgageRate.rate(periodStart: start, terms: terms, series: series, overrides: overrides) else { return nil }
        return "\(rate.explanation) from \(MortgageTerms.dayText(start))"
    }

    private func percentValue(_ text: String) -> Double? {
        let input = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "")
        return input.isEmpty ? nil : Double(input)
    }

    private func save() {
        let balloonInput = balloonText.trimmingCharacters(in: .whitespaces)
        if !balloonInput.isEmpty, Money.parseMinorUnits(balloonInput) == nil { error = MoneyField.invalidAmountMessage(balloonInput); return }
        let borrowedInput = borrowedText.trimmingCharacters(in: .whitespaces)
        if !borrowedInput.isEmpty, Money.parseMinorUnits(borrowedInput) == nil { error = MoneyField.invalidAmountMessage(borrowedInput); return }
        for (text, name) in [(index == .fixed ? fixedRateText : spreadText, index == .fixed ? "rate" : "spread")] {
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, percentValue(text) == nil {
                error = "“\(text)” isn't a \(name): enter a percentage such as 1.000."
                return
            }
        }
        let totalInput = totalText.trimmingCharacters(in: .whitespaces)
        if !totalInput.isEmpty, Int(totalInput) == nil { error = "“\(totalText)” isn't a number of instalments."; return }
        guard let terms = draft else { return }
        if let failure = viewModel.saveMortgageTerms(terms, overrides: overrides) { error = failure } else { dismiss() }
    }
}
