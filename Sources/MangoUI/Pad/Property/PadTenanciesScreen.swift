import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// Property ▸ Tenancies on the iPad (step 10, Task 13): the tenancy picker with New tenancy and More, the tenancy's details
/// (`PadTenancyDetailView`: tenant, rent, deposit, dates, rent history, contract), and its rent receipts by month with their
/// status. A receipt opens in the shared document panel with one extra line about the credit that paid it; "Fetch from Portal
/// das Finanças" opens the built-in browser at the saved site, whose downloads go through the tray and Check and link.
/// Edits show only with Edit on Property and save only on Save or an explicit button; a refusal shows under what was
/// acted on. The tenant's own name is shown here (and in the recharge email) and nowhere else.
struct PadTenanciesScreen: View {
    @ObservedObject var model: PadTenanciesModel
    @ObservedObject var property: PadPropertyModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    /// Selects a library document on the Documents screen.
    let showDocument: (Int64) -> Void
    @State private var request: PadChoiceRequest?
    @State private var form: PadTenancyDraft?
    @State private var documentsOf: DocumentsTarget?
    @State private var credit: TransactionSearch.Row?
    @State private var deleting: Tenancy?
    @Environment(\.phoneTheme) private var theme
    @Environment(\.padBrowser) private var browser
    @Environment(\.quickEdit) private var quickEdit

    struct DocumentsTarget: Identifiable {
        let entity: EvidenceEntity
        let title: String
        let rowId: String
        var id: String { "\(entity.type.rawValue)/\(entity.id)" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PadSpacing.section) {
                    PadWriteNotices(write: write)
                    if property.tenancies.isEmpty {
                        empty
                    } else {
                        controls
                        PadRefusalBanner(message: write.message(for: PadTenanciesModel.screenRow))
                        if let tenancy = property.selectedTenancy {
                            PadTenancyDetailView(model: model, write: write, tenancy: tenancy, run: { run($0, nil, nil) })
                            receipts
                        }
                    }
                }
                .padPageContent()
            }
            .background(theme.background)
            .offlineBannerSlot()
            .padPage("Tenancies")
        }
        .modifier(PadReceiptPanelHost(model: model) { receipt in
            PadReceiptPanelExtra(model: model, write: write, receipt: receipt, run: { run($0, receipt, $1) })
        })
        .task(id: ReloadKey(trigger: SyncReloadTrigger(syncStatus), tenancy: property.selectedTenancyId)) {
            await write.refresh()
            await property.reload()
            await model.reload()
        }
        .sheet(item: $request) { PadChoiceSheet(request: $0) }
        .sheet(item: $form) { draft in
            PadTenancyFormSheet(model: model, write: write, draft: draft)
        }
        .sheet(item: $documentsOf) { target in
            PadLinkedDocumentsSheet(title: target.title, canEdit: write.canEdit, write: write, rowId: target.rowId,
                                    load: { await model.linkedDocuments(of: target.entity) },
                                    unlink: { await model.unlinkDocument($0, from: target.entity, rowId: target.rowId) })
        }
        .sheet(item: $credit) { row in
            TransactionDetailSheet(row: row).environment(\.quickEdit, quickEdit)
        }
        .confirmationDialog(deleting.map { "Delete “\($0.referenceLabel)”?" } ?? "Delete this tenancy?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { tenancy in
            Button("Delete tenancy and its receipts", role: .destructive) { Task { await model.delete(tenancy) } }
        } message: { _ in
            Text("Its rent history, receipts and their credit links go too. Linked documents stay in the library. This can't be undone.")
        }
    }

    private struct ReloadKey: Equatable {
        var trigger: SyncReloadTrigger
        var tenancy: Int64?
    }

    // MARK: Controls

    private var empty: some View {
        VStack(spacing: 16) {
            EmptyState(symbol: "person.2", title: "No tenancies yet",
                       message: "Tenancies appear here once the Mac has shared them, or add one by hand.")
            if write.canEdit {
                Button("New tenancy") { run(.newTenancy, nil, nil) }.buttonStyle(.pad(.primary))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 10) {
            picker
            Spacer(minLength: 8)
            let actions = model.screenActions(hasBrowser: browser != nil)
            if actions.contains(.newTenancy) {
                ViewThatFits(in: .horizontal) {
                    Button { run(.newTenancy, nil, nil) } label: { Label("New tenancy", systemImage: "plus") }
                        .buttonStyle(.pad(.primary))
                    Button { run(.newTenancy, nil, nil) } label: { Image(systemName: "plus") }
                        .buttonStyle(.pad(.primary))
                        .accessibilityLabel("New tenancy")
                }
            }
            let more = actions.filter { $0 != .newTenancy }
            if !more.isEmpty {
                Menu {
                    ForEach(more, id: \.self) { action in
                        Button(action.title + (action == .utilityInvoices ? "…" : "")) { run(action, nil, nil) }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle").frame(minHeight: 44)
                }
                .buttonStyle(.pad(.secondary))
                .accessibilityLabel("More")
            }
        }
    }

    private var picker: some View {
        Menu {
            ForEach(property.tenancies) { tenancy in
                Button { property.selectedTenancyId = tenancy.id } label: {
                    if tenancy.id == property.selectedTenancyId {
                        Label(Self.pickerTitle(tenancy), systemImage: "checkmark")
                    } else {
                        Text(Self.pickerTitle(tenancy))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(property.selectedTenancy?.referenceLabel ?? "Tenancy").lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").mangoFont(.footnote)
            }
            .mangoFont(.headline)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Tenancy")
        .accessibilityValue(property.selectedTenancy?.referenceLabel ?? "")
    }

    /// "Tenancy 2 · 1 Aug 2024 – ongoing": the reference and its days, never the tenant.
    static func pickerTitle(_ tenancy: Tenancy) -> String {
        let end = tenancy.endDate.map(PhoneDateFormat.day) ?? "ongoing"
        return "\(tenancy.referenceLabel) · \(PhoneDateFormat.day(tenancy.startDate)) – \(end)"
    }

    // MARK: Receipts

    private var receipts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rent receipts").mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
                    if !model.detail.receipts.isEmpty {
                        Text("\(model.detail.receipts.count) receipt\(model.detail.receipts.count == 1 ? "" : "s") · \(model.paidCount) of \(model.issuedCount) issued paid"
                            .figuresUnbroken)
                            .mangoFont(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if browser != nil {
                    ViewThatFits(in: .horizontal) {
                        Button { run(.fetchFromPortal, nil, nil) } label: {
                            Label(PadTenanciesAction.fetchFromPortal.title, systemImage: RowAction.openSite.systemImage)
                        }
                        .buttonStyle(.pad(.secondary))
                        RowIconButton(.openSite, item: "Portal das Finanças") { run(.fetchFromPortal, nil, nil) }
                    }
                }
            }
            if browser != nil, PadTenanciesModel.portalSite(in: browser?.sites ?? []) == nil {
                HStack(spacing: 6) {
                    Text("No tax site saved yet.").mangoFont(.subheadline).foregroundStyle(.secondary)
                    Button { run(.fetchFromPortal, nil, nil) } label: { Label("Add site", systemImage: "plus") }
                        .buttonStyle(.pad(.textLink, size: .small))
                }
            }
            if model.detail.receipts.isEmpty {
                Text("No rent receipts yet: fetch them from Portal das Finanças, or the Mac imports the portal's export.")
                    .mangoFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.years) { year in
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(year.year)).mangoFont(.headline, figures: true).foregroundStyle(.secondary).padding(.top, 4)
                    PadTileGrid(minimumColumnWidth: 300, balanced: false) {
                        ForEach(year.receipts) { receipt in
                            PadRentReceiptRow(receipt: receipt, isSelected: receipt.id == model.selectedReceiptId,
                                              actions: model.actions(for: receipt), write: write,
                                              select: { model.select(receipt) },
                                              perform: { run($0, receipt, nil) })
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    /// `receipt`: the one acted on; `transactionId`: the credit a panel line is about.
    private func run(_ action: PadTenanciesAction, _ receipt: PadTenanciesModel.Receipt?, _ transactionId: Int64?) {
        Task { await perform(action, receipt, transactionId) }
    }

    private func perform(_ action: PadTenanciesAction, _ receipt: PadTenanciesModel.Receipt?, _ transactionId: Int64?) async {
        let currency = model.currency
        let tenancy = property.selectedTenancy
        switch action {
        case .newTenancy: form = model.draft(editing: nil)
        case .editTenancy: form = model.draft(editing: tenancy)
        case .deleteTenancy: deleting = tenancy
        case .matchCredits: _ = await model.matchCredits()
        case .utilityInvoices:
            browser?.present(PadThisMonthModel.site(in: browser?.sites ?? [], kind: .utility, name: nil))
        case .fetchFromPortal:
            browser?.present(PadTenanciesModel.portalSite(in: browser?.sites ?? []))
        case .addContract:
            let documents = await model.contractCandidates()
            request = PadChoiceRequest(title: "Add contract", button: "Link", empty: "No rent contract in the library is waiting.",
                                       currency: currency, choices: documents.map(Self.choice),
                                       choose: { id in await model.linkContract(documentId: id) })
        case .contractDocuments:
            guard let id = tenancy?.id else { return }
            documentsOf = DocumentsTarget(entity: .tenancy(id), title: "Contract documents", rowId: PadTenanciesModel.tenancyRow(id))
        case .viewReceipt:
            if let receipt { model.select(receipt) }
        case .linkPayment:
            guard let receipt else { return }
            let credits = await model.candidates(for: receipt)
            request = PadChoiceRequest(title: "Link payment", button: "Link", empty: "No rent credit is left to link.", currency: currency,
                                       choices: credits.map(PadChoice.transaction),
                                       choose: { id in await model.link(receipt, transactionId: id) })
        case .changePayment:
            guard let receipt, let old = transactionId else { return }
            let credits = await model.candidates(for: receipt)
            request = PadChoiceRequest(title: "Change payment", button: "Use this one", empty: "No other rent credit is left to link.",
                                       currency: currency, choices: credits.map(PadChoice.transaction),
                                       choose: { id in await model.change(receipt, from: old, to: id) })
        case .unlinkPayment:
            guard let receipt, let id = transactionId else { return }
            await model.unlink(receipt, transactionId: id)
        case .showCredit:
            guard let id = transactionId, let row = await model.creditRow(transactionId: id) else { return }
            credit = row
        case .addDocument, .replaceDocument:
            guard let receipt else { return }
            let replacing = action == .replaceDocument ? receipt.row.documentIds : []
            let documents = await model.receiptDocuments(for: receipt)
            request = PadChoiceRequest(title: action == .replaceDocument ? "Replace PDF" : "Add the receipt PDF", button: "Link",
                                       empty: "No rent receipt in the library is waiting. Fetch it from Portal das Finanças.",
                                       currency: currency, choices: documents.map(Self.choice),
                                       choose: { id in await model.linkDocument(receipt, documentId: id, replacing: replacing) })
        case .receiptDocuments:
            guard let receipt else { return }
            documentsOf = DocumentsTarget(entity: .rentReceipt(receipt.id), title: "Receipt \(receipt.receipt.receiptNumber): documents",
                                          rowId: receipt.rowId)
        case .showInDocuments:
            if let id = receipt?.row.documentIds.first { showDocument(id) }
        }
    }

    private static func choice(_ document: EvidenceDocument) -> PadChoice {
        PadChoice(id: document.id ?? 0, title: document.displayName, date: document.docDate, amountMinorUnits: document.amountMinorUnits)
    }
}
