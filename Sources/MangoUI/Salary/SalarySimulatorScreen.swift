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
    @Environment(\.usesPadPage) private var usesPadPage

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
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !wide {
                            Picker("Salary", selection: $side) {
                                ForEach(Side.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(minHeight: 44)
                        }
                        let sides: [Side] = wide ? Side.allCases : [side]
                        settingsCard
                        if viewModel.canUsePrefill && sides.contains(.current) { prefillCard }
                        SalaryFormCard(sides: sides, current: $viewModel.current, offer: $viewModel.offer)
                        strip
                        SalaryResultsCard(sides: sides, comparison: viewModel.comparison, ready: viewModel.ready)
                        SalaryBarsCard(sides: sides, comparison: viewModel.comparison, ready: viewModel.ready)
                        Text("An estimate from published UK rates, not tax advice.")
                            .mangoFont(.caption).foregroundStyle(.secondary)
                    }
                    .mangoFont(.body)
                    .phonePageContent()
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(theme.background)
        .task { await viewModel.refreshPrefill() }
        .phonePageTitle("UK Salary Calculator")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Comparison strip

    private var strip: some View {
        let comparison = viewModel.comparison
        return Card {
            HStack {
                Text("New against current").mangoFont(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(viewModel.resetTitle) { viewModel.reset() }.frame(minHeight: 44)
            }
            VStack(spacing: 0) {
                AmountRow(label: "Take-home a month",
                          amount: MoneyText(minorUnits: comparison.monthlyDifference, currency: .gbp, role: .income))
                AmountRow(label: "Take-home a year",
                          amount: MoneyText(minorUnits: comparison.annualDifference, currency: .gbp, role: .income))
                FigureRow(label: "Of each extra £1 gross you keep") {
                    Text(Self.pence(comparison.keepPerExtraPound)).figureText().mangoFont(.body)
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
            Text(SalaryComparisonViewModel.prefillNote).mangoFont(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Tax year and region (one setting for both salaries)

    private var settingsCard: some View {
        Card(title: "Tax year and region") {
            SalaryRow(label: "Tax year") {
                Picker("Tax year", selection: Binding(get: { viewModel.current.taxYearStart },
                                                      set: { viewModel.current.taxYearStart = $0; viewModel.offer.taxYearStart = $0 })) {
                    ForEach(SalaryRules.all.map(\.startYear).sorted(), id: \.self) { year in
                        Text(UKTaxYear(startYear: year).label).tag(year)
                    }
                }
                .labelsHidden()
            }
            SalaryRow(label: "Region") {
                Picker("Region", selection: Binding(get: { viewModel.current.region },
                                                    set: { viewModel.current.region = $0; viewModel.offer.region = $0 })) {
                    Text("England, Wales, NI").tag(SalaryRegion.englandWalesNI)
                    Text("Scotland").tag(SalaryRegion.scotland)
                }
                .labelsHidden()
            }
        }
    }
}

/// One row of the salary screen: a label, then one cell per salary shown, at one height so Current and New line up.
struct SalaryRow<Cell: View>: View {
    let label: String
    let cells: [Cell]
    var minimumHeight: CGFloat = 32

    init(label: String, minimumHeight: CGFloat = 32, @ViewBuilder cell: () -> Cell) {
        self.label = label
        self.cells = [cell()]
        self.minimumHeight = minimumHeight
    }

    init(label: String, minimumHeight: CGFloat = 32, cells: [Cell]) {
        self.label = label
        self.cells = cells
        self.minimumHeight = minimumHeight
    }

    var body: some View {
        HStack(alignment: .center, spacing: PadSpacing.s) {
            Text(label).mangoFont(.subheadline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(width: SalaryMetrics.labelWidth, alignment: .leading)
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                cell.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(minHeight: minimumHeight)
    }
}

enum SalaryMetrics {
    static var labelWidth: CGFloat { 132 }
    /// The £/% control and the amount beside it, the same for Bonus and Pension so they line up.
    static var unitWidth: CGFloat { 84 }
    static var fieldWidth: CGFloat { 96 }
}

/// A header over the cells: "Current" and "New" (nothing when one salary shows).
struct SalarySideHeader: View {
    let sides: [SalarySimulatorScreen.Side]

    var body: some View {
        if sides.count > 1 {
            HStack(spacing: PadSpacing.s) {
                Color.clear.frame(width: SalaryMetrics.labelWidth, height: 1)
                ForEach(sides) { side in
                    Text(side.rawValue).mangoFont(.subheadline, weight: .semibold).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Results

/// What each salary comes to, one row for both: the figures line up Current under New.
struct SalaryResultsCard: View {
    let sides: [SalarySimulatorScreen.Side]
    let comparison: SalaryComparison
    let ready: (current: Bool, offer: Bool)

    private func result(_ side: SalarySimulatorScreen.Side) -> SalaryResult { side == .current ? comparison.current : comparison.offer }
    private func isReady(_ side: SalarySimulatorScreen.Side) -> Bool { side == .current ? ready.current : ready.offer }

    var body: some View {
        Card(title: "Take-home") {
            SalarySideHeader(sides: sides)
            money("A year", .neutral) { $0.takeHomeAnnual }
            money("A month", .neutral) { $0.takeHomeMonthly }
            money("A week", .neutral) { $0.takeHomeWeekly }
            Divider()
            optional("Income tax", .expense) { $0.incomeTax }
            optional("National Insurance", .expense) { $0.employeeNI }
            optional("Student loan", .expense) { $0.studentLoan }
            optional("Postgraduate loan", .expense) { $0.postgraduateLoan }
            optional("Your pension", .expense) { $0.employeePension }
            optional("Employer pension", .neutral) { $0.employerPension }
            optional("Tax on benefits", .expense) { $0.benefitsInKindTax }
            Divider()
            money("Personal allowance", .neutral) { $0.personalAllowance }
            SalaryRow(label: "Effective rate", cells: sides.map { side in percent(isReady(side) ? result(side).effectiveRateBP : nil) })
            SalaryRow(label: "Marginal rate", cells: sides.map { side in percent(isReady(side) ? result(side).marginalRateBP : nil) })
            // Notes: the same height whatever they say, so nothing below or beside them moves while typing.
            SalaryRow(label: "", minimumHeight: 0, cells: sides.map { side in
                Text(SalaryResult.marginalPensionCaption(result(side)) ?? " ").mangoFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true).multilineTextAlignment(.trailing)
            })
            SalaryRow(label: "", minimumHeight: 0, cells: sides.map { side in
                Text(notes(result(side), ready: isReady(side))).mangoFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.trailing)
            })
        }
    }

    private func notes(_ result: SalaryResult, ready: Bool) -> String {
        if !ready { return "Enter a salary to see the take-home." }
        var lines = result.notices.filter { $0 != TaxCode.unreadableNotice }
        if let rules = SalaryRules.forYear(result.effectiveTaxYear), !rules.checkedFields.isEmpty {
            lines.append("Rates for \(rules.ukTaxYear.label) not yet confirmed")
        }
        return lines.isEmpty ? " " : lines.joined(separator: "\n")
    }

    private func money(_ label: String, _ role: MoneyRole, _ value: @escaping (SalaryResult) -> Int) -> some View {
        SalaryRow(label: label, cells: sides.map { side in
            Group {
                if isReady(side) { MoneyText(minorUnits: value(result(side)), currency: .gbp, role: role) }
                else { Text("—").foregroundStyle(.secondary).accessibilityLabel("none") }
            }
        })
    }

    private func optional(_ label: String, _ role: MoneyRole, _ value: @escaping (SalaryResult) -> Int) -> some View {
        SalaryRow(label: label, cells: sides.map { side in
            Group {
                if isReady(side), value(result(side)) > 0 { MoneyText(minorUnits: value(result(side)), currency: .gbp, role: role) }
                else { Text("—").foregroundStyle(.secondary).accessibilityLabel("none") }
            }
        })
    }

    private func percent(_ basisPoints: Int?) -> some View {
        Group {
            if let basisPoints { Text(String(format: "%.1f%%", Double(basisPoints) / 100)).figureText() }
            else { Text("—").foregroundStyle(.secondary) }
        }
        .mangoFont(.subheadline)
    }
}

/// Where a year of gross pay goes, one bar for each salary shown.
struct SalaryBarsCard: View {
    let sides: [SalarySimulatorScreen.Side]
    let comparison: SalaryComparison
    let ready: (current: Bool, offer: Bool)
    @Environment(\.phoneTheme) private var theme

    private var colors: [Color] { [theme.accent, theme.expense, theme.pending, Color.purple, Color.primary] }

    var body: some View {
        Card(title: "Where a year of gross pay goes") {
            ForEach(sides) { side in
                let result = side == .current ? comparison.current : comparison.offer
                if (side == .current ? ready.current : ready.offer) { bar(side.rawValue, result, showsTitle: sides.count > 1) }
            }
        }
    }

    private func bar(_ title: String, _ result: SalaryResult, showsTitle: Bool) -> some View {
        let segments = SalaryBarSegments.segments(result).enumerated().filter { $0.element.pence > 0 }
        let total = max(1, segments.reduce(0) { $0 + $1.element.pence })
        return VStack(alignment: .leading, spacing: 6) {
            if showsTitle { Text(title).mangoFont(.subheadline, weight: .semibold) }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments, id: \.offset) { index, segment in
                        Rectangle().fill(colors[index % colors.count])
                            .frame(width: max(2, proxy.size.width * CGFloat(segment.pence) / CGFloat(total)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            FlowLegend(segments: segments.map { ($0.offset, $0.element.label) }, colors: colors)
        }
    }
}

private struct FlowLegend: View {
    let segments: [(Int, String)]
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(segments, id: \.0) { index, label in
                HStack(spacing: 8) {
                    Circle().fill(colors[index % colors.count]).frame(width: 10, height: 10)
                    Text(label).mangoFont(.caption)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Form

/// The inputs for the salaries shown, one row for both: Current beside New, label on the left.
struct SalaryFormCard: View {
    let sides: [SalarySimulatorScreen.Side]
    @Binding var current: SalaryInputs
    @Binding var offer: SalaryInputs

    private func inputs(_ side: SalarySimulatorScreen.Side) -> Binding<SalaryInputs> { side == .current ? $current : $offer }

    var body: some View {
        Card(title: "Inputs") {
            SalarySideHeader(sides: sides)
            row("Salary a year") { PoundsInput(label: "Salary a year", pence: $0.grossAnnual) }
            row("Bonus") { BonusInput(inputs: $0) }
            row("Tax code") { inputs in
                TextField("1257L", text: inputs.taxCode)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .autocorrectionDisabled()
                    .frame(minWidth: 70)
            }
            SalaryRow(label: "", minimumHeight: 0, cells: sides.map { side in
                Text(TaxCode.parse(inputs(side).wrappedValue.taxCode).notice ?? " ").mangoFont(.caption).foregroundStyle(.orange)
                    .lineLimit(1, reservesSpace: true).multilineTextAlignment(.trailing)
            })
            Divider()
            row("Pension") { PensionInput(label: "Pension", amount: $0.pension) }
            row("Pension taken") { inputs in
                Picker("Pension method", selection: inputs.pensionMethod) {
                    Text("Salary sacrifice").tag(PensionMethod.salarySacrifice)
                    Text("Net pay").tag(PensionMethod.netPay)
                    Text("Relief at source").tag(PensionMethod.reliefAtSource)
                }
                .labelsHidden()
                .disabled(inputs.wrappedValue.pension == .percentOfGross(basisPoints: 0))
            }
            row("Employer pension") { PensionInput(label: "Employer pension", amount: $0.employerPension) }
            Divider()
            row("Student loan") { inputs in
                Picker("Student loan", selection: inputs.studentLoan) {
                    Text("None").tag(StudentLoanPlan?.none)
                    Text("Plan 1").tag(StudentLoanPlan?.some(.plan1))
                    Text("Plan 2").tag(StudentLoanPlan?.some(.plan2))
                    Text("Plan 4").tag(StudentLoanPlan?.some(.plan4))
                    Text("Plan 5").tag(StudentLoanPlan?.some(.plan5))
                }
                .labelsHidden()
            }
            row("Postgraduate loan") { inputs in Toggle("Postgraduate loan", isOn: inputs.postgraduateLoan).labelsHidden() }
            row("Benefits in kind a year") { PoundsInput(label: "Benefits in kind a year", pence: $0.benefitsInKindAnnual) }
        }
    }

    /// One row: the control built for each side's inputs, all at the same height.
    private func row<Control: View>(_ label: String, @ViewBuilder control: @escaping (Binding<SalaryInputs>) -> Control) -> some View {
        SalaryRow(label: label, cells: sides.map { control(inputs($0)) })
    }
}

enum SalaryBonusUnit { case pounds, percent }

/// The bonus: pounds a year, or a percentage of salary (a £/% choice, as pension has).
struct BonusInput: View {
    @Binding var inputs: SalaryInputs
    @State private var text = ""

    private var isPercent: Bool { inputs.bonusPercentBP != nil }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Bonus unit", selection: Binding(get: { isPercent }, set: { setPercent($0) })) {
                Text("£").tag(false)
                Text("%").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 84)
            TextField(isPercent ? "0%" : "£0", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .frame(width: SalaryMetrics.fieldWidth)
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
            Text("£").tag(false)
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
        HStack(spacing: 6) {
            unit.pickerStyle(.menu).frame(width: SalaryMetrics.unitWidth, alignment: .trailing)
            amountField.frame(width: SalaryMetrics.fieldWidth)
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
