import SwiftUI
import BudgetCore

/// Bills & recharges on the iPad (step 10, Task 11): one screen for the selected tenancy and one year. The summary
/// (Outstanding · Recharged in <year> · Bills paid for those months · Difference, with why and a link to the statement),
/// the provider × month bills grid coloured by stage, and the statements below. A bill opens the document panel on its
/// PDF with its details and actions; a statement opens its own sheet. Edits show only with Edit on Property, a refusal
/// under the row it was made on. The tenancy is named by its label, never the tenant.
struct PadBillsAndRechargesView: View {
    @ObservedObject var model: PadBillsAndRechargesModel
    @ObservedObject var property: PadPropertyModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    @State private var request: PadChoiceRequest?
    @State private var correcting: UtilityBill?
    @Environment(\.phoneTheme) private var theme
    @Environment(\.padBrowser) private var browser
    @Environment(\.documentPanelSource) private var documentSource

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.section) {
                    PadWriteNotices(write: write)
                    if property.tenancies.isEmpty {
                        EmptyState(symbol: "doc.text", title: "No tenancy yet", message: "Bills and statements appear here once the Mac has shared a tenancy.")
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        header
                        PadRefusalBanner(message: write.message(for: PadBillsAndRechargesModel.screenRow))
                        summary
                        PadBillsGridView(model: model, property: property)
                        PadStatementsList(model: model, write: write, open: { model.openStatementId = $0.id },
                                          prepareEmail: { model.emailStatementId = $0.id }, choosePayment: choosePayment)
                    }
                }
                .padPageContent()
            }
            .background(theme.background)
            .offlineBannerSlot()
            .padPage("Bills & recharges", contexts: property.tenancies.isEmpty ? [] : contexts, primary: primaryAction) { moreMenu }
        }
        .modifier(PadBillPanelHost(model: model) { bill in panelExtra(bill) })
        .task(id: ReloadKey(trigger: SyncReloadTrigger(syncStatus), tenancy: property.selectedTenancyId)) {
            await write.refresh()
            await property.reload()
            await model.reload()
        }
        .sheet(item: $request) { PadChoiceSheet(request: $0) }
        .sheet(item: $correcting) { bill in
            PadTotalSheet(model: model, write: write, bill: bill)
        }
        .padSidePanel(isPresented: model.openStatementId != nil, onClose: { model.openStatementId = nil }) {
            if let id = model.openStatementId {
                PadStatementSheet(model: model, write: write, statementId: id, choosePayment: choosePayment,
                                  onClose: { model.openStatementId = nil })
            }
        }
        .sheet(isPresented: Binding(get: { model.emailStatementId != nil }, set: { if !$0 { model.emailStatementId = nil } })) {
            if let id = model.emailStatementId {
                PrepareEmailSheet(model: model.prepareEmailModel(statementId: id, open: documentSource?.open), write: write)
            }
        }
    }

    private struct ReloadKey: Equatable {
        var trigger: SyncReloadTrigger
        var tenancy: Int64?
    }

    // MARK: Header

    /// The tenancy first, then its year: both context pickers on the page header (the tenancy by its label).
    private var contexts: [ContextPicker] {
        var pickers = [ContextPicker("Tenancy", items: property.tenancies, selected: property.selectedTenancyId.map(String.init),
                                     fallback: property.selectedTenancy?.referenceLabel ?? "Tenancy",
                                     id: { String($0.id ?? 0) }, title: { $0.referenceLabel },
                                     choose: { property.selectedTenancyId = $0.id })]
        let years = model.years
        pickers.append(ContextPicker("Year", items: years, selected: String(model.year), fallback: String(model.year),
                                     id: { String($0) }, title: { String($0) }, choose: { model.chosenYear = $0 }))
        return pickers
    }

    /// The page's one primary action: prepare the next month's statement. The others are in the menu.
    private var primaryAction: PageAction? {
        guard write.canEdit, !property.tenancies.isEmpty else { return nil }
        let month = RechargeEmail.monthName(model.nextMonth, language: .english)
        return PageAction("Prepare \(month)", systemImage: "square.and.pencil") { Task { await model.prepareNext() } }
    }

    /// Open the utilities' site, Match tenant credits.
    @ViewBuilder
    private var moreMenu: some View {
        if browser != nil || write.canEdit {
            Menu {
                if browser != nil { Button(PadBillsAction.utilityInvoices.title) { openUtilitySite() } }
                if write.canEdit { Button(PadBillsAction.matchCredits.title) { Task { await model.matchCredits() } } }
            } label: {
                Image(systemName: "ellipsis.circle").mangoFont(.body, weight: .semibold)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MangoSpacing.xs) {
            if let message = model.matchMessage {
                InlineBanner(tone: .neutral, text: message)
                    .accessibilityIdentifier("match-credits-result")
            }
        }
    }

    private func openUtilitySite() {
        guard let browser else { return }
        browser.present(PadThisMonthModel.site(in: browser.sites, kind: .utility, name: nil))
    }

    // MARK: Summary

    private var summary: some View {
        let summary = model.summary(year: model.year)
        let currency = model.currency
        return VStack(alignment: .leading, spacing: 10) {
            PadGrid(minimumColumnWidth: 190) {
                tile("Outstanding", caption: summary.outstandingCaption, pill: summary.overdue > 0 ? "\(summary.overdue) overdue" : nil) {
                    MoneyText(minorUnits: summary.outstandingMinorUnits, currency: currency, role: .neutral, fit: .shrink(), font: .title2.weight(.semibold))
                }
                tile("Recharged in \(String(summary.year))", caption: summary.rechargedCaption) {
                    MoneyText(minorUnits: summary.rechargedMinorUnits, currency: currency, role: .income, fit: .shrink(), font: .title2.weight(.semibold))
                }
                tile("Bills paid for those months", caption: "What the bank paid for their bills") {
                    MoneyText(minorUnits: summary.billsPaidMinorUnits, currency: currency, role: .expense, fit: .shrink(), font: .title2.weight(.semibold))
                }
                tile("Difference", caption: summary.differenceCaption) {
                    MoneyText(minorUnits: summary.differenceMinorUnits, currency: currency, role: .income, fit: .shrink(), font: .title2.weight(.semibold))
                }
            }
            ForEach(summary.reasons) { reason in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(reason.text.figuresUnbroken).mangoFont(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(Array(zip(reason.statementIds, reason.statementNames)), id: \.0) { id, name in
                                Button("\(name) ›") { model.openStatementId = id }
                                    .buttonStyle(.pad(.textLink, size: .small))
                                    .accessibilityLabel("Open the \(name) statement")
                            }
                        }
                    }
                }
            }
        }
    }

    private func tile<Value: View>(_ title: String, caption: String, pill: String? = nil, @ViewBuilder value: () -> Value) -> some View {
        Tile(title, value: value) {
            VStack(alignment: .leading, spacing: 6) {
                Text(caption.figuresUnbroken)
                if let pill { StatusPill(pill, .waiting) }
            }
        }
    }

    // MARK: Panel

    @ViewBuilder
    private func panelExtra(_ bill: UtilityBill) -> some View {
        PadBillPanelExtra(model: model, write: write, bill: bill, run: { action in Task { await run(action, bill) } })
    }

    // MARK: Actions

    private func run(_ action: PadBillsAction, _ bill: UtilityBill) async {
        let currency = model.currency
        switch action {
        case .linkDocument:
            let documents = await model.invoiceDocuments()
            request = PadChoiceRequest(title: "Link document", button: "Link", empty: "No invoice in the library is waiting.", currency: currency,
                                       choices: documents.map { PadChoice(id: $0.id ?? 0, title: $0.displayName, date: $0.docDate, amountMinorUnits: $0.amountMinorUnits) },
                                       choose: { id in await model.linkInvoice(bill, documentId: id) })
        case .linkPayment:
            let candidates = await model.paymentCandidates(for: bill)
            request = PadChoiceRequest(title: "Link payment", button: "Link", empty: "No bank movement matches this invoice.", currency: currency,
                                       choices: candidates.map(PadChoice.transaction), choose: { id in await model.linkPayment(bill, transactionId: id) })
        case .recordPayment:
            let suggestions = await model.paymentSuggestions(for: bill)
            request = Self.paymentRequest(suggestions, currency: currency) { suggestion in await model.recordPayment(bill, suggestion) }
        case .addToRecharge: await model.addToRecharge(bill)
        case .markSent: await model.markSent(bill)
        case .correctTotal: correcting = bill
        case .openStatement: if let id = bill.statement?.id { model.openStatementId = id }
        case .unlinkPayment, .reopen, .deleteStatement, .prepareEmail, .matchCredits, .utilityInvoices: break
        }
    }

    private func choosePayment(_ statement: PadBillsAndRechargesModel.Statement) {
        request = Self.paymentRequest(statement.suggestions, currency: model.currency) { suggestion in
            await model.recordPayment(statement, suggestion)
        }
    }

    private static func paymentRequest(_ suggestions: [Recharges.PaymentSuggestion], currency: Currency,
                                       record: @escaping (Recharges.PaymentSuggestion) async -> Bool) -> PadChoiceRequest {
        PadChoiceRequest(title: "Record payment", button: "Record", empty: "No tenant credit pays this statement yet.", currency: currency,
                         choices: suggestions.map { PadChoice(id: $0.transaction.id ?? 0, title: $0.transaction.rawDescription,
                                                              date: $0.transaction.date, amountMinorUnits: $0.amountMinorUnits) },
                         choose: { id in
                             if let suggestion = suggestions.first(where: { $0.transaction.id == id }) { _ = await record(suggestion) }
                         })
    }
}

/// The selected bill's block under the document's details: its stage, statement and what the tenant paid of it, the other
/// bills of its cell, and the actions its stage offers (icon buttons, "Correct total…" as text), a refusal under them.
struct PadBillPanelExtra: View {
    @ObservedObject var model: PadBillsAndRechargesModel
    @ObservedObject var write: PadWriteModel
    let bill: UtilityBill
    let run: (PadBillsAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(bill.providerName).mangoFont(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        MoneyText(minorUnits: bill.amountMinorUnits, currency: model.currency, role: .neutral)
                    }
                    ForEach(model.facts(for: bill), id: \.label) { fact in
                        // A value keeps its figures whole: beside its label when it fits, else under it.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(fact.label).foregroundStyle(.secondary).fixedSize()
                                Spacer(minLength: 12)
                                Text(fact.value).lineLimit(1).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fact.label).foregroundStyle(.secondary)
                                Text(fact.value).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .mangoFont(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let cell = model.selectedCell, cell.bills.count > 1 {
                Picker("Bill", selection: Binding(get: { model.selectedBillId ?? bill.id }, set: { model.selectedBillId = $0 })) {
                    ForEach(cell.bills) { Text(Self.name($0, model.currency)).tag($0.id) }
                }
                .pickerStyle(.menu)
            }
            let offered = model.actions(for: bill)
            if !offered.isEmpty {
                HStack(spacing: 4) {
                    ForEach(offered.filter { $0.rowAction != nil }, id: \.self) { action in
                        if let row = action.rowAction {
                            RowIconButton(row, item: "\(bill.providerName) bill") { run(action) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                ForEach(offered.filter { $0.rowAction == nil }, id: \.self) { action in
                    Button(action.title) { run(action) }.buttonStyle(.pad(.secondary, size: .small))
                }
            }
            PadRefusalBanner(message: write.message(for: bill.id))
        }
        .accessibilityIdentifier("pad-bill-\(bill.id)")
    }

    private static func name(_ bill: UtilityBill, _ currency: Currency) -> String {
        "\(bill.providerName) · \(Money.format(bill.amountMinorUnits, currency: currency))"
    }
}

/// Correct an invoice's total: the amount as the invoice states it. Saved only with Save; a refusal shows inside.
struct PadTotalSheet: View {
    @ObservedObject var model: PadBillsAndRechargesModel
    @ObservedObject var write: PadWriteModel
    let bill: UtilityBill
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var text = ""
    @State private var saving = false

    private var amount: Int? { Money.parseMinorUnits(text).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section { PadRefusalBanner(message: write.message(for: bill.id)) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section { Text(bill.providerName).mangoFont(.headline).lineLimit(2).truncationMode(.middle) }
                Section("Invoice total") {
                    TextField("Total", text: $text, prompt: Text(Money.format(bill.invoice?.amountMinorUnits ?? bill.amountMinorUnits, currency: model.currency)))
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("invoice-total-field")
                }
            }.padFormChrome()
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .mangoNavigationTitle("Correct total")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { PadIconButton(systemImage: "xmark", label: "Cancel") { dismiss() } }.padFlatToolbarItem()
                ToolbarItem(placement: .confirmationAction) {
                    PadIconButton(systemImage: "checkmark", label: "Save", prominent: true) {
                        guard let amount else { return }
                        saving = true
                        Task {
                            let saved = await model.correctTotal(bill, to: amount)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(amount == nil || saving)
                }.padFlatToolbarItem()
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - The panel host

/// The panel for the selected bill on the right of the screen (the shared `DocumentPanel` on the bill's PDF, or a plain
/// panel of the same width when the invoice has no document), beside the content when it keeps `DocumentPanelLayout`'s
/// minimum width, else over its trailing edge. Closing clears the selection.
struct PadBillPanelHost<PanelExtra: View>: ViewModifier {
    @ObservedObject var model: PadBillsAndRechargesModel
    let extra: (UtilityBill) -> PanelExtra
    @Environment(\.phoneTheme) private var theme

    func body(content: Content) -> some View {
        content.padSidePanel(isPresented: model.selectedBill != nil, onClose: { model.closePanel() }) {
            if let bill = model.selectedBill { panel(bill) }
        }
    }

    @ViewBuilder
    private func panel(_ bill: UtilityBill) -> some View {
        if let documentId = bill.invoice?.documentId {
            DocumentPanel(documentId: documentId, onClose: { model.closePanel() }) { extra(bill) }
                .id(documentId)
        } else {
            PadBillPlainPanel(bill: bill, onClose: { model.closePanel() }) { extra(bill) }
        }
    }
}

/// The panel of a bill with no document: its title, a note, and the screen's block.
struct PadBillPlainPanel<Extra: View>: View {
    let bill: UtilityBill
    let onClose: () -> Void
    @ViewBuilder let extra: Extra
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        PadSidePanel(title: bill.providerName, onClose: onClose) {
            Text(bill.invoice == nil ? "No invoice recorded for this payment." : "This invoice has no document yet.")
                .foregroundStyle(.secondary)
            extra
        }
    }
}
