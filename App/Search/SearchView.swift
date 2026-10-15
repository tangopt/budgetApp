// App/Search/SearchView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

private typealias Row = TransactionSearch.Row

/// The Search screen (spec 2026-10-15): the search field (⌘F focuses it), the filter bar, a
/// sortable, multi-select table of every matching transaction, and a summary bar with the
/// count and totals plus Set category…. Double-click or the pencil opens Edit transaction;
/// the context menu also has Show in Budget.
struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    /// Show in Budget: the transaction whose category/month cell the Budget grid opens.
    let showInBudget: (Transaction) -> Void

    @FocusState private var searchFocused: Bool
    @State private var selection: Set<Int64> = []
    @State private var editingTransaction: Transaction?
    @State private var showSetCategory = false
    @State private var remember = false
    /// Set category…'s "New category…": the sheet's draft (opened once the popover has
    /// closed) and the rows it will be assigned to.
    @State private var pendingDraft: NewCategoryDraft?
    @State private var newCategoryDraft: NewCategoryDraft?
    @State private var draftIds: [Int64] = []

    private var selectedRows: [Row] {
        viewModel.rows.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField
            SearchFilterBar(viewModel: viewModel)
            if let error = viewModel.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { viewModel.errorMessage = nil }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
            }
            table
            summaryBar
        }
        .padding()
        .onAppear {
            viewModel.load()
            searchFocused = true
        }
        .onChange(of: viewModel.focusRequest) { _, _ in searchFocused = true }
        .onChange(of: viewModel.rows.map(\.id)) { _, ids in
            // A save or a narrower search can drop selected rows.
            selection.formIntersection(ids)
        }
        .sheet(item: $editingTransaction) { transaction in
            EditTransactionSheet(
                transaction: transaction,
                categories: viewModel.categories,
                groups: viewModel.groups,
                recentIds: viewModel.recentCategoryIds,
                createCategory: viewModel.createCategory,
                transfer: viewModel.transferActions,
                manual: viewModel.manualActions,
                onSave: { changes in
                    guard let id = transaction.id else { return .failed("This transaction hasn't been saved yet.") }
                    return viewModel.saveTransactionEdit(id: id, changes: changes)
                }
            )
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search descriptions, notes, categories or an amount", text: $viewModel.queryText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !viewModel.queryText.isEmpty {
                Button { viewModel.queryText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    // MARK: Table

    private var table: some View {
        Table(viewModel.rows, selection: $selection, sortOrder: $viewModel.sortOrder) {
            TableColumn("Date", value: \Row.date) { row in
                Text(SearchFormat.day(row.date)).monospacedDigit()
            }
            .width(min: 90, ideal: 100, max: 120)
            TableColumn("Description", value: \Row.description) { row in
                descriptionCell(row)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Category", value: \Row.categoryName) { row in
                categoryCell(row)
            }
            .width(min: 120, ideal: 180)
            TableColumn("Account", value: \Row.accountName) { row in
                Text(row.accountName).lineLimit(1)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Amount", value: \Row.amountMinorUnits) { row in
                MoneyText(minorUnits: row.amountMinorUnits, currency: row.currency, alignment: .trailing)
            }
            .width(min: 90, ideal: 110, max: 140)
            TableColumn(Text("").accessibilityLabel("Edit")) { row in
                Button { edit(row.id) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit transaction…")
                    .accessibilityLabel("Edit transaction")
            }
            .width(24)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { edit(id) }
        }
        .overlay {
            if viewModel.rows.isEmpty {
                Text(viewModel.criteria.isDefault ? "No transactions yet." : "No transactions match.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func descriptionCell(_ row: Row) -> some View {
        HStack(spacing: 4) {
            Text(row.description).lineLimit(1).truncationMode(.tail)
            if let note = row.transaction.note, !note.isEmpty {
                Image(systemName: "note.text")
                    .foregroundStyle(Color.accentColor)
                    .help(note)
                    .accessibilityLabel("Note: \(note)")
            }
            if row.isLinkedTransfer {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(transferHelp(row))
                    .accessibilityLabel(row.isIncomingTransferLeg ? "Linked transfer, incoming leg" : "Linked transfer")
            }
            if row.transaction.status == .pendingReview {
                Image(systemName: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Not reviewed yet")
                    .accessibilityLabel("Not reviewed yet")
            }
            if row.transaction.isManual { ManualTag() }
        }
    }

    private func transferHelp(_ row: Row) -> String {
        let lines = (viewModel.transferCounterparts[row.id] ?? []).map(TransferFormat.line)
        return (["Transfer between your accounts"] + lines).joined(separator: "\n")
    }

    @ViewBuilder
    private func categoryCell(_ row: Row) -> some View {
        if let category = row.category {
            HStack(spacing: 4) {
                CategoryBadge(category: category, size: .small)
                Text(category.name).lineLimit(1)
            }
        } else {
            Text("Uncategorised").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<Int64>) -> some View {
        if ids.count == 1, let id = ids.first, viewModel.transaction(id: id) != nil {
            Button("Edit Transaction…") { edit(id) }
            // An incoming transfer leg shows its outgoing leg's cell (the money counts as sent).
            let target = viewModel.budgetTransaction(forRowId: id)
            Button("Show in Budget") { if let target { showInBudget(target) } }
                .disabled(target == nil)
        }
        if !ids.isEmpty {
            Button(ids.count == 1 ? "Set Category…" : "Set Category for \(ids.count) Transactions…") {
                selection = ids
                openSetCategory()
            }
        }
    }

    private func edit(_ id: Int64) {
        guard let transaction = viewModel.transaction(id: id) else { return }
        editingTransaction = transaction
    }

    // MARK: Summary bar

    private var summaryBar: some View {
        let totals = viewModel.totals
        return HStack(spacing: 16) {
            Text(totals.count == 1 ? "1 transaction" : "\(totals.count) transactions")
            summaryFigure("In", totals.inMinorUnits)
            summaryFigure("Out", totals.outMinorUnits)
            summaryFigure("Net", totals.netMinorUnits)
            if totals.excludedTransferLegCount > 0 {
                Text("Transfers between your accounts counted once")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("A linked transfer's incoming leg is listed but left out of In and Out, as on the Budget grid. Pick accounts to total their rows as they are.")
            }
            if !selection.isEmpty {
                Text("\(selection.count) selected").foregroundStyle(.secondary)
            }
            Spacer()
            setCategoryButton
        }
        .font(.callout)
    }

    private func summaryFigure(_ label: String, _ minorUnits: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            MoneyText(minorUnits: minorUnits, font: .callout.monospacedDigit())
        }
    }

    // MARK: Set category…

    private func openSetCategory() {
        // On only for one merchant (and not a payment processor's mixed purchases).
        let keys = Set(selectedRows.map { MerchantKey.make($0.description) })
        remember = keys.count == 1 && keys.first.map(ReviewKey.isProcessorGroup) == false
        showSetCategory = true
    }

    private var setCategoryButton: some View {
        let rows = selectedRows
        let sign = ReviewGrouping.sharedSign(rows.map(\.amountMinorUnits))
        return Button("Set category…") { openSetCategory() }
            .disabled(rows.isEmpty)
            .help("Give every selected transaction one category")
            .onChange(of: showSetCategory) { _, presented in
                guard !presented, let draft = pendingDraft else { return }
                pendingDraft = nil
                // A sheet presented while the popover is still closing can fail to appear.
                DispatchQueue.main.async { newCategoryDraft = draft }
            }
            .newCategorySheet(draft: $newCategoryDraft, groups: viewModel.groups, create: viewModel.createCategory) { category in
                guard let id = category.id else { return }
                viewModel.setCategory(ids: draftIds, categoryId: id, remember: remember)
            }
            .popover(isPresented: $showSetCategory, arrowEdge: .top) {
                CategoryPickerPopover(
                    selection: nil,
                    categories: viewModel.categories,
                    groups: viewModel.groups,
                    suggestedId: nil,
                    recentIds: viewModel.recentCategoryIds,
                    amountMinorUnits: sign,
                    remember: $remember,
                    rememberLabel: rememberLabel(for: rows),
                    onPick: { picked in
                        if let picked {
                            viewModel.setCategory(ids: rows.map(\.id), categoryId: picked, remember: remember)
                        }
                        showSetCategory = false
                    },
                    onCancel: { showSetCategory = false },
                    onNewCategory: { name in
                        draftIds = rows.map(\.id)
                        pendingDraft = NewCategoryDraft(name: name, amountMinorUnits: sign)
                        showSetCategory = false
                    }
                )
            }
    }

    private func rememberLabel(for rows: [Row]) -> String {
        let keys = Set(rows.map { MerchantKey.make($0.description) })
        if keys.count == 1, let key = keys.first { return "Remember for \(key)" }
        return "Remember for these \(keys.count) merchants"
    }
}
