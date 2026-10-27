// App/Tax/TaxReturnTabs.swift
import SwiftUI
import BudgetCore

/// The Return and Calculation tabs of a tax year (plan phase 4 Task 4, UI polish §4.2),
/// laid out from `SelfAssessment.Result` and `SelfAssessmentFiling`.
///
/// Return (one page, filing included): the status with the year's deadlines; HMRC online step by
/// step, in the order it asks, each with its values — box, description, the value right-aligned
/// (whole pounds as the return takes them; SA110 in pence), a copy icon, an "As filed" tag where
/// the return differs from the computed figure and a chevron to the calculation step behind the
/// box; the payments with their proofs.
/// A return value as a table row: a box of the return or a value of a filing step.
struct TaxBoxRow: Identifiable {
    let id: String
    let box: String?
    let label: String
    let value: SelfAssessment.BoxValue
    /// Shown (and copied) in whole pounds.
    let isWholePounds: Bool
    /// What the copy icon puts on the clipboard (`copyText`).
    let copyText: String
    /// The calculation step behind it ("Why?").
    var step: String?
    /// Set when the value is the return's, not the computed one (the computed value and why).
    var asFiled: SelfAssessment.AsFiled?

    init(_ box: SelfAssessment.Box) {
        id = "\(box.form.rawValue)|\(box.section)|\(box.number)"
        self.box = box.number
        label = box.label
        value = box.value
        isWholePounds = box.isWholePounds
        copyText = box.copyText
        step = box.step
        asFiled = box.asFiled
    }

    init(id: String, value: SelfAssessmentFiling.Value, label: String) {
        self.id = id
        box = value.box
        self.label = label
        self.value = value.value
        isWholePounds = value.isWholePounds
        copyText = value.copyText
        step = value.step
        asFiled = value.asFiled
    }

    /// "box 14, Total rents and other receipts", for the copy icon's VoiceOver label.
    var spokenName: String { [box.map { "box \($0)" }, label].compactMap { $0 }.joined(separator: ", ") }
}

/// The columns of a table of return values, the same on every panel of a tab so the values
/// line up from one panel to the next: the box (fixed), the description (the rest), the value
/// (fixed, right-aligned) and the row's icons — copy, and with `why` a chevron to the step
/// (an empty slot where a row has none, so the copy icons stay in one column).
enum TaxBoxTable {
    static let valueWidth: CGFloat = 170

    static func columns(boxWidth: CGFloat, copy: @escaping (String) -> Void,
                        why: ((String) -> Void)? = nil) -> [DataTableColumn<TaxBoxRow>] {
        [
            DataTableColumn("Box", alignment: .trailing, width: .fixed(boxWidth), accessibilityValue: { $0.box }) { row, _ in
                if let box = row.box {
                    Text(box).monospacedDigit().foregroundStyle(.secondary).figureText(.shrink())
                }
            },
            DataTableColumn("Description", width: .fill(min: 180), accessibilityValue: { $0.label }) { row, _ in
                Text(row.label).lineLimit(1).truncationMode(.tail).help(row.label)
            },
            DataTableColumn("Value", alignment: .trailing, width: .fixed(valueWidth),
                            accessibilityValue: { row in
                                TaxBoxValueText.spoken(row.value, wholePounds: row.isWholePounds)
                                    + (row.asFiled.map { ", as filed; " + AsFiledTag.spoken($0, wholePounds: row.isWholePounds) } ?? "")
                            }) { row, _ in
                HStack(spacing: 6) {
                    if let asFiled = row.asFiled { AsFiledTag(asFiled: asFiled, wholePounds: row.isWholePounds, box: row.box) }
                    TaxBoxValueText(value: row.value, wholePounds: row.isWholePounds)
                }
            },
            DataTableColumn("", alignment: .trailing, width: .fixed(why == nil ? 34 : 58)) { row, _ in
                HStack(spacing: 8) {
                    CopyValueButton(text: row.copyText, name: row.spokenName, copy: copy)
                    if let why {
                        if let step = row.step {
                            Button { why(step) } label: {
                                Image(systemName: "chevron.right").font(.callout.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Why: how \(row.box.map { "box \($0)" } ?? "it") is worked out (Calculation)")
                            .accessibilityLabel("Show how \(row.spokenName) is worked out")
                        } else {
                            Image(systemName: "chevron.right").font(.callout.weight(.semibold)).hidden().accessibilityHidden(true)
                        }
                    }
                }
            }
        ]
    }
}

/// "As filed" beside a figure the return gave another value than the app works out: a small
/// tag with an info icon whose tooltip and popover (click, or VoiceOver) give the computed
/// value and the stored reason.
struct AsFiledTag: View {
    let asFiled: SelfAssessment.AsFiled
    var wholePounds = false
    /// The box number, for the text ("SA106 box 14").
    var box: String? = nil
    /// Where the computed figure comes from, for the text (default: the box).
    var computedLabel: String? = nil
    @State private var showing = false

    static func spoken(_ asFiled: SelfAssessment.AsFiled, wholePounds: Bool, computedLabel: String? = nil) -> String {
        var amount = Money.format(asFiled.computed, currency: .gbp)
        if wholePounds, amount.hasSuffix(".00") { amount = String(amount.dropLast(3)) }
        return "Correct value \(amount)" + (computedLabel.map { " (\($0))" } ?? "") + ". \(asFiled.note)"
    }

    private var text: String { Self.spoken(asFiled, wholePounds: wholePounds, computedLabel: computedLabel ?? box.map { "box \($0)" }) }

    var body: some View {
        HStack(spacing: 3) {
            Text("As filed").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Button { showing.toggle() } label: {
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Text(text).font(.callout).frame(maxWidth: 320).padding(12).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityLabel("As filed: \(text)")
        }
        .fixedSize()
        .help(text)
    }
}

/// A box's value: an amount (whole pounds where the return takes them), a text, or an X.
struct TaxBoxValueText: View {
    let value: SelfAssessment.BoxValue
    var wholePounds = false

    var body: some View {
        switch value {
        case let .amount(pence): MoneyText(minorUnits: pence, currency: .gbp, role: .neutral, wholeUnits: wholePounds)
        case let .text(text): Text(text).monospacedDigit().truncationMode(.middle).figureText(.shrink()).help(text)
        case .cross: Text("X").font(.body.weight(.semibold))
        }
    }

    static func spoken(_ value: SelfAssessment.BoxValue, wholePounds: Bool) -> String {
        switch value {
        case let .amount(pence): return MoneyText.format(pence, currency: .gbp, wholeUnits: wholePounds)
        case let .text(text): return text
        case .cross: return "X"
        }
    }
}

/// The computation's warnings, as one banner; then what was saved anyway after the year was
/// filed (plan Task 14), as another.
struct TaxSelfAssessmentWarnings: View {
    let result: SelfAssessment.Result
    var changedAfterFiling: [String] = []

    var body: some View {
        if !changedAfterFiling.isEmpty {
            InlineBanner(.warning) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The figures differ from the filed return:").fontWeight(.medium)
                    ForEach(changedAfterFiling, id: \.self) { Text($0.figuresUnbroken) }
                }
            }
        }
        if !result.warnings.isEmpty {
            InlineBanner(.warning) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.warnings, id: \.self) { Text($0.figuresUnbroken) }
                }
            }
        }
    }
}

/// Why there's no return to show (no UK rules for the year, or the computation failed).
struct TaxSelfAssessmentUnavailable: View {
    let page: TaxOverview.YearPage

    var body: some View {
        Panel {
            EmptyState(systemImage: "doc.text.magnifyingglass", title: "No return to show",
                       message: page.selfAssessmentError ?? "No return to show yet.")
                .inPanel()
        }
    }
}

// MARK: - Calculation

/// The SA110 calculation (UI polish §4.2): the headline figures; how the liability builds up
/// as a waterfall (tax by band, less the finance cost relief, foreign tax credit and the tax
/// already paid, to the balancing payment); then every step, numbered, its explanation beneath
/// and its amount aligned on the right. A Return box's chevron highlights its step.
struct TaxCalculationTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage

    var body: some View {
        if let result = page.selfAssessment {
            let waterfall = TaxReturnFormat.waterfall(result)
            VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                TaxSelfAssessmentWarnings(result: result, changedAfterFiling: page.row.changedAfterFiling)
                Panel("Summary", subtitle: "\(page.row.year.label), in GBP") {
                    FigureStrip(TaxReturnFormat.headline(result, status: page.row.status, payments: page.income.payments))
                }
                Panel("How the tax builds up",
                      subtitle: "Income Tax by band, less the reliefs and the tax already paid, to what's left to pay or come back") {
                    if waterfall.isEmpty {
                        Text("No Income Tax for \(page.row.year.label).").font(.callout).foregroundStyle(.secondary)
                    } else {
                        WaterfallChart(steps: waterfall, currency: .gbp, risesAreCosts: true,
                                       riseLabel: "Tax", fallLabel: "Reliefs and tax paid", totalLabel: "Totals", height: 230,
                                       accessibilityTitle: "How the tax builds up")
                    }
                }
                Panel("Step by step", subtitle: "How HMRC works it out; a Return box's chevron highlights its step") {
                    TaxStepsList(steps: result.steps, focused: viewModel.focusedStep?.title)
                }
                TaxComparisonPanel(comparison: page.comparison, previousLabel: UKTaxYear(startYear: page.row.year.startYear - 1).label)
            }
        } else {
            TaxSelfAssessmentUnavailable(page: page)
        }
    }
}

/// The calculation's steps as table rows: the number, the title over its explanation (wrapping,
/// in the secondary colour), the amount right-aligned in a column of its own that never
/// clips; the focused step (a Return box's "Why?") tinted with an accent bar. Each row carries
/// the step's title as its id, for the page's scroll.
struct TaxStepsList: View {
    let steps: [SelfAssessment.Step]
    let focused: String?
    @Environment(\.theme) private var theme

    private static let amountWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("#").frame(width: 28, alignment: .trailing)
                Text("Step").padding(.leading, 12)
                Spacer(minLength: 8)
                Text("Amount").frame(width: Self.amountWidth, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(theme.gridHeaderBackground)
            .overlay(alignment: .bottom) { Rectangle().frame(height: 1).foregroundStyle(.separator) }
            .accessibilityHidden(true)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                row(index: index, step: step)
            }
        }
    }

    private func row(index: Int, step: SelfAssessment.Step) -> some View {
        let isFocused = focused == step.title
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(index + 1)")
                .monospacedDigit().foregroundStyle(.secondary)
                .figureText()
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                // Sentences that wrap; the figures in them stay whole.
                Text(step.title.figuresUnbroken).font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.detail.figuresUnbroken).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let amount = step.amount {
                    MoneyText(minorUnits: amount, currency: .gbp, role: .neutral)
                } else {
                    Text(verbatim: "")
                }
            }
            .frame(minWidth: Self.amountWidth, alignment: .trailing)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(minHeight: 28)
        .background(isFocused ? theme.accent.opacity(0.15) : theme.rowBackground(index % 2 == 1))
        .overlay(alignment: .leading) {
            if isFocused { Rectangle().fill(theme.accent).frame(width: 3) }
        }
        .overlay(alignment: .bottom) { Rectangle().frame(height: 1).foregroundStyle(.separator) }
        .id(step.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}

// MARK: - Return

/// The Return page (UI polish §4.2; the former Return and Filing tabs in one): the computation's
/// warnings; the status with the year's deadlines (day, amount, a pill saying done or how long is
/// left) and the actions; HMRC online step by step, numbered, each with its deadline, how to fill
/// it and the values to enter (one copy icon per row; the property's values grouped by section;
/// an "As filed" tag and a chevron to the calculation step where there is one); the payments with
/// their proofs.
struct TaxReturnTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    @State private var recording: Identified<HMRCPayment>?
    @State private var editing: Identified<HMRCPayment>?
    @State private var deleting: HMRCPayment?

    private var canMarkFiled: Bool { page.row.status == .preparing || page.row.status == .ready }

    /// Filed, and the balancing payment shows as paid: the year can be marked paid.
    private func canMarkPaid(_ result: SelfAssessment.Result) -> Bool {
        TaxPaymentCoverage.suggestsMarkingPaid(status: page.row.status, balancingDue: result.calculation.balancingPayment,
                                               payments: page.income.payments, startYear: result.taxYear.startYear)
    }

    var body: some View {
        if let result = page.selfAssessment {
            VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                TaxSelfAssessmentWarnings(result: result, changedAfterFiling: page.row.changedAfterFiling)
                Panel("Status", subtitle: TaxReturnFormat.statusNote(page.row.status)) {
                    HStack(spacing: 8) {
                        // The one prominent action: Mark as filed until the return is filed,
                        // then Record payment…, then Mark as paid once the balancing payment is.
                        let markPaid = canMarkPaid(result)
                        Button("Record payment…") { record(result) }
                            .modifier(ProminentIf(isOn: !canMarkFiled && !markPaid))
                        if canMarkFiled {
                            Button("Mark as filed") { viewModel.setStatus(.filed) }
                                .buttonStyle(.borderedProminent).prominentTint()
                                .help("Once the return is submitted online")
                        }
                        if markPaid {
                            Button("Mark as paid") { viewModel.setStatus(.paid) }
                                .buttonStyle(.borderedProminent).prominentTint()
                                .help("The balancing payment is recorded: mark \(page.row.year.label) as paid")
                        }
                    }
                    .controlSize(.small)
                } content: {
                    DataTable(columns: deadlineColumns,
                              rows: TaxReturnFormat.deadlines(result, status: page.row.status, payments: page.income.payments, now: AppClock.now),
                              zebra: false)
                }
                Panel("File online with HMRC",
                      subtitle: "Each step as HMRC online asks for it, with the values to enter: return boxes in whole pounds, SA110 and HMRC's figures in pence") {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("The copy icon puts a value on the clipboard as HMRC online takes it; the chevron shows how it's worked out (Calculation). A value tagged As filed is the filed return's, not the computed one.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 12)
                        let sections = result.boxGroups.filter { $0.form == .sa106 }.map(\.section)
                        ForEach(page.filing) { step in
                            TaxFilingStepView(step: step, isLast: step.id == page.filing.last?.id, sections: sections, copy: viewModel.copy, why: { viewModel.showStep($0) })
                        }
                    }
                }
                Panel("HMRC payments",
                      subtitle: "For \(page.row.year.label) and towards \(UKTaxYear(startYear: page.row.year.startYear + 1).label), with their proofs") {
                    if page.income.payments.isEmpty {
                        Text("No payments yet: record each one with its proof.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        HMRCPaymentsTable(payments: page.income.payments, counts: page.income.documentCounts, startYear: page.row.year.startYear,
                                          edit: { editing = Identified($0) }, delete: { deleting = $0 })
                    }
                }
            }
            .sheet(item: $recording) { item in
                HMRCPaymentSheet(viewModel: viewModel, payment: item.value, yearStatus: page.row.status, markPaid: true, origin: .taxReturn)
            }
            .sheet(item: $editing) { item in
                HMRCPaymentSheet(viewModel: viewModel, payment: item.value, yearStatus: page.row.status, origin: .taxReturn)
            }
            .confirmationDialog("Delete this \(deleting?.kind.displayName.lowercased() ?? "payment")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) {
                    if let id = deleting?.id { viewModel.deletePayment(id) }
                    deleting = nil
                }
            } message: {
                Text("Its document links go too; the documents stay in the library. This can't be undone.")
            }
        } else {
            TaxSelfAssessmentUnavailable(page: page)
        }
    }

    /// A new payment for what the calculation says is left: the balancing payment, or the repayment.
    private func record(_ result: SelfAssessment.Result) {
        let c = result.calculation
        recording = Identified(HMRCPayment(personId: page.row.person.id ?? 0, startYear: result.taxYear.startYear,
                                           date: PayCalendar.utcDay(sameDayAs: AppClock.now, in: .current), amountMinorUnits: abs(c.balancingPayment),
                                           kind: c.balancingPayment >= 0 ? .balancingPayment : .refund))
    }

    private var deadlineColumns: [DataTableColumn<TaxReturnFormat.Deadline>] {
        [
            .text("Deadline", width: .fill(min: 200), { $0.title }, detail: { $0.detail }),
            .date("By") { $0.date },
            .money("Amount", role: .neutral, minWidth: 110, currency: { _ in .gbp }) { $0.amount },
            .status("Status") { $0.pill }
        ]
    }
}

/// `.borderedProminent` when `isOn` (the one prominent action of a header).
struct ProminentIf: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn { content.buttonStyle(.borderedProminent).prominentTint() } else { content }
    }
}

/// One step of the filing checklist: a numbered circle on a line joining the steps, the title
/// with its deadline (day and pill), the explanation, and the values to enter as a table.
struct TaxFilingStepView: View {
    let step: SelfAssessmentFiling.Step
    let isLast: Bool
    /// The SA106 sections, whose name prefixes the property's values ("Land and property abroad · …").
    let sections: [String]
    let copy: (String) -> Void
    /// Shows the calculation step behind a value.
    var why: ((String) -> Void)? = nil
    @Environment(\.theme) private var theme

    private static let circle: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(step.id)")
                .font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(theme.accent)
                .frame(width: Self.circle, height: Self.circle)
                .background(Circle().fill(theme.accent.opacity(0.15)))
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .top) {
                    // The line down to the next step's circle.
                    if !isLast {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                            .padding(.top, Self.circle + 4)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(step.title).font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Step \(step.id): \(step.title)")
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if let deadline = step.deadline {
                        Text("By").font(.callout).foregroundStyle(.secondary)
                        DateText(date: deadline, font: .callout)
                    }
                }
                .frame(minHeight: Self.circle - 4)
                Text(step.detail.figuresUnbroken).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.values.isEmpty {
                    DataTable(columns: TaxBoxTable.columns(boxWidth: 84, copy: copy, why: why), sections: valueSections, showsHeader: false)
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
    }

    /// The values in tables by section: the property's values under their section's strip
    /// (the section said once, not before every label), the rest as they come.
    private var valueSections: [DataTableSection<TaxBoxRow>] {
        let names = sections.sorted { $0.count > $1.count }
        var result: [DataTableSection<TaxBoxRow>] = []
        var current: (title: String?, rows: [TaxBoxRow])?
        for (index, value) in step.values.enumerated() {
            let section = names.first { value.label.hasPrefix($0 + " · ") }
            let label = section.map { String(value.label.dropFirst($0.count + 3)) } ?? value.label
            let row = TaxBoxRow(id: "\(step.id)|\(index)", value: value, label: label)
            if let open = current, open.title == section {
                current?.rows.append(row)
            } else {
                if let open = current { result.append(DataTableSection(open.title, rows: open.rows)) }
                current = (section, [row])
            }
        }
        if let open = current { result.append(DataTableSection(open.title, rows: open.rows)) }
        return result
    }
}

// MARK: - Presentation

/// How the Self Assessment tabs present the computation: the forms' names, the headline
/// figures, the liability as waterfall steps, the deadlines with their state.
enum TaxReturnFormat {
    static func title(_ form: SelfAssessment.Form) -> String {
        switch form {
        case .sa100: return "Tax return"
        case .sa102: return "Employment"
        case .sa106: return "Foreign"
        case .sa110: return "Tax calculation summary"
        }
    }

    /// What the status means for filing, under the Status title.
    static func statusNote(_ status: TaxYearStatus) -> String {
        switch status {
        case .preparing: return "Preparing: check the figures in the steps below, then file online."
        case .ready: return "Ready to file: follow the steps below, then mark the return as filed."
        case .filed: return "Filed: record each payment with its proof; a balancing payment can mark the year as paid."
        case .paid: return "Filed and paid."
        }
    }

    /// The Calculation's headline: Income Tax due, tax deducted, the balancing payment (or
    /// repayment) with its state, and the payments on account for the next year.
    static func headline(_ result: SelfAssessment.Result, status: TaxYearStatus, payments: [HMRCPayment]) -> [FigureTile] {
        let c = result.calculation
        let next = UKTaxYear(startYear: result.taxYear.startYear + 1)
        let deadlines = result.taxYear.deadlines
        let balance: FigureTile
        if c.balancingPayment >= 0 {
            balance = FigureTile(title: "Balancing payment", value: .money(c.balancingPayment, .gbp, .neutral),
                                 caption: "By \(DocumentFormat.day(deadlines.onlineReturnAndBalancingPayment))",
                                 pill: c.balancingPayment == 0 ? nil : balancingPill(result, status: status, payments: payments, now: AppClock.now))
        } else {
            balance = FigureTile(title: "Repayment", value: .money(-c.balancingPayment, .gbp, .neutral),
                                 caption: "Overpaid: HMRC repays it to you")
        }
        return [
            FigureTile(title: "Income Tax due", value: .money(c.incomeTaxDue, .gbp, .neutral), caption: "After reliefs"),
            FigureTile(title: "Tax deducted", value: .money(c.taxDeducted, .gbp, .neutral), caption: "PAYE and other tax taken off"),
            balance,
            FigureTile(title: "Payments on account", value: .money(c.nextPaymentOnAccount, .gbp, .neutral),
                       caption: c.nextPaymentOnAccount > 0 ? "Each, for \(next.label): 31 Jan and 31 Jul" : "None for \(next.label)")
        ]
    }

    /// The liability as a waterfall: each band's tax, the bands' total when there are several,
    /// less the finance cost relief and the foreign tax credit, the Income Tax due, less the tax
    /// deducted and the payments on account made, to the balancing payment (or repayment).
    /// Empty when there's no tax at all.
    static func waterfall(_ result: SelfAssessment.Result) -> [WaterfallStep] {
        let c = result.calculation
        let bands = c.bandLines.filter { $0.tax != 0 }
        guard !bands.isEmpty || c.taxDeducted != 0 || c.paymentsOnAccountMade != 0 else { return [] }
        // Short names under the bars ("Higher 40%"); the band in full on hover.
        var steps = bands.map { line in
            WaterfallStep(label: bandShortLabel(line), kind: .change, minorUnits: line.tax,
                          detail: "\(bandLabel(line)) on \(Money.format(line.amount, currency: .gbp))")
        }
        if bands.count > 1 {
            steps.append(WaterfallStep(label: "Tax charged", kind: .total, detail: "The bands added up"))
        }
        if c.financeCostReduction != 0 {
            steps.append(WaterfallStep(label: "Finance cost relief", kind: .change, minorUnits: -c.financeCostReduction,
                                       detail: "Basic-rate relief on \(Money.format(c.financeCostReliefBase, currency: .gbp)) of finance costs"))
        }
        if c.foreignTaxCreditRelief != 0 {
            steps.append(WaterfallStep(label: "Foreign tax credit", kind: .change, minorUnits: -c.foreignTaxCreditRelief,
                                       detail: "Foreign Tax Credit Relief"))
        }
        steps.append(WaterfallStep(label: "Income Tax due", kind: .total, detail: "After the tax reductions"))
        if c.taxDeducted != 0 {
            steps.append(WaterfallStep(label: "Tax deducted", kind: .change, minorUnits: -c.taxDeducted, detail: "PAYE and other tax taken off"))
        }
        if c.paymentsOnAccountMade != 0 {
            steps.append(WaterfallStep(label: "Paid on account", kind: .change, minorUnits: -c.paymentsOnAccountMade,
                                       detail: "Payments on account made for \(result.taxYear.label)"))
        }
        // A repayment is the level below zero, labelled by what comes back ("£998").
        steps.append(WaterfallStep(label: c.balancingPayment >= 0 ? "Balancing payment" : "Repayment", kind: .total,
                                   detail: c.balancingPayment >= 0
                                       ? "By \(DocumentFormat.day(result.taxYear.deadlines.onlineReturnAndBalancingPayment))" : "Due to you",
                                   showsMagnitude: c.balancingPayment < 0))
        return steps
    }

    /// A band's name under its bar: "Basic 20%", "Higher 40%", "Savings 40%", "Dividends 8.75%".
    static func bandShortLabel(_ line: SelfAssessment.BandLine) -> String {
        let rate = PropertyFormat.percent(line.rate)
        switch line.kind {
        case .nonSavings: return "\(line.band.replacingOccurrences(of: " rate", with: "")) \(rate)"
        case .savings: return "Savings \(rate)"
        case .dividends: return "Dividends \(rate)"
        }
    }

    /// "Basic rate 20%", "Savings higher rate 40%", "Dividends basic rate 8.75%".
    static func bandLabel(_ line: SelfAssessment.BandLine) -> String {
        let rate = PropertyFormat.percent(line.rate)
        switch line.kind {
        case .nonSavings: return "\(line.band) \(rate)"
        case .savings: return "Savings \(line.band.lowercased()) \(rate)"
        case .dividends: return "Dividends \(line.band.lowercased()) \(rate)"
        }
    }

    /// A deadline in the Status table.
    struct Deadline: Identifiable {
        let id: String
        let title: String
        var detail: String?
        let date: Date?
        let amount: Int?
        let pill: StatusPill
    }

    /// The return online, the balancing payment (or repayment) and, when there are any, the
    /// next year's two payments on account — each done (filed; paid once the payments of that
    /// kind recorded add up to within £1 of what's due), part paid, or how long is left.
    static func deadlines(_ result: SelfAssessment.Result, status: TaxYearStatus, payments: [HMRCPayment], now: Date) -> [Deadline] {
        let c = result.calculation
        let d = result.taxYear.deadlines
        let next = UKTaxYear(startYear: result.taxYear.startYear + 1)
        let isFiled = status == .filed || status == .paid
        var rows = [
            Deadline(id: "return", title: "Online return", detail: "Submitted at HMRC online", date: d.onlineReturnAndBalancingPayment, amount: nil,
                     pill: deadlinePill(d.onlineReturnAndBalancingPayment, done: isFiled ? "Filed" : nil, now: now))
        ]
        if c.balancingPayment >= 0 {
            rows.append(Deadline(id: "balance", title: "Balancing payment", detail: "What's left of \(result.taxYear.label)'s tax",
                                 date: d.onlineReturnAndBalancingPayment, amount: c.balancingPayment,
                                 pill: c.balancingPayment == 0 ? StatusPill("Nothing to pay", tone: .neutral)
                                    : balancingPill(result, status: status, payments: payments, now: now)))
        } else {
            rows.append(Deadline(id: "balance", title: "Repayment", detail: "Overpaid: HMRC repays it once the return is processed",
                                 date: nil, amount: -c.balancingPayment, pill: StatusPill("To you", tone: .positive)))
        }
        if c.nextPaymentOnAccount > 0 {
            // Each compares what's recorded for it with what's due, as the balancing payment does.
            func pill(_ kind: HMRCPaymentKind, _ deadline: Date) -> StatusPill {
                paymentPill(due: c.nextPaymentOnAccount, paid: recorded(payments, kind: kind, startYear: next.startYear), deadline: deadline, now: now)
            }
            rows.append(Deadline(id: "poa1", title: "1st payment on account", detail: "Towards \(next.label)", date: d.onlineReturnAndBalancingPayment,
                                 amount: c.nextPaymentOnAccount, pill: pill(.firstPaymentOnAccount, d.onlineReturnAndBalancingPayment)))
            rows.append(Deadline(id: "poa2", title: "2nd payment on account", detail: "Towards \(next.label)", date: d.secondPaymentOnAccount,
                                 amount: c.nextPaymentOnAccount, pill: pill(.secondPaymentOnAccount, d.secondPaymentOnAccount)))
        }
        return rows
    }

    /// How close what's recorded may come to what's due and still count as paid: £1 (HMRC's
    /// figures are in pence, payments are often rounded to the pound).
    static let paidTolerance = TaxPaymentCoverage.tolerance

    /// What the payments of `kind` recorded for the year starting `startYear` add up to.
    static func recorded(_ payments: [HMRCPayment], kind: HMRCPaymentKind, startYear: Int) -> Int {
        TaxPaymentCoverage.recorded(payments, kind: kind, startYear: startYear)
    }

    /// A payment's state: paid once something is recorded and it comes within £1 of `due` (a
    /// due under £1 with nothing recorded isn't paid), part paid while it doesn't yet, else how
    /// long is left until `deadline`.
    static func paymentPill(due: Int, paid: Int, deadline: Date, now: Date) -> StatusPill {
        if due > 0 && paid > 0 && paid >= due - paidTolerance {
            return StatusPill("Paid", tone: .positive, systemImage: "checkmark", help: "\(Money.format(paid, currency: .gbp)) recorded as paid")
        }
        if paid > 0 {
            return StatusPill("Part paid", tone: .warning, help: "\(Money.format(paid, currency: .gbp)) of \(Money.format(due, currency: .gbp)) recorded")
        }
        return deadlinePill(deadline, done: nil, now: now)
    }

    /// Whether the balancing payment counts as paid: the year is marked paid, or balancing
    /// payments are recorded for it and add up to within £1 of it.
    static func balancingIsPaid(_ result: SelfAssessment.Result, status: TaxYearStatus, payments: [HMRCPayment]) -> Bool {
        status == .paid || TaxPaymentCoverage.covers(balancingDue: result.calculation.balancingPayment, payments: payments,
                                                      startYear: result.taxYear.startYear)
    }

    /// The balancing payment's state: paid once the year is marked paid or balancing payments
    /// are recorded for it and add up to within £1 of it, part paid while they don't yet, else
    /// how long is left.
    static func balancingPill(_ result: SelfAssessment.Result, status: TaxYearStatus, payments: [HMRCPayment], now: Date) -> StatusPill {
        let paid = recorded(payments, kind: .balancingPayment, startYear: result.taxYear.startYear)
        if status == .paid {
            return StatusPill("Paid", tone: .positive, systemImage: "checkmark",
                              help: paid > 0 ? "\(Money.format(paid, currency: .gbp)) recorded as paid" : nil)
        }
        return paymentPill(due: result.calculation.balancingPayment, paid: paid,
                           deadline: result.taxYear.deadlines.onlineReturnAndBalancingPayment, now: now)
    }

    /// Done (`done`'s word, positive), or how long until `deadline`: overdue, today, in so many
    /// days (under way within a month) or months.
    static func deadlinePill(_ deadline: Date, done: String?, now: Date) -> StatusPill {
        if let done { return StatusPill(done, tone: .positive, systemImage: "checkmark") }
        let today = PayCalendar.utcDay(sameDayAs: now, in: .current)
        let days = MonthRange.calendar.dateComponents([.day], from: today, to: deadline).day ?? 0
        let day = DocumentFormat.day(deadline)
        switch days {
        case ..<0:
            return StatusPill("Overdue", tone: .warning, systemImage: "exclamationmark.triangle.fill", help: "Was due by \(day)")
        case 0:
            return StatusPill("Due today", tone: .warning, help: "Due by \(day)")
        case 1...30:
            return StatusPill("In \(days) day\(days == 1 ? "" : "s")", tone: .accent, help: "Due by \(day)")
        case 31...59:
            return StatusPill("In \(days) days", tone: .neutral, help: "Due by \(day)")
        default:
            return StatusPill("In \(days / 30) months", tone: .neutral, help: "Due by \(day)")
        }
    }
}
