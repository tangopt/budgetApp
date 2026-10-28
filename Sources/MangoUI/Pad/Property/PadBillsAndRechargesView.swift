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
                VStack(alignment: .leading, spacing: PadSpacing.section) {
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
            .padPage("Bills & recharges")
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
        .sheet(isPresented: Binding(get: { model.openStatementId != nil }, set: { if !$0 { model.openStatementId = nil } })) {
            if let id = model.openStatementId {
                PadStatementSheet(model: model, write: write, statementId: id, choosePayment: choosePayment)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(property.selectedTenancy?.referenceLabel ?? "")
                    .mangoFont(.title3, weight: .semibold).lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                if property.tenancies.count > 1 {
                    Menu {
                        ForEach(property.tenancies) { tenancy in
                            Button { property.selectedTenancyId = tenancy.id } label: {
                                if tenancy.id == property.selectedTenancyId { Label(tenancy.referenceLabel, systemImage: "checkmark") }
                                else { Text(tenancy.referenceLabel) }
                            }
                        }
                    } label: {
                        Label("Tenancy", systemImage: "chevron.up.chevron.down").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Change tenancy")
                }
                Spacer(minLength: 8)
                yearPicker
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons }
                Menu {
                    menuItems
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle").frame(minHeight: 44)
                }
                .buttonStyle(.pad(.secondary))
            }
        }
    }

    @ViewBuilder
    private var yearPicker: some View {
        let years = model.years
        if years.count > 1 {
            Picker("Year", selection: Binding(get: { model.year }, set: { model.chosenYear = $0 })) {
                ForEach(years, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden()
            .frame(minHeight: 44)
            .accessibilityLabel("Year")
        } else {
            Text(String(model.year)).mangoFont(.headline, figures: true)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if browser != nil {
            Button { openUtilitySite() } label: { Label(PadBillsAction.utilityInvoices.title, systemImage: RowAction.openSite.systemImage) }
                .buttonStyle(.pad(.secondary))
        }
        if write.canEdit {
            Button { Task { await model.matchCredits() } } label: { Text(PadBillsAction.matchCredits.title) }
                .buttonStyle(.pad(.secondary))
            Button { Task { await model.prepareNext() } } label: {
                Text("Prepare \(RechargeEmail.monthName(model.nextMonth, language: .english))")
            }
            .buttonStyle(.pad(.primary))
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if browser != nil { Button(PadBillsAction.utilityInvoices.title) { openUtilitySite() } }
        if write.canEdit {
            Button(PadBillsAction.matchCredits.title) { Task { await model.matchCredits() } }
            Button("Prepare \(RechargeEmail.monthName(model.nextMonth, language: .english))") { Task { await model.prepareNext() } }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(2)
            value()
            Text(caption.figuresUnbroken).mangoFont(.footnote).foregroundStyle(.secondary)
            if let pill { PadStatusPill(text: pill, tone: .warning) }
        }
        .padCardSurface()
        .accessibilityElement(children: .combine)
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
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Correct total")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let amount else { return }
                        saving = true
                        Task {
                            let saved = await model.correctTotal(bill, to: amount)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(amount == nil || saving)
                }
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
        GeometryReader { geometry in
            let placement = DocumentPanelLayout.placement(containerWidth: geometry.size.width)
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let bill = model.selectedBill, placement == .beside {
                        Divider()
                        panel(bill)
                    }
                }
                if let bill = model.selectedBill, placement == .overlay {
                    HStack(spacing: 0) {
                        Divider()
                        panel(bill)
                    }
                    .frame(maxHeight: .infinity)
                    .background(theme.background)
                    .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
                    .transition(.move(edge: .trailing))
                }
            }
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
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bill.providerName).mangoFont(.headline).lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").mangoFont(.title2).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44).accessibilityLabel("Close")
            }
            .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 4)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(bill.invoice == nil ? "No invoice recorded for this payment." : "This invoice has no document yet.")
                        .foregroundStyle(.secondary)
                    extra
                }
                .padding(16)
            }
        }
        .frame(width: DocumentPanelLayout.width)
        .background(theme.background)
    }
}
