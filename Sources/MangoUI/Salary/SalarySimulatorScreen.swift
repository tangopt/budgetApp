import SwiftUI
import BudgetCore

/// The salary calculator on iPhone and iPad (design review §3.4, §5 step 6): two salaries, what each leaves you and the
/// difference. On the iPhone two tabs, Inputs and Results, with a pinned "New keeps +£X a year · See results" strip on
/// Inputs; on the iPad (wide) the inputs and the results sit side by side. Current and New are two columns everywhere,
/// aligned row by row; at larger text sizes each row stacks (label, Current over New) so a figure never wraps or shrinks.
/// Everything it shows is `SalaryComparisonViewModel`'s; nothing here changes the household's data.
///
/// The host supplies the navigation container (the iPad's detail, the iPhone's Me sheet).
public struct SalarySimulatorScreen: View {
    @Bindable var viewModel: SalaryComparisonViewModel
    @State private var tab: SalaryPresentation.Tab = .inputs
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Side: String, CaseIterable, Identifiable {
        case current = "Current", offer = "New"
        var id: String { rawValue }
    }

    public init(viewModel: SalaryComparisonViewModel) {
        self.viewModel = viewModel
    }

    /// For the snapshot routes: starts on `tab` at compact width.
    init(viewModel: SalaryComparisonViewModel, startingOn tab: SalaryPresentation.Tab) {
        self.viewModel = viewModel
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        GeometryReader { proxy in
            Group {
                if SalaryPresentation.showsSideBySide(width: proxy.size.width) {
                    sideBySide(width: proxy.size.width)
                } else {
                    tabbed
                }
            }
        }
        .background(theme.background)
        .task { await viewModel.refreshPrefill() }
        .phonePageTitle("Salary calculator", keepsNavigationBar: true)
    }

    // MARK: Layouts

    /// The iPhone: Inputs / Results under a segmented control; the strip is pinned under Inputs.
    private var tabbed: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(SalaryPresentation.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .padding(.horizontal, MangoSpacing.phoneGutter)
            .padding(.vertical, MangoSpacing.xs)
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.s) {
                    switch tab {
                    case .inputs: inputsContent
                    case .results: resultsContent
                    }
                }
                .mangoFont(.body)
                .padding(.horizontal, MangoSpacing.phoneGutter)
                .padding(.bottom, MangoSpacing.m)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tab == .inputs { strip }
        }
    }

    /// The iPad: inputs on the left, results on the right, each scrolling by itself.
    private func sideBySide(width: CGFloat) -> some View {
        let left = max(380, width * 0.46)
        return HStack(alignment: .top, spacing: MangoSpacing.m) {
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.s) { inputsContent }
                    .mangoFont(.body)
                    .padding(.bottom, MangoSpacing.m)
            }
            .frame(width: left)
            .scrollDismissesKeyboard(.interactively)
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.s) { resultsContent }
                    .mangoFont(.body)
                    .padding(.bottom, MangoSpacing.m)
            }
        }
        .padding(.horizontal, MangoSpacing.m)
    }

    // MARK: Inputs

    @ViewBuilder
    private var inputsContent: some View {
        settingsCard
        if viewModel.canUsePrefill { prefillCard }
        SalaryFormCard(current: $viewModel.current, offer: $viewModel.offer)
        Button(viewModel.resetTitle) { viewModel.reset() }
            .buttonStyle(.pad(.secondary))
    }

    /// Pinned under Inputs: what the new salary keeps, and the way to the results.
    private var strip: some View {
        let text = SalaryPresentation.stripText(annualDifference: viewModel.comparison.annualDifference)
        return Button { tab = .results } label: {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: MangoSpacing.s))
            layout {
                Text(text.figuresUnbroken).mangoFont(.subheadline, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: MangoSpacing.xs) }
                Text("See results \u{203A}").mangoFont(.subheadline, weight: .semibold).foregroundStyle(theme.accent)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, MangoSpacing.phoneGutter)
            .padding(.vertical, MangoSpacing.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(theme.surface)
            .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint("Shows the results")
    }

    /// "Use my latest payslip/P60", with what it can't fill in.
    private var prefillCard: some View {
        Card {
            Button("Use my latest payslip/P60") { viewModel.usePrefill() }.frame(minHeight: 44)
            Text(SalaryComparisonViewModel.prefillNote).mangoFont(.caption).foregroundStyle(.secondary)
        }
    }

    /// Tax year and region: one setting for both salaries.
    private var settingsCard: some View {
        Card(title: "Tax year and region") {
            LabeledSetting(label: "Tax year") {
                Picker("Tax year", selection: Binding(get: { viewModel.current.taxYearStart },
                                                      set: { viewModel.current.taxYearStart = $0; viewModel.offer.taxYearStart = $0 })) {
                    ForEach(SalaryRules.all.map(\.startYear).sorted(), id: \.self) { year in
                        Text(UKTaxYear(startYear: year).label).tag(year)
                    }
                }
                .labelsHidden()
            }
            LabeledSetting(label: "Region") {
                Picker("Region", selection: Binding(get: { viewModel.current.region },
                                                    set: { viewModel.current.region = $0; viewModel.offer.region = $0 })) {
                    Text("England, Wales, NI").tag(SalaryRegion.englandWalesNI)
                    Text("Scotland").tag(SalaryRegion.scotland)
                }
                .labelsHidden()
            }
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsContent: some View {
        SalaryHeadlineCard(comparison: viewModel.comparison, ready: viewModel.ready)
        SalaryTakeHomeCard(comparison: viewModel.comparison, ready: viewModel.ready)
        SalaryDeductionsCard(comparison: viewModel.comparison, ready: viewModel.ready)
        SalaryFlowCard(comparison: viewModel.comparison, ready: viewModel.ready)
        Text("An estimate from published UK rates, not tax advice.")
            .mangoFont(.caption).foregroundStyle(.secondary)
    }

    static func pence(_ basisPoints: Int) -> String {
        String(format: "%.0fp", Double(basisPoints) / 100)
    }
}

/// A label with one control beside it (the settings card), at least 44 pt tall; stacked at larger sizes.
private struct LabeledSetting<Control: View>: View {
    let label: String
    let control: Control
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        let layout = SalaryPresentation.stacksRows(at: dynamicTypeSize)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: MangoSpacing.s))
        layout {
            Text(label).mangoFont(.subheadline)
            if !SalaryPresentation.stacksRows(at: dynamicTypeSize) { Spacer(minLength: 0) }
            control
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

// MARK: - Rows

/// One row of the salary screen: a label, then one cell per salary, at one height so Current and New line up. At larger
/// text sizes (`SalaryPresentation.stacksRows`) the label sits on its own line with the cells under it, each named.
struct SalaryRow<Cell: View>: View {
    let label: String
    let cells: [Cell]
    var minimumHeight: CGFloat = 32
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        if SalaryPresentation.stacksRows(at: dynamicTypeSize), cells.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                if !label.isEmpty { Text(label).mangoFont(.subheadline).fixedSize(horizontal: false, vertical: true) }
                ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                    HStack(alignment: .center, spacing: MangoSpacing.s) {
                        Text(SalarySimulatorScreen.Side.allCases[min(index, 1)].rawValue)
                            .mangoFont(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                        cell
                    }
                    .frame(minHeight: 32)
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack(alignment: .center, spacing: MangoSpacing.s) {
                Text(label).mangoFont(.subheadline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(width: SalaryMetrics.labelWidth, alignment: .leading)
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    cell.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(minHeight: minimumHeight)
        }
    }
}

enum SalaryMetrics {
    static var labelWidth: CGFloat { 88 }
}

/// A header over the cells: "Current" and "New" (not at larger sizes, where each cell names itself).
struct SalarySideHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !SalaryPresentation.stacksRows(at: dynamicTypeSize) {
            HStack(spacing: MangoSpacing.s) {
                Color.clear.frame(width: SalaryMetrics.labelWidth, height: 1)
                ForEach(SalarySimulatorScreen.Side.allCases) { side in
                    Text(side.rawValue).mangoFont(.subheadline, weight: .semibold).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Results

private extension SalaryComparison {
    func result(_ side: SalarySimulatorScreen.Side) -> SalaryResult { side == .current ? current : offer }
}

private func isReady(_ ready: (current: Bool, offer: Bool), _ side: SalarySimulatorScreen.Side) -> Bool {
    side == .current ? ready.current : ready.offer
}

/// The headline: what the new salary keeps against the current, a year and a normal month.
struct SalaryHeadlineCard: View {
    let comparison: SalaryComparison
    let ready: (current: Bool, offer: Bool)

    var body: some View {
        Card {
            Text("New against current").mangoFont(.headline).accessibilityAddTraits(.isHeader)
            Text(SalaryPresentation.stripText(annualDifference: comparison.annualDifference).figuresUnbroken)
                .mangoFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            MoneyText(minorUnits: comparison.annualDifference, currency: .gbp, role: .income, fit: .shrink(), font: .figureXL)
            AmountRow(label: "A normal month",
                      amount: MoneyText(minorUnits: comparison.monthlyDifference, currency: .gbp, role: .income))
            FigureRow(label: "Of each extra £1 gross you keep") {
                Text(SalarySimulatorScreen.pence(comparison.keepPerExtraPound)).figureText().mangoFont(.body)
            }
        }
    }
}

/// What each salary leaves: a year, a normal month and the bonus month, Current beside New.
struct SalaryTakeHomeCard: View {
    let comparison: SalaryComparison
    let ready: (current: Bool, offer: Bool)

    var body: some View {
        Card(title: "Take-home") {
            SalarySideHeader()
            row("A year") { $0.takeHomeAnnual }
            row("A normal month") { $0.takeHomeMonthly }
            bonusMonth
        }
    }

    private func row(_ label: String, _ value: @escaping (SalaryResult) -> Int) -> some View {
        SalaryRow(label: label, cells: SalarySimulatorScreen.Side.allCases.map { side in
            Group {
                if isReady(ready, side) { MoneyText(minorUnits: value(comparison.result(side)), currency: .gbp, role: .neutral) }
                else { Text("\u{2014}").foregroundStyle(.secondary).accessibilityLabel("none") }
            }
        })
    }

    /// The bonus month's take-home; a dash for a salary whose bonus is spread monthly (or has none).
    private var bonusMonth: some View {
        let readySides = SalarySimulatorScreen.Side.allCases.filter { isReady(ready, $0) }.map { comparison.result($0) }
        return SalaryRow(label: SalaryComparison.bonusMonthLabel(readySides), cells: SalarySimulatorScreen.Side.allCases.map { side in
            Group {
                if isReady(ready, side), let slip = comparison.result(side).bonusMonth {
                    MoneyText(minorUnits: slip.takeHome, currency: .gbp, role: .neutral)
                } else { Text("\u{2014}").foregroundStyle(.secondary).accessibilityLabel("none") }
            }
        })
    }
}

/// What comes off: tax, NI, loans, pension, then the allowance and the rates, with each salary's notes in words below.
struct SalaryDeductionsCard: View {
    let comparison: SalaryComparison
    let ready: (current: Bool, offer: Bool)

    var body: some View {
        Card(title: "Deductions") {
            SalarySideHeader()
            optional("Income tax", .expense) { $0.incomeTax }
            optional("National Insurance", .expense) { $0.employeeNI }
            optional("Student loan", .expense) { $0.studentLoan }
            optional("Postgraduate loan", .expense) { $0.postgraduateLoan }
            optional("Your pension", .expense) { $0.employeePension }
            optional("Employer pension", .neutral) { $0.employerPension }
            optional("Tax on benefits", .expense) { $0.benefitsInKindTax }
            Divider()
            money("Personal allowance") { $0.personalAllowance }
            SalaryRow(label: "Effective rate", cells: SalarySimulatorScreen.Side.allCases.map { side in
                percent(isReady(ready, side) ? comparison.result(side).effectiveRateBP : nil)
            })
            SalaryRow(label: "Marginal rate", cells: SalarySimulatorScreen.Side.allCases.map { side in
                percent(isReady(ready, side) ? comparison.result(side).marginalRateBP : nil)
            })
            ForEach(SalarySimulatorScreen.Side.allCases) { side in
                ForEach(Self.notes(comparison.result(side), ready: isReady(ready, side)), id: \.self) { line in
                    Text("\(side.rawValue): \(line)").mangoFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A salary's notes in words: the pension caption, the notices, rates not yet confirmed; one line each.
    static func notes(_ result: SalaryResult, ready: Bool) -> [String] {
        if !ready { return ["Enter a salary to see the take-home."] }
        var lines = result.notices.filter { $0 != TaxCode.unreadableNotice }
        if let caption = SalaryResult.marginalPensionCaption(result) { lines.insert(caption, at: 0) }
        if let rules = SalaryRules.forYear(result.effectiveTaxYear), !rules.checkedFields.isEmpty {
            lines.append("Rates for \(rules.ukTaxYear.label) not yet confirmed")
        }
        return lines
    }

    private func money(_ label: String, _ value: @escaping (SalaryResult) -> Int) -> some View {
        SalaryRow(label: label, cells: SalarySimulatorScreen.Side.allCases.map { side in
            Group {
                if isReady(ready, side) { MoneyText(minorUnits: value(comparison.result(side)), currency: .gbp, role: .neutral) }
                else { Text("\u{2014}").foregroundStyle(.secondary).accessibilityLabel("none") }
            }
        })
    }

    private func optional(_ label: String, _ role: MoneyRole, _ value: @escaping (SalaryResult) -> Int) -> some View {
        SalaryRow(label: label, cells: SalarySimulatorScreen.Side.allCases.map { side in
            Group {
                if isReady(ready, side), value(comparison.result(side)) > 0 {
                    MoneyText(minorUnits: value(comparison.result(side)), currency: .gbp, role: role)
                } else { Text("\u{2014}").foregroundStyle(.secondary).accessibilityLabel("none") }
            }
        })
    }

    private func percent(_ basisPoints: Int?) -> some View {
        Group {
            if let basisPoints { Text(String(format: "%.1f%%", Double(basisPoints) / 100)).figureText() }
            else { Text("\u{2014}").foregroundStyle(.secondary) }
        }
        .mangoFont(.subheadline)
    }
}

/// Where a year of gross pay goes: two 100% stacked bars (Current over New), then each slice with both amounts and the
/// difference.
struct SalaryFlowCard: View {
    let comparison: SalaryComparison
    let ready: (current: Bool, offer: Bool)
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var colors: [Color] { [theme.accent, theme.expense, theme.pending, Color.purple, Color.primary] }

    var body: some View {
        let rows = SalaryPresentation.flowRows(comparison)
        Card(title: "Where the money goes") {
            if ready.current && ready.offer {
                bar("Current", rows.map(\.currentShare), rows: rows)
                bar("New", rows.map(\.newShare), rows: rows)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Divider()
                    line(row, color: colors[index % colors.count])
                }
            } else {
                Text("Enter both salaries to compare where the money goes.")
                    .mangoFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bar(_ title: String, _ shares: [Double], rows: [SalaryPresentation.FlowRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).mangoFont(.subheadline, weight: .semibold)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    // The gaps come off the width first, so the segments add up to the bar and never run past it.
                    let shown = shares.filter { $0 > 0 }.count
                    let room = max(0, proxy.size.width - 2 * CGFloat(max(0, shown - 1)))
                    ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                        if share > 0 {
                            Rectangle().fill(colors[index % colors.count]).frame(width: room * CGFloat(share))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): " + zip(rows, shares).map { "\($0.label) \(Int(($1 * 100).rounded())) percent" }.joined(separator: ", "))
    }

    /// A slice: its colour and name, "£a → £b" under it, the difference trailing (stacked at larger sizes).
    private func line(_ row: SalaryPresentation.FlowRow, color: Color) -> some View {
        let layout = SalaryPresentation.stacksRows(at: dynamicTypeSize)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: MangoSpacing.s))
        let money = { (pence: Int) in MoneyPresentation(minorUnits: pence, currency: .gbp, role: .neutral).text }
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).mangoFont(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Text("\(money(row.current)) \u{2192} \(money(row.new))".figuresUnbroken)
                        .mangoFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MoneyText(minorUnits: row.difference, currency: .gbp, role: .neutral)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Form

/// The inputs for both salaries, one row for both: Current beside New, label on the left (stacked at larger sizes).
struct SalaryFormCard: View {
    @Binding var current: SalaryInputs
    @Binding var offer: SalaryInputs
    @Environment(\.phoneTheme) private var theme

    private func inputs(_ side: SalarySimulatorScreen.Side) -> Binding<SalaryInputs> { side == .current ? $current : $offer }

    var body: some View {
        Card(title: "Inputs") {
            SalarySideHeader()
            row("Salary a year") { PoundsInput(label: "Salary a year", pence: $0.grossAnnual) }
            row("Bonus") { BonusInput(inputs: $0) }
            row("Bonus paid") { inputs in
                Picker("Bonus paid", selection: inputs.bonusPayment) {
                    ForEach(BonusPayment.choices, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .disabled(inputs.wrappedValue.bonusPay == 0)
            }
            row("Tax code") { inputs in
                TextField("1257L", text: inputs.taxCode)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .autocorrectionDisabled()
            }
            ForEach(SalarySimulatorScreen.Side.allCases) { side in
                if let notice = TaxCode.parse(inputs(side).wrappedValue.taxCode).notice {
                    Text("\(side.rawValue): \(notice)").mangoFont(.caption).foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            row("Pension") { PensionInput(label: "Pension", amount: $0.pension, gross: $0.grossAnnual.wrappedValue) }
            row("Pension taken") { inputs in
                Picker("Pension method", selection: inputs.pensionMethod) {
                    ForEach(PensionMethod.allCases, id: \.self) { Text(SalaryPresentation.shortPensionMethod($0)).tag($0) }
                }
                .labelsHidden()
                .disabled(inputs.wrappedValue.pension == .percentOfGross(basisPoints: 0))
            }
            row("Employer pension") { PensionInput(label: "Employer pension", amount: $0.employerPension, gross: $0.grossAnnual.wrappedValue) }
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
        SalaryRow(label: label, cells: SalarySimulatorScreen.Side.allCases.map { control(inputs($0)) })
    }
}

/// A £/% segmented toggle over an amount field, with the other unit under it ("= £5,200.00" or "= 12.5%"): the cell of a
/// Bonus or Pension row. The toggle is always there, so Current and New keep the same three lines and stay aligned.
struct UnitAmountCell: View {
    let label: String
    @Binding var isPercent: Bool
    @Binding var text: String
    let otherUnit: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(isPercent ? "0%" : "\u{00A3}0", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .frame(minHeight: 32)
                .accessibilityLabel(label)
            Picker("\(label) unit", selection: $isPercent) {
                Text("\u{00A3}").tag(false)
                Text("%").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 84)
            Text(otherUnit).figureText().mangoFont(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The bonus: pounds a year, or a percentage of salary.
struct BonusInput: View {
    @Binding var inputs: SalaryInputs
    @State private var text = ""

    private var isPercent: Bool { inputs.bonusPercentBP != nil }

    var body: some View {
        UnitAmountCell(label: "Bonus a year", isPercent: Binding(get: { isPercent }, set: { setPercent($0) }), text: $text,
                       otherUnit: SalaryPresentation.bonusOtherUnit(inputs))
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
        TextField("\u{00A3}0", text: $text)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
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
}

/// A pension amount: a percentage of pay or a yearly pounds figure, with the other unit under it.
struct PensionInput: View {
    let label: String
    @Binding var amount: PensionAmount
    /// The salary a percentage is of (pence a year), for the other-unit line.
    let gross: Int
    @State private var text = ""

    private var isPercent: Bool {
        if case .percentOfGross = amount { return true }
        return false
    }

    var body: some View {
        UnitAmountCell(label: label, isPercent: Binding(get: { isPercent }, set: { setPercent($0) }), text: $text,
                       otherUnit: SalaryPresentation.pensionOtherUnit(amount, gross: gross))
            .onChange(of: text) { _, new in
                if !isPercent {
                    let shown = Money.poundsFieldText(typed: new)
                    if shown != new { text = shown; return }
                }
                commit(new)
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
