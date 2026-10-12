// App/Import/ReviewView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ReviewView: View {
    @ObservedObject var viewModel: ImportViewModel
    let onCommitted: () -> Void

    @State private var showUnparsed = true
    @State private var showDuplicates = false
    @State private var isForcing = false
    /// The list on show (spec §7); settled whenever the row counts change.
    @State private var tab: ReviewTab = .needsAttention
    /// Each tab's selected rows and groups (⌘/⇧-click for several); a group means all its
    /// rows. Confirmed lines aren't selectable, so that tab never has one.
    @State private var selections: [ReviewTab: Set<ReviewItemId>] = [:]
    /// Group ids carry their tab's scope, so one set serves every tab.
    @State private var expandedGroups: Set<ReviewItemId> = []
    @State private var showSetCategory = false
    @State private var bulkRemember = false
    /// Set category…'s "New category…": the sheet's draft, opened once the popover has
    /// closed, and the rows it will be applied to.
    @State private var pendingBulkDraft: NewCategoryDraft?
    @State private var bulkDraft: NewCategoryDraft?
    @State private var bulkDraftRowIds: [UUID] = []
    @State private var showFinishChoice = false
    @State private var showCancelConfirmation = false

    private var categories: [Category] { viewModel.categories }

    var body: some View {
        let sections = viewModel.reviewSections
        // Only the transactions list scrolls: the notices, status and actions above it are
        // pinned, and the expanded notice lists scroll inside their own bounded height.
        VStack(alignment: .leading, spacing: 12) {
            Group {
                header
                tabBar(sections)
            }
            // Sized before the list, which then takes whatever height is left.
            .layoutPriority(1)
            transactionList(sections)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Opens on Needs your attention (or Ready to confirm if that's empty), and leaves
        // a tab that empties for the next one with rows.
        .onAppear { tab = .settled(current: tab, rowCounts: sections.rowCounts) }
        .onChange(of: sections.rowCounts) { _, counts in tab = .settled(current: tab, rowCounts: counts) }
    }

    /// The notices, then the caption, error and action buttons.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Exactly as tall as the notices when they fit; capped and scrollable when
            // they don't, so the transactions list keeps its minimum.
            BoundedScroll(maxHeight: Self.noticesMaxHeight) { notices }
            actions
        }
    }

    /// Statement balances, unparsed lines and duplicates.
    private var notices: some View {
        VStack(alignment: .leading, spacing: 12) {
            statementBalancesPanel

            if !viewModel.unparsedLines.isEmpty {
                GroupBox {
                    DisclosureGroup(isExpanded: $showUnparsed) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("These lines couldn't be auto-parsed and were not imported. Enter them manually if they're real transactions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            BoundedScroll(maxHeight: Self.noticeListMaxHeight) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(viewModel.unparsedLines.enumerated()), id: \.offset) { _, line in
                                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
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
                            BoundedScroll(maxHeight: Self.noticeListMaxHeight) {
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
        }
    }

    /// The progress caption, any error and the action buttons.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progressCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel import", role: .cancel) {
                    if viewModel.confirmedCount > 0 { showCancelConfirmation = true } else { viewModel.cancel() }
                }
                .confirmationDialog("Discard this import?", isPresented: $showCancelConfirmation) {
                    Button("Discard \(viewModel.confirmedCount) confirmed", role: .destructive) { viewModel.cancel() }
                    Button("Keep reviewing", role: .cancel) {}
                } message: {
                    Text("Nothing from \(viewModel.confirmedCount == 1 ? "this transaction" : "these transactions") has been saved yet.")
                }
                // The only button that writes anything: one commit for the whole review.
                // ⌘Return, not Return, which stays with Return-to-confirm on a selected line.
                Button("Finish import") {
                    if viewModel.unconfirmedCount > 0 {
                        showFinishChoice = true
                    } else if viewModel.finish(unconfirmed: .leaveOut) {
                        onCommitted()
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .confirmationDialog(finishChoiceTitle, isPresented: $showFinishChoice) {
                    Button("Save \(viewModel.unconfirmedCount) unconfirmed as Uncategorized") {
                        if viewModel.finish(unconfirmed: .saveAsUncategorized) { onCommitted() }
                    }
                    if viewModel.confirmedCount > 0 {
                        Button("Leave them out") {
                            if viewModel.finish(unconfirmed: .leaveOut) { onCommitted() }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(finishChoiceMessage)
                }
            }
        }
    }

    private static let noticeListMaxHeight: CGFloat = 160
    private static let noticesMaxHeight: CGFloat = 220

    private var finishChoiceMessage: String {
        var lines = ["Unconfirmed transactions keep a category if you chose one; the rest go to Uncategorized to assign later."]
        if viewModel.confirmedCount > 0 {
            lines.append("Left-out transactions are imported again next time.")
            if viewModel.recordStatementBalancesOnConfirm, case .available = viewModel.statementBalances {
                lines.append("The statement balances are recorded either way.")
            }
        }
        return lines.joined(separator: " ")
    }

    /// The three lists' tabs with their row counts, then the current tab's actions.
    private func tabBar(_ sections: ReviewSections) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("List", selection: $tab) {
                ForEach(ReviewTab.allCases, id: \.self) { tab in
                    Text("\(Self.title(of: tab)) (\(sections.rowCounts[tab] ?? 0))").tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                // Always present (disabled on Confirmed) so its popover and New category…
                // sheet survive a tab switch.
                setCategoryButton(sections)
                if tab == .ready {
                    // Only marks rows confirmed; deliberately no Return shortcut.
                    Button("Confirm all") { viewModel.confirmReady() }
                        .disabled(sections.ready.isEmpty)
                }
            }
        }
    }

    private static func title(of tab: ReviewTab) -> String {
        switch tab {
        case .needsAttention: return "Needs your attention"
        case .ready: return "Ready to confirm"
        case .confirmed: return "Confirmed"
        }
    }

    private func selection(in tab: ReviewTab) -> Binding<Set<ReviewItemId>> {
        Binding(get: { selections[tab] ?? [] }, set: { selections[tab] = $0 })
    }

    /// The current tab's list: its own List (`.id`), so each tab keeps a separate
    /// selection and scroll position starts fresh on a switch.
    @ViewBuilder
    private func transactionList(_ sections: ReviewSections) -> some View {
        let groups = sections.groups(in: tab)
        Group {
            if groups.isEmpty {
                Text(Self.emptyMessage(for: tab))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == .confirmed {
                // No selection: confirmed lines only offer Undo.
                List {
                    ForEach(groups) { group in confirmedGroupContent(group) }
                }
            } else {
                List(selection: selection(in: tab)) {
                    ForEach(groups) { group in groupContent(group) }
                }
                .onKeyPress(.return) { confirmSelection() }
            }
        }
        .id(tab)
        // Takes the height the pinned header leaves; it scrolls, the page doesn't.
        .frame(minHeight: 160, maxHeight: .infinity)
        // Confirming (inline, a group, Return, Confirm all) moves rows to Confirmed and
        // Undo moves them back, which can turn a group into a single row, so drop
        // selected ids that no longer name a line in their tab.
        .onChange(of: viewModel.stagedRows.map(\.id)) { _, _ in pruneSelection() }
        .onChange(of: viewModel.confirmedIds) { _, _ in pruneSelection() }
    }

    private static func emptyMessage(for tab: ReviewTab) -> String {
        switch tab {
        case .needsAttention: return "Nothing needs your attention."
        case .ready: return "Nothing is ready to confirm."
        case .confirmed: return "Nothing confirmed yet."
        }
    }

    /// Return confirms the current tab's single selected row or group once every row in
    /// it has a category, then selects the first line still showing in that tab.
    private func confirmSelection() -> KeyPress.Result {
        let selection = selections[tab] ?? []
        guard selection.count == 1 else { return .ignored }
        let rows = rows(for: selection, in: viewModel.reviewSections.groups(in: tab))
        guard !rows.isEmpty, rows.allSatisfy({ $0.chosenCategoryId != nil }) else { return .ignored }
        viewModel.confirmRows(rows)
        let visible = ReviewGrouping.visibleItems(viewModel.reviewSections.groups(in: tab), expanded: expandedGroups)
        selections[tab] = visible.first.map { [$0] } ?? []
        return .handled
    }

    private func pruneSelection() {
        let sections = viewModel.reviewSections
        for tab in ReviewTab.allCases {
            selections[tab]?.formIntersection(Set(ReviewGrouping.selectableItems(sections.groups(in: tab))))
        }
        expandedGroups.formIntersection(Set(ReviewGrouping.selectableItems(sections.all + sections.confirmed)))
    }

    private var finishChoiceTitle: String {
        let unconfirmed = viewModel.unconfirmedCount
        let rows = unconfirmed == 1 ? "1 transaction isn't" : "\(unconfirmed) transactions aren't"
        return "\(rows) confirmed yet"
    }

    /// What Finish import will save, kept in view since confirming no longer saves.
    private var progressCaption: String {
        let confirmed = viewModel.confirmedCount
        let unconfirmed = viewModel.unconfirmedCount
        if confirmed == 0 && unconfirmed == 0 { return "No transactions to save — Finish import ends this review." }
        return "\(confirmed) confirmed, \(unconfirmed) still to review. Nothing is saved until you finish the import."
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
                    if let summary = viewModel.statementBalanceSummary { Text(summary) }
                    // Recorded by Finish import, with the transactions — never before.
                    Toggle("Record them when I finish the import", isOn: $viewModel.recordStatementBalancesOnConfirm)
                    Text("Snapshots on the same dates are replaced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Statement balances", systemImage: "banknote")
            }
        }
    }

    /// Every row of these groups (one tab's) the selection covers, in display order.
    private func rows(for selection: Set<ReviewItemId>, in groups: [ReviewGroup<ReviewRow>]) -> [ReviewRow] {
        let ids = ReviewGrouping.selectedRowIds(selection, in: groups)
        let rowsById = Dictionary(uniqueKeysWithValues: groups.flatMap(\.rows).map { ($0.id, $0) })
        return ids.compactMap { rowsById[$0] }
    }

    /// A merchant group of 2+ rows as one disclosable line; a single row as today's row.
    @ViewBuilder
    private func groupContent(_ group: ReviewGroup<ReviewRow>) -> some View {
        if group.isMultiRow {
            DisclosureGroup(isExpanded: expansion(of: group.id)) {
                ForEach(group.rows) { row in
                    reviewRow(row).tag(ReviewItemId.row(row.id))
                }
            } label: {
                // Selection tags go on row views: the label is the group's outline row.
                groupRow(group).tag(group.id)
            }
        } else if let row = group.rows.first {
            reviewRow(row, singleRowGroup: group).tag(group.selectionId)
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

    private func groupRow(_ group: ReviewGroup<ReviewRow>) -> some View {
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
            Button("Confirm") { viewModel.confirmRows(group.rows) }
                .disabled(group.rows.contains { $0.chosenCategoryId == nil })
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
            placeholder: state == .mixed ? "Mixed" : "Choose category",
            createCategory: viewModel.createCategory
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

    /// Applies one category to every row selected in the current tab (a selected group =
    /// all its rows), with the "Remember for <key>" toggle in the popover.
    private func setCategoryButton(_ sections: ReviewSections) -> some View {
        let rows = rows(for: selections[tab] ?? [], in: sections.groups(in: tab))
        return Button("Set category…") {
            bulkRemember = viewModel.setCategoryRememberDefault(for: rows)
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
            viewModel.setCategory(category.id, forRowIds: bulkDraftRowIds, learnRule: bulkRemember)
        }
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
                onCancel: { showSetCategory = false },
                onNewCategory: { name in
                    bulkDraftRowIds = rows.map(\.id)
                    pendingBulkDraft = NewCategoryDraft(name: name, amountMinorUnits: ReviewGrouping.sharedSign(rows.map(\.staged.parsed.amountMinorUnits)))
                    showSetCategory = false
                }
            )
        }
    }

    private func rememberLabel(for rows: [ReviewRow]) -> String {
        let keys = Set(rows.map { MerchantKey.make($0.staged.parsed.rawDescription) })
        if keys.count == 1, let key = keys.first { return "Remember for \(key)" }
        return "Remember for these \(keys.count) merchants"
    }

    /// A confirmed group or row: dimmed, with its category and an Undo that returns it to
    /// its unconfirmed tab (category kept). Not selectable (its List has no selection).
    @ViewBuilder
    private func confirmedGroupContent(_ group: ReviewGroup<ReviewRow>) -> some View {
        if group.isMultiRow {
            DisclosureGroup(isExpanded: expansion(of: group.id)) {
                ForEach(group.rows) { row in confirmedRow(row) }
            } label: {
                HStack {
                    Text(group.key)
                    Text("× \(group.rows.count)").foregroundStyle(.secondary)
                    Spacer()
                    MoneyText(minorUnits: ReviewGrouping.total(group.rows.map(\.staged.parsed.amountMinorUnits)))
                    Text(categoryText(ReviewGrouping.categoryState(of: group.rows.map(\.chosenCategoryId))))
                        .frame(width: 200, alignment: .leading)
                    Button("Undo") { viewModel.unconfirmRows(group.rows) }
                        .help("Back to review")
                }
                .foregroundStyle(.secondary)
            }
        } else if let row = group.rows.first {
            confirmedRow(row)
        }
    }

    private func confirmedRow(_ row: ReviewRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.staged.parsed.rawDescription)
                Text(row.staged.parsed.date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
            }
            Spacer()
            MoneyText(minorUnits: row.staged.parsed.amountMinorUnits)
            Text(categoryText(.uniform(row.chosenCategoryId)))
                .frame(width: 200, alignment: .leading)
            Button("Undo") { viewModel.unconfirmRows([row]) }
                .help("Back to review")
        }
        .foregroundStyle(.secondary)
    }

    private func categoryText(_ state: ReviewCategoryState) -> String {
        switch state {
        case .mixed: return "Mixed"
        case .uniform(nil): return "Uncategorized"
        case .uniform(let id?): return categories.first { $0.id == id }?.name ?? "Uncategorized"
        }
    }

    /// A row on its own (`singleRowGroup` set: it gets its own Remember checkbox, spec §3)
    /// or inside an expanded group (whose line holds the checkbox).
    private func reviewRow(_ row: ReviewRow, singleRowGroup: ReviewGroup<ReviewRow>? = nil) -> some View {
        HStack {
            ConfidenceDot(source: row.staged.source, confidence: row.staged.confidence)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.staged.parsed.rawDescription)
                Text(detailLine(for: row))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(minorUnits: row.staged.parsed.amountMinorUnits)
            NoteButton(note: row.note) { viewModel.setNote($0, forRowId: row.id) }
            if let group = singleRowGroup {
                Toggle("Remember", isOn: Binding(
                    get: { viewModel.remembers(row, in: group) },
                    set: { viewModel.setRemember($0, forRowIds: [row.id]) }
                ))
                .toggleStyle(.checkbox)
                .help("Remember for \(group.key): learn a rule so future \(group.key) transactions get this category")
            }
            categoryPicker(for: row, isSingleRow: singleRowGroup != nil).frame(width: 200)
            Button("Confirm") { viewModel.confirmRow(row) }
                .disabled(row.chosenCategoryId == nil)
        }
    }

    /// A row's own picker. A single row keeps its Remember checkbox's value (spec §3); a
    /// row set on its own inside a group doesn't learn a rule unless Remember is ticked via
    /// Set category….
    private func categoryPicker(for row: ReviewRow, isSingleRow: Bool) -> some View {
        let binding = Binding<Int64?>(
            get: { row.chosenCategoryId },
            set: { newValue in
                if isSingleRow {
                    viewModel.setCategory(newValue, forRowIds: [row.id], learnRule: row.learnRule)
                } else {
                    viewModel.setCategory(newValue, forRowIds: [row.id], learnRule: false)
                }
            }
        )
        return CategoryPickerButton(
            selection: binding,
            categories: categories,
            groups: viewModel.categoryGroups,
            suggestedId: row.staged.suggestedCategoryId,
            recentIds: viewModel.recentCategoryIds,
            amountMinorUnits: row.staged.parsed.amountMinorUnits,
            createCategory: viewModel.createCategory
        )
    }

    /// "1 Oct 2026 · Suggested from 3 past transactions" for history suggestions.
    private func detailLine(for row: ReviewRow) -> String {
        let date = row.staged.parsed.date.formatted(date: .abbreviated, time: .omitted)
        guard row.staged.source == .history, let count = row.staged.historyCount else { return date }
        return "\(date) · Suggested from \(count) past transaction\(count == 1 ? "" : "s")"
    }
}

/// A vertical scroll view that is exactly as tall as its content up to `maxHeight`, then
/// scrolls. (A bare ScrollView takes all the height offered, leaving a gap under short content.)
struct BoundedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(contentHeight, maxHeight))
    }
}
