// App/Salary/SalaryFormView.swift
import SwiftUI
import BudgetCore

/// The salary simulator's inputs: one row per setting, Current and New side by side so the two line
/// up. The tax year and region are one setting for both, above the rows. Everything it shows
/// is the view model's; the results are `SalaryResultsView`'s, on the other side of the split.
struct SalaryFormView: View {
    @Bindable var model: SalaryComparisonViewModel
    /// "Try in Forecast…" or "Update <scenario>…" under the form.
    let forecastTitle: String
    let forecastDisabled: Bool
    /// Why it's off, or what went wrong opening it.
    let forecastMessage: String?
    let forecastMessageIsError: Bool
    let tryInForecast: () -> Void

    /// One value column (room for £1,234,567.89, or "Salary sacrifice").
    static let column: CGFloat = 124
    private static let labelWidth: CGFloat = 112

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                Panel("Salaries", padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.canUsePrefill {
                            Button("Use my latest payslip/P60") { model.usePrefill() }.buttonStyle(.link)
                            Text(SalaryComparisonViewModel.prefillNote).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        settings
                        Divider()
                        grid
                        // Always two lines tall, so a notice appearing as the code is typed moves nothing.
                        Text(taxCodeNotice).font(.caption).foregroundStyle(.orange)
                            .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                tryInForecastButton
            }
            .padding(12)
        }
    }

    // MARK: Tax year and region (one setting for both salaries)

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            labelled("Tax year") {
                Picker("Tax year", selection: Binding(get: { model.current.taxYearStart },
                                                      set: { model.current.taxYearStart = $0; model.offer.taxYearStart = $0 })) {
                    ForEach(SalaryRules.all.map(\.startYear).sorted(), id: \.self) { year in
                        Text(UKTaxYear(startYear: year).label).tag(year)
                    }
                }
                .labelsHidden().fixedSize()
            }
            labelled("Region") {
                Picker("Region", selection: Binding(get: { model.current.region },
                                                    set: { model.current.region = $0; model.offer.region = $0 })) {
                    Text("England, Wales, NI").tag(SalaryRegion.englandWalesNI)
                    Text("Scotland").tag(SalaryRegion.scotland)
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private func labelled<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(label).lineLimit(1)
            Spacer(minLength: 8)
            control()
        }
    }

    // MARK: Rows

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Color.clear.frame(width: Self.labelWidth, height: 1)
                Text("Current").font(.subheadline.weight(.semibold)).frame(width: Self.column, alignment: .trailing)
                Text("New").font(.subheadline.weight(.semibold)).frame(width: Self.column, alignment: .trailing)
            }
            row("Salary") { PoundsField(label: "Salary a year", pence: $0.grossAnnual) }
            row("Bonus") { BonusField(inputs: $0) }
            row("Bonus paid") { inputs in
                Picker("Bonus paid", selection: inputs.bonusPayment) {
                    ForEach(BonusPayment.choices, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: Self.column)
                .disabled(inputs.wrappedValue.bonusPay == 0)
            }
            row("Tax code") { inputs in
                TextField("1257L", text: inputs.taxCode)
                    .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 90)
            }
            Divider().gridCellColumns(3)
            row("Pension") { PensionAmountField(label: "Pension", amount: $0.pension) }
            row("Taken") { inputs in
                Picker("Pension method", selection: inputs.pensionMethod) {
                    Text("Salary sacrifice").tag(PensionMethod.salarySacrifice)
                    Text("Net pay").tag(PensionMethod.netPay)
                    Text("Relief at source").tag(PensionMethod.reliefAtSource)
                }
                .labelsHidden().frame(width: Self.column)
                .disabled(inputs.wrappedValue.pension == .percentOfGross(basisPoints: 0))
            }
            row("Employer pension") { PensionAmountField(label: "Employer pension", amount: $0.employerPension) }
            Divider().gridCellColumns(3)
            row("Student loan") { inputs in
                Picker("Student loan", selection: inputs.studentLoan) {
                    Text("None").tag(StudentLoanPlan?.none)
                    Text("Plan 1").tag(StudentLoanPlan?.some(.plan1))
                    Text("Plan 2").tag(StudentLoanPlan?.some(.plan2))
                    Text("Plan 4").tag(StudentLoanPlan?.some(.plan4))
                    Text("Plan 5").tag(StudentLoanPlan?.some(.plan5))
                }
                .labelsHidden().frame(width: Self.column)
            }
            row("Postgraduate loan") { Toggle("Postgraduate loan", isOn: $0.postgraduateLoan).labelsHidden() }
            row("Benefits in kind") { PoundsField(label: "Benefits in kind a year", pence: $0.benefitsInKindAnnual) }
        }
    }

    /// One row: the label, then the control for Current and for New.
    private func row<Control: View>(_ label: String, @ViewBuilder control: @escaping (Binding<SalaryInputs>) -> Control) -> some View {
        GridRow {
            Text(label).lineLimit(1).truncationMode(.middle).frame(width: Self.labelWidth, alignment: .leading)
                .help(label)
            control($model.current).frame(width: Self.column, alignment: .trailing)
            control($model.offer).frame(width: Self.column, alignment: .trailing)
        }
    }

    /// A tax code's notice, for whichever side has one.
    private var taxCodeNotice: String {
        let current = TaxCode.parse(model.current.taxCode).notice.map { "Current: \($0)" }
        let offer = TaxCode.parse(model.offer.taxCode).notice.map { "New: \($0)" }
        let text = [current, offer].compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? " " : text
    }

    private var tryInForecastButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(forecastTitle, action: tryInForecast)
                .disabled(forecastDisabled)
            if let forecastMessage {
                Text(forecastMessage).font(.caption).foregroundStyle(forecastMessageIsError ? Color.red : Color.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Fields

/// A pounds-and-pence field over an amount in pence. Keeps what is typed until it is a valid
/// amount; an empty field is nothing.
struct PoundsField: View {
    let label: String
    @Binding var pence: Int
    @State private var text = ""

    var body: some View {
        TextField("£0", text: $text)
            .multilineTextAlignment(.trailing).monospacedDigit()
            .textFieldStyle(.roundedBorder).frame(width: Self.width)
            .accessibilityLabel(label)
            .onChange(of: text) { _, new in
                // Shown as £65,000 as it is typed; the amount follows once it parses.
                let shown = Money.poundsFieldText(typed: new)
                if shown != new { text = shown; return }
                if shown.isEmpty { if pence != 0 { pence = 0 } }
                else if let value = Money.parseMinorUnits(shown), value != pence { pence = max(0, value) }
            }
            .onAppear { sync() }
        .onChange(of: pence) { _, new in
            if Money.parseMinorUnits(text) != new && !(text.isEmpty && new == 0) { sync() }
        }
    }

    private func sync() { text = Money.poundsFieldText(pence: pence) }

    /// Fixed, so the column doesn't move as the figure grows (room for £1,234,567.89).
    static let width: CGFloat = 124
}

/// A pension amount: a percentage of pay or a yearly pounds figure.
struct PensionAmountField: View {
    let label: String
    @Binding var amount: PensionAmount
    @State private var text = ""

    private var isPercent: Bool {
        if case .percentOfGross = amount { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("\(label) unit", selection: Binding(get: { isPercent }, set: { setPercent($0) })) {
                Text("%").tag(true)
                Text("£").tag(false)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 50)
            .help("A percentage of pay, or pounds a year")
            TextField(isPercent ? "0" : "£0", text: $text)
                .multilineTextAlignment(.trailing).monospacedDigit()
                .textFieldStyle(.roundedBorder).frame(width: PoundsField.width - 56)
                .accessibilityLabel(label)
                .onChange(of: text) { _, new in
                    if !isPercent {
                        let shown = Money.poundsFieldText(typed: new)
                        if shown != new { text = shown; return }
                    }
                    commit(new)
                }
        }
        .onAppear { sync() }
    }

    private func setPercent(_ percent: Bool) {
        guard percent != isPercent else { return }
        amount = percent ? .percentOfGross(basisPoints: 0) : .fixedAnnual(pence: 0)
        text = ""
    }

    private func commit(_ new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        if isPercent {
            let value = trimmed.isEmpty ? 0 : Double(trimmed.replacingOccurrences(of: ",", with: "."))
            if let value { amount = .percentOfGross(basisPoints: max(0, Int((value * 100).rounded()))) }
        } else {
            let value = trimmed.isEmpty ? 0 : Money.parseMinorUnits(trimmed)
            if let value { amount = .fixedAnnual(pence: max(0, value)) }
        }
    }

    private func sync() {
        switch amount {
        case .percentOfGross(let bp): text = bp == 0 ? "" : String(format: "%g", Double(bp) / 100)
        case .fixedAnnual(let pence): text = Money.poundsFieldText(pence: pence)
        }
    }
}

/// The bonus: pounds a year, or a percentage of salary (a £/% choice, as pension has).
struct BonusField: View {
    @Binding var inputs: SalaryInputs
    @State private var text = ""

    private var isPercent: Bool { inputs.bonusPercentBP != nil }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Bonus unit", selection: Binding(get: { isPercent }, set: { setPercent($0) })) {
                Text("£").tag(false)
                Text("%").tag(true)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 50)
            .help("Pounds a year, or a percentage of salary")
            TextField(isPercent ? "0" : "£0", text: $text)
                .multilineTextAlignment(.trailing).monospacedDigit()
                .textFieldStyle(.roundedBorder).frame(width: PoundsField.width - 56)
                .accessibilityLabel("Bonus a year")
                .onChange(of: text) { _, new in
                    if isPercent {
                        let trimmed = new.trimmingCharacters(in: .whitespaces)
                        let value = trimmed.isEmpty ? 0 : Double(trimmed.replacingOccurrences(of: ",", with: "."))
                        if let value { inputs.bonusPercentBP = max(0, Int((value * 100).rounded())) }
                    } else {
                        let shown = Money.poundsFieldText(typed: new)
                        if shown != new { text = shown; return }
                        if shown.isEmpty { if inputs.bonusAnnual != 0 { inputs.bonusAnnual = 0 } }
                        else if let value = Money.parseMinorUnits(shown), value != inputs.bonusAnnual { inputs.bonusAnnual = max(0, value) }
                    }
                }
        }
        .onAppear { sync() }
        // A reset or a payslip fill changes the bonus from outside.
        .onChange(of: inputs.bonusPercentBP) { _, new in
            guard let new else { sync(); return }
            let typed = Double(text.replacingOccurrences(of: ",", with: ".")).map { Int(($0 * 100).rounded()) } ?? 0
            if typed != new { sync() }
        }
        .onChange(of: inputs.bonusAnnual) { _, _ in if !isPercent, Money.parseMinorUnits(text) != inputs.bonusAnnual, !(text.isEmpty && inputs.bonusAnnual == 0) { sync() } }
    }

    private func setPercent(_ percent: Bool) {
        guard percent != isPercent else { return }
        inputs.bonusPercentBP = percent ? 0 : nil
        if !percent { inputs.bonusAnnual = 0 }
        text = ""
    }

    private func sync() {
        if let bp = inputs.bonusPercentBP { text = bp == 0 ? "" : String(format: "%g", Double(bp) / 100) }
        else { text = Money.poundsFieldText(pence: inputs.bonusAnnual) }
    }
}
