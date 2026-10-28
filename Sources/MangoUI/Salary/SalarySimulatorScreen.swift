import SwiftUI
import BudgetCore

/// The salary simulator on iPad and iPhone (step 13, Task 3): two salaries, what each leaves you, and the difference
/// pinned above them. At regular width the two sit side by side; at compact width a "Current | New" switch shows one at
/// a time under the pinned comparison strip. At accessibility Dynamic Type sizes the strip scrolls with the page instead
/// of taking the screen. Everything it shows is `SalaryComparisonViewModel`'s; nothing here changes the household's data.
///
/// The host supplies the navigation container (the iPad's detail, the iPhone's sheet).
public struct SalarySimulatorScreen: View {
    @Bindable var viewModel: SalaryComparisonViewModel
    @State private var side: Side = .current
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Side: String, CaseIterable, Identifiable {
        case current = "Current", offer = "New"
        var id: String { rawValue }
    }

    /// The narrowest width that holds two columns.
    static let sideBySideWidth: CGFloat = 700

    public init(viewModel: SalaryComparisonViewModel) {
        self.viewModel = viewModel
    }

    /// For the snapshot routes: starts on `side` at compact width.
    init(viewModel: SalaryComparisonViewModel, startingOn side: Side) {
        self.viewModel = viewModel
        _side = State(initialValue: side)
    }

    public var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.sideBySideWidth
            let pinned = !dynamicTypeSize.isAccessibilitySize
            VStack(spacing: 0) {
                if pinned {
                    strip.padding([.horizontal, .top], 16).padding(.bottom, 8)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !pinned { strip }
                        if wide {
                            HStack(alignment: .top, spacing: 16) {
                                column(.current)
                                column(.offer)
                            }
                        } else {
                            Picker("Salary", selection: $side) {
                                ForEach(Side.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(minHeight: 44)
                            column(side)
                        }
                        Text("An estimate from published UK rates, not tax advice.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .padding(.top, pinned ? 0 : 0)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(theme.background)
        .task { await viewModel.refreshPrefill() }
        .navigationTitle("UK Salary Calculator")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Comparison strip

    private var strip: some View {
        let comparison = viewModel.comparison
        return Card {
            HStack {
                Text("New against current").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(viewModel.resetTitle) { viewModel.reset() }.frame(minHeight: 44)
            }
            VStack(spacing: 0) {
                AmountRow(label: "Take-home a month",
                          amount: MoneyText(minorUnits: comparison.monthlyDifference, currency: .gbp, role: .income))
                AmountRow(label: "Take-home a year",
                          amount: MoneyText(minorUnits: comparison.annualDifference, currency: .gbp, role: .income))
                FigureRow(label: "Of each extra £1 gross you keep") {
                    Text(Self.pence(comparison.keepPerExtraPound)).font(.body).figureText()
                }
            }
        }
    }

    static func pence(_ basisPoints: Int) -> String {
        String(format: "%.0fp", Double(basisPoints) / 100)
    }

    /// "Use my latest payslip/P60", with what it can't fill in.
    private var prefillCard: some View {
        Card {
            Button("Use my latest payslip/P60") { viewModel.usePrefill() }.frame(minHeight: 44)
            Text(SalaryComparisonViewModel.prefillNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Columns

    @ViewBuilder
    private func column(_ side: Side) -> some View {
        let isCurrent = side == .current
        let comparison = viewModel.comparison
        VStack(alignment: .leading, spacing: 16) {
            SalaryResultsCard(title: side.rawValue, result: isCurrent ? comparison.current : comparison.offer,
                              ready: isCurrent ? viewModel.ready.current : viewModel.ready.offer)
            if isCurrent && viewModel.canUsePrefill { prefillCard }
            SalaryFormCard(title: side.rawValue, inputs: isCurrent ? $viewModel.current : $viewModel.offer)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Results

/// What one salary comes to, and where its year of gross pay goes.
struct SalaryResultsCard: View {
    let title: String
    let result: SalaryResult
    let ready: Bool
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Card(title: "\(title) take-home") {
            if !ready {
                Text("Enter a salary to see the take-home.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    AmountRow(label: "A year", amount: money(result.takeHomeAnnual, .neutral))
                    AmountRow(label: "A month", amount: money(result.takeHomeMonthly, .neutral))
                    AmountRow(label: "A week", amount: money(result.takeHomeWeekly, .neutral))
                }
                Divider()
                // Every row is always there (a dash when it doesn't apply), so nothing moves as figures are typed.
                VStack(spacing: 0) {
                    optional("Income tax", result.incomeTax, .expense)
                    optional("National Insurance", result.employeeNI, .expense)
                    optional("Student loan", result.studentLoan, .expense)
                    optional("Postgraduate loan", result.postgraduateLoan, .expense)
                    optional("Your pension", result.employeePension, .expense)
                    optional("Employer pension", result.employerPension, .neutral)
                    optional("Tax on benefits in kind", result.benefitsInKindTax, .expense)
                }
                Divider()
                VStack(spacing: 0) {
                    AmountRow(label: "Personal allowance", amount: money(result.personalAllowance, .neutral))
                    percent("Effective rate", result.effectiveRateBP)
                    percent("Marginal rate", result.marginalRateBP)
                    Text(SalaryResult.marginalPensionCaption(result) ?? " ").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                bar
            }
            notices
        }
    }

    @ViewBuilder private func optional(_ label: String, _ pence: Int, _ role: MoneyRole) -> some View {
        if pence > 0 {
            AmountRow(label: label, amount: money(pence, role))
        } else {
            FigureRow(label: label) { Text("—").font(.body).foregroundStyle(.secondary).accessibilityLabel("none") }
        }
    }

    private func money(_ pence: Int, _ role: MoneyRole) -> MoneyText {
        MoneyText(minorUnits: pence, currency: .gbp, role: role)
    }

    private func percent(_ label: String, _ basisPoints: Int) -> some View {
        FigureRow(label: label) {
            Text(String(format: "%.1f%%", Double(basisPoints) / 100)).font(.body).figureText()
        }
    }

    // MARK: Where the money goes

    private var colors: [Color] { [theme.accent, theme.expense, theme.pending, Color.purple, Color.primary] }

    private var bar: some View {
        let segments = SalaryBarSegments.segments(result).enumerated().filter { $0.element.pence > 0 }
        let total = max(1, segments.reduce(0) { $0 + $1.element.pence })
        return VStack(alignment: .leading, spacing: 8) {
            Text("Where a year of gross pay goes").font(.subheadline).foregroundStyle(.secondary)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments, id: \.offset) { index, segment in
                        Rectangle().fill(colors[index % colors.count])
                            .frame(width: max(2, proxy.size.width * CGFloat(segment.pence) / CGFloat(total)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 16)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(segments, id: \.offset) { index, segment in
                    HStack(spacing: 8) {
                        Circle().fill(colors[index % colors.count]).frame(width: 10, height: 10)
                        Text(segment.label).font(.caption)
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var notices: some View {
        ForEach(result.notices.filter { $0 != TaxCode.unreadableNotice }, id: \.self) { notice in
            Text(notice).font(.caption).foregroundStyle(.secondary)
        }
        if let rules = SalaryRules.forYear(result.effectiveTaxYear), !rules.checkedFields.isEmpty {
            Text("Rates for \(rules.ukTaxYear.label) not yet confirmed").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Form

/// The inputs for one salary.
struct SalaryFormCard: View {
    let title: String
    @Binding var inputs: SalaryInputs

    var body: some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: 0) {
                field("Salary a year") { PoundsInput(label: "Salary a year", pence: $inputs.grossAnnual) }
                field("Bonus a year") { PoundsInput(label: "Bonus a year", pence: $inputs.bonusAnnual) }
                field("Tax year") {
                    Picker("Tax year", selection: $inputs.taxYearStart) {
                        ForEach(SalaryRules.all.map(\.startYear).sorted(), id: \.self) { year in
                            Text(UKTaxYear(startYear: year).label).tag(year)
                        }
                    }
                    .labelsHidden()
                }
                field("Region") {
                    Picker("Region", selection: $inputs.region) {
                        Text("England, Wales, NI").tag(SalaryRegion.englandWalesNI)
                        Text("Scotland").tag(SalaryRegion.scotland)
                    }
                    .labelsHidden()
                }
                field("Tax code") {
                    TextField("1257L", text: $inputs.taxCode)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                        .frame(minWidth: 80)
                }
                Text(TaxCode.parse(inputs.taxCode).notice ?? " ").font(.caption).foregroundStyle(.orange)
                    .lineLimit(3, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.vertical, 4)
                stacked("Pension") { PensionInput(label: "Pension", amount: $inputs.pension) }
                field("Taken") {
                    Picker("Pension method", selection: $inputs.pensionMethod) {
                        Text("Salary sacrifice").tag(PensionMethod.salarySacrifice)
                        Text("Net pay").tag(PensionMethod.netPay)
                        Text("Relief at source").tag(PensionMethod.reliefAtSource)
                    }
                    .labelsHidden()
                    .disabled(inputs.pension == .percentOfGross(basisPoints: 0))
                }
                stacked("Employer pension") { PensionInput(label: "Employer pension", amount: $inputs.employerPension) }
                Divider().padding(.vertical, 4)
                field("Student loan") {
                    Picker("Student loan", selection: $inputs.studentLoan) {
                        Text("None").tag(StudentLoanPlan?.none)
                        Text("Plan 1").tag(StudentLoanPlan?.some(.plan1))
                        Text("Plan 2").tag(StudentLoanPlan?.some(.plan2))
                        Text("Plan 4").tag(StudentLoanPlan?.some(.plan4))
                        Text("Plan 5").tag(StudentLoanPlan?.some(.plan5))
                    }
                    .labelsHidden()
                }
                Toggle("Postgraduate loan", isOn: $inputs.postgraduateLoan).frame(minHeight: 44)
                field("Benefits in kind a year") { PoundsInput(label: "Benefits in kind a year", pence: $inputs.benefitsInKindAnnual) }
            }
        }
    }

    /// A label with its control beside it (under it when the label needs the room).
    private func field<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(label).fixedSize()
                Spacer(minLength: 8)
                control().fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).fixedSize(horizontal: false, vertical: true)
                control().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 44)
    }

    /// A label over a wide control.
    private func stacked<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            control()
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44, alignment: .topLeading)
    }
}

// MARK: - Inputs

/// A pounds-and-pence field over an amount in pence, with the decimal keyboard. Keeps what is typed until it is a valid
/// amount; an empty field is nothing.
struct PoundsInput: View {
    let label: String
    @Binding var pence: Int
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("£0", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .frame(width: 130)
                .accessibilityLabel(label)
                .onChange(of: text) { _, new in
                    // Shown as £65,000 as it is typed; the amount follows once it parses.
                    let shown = Money.poundsFieldText(typed: new)
                    if shown != new { text = shown; return }
                    if shown.isEmpty { if pence != 0 { pence = 0 } }
                    else if let value = Money.parseMinorUnits(shown), value != pence { pence = max(0, value) }
                }
        }
        .onAppear { sync() }
        .onChange(of: pence) { _, new in
            if Money.parseMinorUnits(text) != new && !(text.isEmpty && new == 0) { sync() }
        }
    }

    private func sync() { text = Money.poundsFieldText(pence: pence) }
}

/// A pension amount: a percentage of pay or a yearly pounds figure.
struct PensionInput: View {
    let label: String
    @Binding var amount: PensionAmount
    @State private var text = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isPercent: Bool {
        if case .percentOfGross = amount { return true }
        return false
    }

    var body: some View {
        let unit = Picker("\(label) unit", selection: Binding(get: { isPercent }, set: { setPercent($0) })) {
            Text("%").tag(true)
            Text("£ a year").tag(false)
        }
        .labelsHidden()
        let amountField = TextField(isPercent ? "0" : "£0", text: $text)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .accessibilityLabel(label)
            .onChange(of: text) { _, new in
                if !isPercent {
                    let shown = Money.poundsFieldText(typed: new)
                    if shown != new { text = shown; return }
                }
                commit(new)
            }
        // Segments don't grow with Dynamic Type: a menu takes over at accessibility sizes.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { unit.pickerStyle(.menu); amountField }
            } else {
                HStack(spacing: 8) { unit.pickerStyle(.segmented); amountField.frame(minWidth: 60, maxWidth: 110) }
            }
        }
        .frame(minHeight: 44)
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
