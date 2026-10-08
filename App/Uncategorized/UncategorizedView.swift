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
        .searchable(text: $searchText, prompt: "Search descriptions")
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
            transactionRow(transaction).tag(group.selectionId)
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
                    Text(group.key)
                    Text("× \(group.rows.count)").foregroundStyle(.secondary)
                }
                Text(dateRangeText(group))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(minorUnits: ReviewGrouping.total(group.rows.map(\.amountMinorUnits)))
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
                amountMinorUnits: ReviewGrouping.sharedSign(group.rows.map(\.amountMinorUnits))
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

    private func transactionRow(_ transaction: Transaction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.rawDescription)
                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(minorUnits: transaction.amountMinorUnits)
            categoryPicker(for: transaction).frame(width: 200)
        }
    }

    /// A row's own picker. Setting one row (on its own or inside a group) doesn't learn a
    /// rule unless Remember is ticked via Set category… (spec §4).
    private func categoryPicker(for transaction: Transaction) -> some View {
        CategoryPickerButton(
            selection: Binding<Int64?>(
                get: { transaction.categoryId },
                set: { newValue in
                    guard let newValue else { return }
                    viewModel.assignCategory([transaction], to: newValue, remember: { _ in false })
                }
            ),
            categories: viewModel.categories,
            groups: viewModel.categoryGroups,
            suggestedId: nil,
            recentIds: viewModel.recentCategoryIds,
            amountMinorUnits: transaction.amountMinorUnits
        )
    }

    /// Applies one category to every selected row (a selected group = all its rows), with
    /// the "Remember for <key>" toggle in the popover.
    private func setCategoryButton(_ groups: [ReviewGroup<Transaction>]) -> some View {
        let rows = rows(for: selection, in: groups)
        return Button("Set category…") {
            bulkRemember = ReviewGrouping.rememberDefault(rowCount: rows.count)
            showSetCategory = true
        }
        .disabled(rows.isEmpty)
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
                onCancel: { showSetCategory = false }
            )
        }
    }

    private func rememberLabel(for rows: [Transaction]) -> String {
        let keys = Set(rows.map { MerchantKey.make($0.rawDescription) })
        if keys.count == 1, let key = keys.first { return "Remember for \(key)" }
        return "Remember for these \(keys.count) merchants"
    }
}
