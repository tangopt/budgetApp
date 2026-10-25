// App/Uncategorized/UncategorizedView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

private typealias ItemId = ReviewSelectionId<Int64?>

struct UncategorizedView: View {
    @ObservedObject var viewModel: UncategorizedViewModel
    @State private var searchText = ""
    /// Selected rows and groups (⌘/⇧-click for several); a group means all its rows.
    @State private var selection: Set<ItemId> = []
    @State private var expandedGroups: Set<ItemId> = []
    @State private var showSetCategory = false
    @State private var bulkRemember = false
    /// Set category…'s "New category…": the sheet's draft, opened once the popover has
    /// closed, and the rows it will be assigned to.
    @State private var pendingBulkDraft: NewCategoryDraft?
    @State private var bulkDraft: NewCategoryDraft?
    @State private var bulkDraftRows: [Transaction] = []

    /// `viewModel.transactions` filtered by a case-insensitive substring match against
    /// `rawDescription`. An empty `searchText` (the default) matches everything, so
    /// existing behavior is unchanged until the user actually types.
    private var filteredTransactions: [Transaction] {
        guard !searchText.isEmpty else { return viewModel.transactions }
        return viewModel.transactions.filter { $0.rawDescription.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        let groups = viewModel.groups(of: filteredTransactions)
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Group {
                if viewModel.transactions.isEmpty {
                    VStack(spacing: 8) {
                        Text("Nothing uncategorized").font(.headline)
                        Text("Every committed transaction has a category. If you expected something here, check Import.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        ForEach(groups) { group in
                            groupContent(group)
                        }
                    }
                    .wrapProbeClips()
                    // Assigning removes rows and can turn a group into a single row, so drop
                    // selected ids that no longer name a line.
                    .onChange(of: viewModel.transactions.map(\.id)) { _, _ in
                        let selectable = Set(ReviewGrouping.selectableItems(viewModel.groups(of: viewModel.transactions)))
                        selection.formIntersection(selectable)
                        expandedGroups.formIntersection(selectable)
                    }
                }
            }
            HStack {
                setCategoryButton(groups)
                Spacer()
            }
        }
        .padding()
        .screenSearchable(text: $searchText, prompt: "Search descriptions")
        .filedYearQuestion($viewModel.filedYearQuestion)
    }

    /// Every transaction the given selection covers, in display order.
    private func rows(for selection: Set<ItemId>, in groups: [ReviewGroup<Transaction>]) -> [Transaction] {
        let ids = ReviewGrouping.selectedRowIds(selection, in: groups)
        let rowsById = Dictionary(groups.flatMap(\.rows).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { rowsById[$0] }
    }

    /// A merchant group of 2+ rows as one disclosable line; a single row as today's row.
    @ViewBuilder
    private func groupContent(_ group: ReviewGroup<Transaction>) -> some View {
        if group.isMultiRow {
            DisclosureGroup(isExpanded: expansion(of: group.id)) {
                ForEach(group.rows) { transaction in
                    transactionRow(transaction).tag(ItemId.row(transaction.id))
                }
            } label: {
                // Selection tags go on row views: the label is the group's outline row.
                groupRow(group).tag(group.id)
            }
        } else if let transaction = group.rows.first {
            transactionRow(transaction, singleRowGroup: group).tag(group.selectionId)
        }
    }

    private func expansion(of id: ItemId) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
            }
        )
    }

    private func groupRow(_ group: ReviewGroup<Transaction>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // The name gives way; the count and the days never wrap.
                    Text(group.key).lineLimit(1)
                    Text("× \(group.rows.count)").foregroundStyle(.secondary).figureText()
                }
                Text(dateRangeText(group))
                    .font(.caption).foregroundStyle(.secondary)
                    .figureText()
            }
            Spacer()
            let total = viewModel.groupTotal(group.rows)
            MoneyText(minorUnits: total.minorUnits, currency: total.currency)
            // One source per row, so the checkbox shows mixed when rows differ; clicking it
            // sets them all.
            Toggle("Remember", sources: group.rows.map { row in
                Binding(
                    get: { viewModel.remembers(row, in: group) },
                    set: { viewModel.setRemember($0, for: row) }
                )
            }, isOn: \.self)
            .toggleStyle(.checkbox)
            .help("Remember for \(group.key): learn a rule so future \(group.key) transactions get this category")
            // Picking assigns the whole group, learning a rule for each row whose Remember is ticked.
            CategoryPickerButton(
                selection: Binding<Int64?>(
                    get: { nil },
                    set: { newValue in
                        guard let newValue else { return }
                        viewModel.assignCategory(group.rows, to: newValue, remember: { viewModel.remembers($0, in: group) })
                    }
                ),
                categories: viewModel.categories,
                groups: viewModel.categoryGroups,
                suggestedId: nil,
                recentIds: viewModel.recentCategoryIds,
                amountMinorUnits: ReviewGrouping.sharedSign(group.rows.map(\.amountMinorUnits)),
                createCategory: viewModel.createCategory
            )
            .frame(width: 200)
        }
    }

    /// "1 Oct 2026" or "1 Oct 2026 – 14 Oct 2026".
    private func dateRangeText(_ group: ReviewGroup<Transaction>) -> String {
        guard let range = ReviewGrouping.dateRange(group.rows.map(\.date)) else { return "" }
        let start = range.lowerBound.formatted(date: .abbreviated, time: .omitted)
        let end = range.upperBound.formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) – \(end)"
    }

    /// A row on its own (`singleRowGroup` set: it gets its own Remember checkbox, spec §3)
    /// or inside an expanded group (whose line holds the checkbox).
    private func transactionRow(_ transaction: Transaction, singleRowGroup: ReviewGroup<Transaction>? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.rawDescription)
                HStack(spacing: 4) {
                    Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .figureText()
                    if transaction.isManual { ManualTag() }
                }
            }
            Spacer()
            MoneyText(minorUnits: transaction.amountMinorUnits, currency: viewModel.conversion.currency(ofAccount: transaction.accountId))
            NoteButton(note: transaction.note) { viewModel.setNote($0, for: transaction) }
            if let group = singleRowGroup {
                Toggle("Remember", isOn: Binding(
                    get: { viewModel.remembers(transaction, in: group) },
                    set: { viewModel.setRemember($0, for: transaction) }
                ))
                .toggleStyle(.checkbox)
                .help("Remember for \(group.key): learn a rule so future \(group.key) transactions get this category")
            }
            categoryPicker(for: transaction, singleRowGroup: singleRowGroup).frame(width: 200)
        }
    }

    /// A row's own picker, which assigns at once. A single row learns a rule unless its
    /// Remember checkbox (on by default, spec §3) was unticked first; a row set on its own
    /// inside a group doesn't — use the group or Set category….
    private func categoryPicker(for transaction: Transaction, singleRowGroup: ReviewGroup<Transaction>?) -> some View {
        CategoryPickerButton(
            selection: Binding<Int64?>(
                get: { transaction.categoryId },
                set: { newValue in
                    guard let newValue else { return }
                    let remember = singleRowGroup.map { viewModel.remembers(transaction, in: $0) } ?? false
                    viewModel.assignCategory([transaction], to: newValue, remember: { _ in remember })
                }
            ),
            categories: viewModel.categories,
            groups: viewModel.categoryGroups,
            suggestedId: nil,
            recentIds: viewModel.recentCategoryIds,
            amountMinorUnits: transaction.amountMinorUnits,
            createCategory: viewModel.createCategory
        )
    }

    /// Applies one category to every selected row (a selected group = all its rows), with
    /// the "Remember for <key>" toggle in the popover.
    private func setCategoryButton(_ groups: [ReviewGroup<Transaction>]) -> some View {
        let rows = rows(for: selection, in: groups)
        return Button("Set category…") {
            // One processor group's purchases default off; otherwise on (spec §3).
            let keys = Set(rows.compactMap { row in groups.first { $0.rows.contains { $0.id == row.id } }?.key })
            let isProcessorGroup = keys.count == 1 && keys.first.map(ReviewKey.isProcessorGroup) == true
            bulkRemember = ReviewGrouping.rememberDefault(rowCount: rows.count, isProcessorGroup: isProcessorGroup)
            showSetCategory = true
        }
        .disabled(rows.isEmpty)
        .onChange(of: showSetCategory) { _, presented in
            guard !presented, let draft = pendingBulkDraft else { return }
            pendingBulkDraft = nil
            // A sheet presented while the popover is still closing can fail to appear.
            DispatchQueue.main.async { bulkDraft = draft }
        }
        .newCategorySheet(draft: $bulkDraft, groups: viewModel.categoryGroups, create: viewModel.createCategory) { category in
            guard let id = category.id else { return }
            let remember = bulkRemember
            viewModel.assignCategory(bulkDraftRows, to: id, remember: { _ in remember })
        }
        .popover(isPresented: $showSetCategory, arrowEdge: .top) {
            CategoryPickerPopover(
                selection: nil,
                categories: viewModel.categories,
                groups: viewModel.categoryGroups,
                suggestedId: nil,
                recentIds: viewModel.recentCategoryIds,
                amountMinorUnits: ReviewGrouping.sharedSign(rows.map(\.amountMinorUnits)),
                remember: $bulkRemember,
                rememberLabel: rememberLabel(for: rows),
                onPick: { picked in
                    if let picked {
                        let remember = bulkRemember
                        viewModel.assignCategory(rows, to: picked, remember: { _ in remember })
                    }
                    showSetCategory = false
                },
                onCancel: { showSetCategory = false },
                onNewCategory: { name in
                    bulkDraftRows = rows
                    pendingBulkDraft = NewCategoryDraft(name: name, amountMinorUnits: ReviewGrouping.sharedSign(rows.map(\.amountMinorUnits)))
                    showSetCategory = false
                }
            )
        }
    }

    private func rememberLabel(for rows: [Transaction]) -> String {
        let keys = Set(rows.map { MerchantKey.make($0.rawDescription) })
        if keys.count == 1, let key = keys.first { return "Remember for \(key)" }
        return "Remember for these \(keys.count) merchants"
    }
}
