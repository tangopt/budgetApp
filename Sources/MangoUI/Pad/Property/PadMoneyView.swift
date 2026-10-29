import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// Property ▸ Money on the iPad (step 10, Task 15): the period (calendar year, tax year or a custom range) and the view
/// (by month, or the transactions behind a figure), a "Show in GBP" toggle, the headline tiles and the cost categories as
/// chips. A month expands to the transactions behind its cash flow; a transaction opens the shared document panel with its
/// linked document and its figures; the Mac's charts and its full figures table are one "Charts and figures" button away.
/// Linking and unlinking a document need Edit on Documents (hidden otherwise) and a refusal shows under the panel.
struct PadMoneyView: View {
    @ObservedObject var model: PadMoneyModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    /// Selects a library document on the Documents screen.
    let showDocument: (Int64) -> Void
    @State private var request: PadChoiceRequest?
    @State private var showsCustom = false
    @State private var detail: TransactionSearch.Row?
    @Environment(\.phoneTheme) private var theme
    @Environment(\.quickEdit) private var quickEdit

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.section) {
                    PadWriteNotices(write: write)
                    if model.snapshot.property == nil, model.property.property == nil {
                        EmptyState(symbol: "sterlingsign.circle", title: "No property", message: "The property's money appears here once the Mac has shared it.")
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        controls
                        if model.period == nil {
                            InlineBanner(tone: .neutral, text: "Pick a range that ends after it starts.")
                        } else if model.summary != nil {
                            tiles
                            chips
                            switch model.mode {
                            case .months:
                                monthList
                                PadMoneyChartsContent(model: model, onShow: { figure in Task { await model.show(figure) } })
                            case .transactions: transactionList
                            }
                        }
                    }
                }
                .padPageContent()
            }
            .background(theme.background)
            .offlineBannerSlot()
            .padPage("Money")
        }
        .modifier(PadMoneyPanelHost(model: model) { line in
            PadMoneyPanelExtra(model: model, write: write, line: line, run: { run($0) })
        })
        .task(id: SyncReloadTrigger(syncStatus)) {
            await write.refresh()
            await model.property.reload()
            await model.reload()
        }
        .sheet(item: $request) { PadChoiceSheet(request: $0) }
        .padSidePanel(isPresented: model.expandedMonth != nil && model.panel == nil, onClose: { model.closeMonth() }) {
            if let month = model.months.first(where: { $0.start == model.expandedMonth }) {
                PadSidePanel(title: PadMoneyModel.monthTitle(month), onClose: { model.closeMonth() }) { monthDetail(month) }
            }
        }
        .sheet(isPresented: $showsCustom) { PadMoneyCustomRangeSheet(model: model) }
        .sheet(item: $detail) { row in
            TransactionDetailSheet(row: row).environment(\.quickEdit, quickEdit)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { periodMenu; viewPicker.frame(maxWidth: 300); Spacer(minLength: 8); if model.offersGBP { gbpToggle } }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) { periodMenu; Spacer(minLength: 8) }
                    viewPicker
                    if model.offersGBP { gbpToggle }
                }
            }
            if let note = model.rateNote {
                Text(note.figuresUnbroken).mangoFont(.footnote).foregroundStyle(.secondary)
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
            Divider()
            Button("Custom range…") { showsCustom = true }
        } label: {
            HStack(spacing: 6) {
                Text(model.periodTitle.figuresUnbroken).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").mangoFont(.footnote)
            }
            .mangoFont(.headline)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Period")
        .accessibilityValue(model.periodTitle)
    }

    private var viewPicker: some View {
        Picker("View", selection: Binding(get: { model.mode }, set: { mode in
            switch mode {
            case .months: model.showMonths()
            case .transactions: Task { await model.show(model.drill ?? PadMoneyModel.allCosts) }
            }
        })) {
            ForEach(PadMoneyModel.Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("View")
    }

    private var gbpToggle: some View {
        Toggle("Show in GBP", isOn: $model.showsGBP).fixedSize().frame(minHeight: 44)
    }

    // MARK: Tiles and chips

    private var tiles: some View {
        PadGrid(minimumColumnWidth: 190) {
            ForEach(model.tiles) { tile in
                PadTile(tile.title) {
                    if let amount = tile.amount {
                        MoneyText(minorUnits: model.shown(amount), currency: model.displayCurrency, role: tile.role, fit: .shrink(),
                                  font: .title2.weight(.semibold))
                    } else if let text = tile.text {
                        Text(text).mangoFont(.title2, weight: .semibold, figures: true).lineLimit(1)
                    }
                } caption: {
                    if let caption = tile.caption {
                        Text(caption.figuresUnbroken)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        let categories = model.categoryChips
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                PadSectionHeader("Costs by category")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(PadMoneyModel.allCosts)
                        ForEach(categories) { chip($0) }
                    }
                }
            }
        }
    }

    private func chip(_ drill: PadMoneyModel.Drill) -> some View {
        let selected = model.mode == .transactions && model.drill?.id == drill.id
        return Button { Task { await model.show(drill) } } label: {
            Text(drill.title).mangoFont(.subheadline, weight: .semibold).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .foregroundStyle(selected ? Color.white : theme.accent)
                .background(Capsule().fill(selected ? theme.accent : theme.accent.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transactions: \(drill.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Months

    private var monthList: some View {
        VStack(alignment: .leading, spacing: 12) {
            PadSectionHeader("Months")
            Card {
                ForEach(Array(model.months.enumerated()), id: \.element.start) { index, month in
                    if index > 0 { Divider() }
                    monthRow(month)
                }
            }
        }
    }

    private func monthRow(_ month: PropertyMonthFigures) -> some View {
        let selected = model.expandedMonth == month.start
        return Button { Task { await model.toggle(month) } } label: {
            HStack(alignment: .center, spacing: 10) {
                Text(PadMoneyModel.monthTitle(month).figuresUnbroken).mangoFont(.headline).lineLimit(1)
                Spacer(minLength: 8)
                MoneyText(minorUnits: model.shown(month.figures.netCashFlow), currency: model.displayCurrency, role: .income, font: .headline)
                Image(systemName: "chevron.right").mangoFont(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? theme.accent.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the month's transactions")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func monthDetail(_ month: PropertyMonthFigures) -> some View {
        if let breakdown = model.breakdown(month) {
            VStack(alignment: .leading, spacing: 4) {
                figure("Rent received", breakdown.rentReceived, .income)
                figure("Costs", breakdown.costs, .expense)
                figure("Net cash flow", breakdown.netCashFlow, .income, bold: true)
            }
            if breakdown.groups.isEmpty {
                Text("No transactions in this month.").mangoFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(breakdown.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.kind.title).mangoFont(.subheadline, weight: .semibold).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        MoneyText(minorUnits: model.shown(group.total), currency: model.displayCurrency, role: .income, font: .subheadline)
                    }
                    .padding(.top, 4)
                    ForEach(model.lines(group)) { line in
                        PadMoneyLineRow(model: model, line: line, isSelected: model.panel?.line.id == line.id) {
                            Task { await model.select(line, month: month.start) }
                        }
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func figure(_ title: String, _ amount: PropertyAmount, _ role: MoneyRole, bold: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title).fontWeight(bold ? .semibold : .regular).lineLimit(1)
            Spacer(minLength: 8)
            MoneyText(minorUnits: model.shown(amount), currency: model.displayCurrency, role: role, font: .body.weight(bold ? .semibold : .regular))
        }
        .mangoFont(.body)
    }

    // MARK: Transactions

    private var transactionList: some View {
        let drill = model.drill ?? PadMoneyModel.allCosts
        let lines = model.drillLines
        return VStack(alignment: .leading, spacing: 8) {
            Text(drill.title).mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            Text("\(lines.count) transaction\(lines.count == 1 ? "" : "s") · \(model.summary?.period.label ?? "")".figuresUnbroken)
                .mangoFont(.subheadline).foregroundStyle(.secondary)
            if lines.isEmpty {
                Text("No transactions in this period.").mangoFont(.callout).foregroundStyle(.secondary)
            }
            if model.displayCurrency != model.currency || model.showsGBP && model.offersGBP {
                Text("Transactions keep their own currency.").mangoFont(.footnote).foregroundStyle(.secondary)
            }
            PadGrid(minimumColumnWidth: 340, balanced: false) {
                ForEach(lines) { line in
                    PadMoneyLineRow(model: model, line: line, isSelected: model.panel?.line.id == line.id, card: true) {
                        Task { await model.select(line) }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func run(_ action: PadMoneyAction) {
        Task {
            guard let panel = model.panel else { return }
            switch action {
            case .transactionDetails:
                if let row = await model.detailRow(transactionId: panel.line.transactionId) { detail = row }
            case .showInDocuments:
                if let id = model.panelDocumentId { showDocument(id) }
            case .linkDocument:
                let choices = await model.documentChoices(for: panel.line.transactionId)
                request = PadChoiceRequest(title: "Link document", button: "Link", empty: "No document in the library is waiting.",
                                           currency: panel.line.currency, choices: choices,
                                           choose: { id in await model.link(documentId: id) })
            case .unlinkDocument:
                if let id = model.panelDocumentId { await model.unlink(documentId: id) }
            default: break
            }
        }
    }
}

/// One transaction in the Money lists: its description, category and account, the day, what it counts (or its amount),
/// and a paperclip with the number of documents. Tapping opens the panel.
struct PadMoneyLineRow: View {
    let model: PadMoneyModel
    let line: PadMoneyModel.Line
    let isSelected: Bool
    var card = false
    let select: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.transaction.rawDescription).mangoFont(.headline).lineLimit(1).truncationMode(.middle)
                        if !line.detail.isEmpty {
                            Text(line.detail).mangoFont(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    amount
                }
                HStack(spacing: 8) {
                    Text(PhoneDateFormat.day(line.transaction.date).unbroken).mangoFont(.footnote, figures: true).foregroundStyle(.secondary)
                    if line.documentCount > 0 {
                        Label("\(line.documentCount)", systemImage: "paperclip").mangoFont(.footnote, figures: true).foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                            .accessibilityLabel("\(line.documentCount) document\(line.documentCount == 1 ? "" : "s")")
                    }
                    Spacer(minLength: 4)
                }
                if let note = line.note {
                    Text(note.figuresUnbroken).mangoFont(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, card ? 14 : 8).padding(.horizontal, card ? 14 : 10)
            // As a card in a grid row, as tall as the row.
            .frame(maxWidth: .infinity, maxHeight: card ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: card ? MangoRadius.card : 12, style: .continuous).fill(card ? theme.surface : theme.background))
            .overlay(RoundedRectangle(cornerRadius: card ? MangoRadius.card : 12, style: .continuous).stroke(isSelected ? theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the transaction")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var amount: some View {
        if let counted = line.counted {
            MoneyText(minorUnits: model.shown(counted), currency: model.displayCurrency, role: .income, font: .headline)
        } else {
            MoneyText(minorUnits: line.transaction.amountMinorUnits, currency: line.currency, role: .income, font: .headline)
        }
    }
}

// MARK: - The panel

/// The panel for the open transaction on the right of the screen: the shared `DocumentPanel` on its document, or a plain
/// panel of the same width when it has none; beside the content when it keeps `DocumentPanelLayout`'s minimum width, else
/// over its trailing edge. Closing clears the selection.
struct PadMoneyPanelHost<PanelExtra: View>: ViewModifier {
    @ObservedObject var model: PadMoneyModel
    let extra: (PadMoneyModel.Line) -> PanelExtra
    @Environment(\.phoneTheme) private var theme

    func body(content: Content) -> some View {
        content.padSidePanel(isPresented: model.panel != nil, onClose: { model.closePanel() }) {
            if let panel = model.panel { self.panel(panel) }
        }
    }

    @ViewBuilder
    private func panel(_ panel: PadMoneyModel.Panel) -> some View {
        if let documentId = model.panelDocumentId {
            DocumentPanel(documentId: documentId, onClose: { model.closePanel() }) { extra(panel.line) }
                .id(documentId)
        } else {
            PadMoneyPlainPanel(onClose: { model.closePanel() }) { extra(panel.line) }
        }
    }
}

/// The panel of a transaction with no document: its title and the screen's block.
struct PadMoneyPlainPanel<Extra: View>: View {
    let onClose: () -> Void
    @ViewBuilder let extra: Extra
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        PadSidePanel(title: "Transaction", onClose: onClose) { extra }
    }
}

/// Under the document's details: the transaction itself (day, amount, what it counts, category, account), the month's
/// figures when it was opened from a month, the transaction's other documents (View swaps the panel's), and the actions.
struct PadMoneyPanelExtra: View {
    @ObservedObject var model: PadMoneyModel
    @ObservedObject var write: PadWriteModel
    let line: PadMoneyModel.Line
    let run: (PadMoneyAction) -> Void

    var body: some View {
        let panel = model.panel
        let transaction = panel?.line.transaction ?? line.transaction
        VStack(alignment: .leading, spacing: 16) {
            if panel?.documents.isEmpty ?? true {
                Text("No document is linked to this transaction.").foregroundStyle(.secondary)
            }
            Card(title: "Transaction") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(transaction.rawDescription).mangoFont(.subheadline, weight: .semibold).lineLimit(3).truncationMode(.middle)
                    fact("Date", Text(PhoneDateFormat.day(transaction.date).unbroken))
                    fact("Amount", MoneyText(minorUnits: transaction.amountMinorUnits, currency: line.currency, role: .income, font: .subheadline))
                    if let counted = line.counted {
                        fact("Counts", MoneyText(minorUnits: model.shown(counted), currency: model.displayCurrency, role: .income, font: .subheadline))
                    }
                    if let name = line.categoryName { fact("Category", Text(name).lineLimit(1).truncationMode(.middle)) }
                    if !line.accountName.isEmpty { fact("Account", Text(line.accountName).lineLimit(1).truncationMode(.middle)) }
                    if let note = line.note { Text(note.figuresUnbroken).mangoFont(.footnote).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let month = model.panelMonth {
                Card(title: "The month") {
                    VStack(alignment: .leading, spacing: 8) {
                        fact("Rent received", MoneyText(minorUnits: model.shown(month.rentReceived), currency: model.displayCurrency, role: .income, font: .subheadline))
                        fact("Costs", MoneyText(minorUnits: model.shown(month.costs), currency: model.displayCurrency, role: .expense, font: .subheadline))
                        fact("Net cash flow", MoneyText(minorUnits: model.shown(month.netCashFlow), currency: model.displayCurrency, role: .income, font: .subheadline))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let documents = panel?.documents, documents.count > 1 {
                Card(title: "Documents") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(documents) { document in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.displayName).mangoFont(.subheadline).lineLimit(1).truncationMode(.middle)
                                    Text(document.kindLabel).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if document.id == model.panelDocumentId {
                                    PadStatusPill(text: "Shown", tone: .accent)
                                } else {
                                    RowIconButton(.view, item: document.displayName, size: .small) { model.shownDocumentId = document.id }
                                }
                            }
                        }
                    }
                }
            }
            actions
            PadRefusalBanner(message: write.message(for: PadMoneyModel.transactionRow(line.transactionId)))
        }
    }

    private var actions: some View {
        let offered = model.actions()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if offered.contains(.linkDocument) {
                    Button { run(.linkDocument) } label: { Label("Link document", systemImage: RowAction.linkDocument.systemImage) }
                        .buttonStyle(.pad(.secondary))
                }
                if offered.contains(.unlinkDocument) {
                    RowIconButton(.unlink, item: "document", size: .regular) { run(.unlinkDocument) }
                }
            }
            HStack(spacing: 8) {
                Button { run(.transactionDetails) } label: { Text("Details") }.buttonStyle(.pad(.textLink))
                if offered.contains(.showInDocuments) {
                    Button { run(.showInDocuments) } label: { Text("Show in Documents") }.buttonStyle(.pad(.textLink))
                }
            }
        }
    }

    private func fact<Value: View>(_ label: String, _ value: Value) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 12)
                value.lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                value.fixedSize(horizontal: false, vertical: true)
            }
        }
        .mangoFont(.subheadline)
    }
}

// MARK: - Custom range

/// A custom range: its first and last day, applied only on "Show".
struct PadMoneyCustomRangeSheet: View {
    @ObservedObject var model: PadMoneyModel
    @Environment(\.dismiss) private var dismiss
    @State private var first: Date
    @State private var last: Date

    init(model: PadMoneyModel) {
        self.model = model
        _first = State(initialValue: model.customFirstDay)
        _last = State(initialValue: model.customLastDay)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("First day", selection: $first, displayedComponents: .date)
                DatePicker("Last day", selection: $last, displayedComponents: .date)
                if first > last {
                    Text("Pick a range that ends after it starts.").foregroundStyle(.secondary)
                }
            }.padFormChrome()
            .environment(\.timeZone, MonthRange.calendar.timeZone)
            .environment(\.calendar, MonthRange.calendar)
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { PadIconButton(systemImage: "xmark", label: "Cancel") { dismiss() } }.padFlatToolbarItem()
                ToolbarItem(placement: .confirmationAction) {
                    PadIconButton(systemImage: "checkmark", label: "Show", prominent: true) {
                        model.customFirstDay = first
                        model.customLastDay = last
                        Task {
                            await model.choose(.custom)
                            dismiss()
                        }
                    }
                    .disabled(first > last)
                }.padFlatToolbarItem()
            }
        }
    }
}
