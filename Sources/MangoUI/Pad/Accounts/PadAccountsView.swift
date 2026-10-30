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
                        MangoDivider()
                        panel
                    }
                }
                .background(theme.background)
                .padSidePanel(isPresented: !split && model.openTransaction != nil, onClose: { model.closeTransaction() }) {
                    if let open = model.openTransaction { PadAccountTransactionPanel(open: open, onClose: { model.closeTransaction() }) }
                }
                .padPage("Accounts") {
                    if canAdd, let onAdd {
                        Button(action: onAdd) { Label("Add account", systemImage: "plus") }
                            .buttonStyle(.pad(.secondary))
                            .accessibilityIdentifier("add-account")
                    }
                }
                .navigationDestination(for: AccountDestination.self) { destination in
                    PadAccountDetailView(model: model, detail: accounts.detailModel(for: destination), onEdit: onEdit)
                        .mangoNavigationTitle(accounts.row(for: destination)?.name ?? "Account")
                        .navigationBarTitleDisplayModeInline()
                        .demoBannerSlot()
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
    }

    // MARK: The list

    private func list(split: Bool) -> some View {
        ScrollView {
            // Not lazy: a household has a dozen accounts or so, and the snapshot probe measures every one.
            VStack(alignment: .leading, spacing: MangoSpacing.m) {
                PadWriteNotices(write: write)
                content(split: split)
            }
            .frame(maxWidth: split ? .infinity : 720, alignment: .leading)
            .padPageContent()
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
            .mangoFont(.headline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.title)
            .accessibilityValue(section.spokenSubtotal)
            .accessibilityAddTraits(.isHeader)
            ForEach(section.rows) { row in
                MangoDivider()
                if split {
                    Button { model.selectedId = row.id } label: {
                        rowLabel(row)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .mangoRowSelection(model.selectedId == row.id)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                .mangoFont(.footnote, weight: .semibold)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    // MARK: The panel

    @ViewBuilder
    private var panel: some View {
        Group {
            if let open = model.openTransaction {
                PadAccountTransactionPanel(open: open, onClose: { model.closeTransaction() }).id(open.id)
            } else if let id = model.selectedId, accounts.row(for: AccountDestination(accountId: id)) != nil {
                PadAccountDetailView(model: model, detail: accounts.detailModel(for: AccountDestination(accountId: id)), onEdit: onEdit)
                    .id(id)
            } else {
                EmptyState(symbol: "building.columns", title: "Pick an account", message: "Its balance and recent transactions show here.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
            }
        }
        .frame(width: PadSidePanelLayout.storedWidth())
    }
}

/// A transaction from an account's detail, in the side panel: what it is (description, signed amount, date, account), its
/// category and note (editable, saved only with the checkmark), its tags, and its linked documents with a preview.
struct PadAccountTransactionPanel: View {
    let open: PadAccountsModel.OpenTransaction
    let onClose: () -> Void
    @Environment(\.quickEdit) private var quickEdit
    @Environment(\.documentPanelSource) private var source
    @Environment(\.phoneTheme) private var theme
    @State private var canEdit = false
    @State private var categoryId: Int64?
    @State private var note: String
    @State private var saving = false
    @State private var previewId: Int64?
    @State private var preview: DocumentPanelModel?

    init(open: PadAccountsModel.OpenTransaction, onClose: @escaping () -> Void) {
        self.open = open
        self.onClose = onClose
        _categoryId = State(initialValue: open.row.transaction.categoryId)
        _note = State(initialValue: open.row.transaction.note ?? "")
        _previewId = State(initialValue: open.documentId)
    }

    private var changed: Bool { categoryId != open.row.transaction.categoryId || note != (open.row.transaction.note ?? "") }

    var body: some View {
        let row = open.row
        let shown = TransactionDetailPresentation(row)
        PadSidePanel(title: row.description, subtitle: PhoneDateFormat.day(row.date), onClose: onClose, actions: {
            if canEdit {
                PadIconButton(systemImage: "checkmark", label: "Save", prominent: true) { save() }
                    .disabled(!changed || saving)
            }
        }) {
            if let refusal = quickEdit?.refusal { PadRefusalBanner(message: refusal) }
            MoneyText(minorUnits: shown.amount.minorUnits, currency: shown.currency, role: shown.amount.role,
                      fit: .shrink(), font: .title.weight(.semibold))
            Card {
                PadAccountDetailLine(label: "Account", value: shown.account.isEmpty ? "—" : shown.account)
                MangoDivider()
                PadAccountDetailLine(label: "Date", value: PhoneDateFormat.day(row.date))
                MangoDivider()
                categoryRow
                MangoDivider()
                noteRow
                if !tags.isEmpty {
                    MangoDivider()
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { PadStatusPill(text: $0, tone: .neutral) }
                        Spacer(minLength: 0)
                    }
                }
            }
            documents
        }
        .task(id: row.id) { canEdit = await quickEdit?.canEdit(transactionId: row.id) ?? false }
        .task(id: previewId) { await loadPreview() }
    }

    private var tags: [String] {
        var tags: [String] = []
        if let group = quickEdit?.lists.groups.first(where: { $0.id == open.row.category?.groupId }) { tags.append(group.name) }
        if open.row.isLinkedTransfer { tags.append("Transfer") }
        return tags
    }

    @ViewBuilder
    private var categoryRow: some View {
        if canEdit, let quickEdit {
            let sections = CategoryPickerSections.build(categories: quickEdit.lists.categories, groups: quickEdit.lists.groups, suggestedId: nil,
                                                        recentIds: [], amountMinorUnits: nil, query: "", showAll: true)
            HStack {
                Text("Category").mangoFont(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("Category", selection: $categoryId) {
                    Text("Uncategorised").tag(Int64?.none)
                    ForEach(Self.choices(sections), id: \.id) { Text($0.title).tag(Int64?.some($0.id)) }
                }
                .labelsHidden()
                .accessibilityLabel("Category")
            }
            .frame(minHeight: 44)
        } else {
            PadAccountDetailLine(label: "Category", value: open.row.categoryName.isEmpty ? "Uncategorised" : open.row.categoryName)
        }
    }

    private static func choices(_ sections: [CategoryPickerSection]) -> [(id: Int64, title: String)] {
        var found: [(id: Int64, title: String)] = []
        for section in sections {
            for entry in section.entries {
                if case .pick(let id?) = entry.action { found.append((id, entry.title)) }
            }
        }
        return found
    }

    @ViewBuilder
    private var noteRow: some View {
        if canEdit {
            VStack(alignment: .leading, spacing: 4) {
                Text("Note").mangoFont(.subheadline).foregroundStyle(.secondary)
                TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical).lineLimit(1...5).mangoFont(.body)
            }
            .frame(minHeight: 44, alignment: .topLeading)
        } else if let text = TransactionDetailPresentation(open.row).note {
            PadAccountDetailLine(label: "Note", value: text)
        }
    }

    @ViewBuilder
    private var documents: some View {
        if open.documents.isEmpty {
            Text("No document is linked to this transaction.").mangoFont(.callout).foregroundStyle(.secondary)
        } else {
            PadSectionHeader("Documents")
            if let preview {
                DocumentThumbnailView(file: preview.file, onOpen: {}, onRetry: { Task { await preview.retry() } })
            }
            Card {
                ForEach(Array(open.documents.enumerated()), id: \.element.id) { index, document in
                    if index > 0 { MangoDivider() }
                    Button { previewId = document.id } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.displayName).mangoFont(.subheadline, weight: .semibold).lineLimit(1).truncationMode(.middle)
                                Text(document.kindLabel).mangoFont(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if previewId == document.id { Image(systemName: "eye").foregroundStyle(theme.accent).accessibilityLabel("Shown") }
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadPreview() async {
        guard let id = previewId, source != nil else { preview = nil; return }
        let loaded = DocumentPanelModel(documentId: id, source: source)
        preview = loaded
        if loaded.loadNow() { return }
        await loaded.load()
    }

    private func save() {
        guard let quickEdit else { return }
        saving = true
        Task {
            let saved = await quickEdit.save(transactionId: open.row.id, categoryId: categoryId, note: note)
            saving = false
            if saved { onClose() }
        }
    }
}
