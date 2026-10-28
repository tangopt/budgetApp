// App/Salary/SalaryColumnView.swift
import SwiftUI
import BudgetCore

/// One side of the salary simulator: the form for a salary and, under it, what it comes to.
struct SalaryColumnView: View {
    let title: String
    @Binding var inputs: SalaryInputs
    let result: SalaryResult
    let ready: Bool
    /// "Use my latest payslip/P60" (the Current column, when there is one to use); nil hides the button.
    var usePrefill: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            Panel("\(title) take-home") { results }
            Panel(title) {
                VStack(alignment: .leading, spacing: 8) {
                    if let usePrefill {
                        Button("Use my latest payslip/P60", action: usePrefill).buttonStyle(.link)
                        Text(SalaryComparisonViewModel.prefillNote).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    form
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Salary") { PoundsField(label: "Salary a year", pence: $inputs.grossAnnual) }
            row("Bonus") { PoundsField(label: "Bonus a year", pence: $inputs.bonusAnnual) }
            row("Tax year") {
                Picker("Tax year", selection: $inputs.taxYearStart) {
                    ForEach(SalaryRules.all.map(\.startYear).sorted(), id: \.self) { year in
                        Text(UKTaxYear(startYear: year).label).tag(year)
                    }
                }
                .labelsHidden().fixedSize()
            }
            row("Region") {
                Picker("Region", selection: $inputs.region) {
                    Text("England, Wales, NI").tag(SalaryRegion.englandWalesNI)
                    Text("Scotland").tag(SalaryRegion.scotland)
                }
                .labelsHidden().fixedSize()
            }
            row("Tax code") {
                TextField("1257L", text: $inputs.taxCode)
                    .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 90)
            }
            // Always two lines tall, so a notice appearing as the code is typed moves nothing.
            Text(TaxCode.parse(inputs.taxCode).notice ?? " ").font(.caption).foregroundStyle(.orange)
                .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            row("Pension") { PensionAmountField(label: "Pension", amount: $inputs.pension) }
            row("Taken") {
                Picker("Pension method", selection: $inputs.pensionMethod) {
                    Text("Salary sacrifice").tag(PensionMethod.salarySacrifice)
                    Text("Net pay").tag(PensionMethod.netPay)
                    Text("Relief at source").tag(PensionMethod.reliefAtSource)
                }
                .labelsHidden().fixedSize()
                .disabled(inputs.pension == .percentOfGross(basisPoints: 0))
            }
            row("Employer pension") { PensionAmountField(label: "Employer pension", amount: $inputs.employerPension) }
            Divider()
            row("Student loan") {
                Picker("Student loan", selection: $inputs.studentLoan) {
                    Text("None").tag(StudentLoanPlan?.none)
                    Text("Plan 1").tag(StudentLoanPlan?.some(.plan1))
                    Text("Plan 2").tag(StudentLoanPlan?.some(.plan2))
                    Text("Plan 4").tag(StudentLoanPlan?.some(.plan4))
                    Text("Plan 5").tag(StudentLoanPlan?.some(.plan5))
                }
                .labelsHidden().fixedSize()
            }
            row("Postgraduate loan") { Toggle("Postgraduate loan", isOn: $inputs.postgraduateLoan).labelsHidden() }
            row("Benefits in kind") { PoundsField(label: "Benefits in kind a year", pence: $inputs.benefitsInKindAnnual) }
        }
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            control()
        }
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        // Every row is always there (a dash when it doesn't apply, the whole block faded until there is
        // a salary), so nothing moves as the figures are typed.
        VStack(alignment: .leading, spacing: 8) {
            FigureStrip([
                FigureTile(title: "A year", value: .money(result.takeHomeAnnual, .gbp, .neutral)),
                FigureTile(title: "A month", value: .money(result.takeHomeMonthly, .gbp, .neutral)),
                FigureTile(title: "A week", value: .money(result.takeHomeWeekly, .gbp, .neutral))
            ])
            Divider()
            line("Income tax", result.incomeTax, cost: true)
            line("National Insurance", result.employeeNI, cost: true)
            line("Student loan", result.studentLoan, cost: true)
            line("Postgraduate loan", result.postgraduateLoan, cost: true)
            line("Your pension", result.employeePension, cost: true)
            line("Employer pension", result.employerPension, cost: false)
            line("Tax on benefits in kind", result.benefitsInKindTax, cost: true)
            Divider()
            line("Personal allowance", result.personalAllowance, cost: false)
            percentLine("Effective rate", result.effectiveRateBP)
            percentLine("Marginal rate", result.marginalRateBP)
            Text(SalaryResult.marginalPensionCaption(result) ?? " ").font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(ready ? 1 : 0.35)
        .overlay(alignment: .top) {
            if !ready { Text("Enter a salary to see the take-home.").foregroundStyle(.secondary).padding(.top, 4) }
        }
        notices
    }

    private func line(_ label: String, _ pence: Int, cost: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if pence > 0 { MoneyText(minorUnits: pence, role: cost ? .cost : .neutral) }
            else { Text("—").foregroundStyle(.secondary).accessibilityLabel("none") }
        }
    }

    private func percentLine(_ label: String, _ basisPoints: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(String(format: "%.1f%%", Double(basisPoints) / 100)).monospacedDigit().figureText()
        }
    }

    /// Notices come and go with the figures: their room is kept (two lines).
    private var notices: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(result.notices.filter { $0 != TaxCode.unreadableNotice }, id: \.self) { notice in
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let rules = SalaryRules.forYear(result.effectiveTaxYear), !rules.checkedFields.isEmpty {
                Text("Rates for \(rules.ukTaxYear.label) not yet confirmed").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
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
                Text("£ a year").tag(false)
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            TextField(isPercent ? "0" : "£0", text: $text)
                .multilineTextAlignment(.trailing).monospacedDigit()
                .textFieldStyle(.roundedBorder).frame(width: PoundsField.width - 54)
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
