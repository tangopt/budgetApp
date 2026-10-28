import SwiftUI
import BudgetCore

/// Accounts on the iPad (step 11, Task 2): the iPhone's grouped cards under the net worth header, and the selected
/// account beside them in a 380 pt panel when the screen keeps room for both (landscape, the 13-inch), else pushed
/// (portrait 11-inch). A recent transaction opens in a sheet with its document in the document panel. The controls
/// (Add account, Edit, Update balance, Fetch statement) show only where `PadAccountsModel.actions` offers them; Edit and
/// Add account open the forms of Task 3 (`onAdd`, `onEdit`).
struct PadAccountsView: View {
    @ObservedObject var model: PadAccountsModel
    @ObservedObject var accounts: AccountsViewModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    let onRefresh: () async -> Void
    var onAdd: (() -> Void)?
    var onEdit: ((Int64) -> Void)?
    @Environment(\.phoneTheme) private var theme
    @Environment(\.padBrowser) private var browser
    @State private var canAdd = false
    @State private var isSplit = false

    init(model: PadAccountsModel, write: PadWriteModel, syncStatus: SyncStatus, onRefresh: @escaping () async -> Void = {},
         onAdd: (() -> Void)? = nil, onEdit: ((Int64) -> Void)? = nil) {
        self.model = model
        accounts = model.accounts
        self.write = write
        self.syncStatus = syncStatus
        self.onRefresh = onRefresh
        self.onAdd = onAdd
        self.onEdit = onEdit
    }

    var body: some View {
        GeometryReader { geometry in
            let split = DocumentPanelLayout.placement(containerWidth: geometry.size.width) == .beside
            NavigationStack(path: Binding(get: { split ? [] : accounts.path }, set: { if !split { accounts.path = $0 } })) {
                HStack(spacing: 0) {
                    list(split: split)
                    if split {
                        Divider()
                        panel
                    }
                }
                .navigationTitle("Accounts")
                .navigationDestination(for: AccountDestination.self) { destination in
                    PadAccountDetailView(model: model, detail: accounts.detailModel(for: destination), onEdit: onEdit)
                        .navigationTitle(accounts.row(for: destination)?.name ?? "Account")
                        .navigationBarTitleDisplayModeInline()
                        .demoBannerSlot()
                }
                .toolbar {
                    if canAdd, let onAdd {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: onAdd) { Label("Add account", systemImage: "plus") }
                                .accessibilityIdentifier("add-account")
                        }
                    }
                }
            }
            .onChange(of: split, initial: true) { _, isSplit in
                // Side by side: a pushed account becomes the selected one, and the first is selected when none is.
                self.isSplit = isSplit
                guard isSplit else { return }
                if let pushed = accounts.path.last { model.selectedId = pushed.accountId; accounts.path = [] }
                if model.selectedId == nil { model.selectedId = accounts.state.page?.sections.first?.rows.first?.id }
            }
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await accounts.reload(for: AccountsViewModel.reloadKey(syncStatus))
            await write.refresh()
            canAdd = await model.canAdd()
            if model.selectedId == nil, isSplit { model.selectedId = accounts.state.page?.sections.first?.rows.first?.id }
        }
        .sheet(item: $model.form) { form in
            if form.model.isAdding {
                PadAddAccountSheet(model: form.model) { _ in Task { await model.formSaved(form.model) } }
            } else {
                PadEditAccountSheet(model: form.model) { _ in Task { await model.formSaved(form.model) } }
            }
        }
        .sheet(item: Binding(get: { model.openTransaction }, set: { if $0 == nil { model.closeTransaction() } })) { open in
            PadAccountTransactionSheet(open: open, onClose: { model.closeTransaction() })
        }
    }

    // MARK: The list

    private func list(split: Bool) -> some View {
        ScrollView {
            // Not lazy: a household has a dozen accounts or so, and the snapshot probe measures every one.
            VStack(alignment: .leading, spacing: 16) {
                PadWriteNotices(write: write)
                content(split: split)
            }
            .padding(16)
            .frame(maxWidth: split ? .infinity : 720)
            .frame(maxWidth: .infinity)
        }
        .background(theme.background)
        .refreshable {
            await onRefresh()
            await accounts.load()
        }
        .offlineBannerSlot()
    }

    @ViewBuilder
    private func content(split: Bool) -> some View {
        switch accounts.state {
        case .idle:
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        case .empty:
            EmptyState(symbol: "building.columns", title: AccountsCopy.emptyTitle, message: AccountsCopy.emptyMessage)
                .frame(maxWidth: .infinity).padding(.top, 60)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Accounts couldn't load", message: message)
                .frame(maxWidth: .infinity).padding(.top, 60)
        case .loaded(let page):
            if let error = accounts.errorMessage { InlineBanner(tone: .amber, text: error) }
            AccountsHeader(page: page)
            ForEach(page.sections) { section in sectionCard(section, split: split) }
        }
    }

    private func sectionCard(_ section: AccountsSection, split: Bool) -> some View {
        Card {
            FigureRow(label: section.title) {
                MoneyText(minorUnits: section.subtotalGBP, currency: .gbp, role: .balance, font: .headline)
            }
            .font(.headline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.title)
            .accessibilityValue(section.spokenSubtotal)
            .accessibilityAddTraits(.isHeader)
            ForEach(section.rows) { row in
                Divider()
                if split {
                    Button { model.selectedId = row.id } label: { rowLabel(row) }
                        .buttonStyle(.plain)
                        .background(model.selectedId == row.id ? theme.accent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    NavigationLink(value: AccountDestination(accountId: row.id)) { rowLabel(row) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func rowLabel(_ row: AccountRowPresentation) -> some View {
        HStack(spacing: 8) {
            AccountRowView(row: row)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    // MARK: The panel

    @ViewBuilder
    private var panel: some View {
        Group {
            if let id = model.selectedId, accounts.row(for: AccountDestination(accountId: id)) != nil {
                PadAccountDetailView(model: model, detail: accounts.detailModel(for: AccountDestination(accountId: id)), onEdit: onEdit)
                    .id(id)
            } else {
                EmptyState(symbol: "building.columns", title: "Pick an account", message: "Its balance and recent transactions show here.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
            }
        }
        .frame(width: DocumentPanelLayout.width)
    }
}

/// A transaction from an account's detail, in its sheet: the shared document panel on its first document, else a plain
/// panel of the same width, with the transaction's own facts under the details.
struct PadAccountTransactionSheet: View {
    let open: PadAccountsModel.OpenTransaction
    let onClose: () -> Void

    var body: some View {
        Group {
            if let documentId = open.documentId {
                DocumentPanel(documentId: documentId, onClose: onClose) { facts }.id(documentId)
            } else {
                PadMoneyPlainPanel(onClose: onClose) { facts }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.large])
    }

    private var facts: some View {
        let row = open.row
        let amount = AccountDetailModel.amount(row.amountMinorUnits, category: row.category)
        return VStack(alignment: .leading, spacing: 16) {
            if open.documentId == nil {
                Text("No document is linked to this transaction.").foregroundStyle(.secondary)
            }
            Card(title: "Transaction") {
                Text(row.description).font(.subheadline.weight(.semibold)).lineLimit(3).truncationMode(.middle)
                PadAccountDetailLine(label: "Date", value: PhoneDateFormat.day(row.date))
                Divider()
                FigureRow(label: "Amount") { MoneyText(minorUnits: amount.minorUnits, currency: row.currency, role: amount.role) }
                if !row.categoryName.isEmpty {
                    Divider()
                    PadAccountDetailLine(label: "Category", value: row.categoryName)
                }
                Divider()
                PadAccountDetailLine(label: "Account", value: row.accountName)
            }
        }
    }
}
