import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// Property ▸ Checks on the iPad (step 10, Task 16): the period's checks as lines — a tick when all is well, a mark when
/// something needs a look, a dash when it couldn't be checked — and the selected check's findings in a card beside them
/// (above them when there is no room): months without a receipt, receipts without their credit (Match credits), rent credits
/// without a receipt (each opens its details), the deposit against the tenancy's terms, overdue recurring costs. Below, every
/// recurring cost by provider, overdue or expected, each with "Not expected any more" (Edit on Property) and an Undo toast.
struct PadChecksView: View {
    @ObservedObject var model: PadChecksModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    /// Opens the Evidence screen (Missing evidence).
    let showEvidence: () -> Void
    @State private var detail: TransactionSearch.Row?
    @Environment(\.phoneTheme) private var theme
    @Environment(\.quickEdit) private var quickEdit

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let sideCard = geometry.size.width >= 860 && model.selected != nil
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: MangoSpacing.section) {
                            PadWriteNotices(write: write)
                            if model.snapshot.property == nil, model.property.property == nil {
                                EmptyState(symbol: "checkmark.seal", title: "No property",
                                           message: "The property's checks appear here once the Mac has shared it.")
                                    .frame(maxWidth: .infinity).padding(.top, 60)
                            } else {
                                controls
                                PadRefusalBanner(message: write.message(for: PadChecksModel.screenRow))
                                if let info = model.info { InlineBanner(tone: .neutral, text: info) }
                                checksCard
                                if !sideCard, let check = model.selected { findings(check) }
                                recurringSection
                            }
                        }
                        .padPageContent()
                    }
                    .frame(maxWidth: .infinity)
                    if sideCard, let check = model.selected {
                        Divider()
                        ScrollView { findings(check).padSidePanelContent() }
                            .frame(width: 380)
                    }
                }
            }
            .background(theme.background)
            .safeAreaInset(edge: .bottom) {
                if let toast = model.toast {
                    UndoToastView(message: toast.message, canUndo: toast.canUndo && write.canEdit) { Task { await model.undo() } }
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.toast)
            .task(id: model.toast?.id) {
                guard let id = model.toast?.id else { return }
                try? await Task.sleep(for: .seconds(QuickEditModel.toastSeconds))
                model.expireToast(id)
            }
            .offlineBannerSlot()
            .padPage("Checks")
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await write.refresh()
            await model.property.reload()
            await model.reload()
        }
        .sheet(item: $detail) { row in
            TransactionDetailSheet(row: row).environment(\.quickEdit, quickEdit)
        }
    }

    // MARK: Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                periodMenu
                Spacer(minLength: 8)
                screenButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                periodMenu
                HStack(spacing: 12) { screenButtons }
            }
        }
    }

    private var periodMenu: some View {
        Menu {
            ForEach(model.snapshot.years, id: \.self) { year in
                Button { Task { await model.choose(.calendarYear(year)) } } label: {
                    if model.periodChoice == .calendarYear(year) { Label(String(year), systemImage: "checkmark") } else { Text(String(year)) }
                }
            }
            Divider()
            ForEach(model.snapshot.years, id: \.self) { year in
                Button { Task { await model.choose(.taxYear(year)) } } label: {
                    let title = "Tax year \(UKTaxYear(startYear: year).label)"
                    if model.periodChoice == .taxYear(year) { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(model.periodTitle), up to today".figuresUnbroken).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").mangoFont(.footnote)
            }
            .mangoFont(.headline)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Period")
        .accessibilityValue(model.periodTitle)
    }

    @ViewBuilder
    private var screenButtons: some View {
        ForEach(model.screenActions(), id: \.self) { action in
            switch action {
            case .missingEvidence:
                Button(action: showEvidence) { Label("Missing evidence", systemImage: "exclamationmark.magnifyingglass") }
                    .buttonStyle(.pad(.secondary))
            case .addEvidenceRules:
                Button { Task { await model.addEvidenceRules() } } label: { Text("Add evidence rules") }
                    .buttonStyle(.pad(.secondary))
                    .accessibilityHint("Asks for one PDF per rent receipt and one contract per tenancy in Missing evidence")
            default:
                EmptyView()
            }
        }
    }

    // MARK: Checks

    private var checksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.headline).mangoFont(.title3, weight: .semibold).lineLimit(1).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                }
                .padding(.bottom, 6)
                ForEach(model.lines) { line in
                    checkLine(line)
                    if line.id != model.lines.last?.id { MangoDivider() }
                }
            }
        }
    }

    private func checkLine(_ line: PadChecksModel.Line) -> some View {
        let isSelected = model.selected == line.check
        return Button { model.select(line.check) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol(line.state)).foregroundStyle(color(line.state)).mangoFont(.title3).accessibilityHidden(true)
                Text(line.text.figuresUnbroken).foregroundStyle(line.state == .notChecked ? Color.secondary : Color.primary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").mangoFont(.footnote, weight: .semibold).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .mangoRowSelection(isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(line.state == .ok ? "All well" : line.state == .issue ? "Needs a look" : "Not checked")
        .accessibilityHint("Shows the details")
    }

    private func symbol(_ state: PadChecksModel.LineState) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .issue: "exclamationmark.circle.fill"
        case .notChecked: "minus.circle"
        }
    }

    private func color(_ state: PadChecksModel.LineState) -> Color {
        switch state {
        case .ok: theme.income
        case .issue: theme.pending
        case .notChecked: .secondary
        }
    }

    // MARK: Findings

    private func findings(_ check: PadChecksModel.Check) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(PadChecksModel.cardTitle(check)).mangoFont(.headline).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: model.closeCard) { Image(systemName: "xmark.circle.fill").mangoFont(.title2).foregroundStyle(.secondary) }
                        .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44).accessibilityLabel("Close")
                }
                Text(PadChecksModel.cardSubtitle(check)).mangoFont(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                findingsContent(check)
            }
        }
    }

    @ViewBuilder
    private func findingsContent(_ check: PadChecksModel.Check) -> some View {
        let report = model.snapshot.report ?? PropertyCheckReport()
        switch check {
        case .months:
            if report.monthsWithoutReceipt.isEmpty { allWell("Every month the tenancy ran has a receipt.") }
            ForEach(Array(report.monthsWithoutReceipt.enumerated()), id: \.offset) { _, item in
                let line = model.monthLine(item)
                fact(line.month, Text(line.tenancy).foregroundStyle(.secondary))
            }
        case .receipts:
            if report.receiptsWithoutCredit.isEmpty { allWell("Every receipt has its credit.") }
            ForEach(report.receiptsWithoutCredit, id: \.id) { receipt in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No. \(receipt.receiptNumber)".figuresUnbroken).mangoFont(.subheadline, weight: .semibold).lineLimit(1)
                        Text("\(PhoneDateFormat.day(receipt.periodStart)) – \(PhoneDateFormat.day(receipt.periodEnd))".figuresUnbroken)
                            .mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    MoneyText(minorUnits: receipt.amountReceivedMinorUnits, currency: model.currency, role: .neutral, font: .subheadline)
                }
            }
            if !report.receiptsWithoutCredit.isEmpty, model.offersMatchCredits {
                Button { Task { await model.matchCredits() } } label: { Text("Match credits") }
                    .buttonStyle(.pad(.secondary))
                    .accessibilityHint("Links rent credits on the current account to the receipts they paid")
            }
        case .credits:
            if report.creditsWithoutReceipt.isEmpty { allWell("Every rent credit has its receipt.") }
            ForEach(report.creditsWithoutReceipt, id: \.id) { credit in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.creditTitle(credit)).mangoFont(.subheadline, weight: .semibold).lineLimit(1).truncationMode(.middle)
                        Text(PhoneDateFormat.day(credit.date).unbroken).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    MoneyText(minorUnits: credit.amountMinorUnits, currency: model.currency, role: .neutral, font: .subheadline)
                    RowIconButton(.view, item: model.creditTitle(credit), size: .small) {
                        Task { if let id = credit.id { detail = await model.creditRow(transactionId: id) } }
                    }
                }
            }
        case .deposit:
            if let deposit = report.deposit {
                HStack(spacing: 8) {
                    PadStatusPill(text: PadChecksModel.depositPill(deposit, currency: model.currency), tone: deposit.matches ? .positive : .warning)
                    Text("Held on \(PhoneDateFormat.day(deposit.date))".figuresUnbroken).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(PadChecksModel.depositLines(deposit)) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.title).mangoFont(.subheadline).lineLimit(1)
                        if line.matches { Image(systemName: "checkmark").foregroundStyle(theme.income).accessibilityLabel("Matches") }
                        Spacer(minLength: 8)
                        MoneyText(minorUnits: line.amountMinorUnits, currency: model.currency, role: .neutral,
                                  font: line.id == "difference" ? .subheadline.weight(.semibold) : .subheadline)
                    }
                }
            } else {
                Text("Link a deposit account in Profile (and set the tenancy's deposit months) to check it.")
                    .mangoFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .recurring:
            if model.overdueCosts.isEmpty { allWell("No recurring cost is overdue.") }
            ForEach(model.overdueCosts) { cost in costRow(cost, compact: true) }
        }
    }

    private func allWell(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill").mangoFont(.subheadline).foregroundStyle(theme.income)
    }

    private func fact<Value: View>(_ label: String, _ value: Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.figuresUnbroken).lineLimit(1)
            Spacer(minLength: 12)
            value.lineLimit(1).truncationMode(.middle)
        }
        .mangoFont(.subheadline)
    }

    // MARK: Recurring costs

    @ViewBuilder
    private var recurringSection: some View {
        let costs = model.recurringCosts
        VStack(alignment: .leading, spacing: 4) {
            Text("Recurring costs").mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            Text("By provider: overdue, or when the next one is expected").mangoFont(.footnote).foregroundStyle(.secondary)
        }
        if costs.isEmpty {
            Text("No cost repeats in the property's history yet.").mangoFont(.callout).foregroundStyle(.secondary)
        }
        PadGrid(minimumColumnWidth: 360, balanced: false) {
            ForEach(costs) { cost in
                VStack(alignment: .leading, spacing: 8) {
                    costRow(cost, compact: false)
                }
                .padCardSurface()
            }
        }
    }

    /// A recurring cost: its provider, how often, its last amount, overdue or expected, and "Not expected any more".
    @ViewBuilder
    private func costRow(_ cost: PadChecksModel.RecurringCost, compact: Bool) -> some View {
        let pattern = cost.pattern
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pattern.title).mangoFont(compact ? .subheadline : .headline, weight: compact ? .semibold : nil).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    PadStatusPill(text: cost.isOverdue ? "Overdue" : "Expected", tone: cost.isOverdue ? .warning : .neutral)
                    Text(every(pattern.everyMonths)).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                MoneyText(minorUnits: pattern.lastAmountMinorUnits, currency: pattern.currency, role: .neutral,
                          font: compact ? .subheadline : .headline)
                Text("around \(PhoneDateFormat.day(cost.overdueSince ?? pattern.nextDate))".figuresUnbroken)
                    .mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(model.actions(for: cost), id: \.self) { action in
                if let icon = action.rowAction {
                    RowIconButton(icon, item: pattern.title, size: compact ? .small : .regular) {
                        Task { await model.stopExpecting(cost) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pattern.title), \(cost.status)")
        PadRefusalBanner(message: write.message(for: cost.rowId))
    }

    private func every(_ months: Int) -> String {
        switch months {
        case 1: "Monthly"
        case 3: "Every 3 months"
        case 6: "Every 6 months"
        case 12: "Yearly"
        default: "Every \(months) months"
        }
    }
}
