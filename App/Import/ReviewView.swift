// App/Import/ReviewView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ReviewView: View {
    @ObservedObject var viewModel: ImportViewModel
    let categories: [Category]
    let onCommitted: () -> Void

    @State private var showUnparsed = true
    @State private var showDuplicates = false
    @State private var isForcing = false
    /// Selected rows and groups (⌘/⇧-click for several); a group means all its rows.
    @State private var selection: Set<ReviewItemId> = []
    @State private var expandedGroups: Set<ReviewItemId> = []
    @State private var showReady = false
    @State private var showSetCategory = false
    @State private var bulkRemember = false

    private var uncategorizedCount: Int {
        viewModel.stagedRows.filter { $0.chosenCategoryId == nil }.count
    }

    var body: some View {
        let sections = viewModel.reviewSections
        VStack(alignment: .leading, spacing: 12) {
            statementBalancesPanel

            if !viewModel.unparsedLines.isEmpty {
                GroupBox {
                    DisclosureGroup(isExpanded: $showUnparsed) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("These lines couldn't be auto-parsed and were not imported. Enter them manually if they're real transactions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(viewModel.unparsedLines.enumerated()), id: \.offset) { _, line in
                                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                            Button("Dismiss") { viewModel.dismissUnparsedLines() }
                        }
                    } label: {
                        Label("\(viewModel.unparsedLines.count) line(s) couldn't be auto-parsed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !viewModel.duplicates.isEmpty {
                GroupBox {
                    DisclosureGroup(isExpanded: $showDuplicates) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Already imported for this account, so skipped. Import them anyway only if they're genuinely separate transactions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(viewModel.duplicates.enumerated()), id: \.offset) { _, duplicate in
                                        HStack {
                                            Text(duplicate.date.formatted(date: .abbreviated, time: .omitted))
                                            Text(duplicate.rawDescription)
                                            Spacer()
                                            MoneyText(minorUnits: duplicate.amountMinorUnits, font: .caption)
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                            .frame(maxHeight: 120)
                            HStack {
                                Button("Import anyway") {
                                    isForcing = true
                                    Task {
                                        await viewModel.forceImportDuplicates()
                                        isForcing = false
                                    }
                                }
                                .disabled(isForcing)
                                Button("Dismiss") { viewModel.dismissDuplicates() }
                            }
                        }
                    } label: {
                        Text("\(viewModel.duplicateCount) duplicate transaction(s) skipped")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            List(selection: $selection) {
                if !sections.needsAttention.isEmpty {
                    Section("Needs your attention (\(sections.needsAttentionCount))") {
                        ForEach(sections.needsAttention) { group in
                            groupContent(group, showInlineConfirm: true)
                        }
                    }
                }
                if !sections.ready.isEmpty {
                    DisclosureGroup("Ready to confirm (\(sections.readyCount))", isExpanded: $showReady) {
                        ForEach(sections.ready) { group in
                            groupContent(group, showInlineConfirm: false)
                        }
                    }
                }
            }
            .frame(minHeight: 240)
            .onKeyPress(.return) {
                // Return confirms a single selected row or group once every row in it has a
                // category, then moves to the first line still showing.
                guard selection.count == 1 else { return .ignored }
                let rows = rows(for: selection, in: sections)
                guard !rows.isEmpty, rows.allSatisfy({ $0.chosenCategoryId != nil }) else { return .ignored }
                // On failure, keep the selection so its error and state stay put.
                guard viewModel.confirmRows(rows) else { return .handled }
                let after = viewModel.reviewSections
                let visible = ReviewGrouping.visibleItems(after.needsAttention, expanded: expandedGroups)
                    + (showReady ? ReviewGrouping.visibleItems(after.ready, expanded: expandedGroups) : [])
                selection = visible.first.map { [$0] } ?? []
                return .handled
            }
            // Confirming (inline, a group, Confirm N ready) removes rows and can turn a group
            // into a single row, so drop selected ids that no longer name a line.
            .onChange(of: viewModel.stagedRows.map(\.id)) { _, _ in
                let selectable = Set(ReviewGrouping.selectableItems(viewModel.reviewSections.all))
                selection.formIntersection(selectable)
                expandedGroups.formIntersection(selectable)
            }

            if uncategorizedCount > 0 {
                Text("\(uncategorizedCount) transaction(s) will be saved as Uncategorized for you to assign later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                setCategoryButton(sections)
                Button("Confirm \(sections.readyCount) ready") {
                    if viewModel.confirmReady() && viewModel.stagedRows.isEmpty {
                        onCommitted()
                    }
                }
                .disabled(sections.ready.isEmpty)
                .keyboardShortcut(.defaultAction)
                // The only way to commit rows with no category picked at all (they can't
                // use Confirm/Confirm-ready) — they're saved as Uncategorized to assign later.
                Button("Save \(viewModel.stagedRows.count) remaining as Uncategorized") {
                    if viewModel.saveRemainingAsUncategorized() { onCommitted() }
                }
                .disabled(viewModel.stagedRows.isEmpty)
                Button("Cancel import", role: .cancel) { viewModel.cancel() }
            }
        }
    }

    @ViewBuilder
    private var statementBalancesPanel: some View {
        switch viewModel.statementBalances {
        case .notProvided:
            EmptyView()
        case .unverified(let reason):
            GroupBox {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Statement balances")
            }
        case .available:
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if let recorded = viewModel.statementBalancesRecorded {
                        Label("Recorded \(recorded.added + recorded.updated) balance snapshot(s)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        if let summary = viewModel.statementBalanceSummary { Text(summary) }
                        Toggle("Record them when I confirm", isOn: $viewModel.recordStatementBalancesOnConfirm)
                        HStack {
                            Button("Record now") { viewModel.recordStatementBalancesNow() }
                            Text("Snapshots on the same dates are replaced.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Statement balances", systemImage: "banknote")
            }
        }
    }

    /// Every staged row the given selection covers, in display order.
    private func rows(for selection: Set<ReviewItemId>, in sections: ReviewSections) -> [ReviewRow] {
        let groups = sections.all
        let ids = ReviewGrouping.selectedRowIds(selection, in: groups)
        let rowsById = Dictionary(uniqueKeysWithValues: groups.flatMap(\.rows).map { ($0.id, $0) })
        return ids.compactMap { rowsById[$0] }
    }

    /// A merchant group of 2+ rows as one disclosable line; a single row as today's row.
    @ViewBuilder
    private func groupContent(_ group: ReviewGroup<ReviewRow>, showInlineConfirm: Bool) -> some View {
        if group.isMultiRow {
            DisclosureGroup(isExpanded: expansion(of: group.id)) {
                ForEach(group.rows) { row in
                    reviewRow(row, showInlineConfirm: showInlineConfirm).tag(ReviewItemId.row(row.id))
                }
            } label: {
                // Selection tags go on row views: the label is the group's outline row.
                groupRow(group, showInlineConfirm: showInlineConfirm).tag(group.id)
            }
        } else if let row = group.rows.first {
            reviewRow(row, showInlineConfirm: showInlineConfirm).tag(group.selectionId)
        }
    }

    private func expansion(of id: ReviewItemId) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
            }
        )
    }

    private func groupRow(_ group: ReviewGroup<ReviewRow>, showInlineConfirm: Bool) -> some View {
        let amounts = group.rows.map(\.staged.parsed.amountMinorUnits)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.key)
                    Text("× \(group.rows.count)").foregroundStyle(.secondary)
                }
                Text(dateRangeText(group))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(minorUnits: ReviewGrouping.total(amounts))
            // One source per row, so the checkbox shows mixed when rows differ (e.g. after one
            // row was changed on its own); clicking it sets them all.
            Toggle("Remember", sources: group.rows.map { row in
                Binding(
                    get: { viewModel.remembers(row, in: group) },
                    set: { viewModel.setRemember($0, forRowIds: [row.id]) }
                )
            }, isOn: \.self)
            .toggleStyle(.checkbox)
            .help("Remember for \(group.key): learn a rule so future \(group.key) transactions get this category")
            groupPicker(for: group).frame(width: 200)
            if showInlineConfirm {
                Button("Confirm") { _ = viewModel.confirmRows(group.rows) }
                    .disabled(group.rows.contains { $0.chosenCategoryId == nil })
            }
        }
    }

    /// Sets every row in the group; shows "Mixed" once a row has been changed on its own.
    private func groupPicker(for group: ReviewGroup<ReviewRow>) -> some View {
        let state = ReviewGrouping.categoryState(of: group.rows.map(\.chosenCategoryId))
        let binding = Binding<Int64?>(
            get: { if case .uniform(let id) = state { return id } else { return nil } },
            set: { newValue in
                viewModel.setCategory(newValue, for: group)
            }
        )
        return CategoryPickerButton(
            selection: binding,
            categories: categories,
            groups: viewModel.categoryGroups,
            suggestedId: sharedSuggestion(group.rows),
            recentIds: viewModel.recentCategoryIds,
            amountMinorUnits: ReviewGrouping.sharedSign(group.rows.map(\.staged.parsed.amountMinorUnits)),
            placeholder: state == .mixed ? "Mixed" : "Choose category"
        )
    }

    private func sharedSuggestion(_ rows: [ReviewRow]) -> Int64? {
        if case .uniform(let id) = ReviewGrouping.categoryState(of: rows.map(\.staged.suggestedCategoryId)) { return id }
        return nil
    }

    /// "1 Oct 2026" or "1 Oct 2026 – 14 Oct 2026".
    private func dateRangeText(_ group: ReviewGroup<ReviewRow>) -> String {
        guard let range = ReviewGrouping.dateRange(group.rows.map(\.staged.parsed.date)) else { return "" }
        let start = range.lowerBound.formatted(date: .abbreviated, time: .omitted)
        let end = range.upperBound.formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) – \(end)"
    }

    /// Applies one category to every selected row (a selected group = all its rows), with
    /// the "Remember for <key>" toggle in the popover.
    private func setCategoryButton(_ sections: ReviewSections) -> some View {
        let rows = rows(for: selection, in: sections)
        return Button("Set category…") {
            bulkRemember = ReviewGrouping.rememberDefault(rowCount: rows.count)
            showSetCategory = true
        }
        .disabled(rows.isEmpty)
        .popover(isPresented: $showSetCategory, arrowEdge: .top) {
            let current = ReviewGrouping.categoryState(of: rows.map(\.chosenCategoryId))
            CategoryPickerPopover(
                selection: { if case .uniform(let id) = current { return id } else { return nil } }(),
                categories: categories,
                groups: viewModel.categoryGroups,
                suggestedId: sharedSuggestion(rows),
                recentIds: viewModel.recentCategoryIds,
                amountMinorUnits: ReviewGrouping.sharedSign(rows.map(\.staged.parsed.amountMinorUnits)),
                remember: $bulkRemember,
                rememberLabel: rememberLabel(for: rows),
                onPick: { picked in
                    viewModel.setCategory(picked, forRowIds: rows.map(\.id), learnRule: bulkRemember)
                    showSetCategory = false
                },
                onCancel: { showSetCategory = false }
            )
        }
    }

    private func rememberLabel(for rows: [ReviewRow]) -> String {
        let keys = Set(rows.map { MerchantKey.make($0.staged.parsed.rawDescription) })
        if keys.count == 1, let key = keys.first { return "Remember for \(key)" }
        return "Remember for these \(keys.count) merchants"
    }

    private func reviewRow(_ row: ReviewRow, showInlineConfirm: Bool) -> some View {
        HStack {
            ConfidenceDot(source: row.staged.source, confidence: row.staged.confidence)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.staged.parsed.rawDescription)
                Text(detailLine(for: row))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(minorUnits: row.staged.parsed.amountMinorUnits)
            categoryPicker(for: row).frame(width: 200)
            if showInlineConfirm {
                Button("Confirm") { _ = viewModel.confirmRow(row) }
                    .disabled(row.chosenCategoryId == nil)
            }
        }
    }

    /// A row's own picker. Setting one row (on its own or inside a group) doesn't learn a
    /// rule unless Remember is ticked via Set category… (spec §4).
    private func categoryPicker(for row: ReviewRow) -> some View {
        let binding = Binding<Int64?>(
            get: { row.chosenCategoryId },
            set: { newValue in viewModel.setCategory(newValue, forRowIds: [row.id], learnRule: false) }
        )
        return CategoryPickerButton(
            selection: binding,
            categories: categories,
            groups: viewModel.categoryGroups,
            suggestedId: row.staged.suggestedCategoryId,
            recentIds: viewModel.recentCategoryIds,
            amountMinorUnits: row.staged.parsed.amountMinorUnits
        )
    }

    /// "1 Oct 2026 · Suggested from 3 past transactions" for history suggestions.
    private func detailLine(for row: ReviewRow) -> String {
        let date = row.staged.parsed.date.formatted(date: .abbreviated, time: .omitted)
        guard row.staged.source == .history, let count = row.staged.historyCount else { return date }
        return "\(date) · Suggested from \(count) past transaction\(count == 1 ? "" : "s")"
    }
}
