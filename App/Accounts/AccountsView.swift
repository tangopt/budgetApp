// App/Accounts/AccountsView.swift
import SwiftUI
import Charts
import Combine
import BudgetCore

/// Net worth and accounts on one screen: header total, banners, accounts grouped by kind
/// on the left, the selected account's detail and balance history on the right.
struct AccountsView: View {
    @ObservedObject var viewModel: AccountsViewModel
    @ObservedObject var environment: AppEnvironment
    @Environment(\.theme) private var theme
    /// Import statement's CSV…/PDF… and Edit column mapping… are shortcuts into the window's
    /// importer (the review is on the Imports screen); the saved mapping and layout are reset here.
    let profileStore: ImportProfileStore
    let navigate: (AppScreen) -> Void
    @State private var activeSheet: AccountsSheet?
    /// The formats the selected account has a saved import profile for.
    @State private var savedProfiles: Set<ImportFormat> = []
    /// The format whose saved mapping/layout the reset alert is asking about.
    @State private var pendingReset: ImportFormat?
    @State private var resetError: String?
    /// The account list's width, dragged on its divider and remembered between launches.
    @AppStorage("accounts.listWidth") private var listWidth: Double = 560
    /// `listWidth` when a divider drag began; nil when not dragging.
    @State private var dragStartWidth: Double?
    /// The list-and-detail row's width, which bounds the list's.
    @State private var availableWidth: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let overview = viewModel.overview, !viewModel.accounts.isEmpty {
                header(overview)
                banners(overview)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        AccountsListView(groups: overview.groups, selection: $viewModel.selectedAccountId,
                                         importedThrough: viewModel.importedThrough,
                                         onAddTransaction: addTransaction(in:), onSetMain: { viewModel.setMain($0) },
                                         onSetIncludeInNetWorth: { viewModel.setIncludeInNetWorth($0, $1) }) { group, from, to in
                            viewModel.moveAccounts(ids: group.rows.map(\.id), fromOffsets: from, toOffset: to)
                        }
                        footer
                    }
                    // The dragged width, kept between the list's minimum and what leaves the
                    // detail its own; the detail takes the rest.
                    .frame(width: effectiveListWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    listDivider
                    detail
                        .frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .onGeometryChange(for: Double.self) { $0.size.width } action: { availableWidth = $0 }
            } else {
                commonBanners
                // Only claim "no accounts" once a load has succeeded; a failed first load
                // shows just its error banner.
                if viewModel.overview != nil {
                    emptyState
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: viewModel.selectedAccountId) { refreshSavedProfiles() }
        // A confirmed import may have saved a mapping or layout (mapped in its review).
        // Only when an import ends (not on every reading-progress tick).
        .onReceive(environment.importCenter.$phase.filter { phase in
            switch phase {
            case .finished, .idle: return true
            default: return false
            }
        }.removeDuplicates()) { _ in refreshSavedProfiles() }
        .alert(resetTitle, isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } })) {
            Button("Cancel", role: .cancel) { pendingReset = nil }
            Button("Reset", role: .destructive) { resetProfile() }
        } message: {
            Text(pendingReset == .pdf
                 ? "The next PDF import asks you to set up its layout again."
                 : "The next CSV import asks you to map its columns again.")
        }
        .alert("Couldn't reset", isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
            Button("OK", role: .cancel) { resetError = nil }
        } message: {
            Text(resetError ?? "")
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                AddAccountSheet(viewModel: viewModel)
            case .edit(let account):
                EditAccountSheet(viewModel: viewModel, account: account)
            case .updateOne(let row):
                UpdateBalanceSheet(viewModel: viewModel, row: row)
            case .updateAll(let groups):
                UpdateBalancesSheet(viewModel: viewModel, groups: groups)
            case .addTransaction(let accountId):
                AddTransactionSheet(
                    accounts: viewModel.accounts,
                    accountId: accountId,
                    categories: viewModel.categories,
                    groups: viewModel.categoryGroups,
                    recentIds: viewModel.recentCategoryIds,
                    createCategory: viewModel.createCategory,
                    onSave: viewModel.addTransaction
                )
            }
        }
    }

    // MARK: Resizable list

    private static let listMinWidth: Double = 380
    private static let listMaxWidth: Double = 760
    private static let detailMinWidth: Double = 300
    /// The divider's hit area (the gap between the list and the detail).
    private static let dividerWidth: Double = 16

    /// The widest the list can be in the current window.
    private var listUpperBound: Double {
        let fits = availableWidth > 0 ? availableWidth - Self.dividerWidth - Self.detailMinWidth : Self.listMaxWidth
        return max(Self.listMinWidth, min(Self.listMaxWidth, fits))
    }

    private var effectiveListWidth: Double {
        min(max(listWidth, Self.listMinWidth), listUpperBound)
    }

    /// The draggable gap between the list and the detail: a column-resize pointer, and an
    /// accent line while dragged.
    private var listDivider: some View {
        Rectangle()
            .fill(dragStartWidth == nil ? Color.secondary.opacity(0.25) : theme.accent.opacity(0.6))
            .frame(width: dragStartWidth == nil ? 1 : 2)
            .frame(width: Self.dividerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? effectiveListWidth
                        if dragStartWidth == nil { dragStartWidth = start }
                        listWidth = min(max(start + value.translation.width, Self.listMinWidth), listUpperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .help("Drag to resize the account list")
            .accessibilityHidden(true)
    }

    private var detail: some View {
        AccountDetailView(
            row: viewModel.selectedRow,
            importedThrough: viewModel.selectedRow.flatMap { viewModel.importedThrough[$0.id] },
            history: viewModel.selectedHistory,
            importCenter: environment.importCenter,
            savedProfiles: savedProfiles,
            onUpdateBalance: { activeSheet = .updateOne($0) },
            onEdit: { activeSheet = .edit($0.account) },
            onAddTransaction: { addTransaction(in: $0.id) },
            onReset: { pendingReset = $0 },
            onResumeReview: { navigate(.imports) }
        )
    }

    // MARK: Saved mapping and layout

    private func refreshSavedProfiles() {
        guard let accountId = viewModel.selectedRow?.account.id else { savedProfiles = []; return }
        savedProfiles = Set([ImportFormat.csv, .pdf].filter { (try? profileStore.find(accountId: accountId, format: $0)) != nil })
    }

    private var resetTitle: String {
        let name = viewModel.selectedRow?.account.displayName ?? "this account"
        return pendingReset == .pdf ? "Reset the PDF layout for \(name)?" : "Reset the column mapping for \(name)?"
    }

    /// Deletes the selected account's saved mapping or layout (`ImportProfileStore.delete`).
    private func resetProfile() {
        guard let format = pendingReset else { return }
        pendingReset = nil
        guard let accountId = viewModel.selectedRow?.account.id else { return }
        do {
            _ = try profileStore.delete(accountId: accountId, format: format)
        } catch {
            resetError = "Couldn't reset the \(format == .pdf ? "PDF layout" : "column mapping"): \(error.localizedDescription)"
        }
        refreshSavedProfiles()
    }

    /// Add transaction… for an account (its row's menu, or the detail's button).
    private func addTransaction(in accountId: Int64) {
        viewModel.prepareAddTransaction()
        activeSheet = .addTransaction(accountId)
    }

    // MARK: Header

    private func header(_ overview: AccountsOverview) -> some View {
        HStack(alignment: .top) {
            headerTotals(overview)
            Spacer()
            Button("Update balances…") { activeSheet = .updateAll(overview.groups) }
            Button("+ Add account") { activeSheet = .add }
                .buttonStyle(.borderedProminent).prominentTint()
        }
    }

    private func headerTotals(_ overview: AccountsOverview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(overview.asOf.map { "Net worth · as of \(DashboardFormat.day($0))" } ?? "Net worth")
                .font(.callout)
                .foregroundStyle(.secondary)
                .figureText()
            MoneyText(minorUnits: overview.netWorthGBP, font: .largeTitle.bold().monospacedDigit(), tint: .primary)
            if let change = overview.changeVsPreviousMonthGBP {
                HStack(spacing: 4) {
                    if change == 0 {
                        Text("No change vs previous month")
                    } else {
                        Text(change > 0 ? "↑" : "↓")
                        Text("\(Money.format(abs(change), currency: .gbp)) vs previous month").figureText()
                    }
                }
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(change > 0 ? theme.yoyGood : (change < 0 ? theme.yoyBad : Color.secondary))
            }
        }
    }

    // MARK: Banners

    @ViewBuilder
    private func banners(_ overview: AccountsOverview) -> some View {
        if overview.staleCount > 0 {
            let since = overview.oldestStaleDate.map { " since \(DashboardFormat.day($0).unbroken)" } ?? ""
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                Text("\(overview.staleCount) balance\(overview.staleCount == 1 ? "" : "s") not updated\(since) — import a statement or update them.")
            }
        }
        if !viewModel.balanceMessages.isEmpty {
            Banner(systemImage: "checkmark.circle.fill", tint: .green, onDismiss: { viewModel.balanceMessages = [] }) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewModel.balanceMessages.enumerated()), id: \.offset) { Text($0.element) }
                }
            }
        }
        commonBanners
    }

    @ViewBuilder
    private var commonBanners: some View {
        if let error = viewModel.errorMessage {
            Banner(systemImage: "xmark.octagon.fill", tint: .red, onDismiss: { viewModel.errorMessage = nil }) {
                Text(error)
            }
        }
        if let banner = environment.exchangeRateBanner {
            Banner(systemImage: "eurosign.circle", tint: .blue, onDismiss: { environment.exchangeRateBanner = nil }) {
                Text(banner)
            }
        }
    }

    // MARK: Footer / empty

    private var footer: some View {
        let rate = viewModel.rate
        let formattedRate = rate.eurToGbpRate.formatted(.number.precision(.fractionLength(2...4)))
        return Text("EUR rate \(formattedRate) · updated \(DashboardFormat.day(rate.updatedAt))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .figureText()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "building.columns")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Add your first account").font(.title3)
            Text("Accounts and their balances make up your net worth.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("+ Add account") { activeSheet = .add }
                .buttonStyle(.borderedProminent).prominentTint()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sheets

private enum AccountsSheet: Identifiable {
    case add
    case edit(Account)
    case updateOne(AccountRow)
    case updateAll([AccountGroup])
    case addTransaction(Int64)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let account): return "edit-\(account.id ?? 0)"
        case .updateOne(let row): return "update-\(row.id)"
        case .updateAll: return "update-all"
        case .addTransaction(let accountId): return "add-transaction-\(accountId)"
        }
    }
}

// MARK: - Banner

private struct Banner<Content: View>: View {
    let systemImage: String
    let tint: Color
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: systemImage).foregroundStyle(tint)
            content.font(.callout)
            Spacer()
            if let onDismiss {
                Button("Dismiss", action: onDismiss).font(.caption)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }
}

// MARK: - List

private struct AccountsListView: View {
    let groups: [AccountGroup]
    @Environment(\.theme) private var theme
    @Binding var selection: Int64?
    /// Each account's latest imported transaction date (absent: nothing imported).
    let importedThrough: [Int64: Date]
    /// Add transaction… from a row's context menu.
    let onAddTransaction: (Int64) -> Void
    /// Set as main account / Unset main account (nil) from a row's context menu.
    let onSetMain: (Int64?) -> Void
    /// Count toward net worth on or off from a row's context menu.
    let onSetIncludeInNetWorth: (Int64, Bool) -> Void
    /// The window's importer, read here and handed to the context menu's shortcuts.
    @Environment(\.documentImport) private var documentImport
    /// A drag within a section (accounts reorder within their kind).
    let onMove: (AccountGroup, IndexSet, Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            list
        }
    }

    /// The column titles, lined up with `AccountListRow`'s columns.
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Account").figureText()
            Spacer(minLength: 8)
            Text("Last import").figureText().frame(width: AccountListRow.dateColumnWidth, alignment: .leading)
            Text("Balance").figureText().frame(width: AccountListRow.balanceColumnWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.leading, 16).padding(.trailing, 16).padding(.vertical, 4)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        AccountListRow(row: row, importedThrough: importedThrough[row.id]).tag(row.id)
                            .contextMenu {
                                Button("Add transaction…") { onAddTransaction(row.id) }
                                Menu("Import statement") {
                                    // Handed in: a context menu may not inherit the environment's importer.
                                    ImportShortcutButton("CSV…", shortcut: .statement(accountId: row.id, format: .csv, from: .accounts),
                                                         importer: documentImport)
                                    ImportShortcutButton("PDF…", shortcut: .statement(accountId: row.id, format: .pdf, from: .accounts),
                                                         importer: documentImport)
                                }
                                Divider()
                                if row.account.isMain {
                                    Button("Unset main account") { onSetMain(nil) }
                                } else {
                                    Button("Set as main account") { onSetMain(row.id) }
                                }
                                if row.account.includeInNetWorth {
                                    Button("Don't count toward net worth") { onSetIncludeInNetWorth(row.id, false) }
                                        .help(NetWorthToggle.help)
                                } else {
                                    Button("Count toward net worth") { onSetIncludeInNetWorth(row.id, true) }
                                }
                            }
                    }
                    .onMove { from, to in onMove(group, from, to) }
                } header: {
                    HStack(spacing: 4) {
                        Text("\(AccountsFormat.kind(group.kind)) ·")
                        MoneyText(minorUnits: group.subtotalGBP, font: .headline.monospacedDigit(), tint: group.subtotalGBP < 0 ? theme.expense : .primary)
                    }
                    .font(.headline)
                }
            }
        }
        .wrapProbeClips()
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }
}

private struct AccountListRow: View {
    let row: AccountRow
    let importedThrough: Date?

    static let dateColumnWidth: Double = 92
    static let balanceColumnWidth: Double = 132

    /// The Last import column: the day of the latest imported transaction, or a dash.
    private var importedText: String {
        importedThrough.map { AccountsFormat.shortDay($0) } ?? "—"
    }

    /// Every row is two lines, whatever it shows — the name (with its flags and pills) over
    /// the caption on the left, the native balance over its GBP equivalent on the right — so
    /// all rows are the same height.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.account.displayName).lineLimit(1)
                    flags
                }
                // The nickname's account name truncates; the import date never does.
                HStack(spacing: 0) {
                    if row.account.displayName != row.account.name {
                        Text(row.account.name).lineLimit(1)
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(importedText).figureText()
                .foregroundStyle(row.isStale ? Color.orange : Color.secondary)
                .frame(width: Self.dateColumnWidth, alignment: .leading)
                .help(importedThrough == nil ? "Nothing imported for this account" : "Latest imported transaction")
            VStack(alignment: .trailing, spacing: 1) {
                AccountsFormat.balanceText(row.nativeBalanceMinorUnits, kind: row.account.kind, currency: row.account.currency,
                                           muted: !row.account.includeInNetWorth)
                // The GBP equivalent, secondary and without "owed" (said once, above). An
                // account left out of net worth doesn't need it.
                if row.account.currency != .gbp, row.account.includeInNetWorth {
                    AccountsFormat.balanceText(row.gbpBalanceMinorUnits, kind: row.account.kind, currency: .gbp,
                                               font: .caption.monospacedDigit(), muted: true, saysOwed: false)
                } else {
                    // Keeps the second line's height, so every row matches.
                    Text(" ").font(.caption).accessibilityHidden(true)
                }
            }
            .frame(width: Self.balanceColumnWidth, alignment: .trailing)
        }
        .font(.body.monospacedDigit())
        .padding(.vertical, 2)
    }

    /// Stale and mismatch flags, then the Main account and Not in net worth pills.
    @ViewBuilder
    private var flags: some View {
        if row.isStale {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .help("Not updated in over \(BalanceStaleness.thresholdDays) days")
        }
        if let mismatch = AccountsFormat.statementMismatch(row.account) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .help(mismatch)
                .accessibilityLabel(mismatch)
        }
        if row.account.isMain {
            MainAccountBadge()
        }
        if !row.account.includeInNetWorth {
            NotInNetWorthBadge()
        }
    }
}

// MARK: - Detail

/// The "Bank details" section (spec 2026-10-15 §3): bank name, the region's fields and BIC
/// (only those set), each with a copy button that puts the unformatted value on the
/// clipboard, and Copy all. Without any, an "Add bank details…" link opens Edit.
private struct AccountBankDetails: View {
    let account: Account
    let onAdd: () -> Void

    var body: some View {
        let lines = BankDetailsFormat.lines(for: account)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bank details").font(.headline)
                Spacer()
                if let all = BankDetailsFormat.copyAllText(for: account) {
                    Button("Copy all") { Self.copy(all) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .help("Copy all bank details as text")
                }
            }
            if lines.isEmpty {
                Button("Add bank details…", action: onAdd)
                    .buttonStyle(.link)
                    .font(.callout)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(lines, id: \.label) { line in
                        GridRow {
                            Text(line.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(line.shown).font(.body.monospacedDigit()).textSelection(.enabled).figureText()
                            Button {
                                Self.copy(line.copied)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy \(line.label.lowercased())")
                            .accessibilityLabel("Copy \(line.label.lowercased())")
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct AccountDetailView: View {
    let row: AccountRow?
    @Environment(\.theme) private var theme
    /// The account's latest imported transaction date; nil: nothing imported.
    let importedThrough: Date?
    let history: AccountHistory
    /// The window's importer (an import under way links to its review).
    let importCenter: ImportCenterModel
    /// The formats the account has a saved mapping or layout for (their Edit and Reset items).
    let savedProfiles: Set<ImportFormat>
    let onUpdateBalance: (AccountRow) -> Void
    let onEdit: (AccountRow) -> Void
    let onAddTransaction: (AccountRow) -> Void
    let onReset: (ImportFormat) -> Void
    let onResumeReview: () -> Void
    @State private var showAllHistory = false
    @State private var selectedDate: Date?
    private let historyLimit = 12

    var body: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.account.displayName).font(.title2.bold())
                        if row.account.displayName != row.account.name {
                            Text(row.account.name).font(.callout).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text("\(row.account.currency.rawValue.uppercased()) · \(AccountsFormat.kind(row.account.kind))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if row.account.isMain {
                                MainAccountBadge()
                            }
                            if !row.account.includeInNetWorth {
                                NotInNetWorthBadge()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        AccountsFormat.balanceText(row.nativeBalanceMinorUnits, kind: row.account.kind, currency: row.account.currency, font: .title.bold().monospacedDigit())
                        if row.account.currency != .gbp {
                            AccountsFormat.balanceText(row.gbpBalanceMinorUnits, kind: row.account.kind, currency: .gbp, muted: true, saysOwed: false)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        updatedLine(row)
                        Text(importedThrough.map { "Imported up to \(DashboardFormat.day($0))" } ?? "Not imported yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .figureText()
                    }
                    if let mismatch = AccountsFormat.statementMismatch(row.account) {
                        Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .help("A statement import's closing balance didn't match. Check for missing or duplicate transactions, or use Update balance… to settle it.")
                    }
                    HStack {
                        Button("Update balance…") { onUpdateBalance(row) }
                        Button("Edit…") { onEdit(row) }
                        Button("Add transaction…") { onAddTransaction(row) }
                    }
                    importRow(row)
                    AccountBankDetails(account: row.account, onAdd: { onEdit(row) })
                    chart(row)
                    historyList(row)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .onChange(of: row.id) { showAllHistory = false }
        } else {
            Text("Select an account.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Import statement ▾ (spec 2026-10-15 §1): CSV…, PDF… and, with a saved mapping, Edit
    /// column mapping… (shortcuts into the importer), then the saved mapping/layout's Reset items.
    /// An import under way links to its review.
    private func importRow(_ row: AccountRow) -> some View {
        HStack {
            Menu("Import statement") {
                ImportShortcutButton("CSV…", shortcut: .statement(accountId: row.id, format: .csv, from: .accounts))
                ImportShortcutButton("PDF…", shortcut: .statement(accountId: row.id, format: .pdf, from: .accounts))
                if !savedProfiles.isEmpty {
                    Divider()
                }
                if savedProfiles.contains(.csv) {
                    ImportShortcutButton("Edit column mapping…", shortcut: .editColumnMapping(accountId: row.id))
                    Button("Reset column mapping…") { onReset(.csv) }
                }
                if savedProfiles.contains(.pdf) {
                    Button("Reset PDF layout…") { onReset(.pdf) }
                }
            }
            .fixedSize()
            ImportUnderWayLink(center: importCenter, open: onResumeReview)
        }
    }

    private func updatedLine(_ row: AccountRow) -> some View {
        Group {
            if let date = row.lastUpdated {
                Text("Updated \(DashboardFormat.day(date)) · \(AccountsFormat.age(of: date))").figureText()
            } else {
                Text("No balance recorded yet")
            }
        }
        .font(.callout)
        .foregroundStyle(row.isStale ? Color.orange : Color.secondary)
    }

    @ViewBuilder
    private func chart(_ row: AccountRow) -> some View {
        // Computed balances: the opening day, each month end, then today.
        let points = history.points.enumerated().map { (index: $0.offset, date: $0.element.date, value: Double($0.element.balanceMinorUnits) / 100, minorUnits: $0.element.balanceMinorUnits) }
        if points.count >= 2 {
            let hovered = selectedDate.flatMap { date in points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
            Chart {
                ForEach(points, id: \.index) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Balance", point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(theme.series(0))
                }
                if let hovered {
                    RuleMark(x: .value("Selected", hovered.date))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
            }
            // Charts lay their labels out apart from the scroll view: no clip check on them.
            .wrapProbeInChart()
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                // Inside the plot's top edge, following the hovered balance but clamped to the plot's width.
                GeometryReader { geometry in
                    if let hovered, let frame = proxy.plotFrame.map({ geometry[$0] }), let x = proxy.position(forX: hovered.date) {
                        let width: CGFloat = 150
                        let left = max(frame.minX, min(frame.minX + x - width / 2, frame.maxX - width))
                        readoutBox(row, date: hovered.date, minorUnits: hovered.minorUnits)
                            .frame(width: width)
                            .offset(x: left, y: frame.minY)
                            .allowsHitTesting(false)
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 90)
        }
    }

    private func readoutBox(_ row: AccountRow, date: Date, minorUnits: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DashboardFormat.day(date)).font(.caption2).foregroundStyle(.secondary).figureText()
            HStack(spacing: 4) {
                Circle().fill(theme.series(0)).frame(width: 6, height: 6)
                Text(row.account.displayName).font(.caption2).lineLimit(1)
                Spacer(minLength: 8)
                AccountsFormat.balanceText(minorUnits, kind: row.account.kind, currency: row.account.currency, font: .caption.bold().monospacedDigit())
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.windowFill))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    @ViewBuilder
    private func historyList(_ row: AccountRow) -> some View {
        let entries = history.entries
        VStack(alignment: .leading, spacing: 6) {
            Text("Balance history").font(.headline)
            if entries.isEmpty {
                Text("No opening balance or adjustments.").font(.callout).foregroundStyle(.secondary)
            }
            let visible = showAllHistory ? entries : Array(entries.prefix(historyLimit))
            ForEach(visible) { entry in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(DashboardFormat.day(entry.date)).figureText()
                        Text(Self.label(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                    switch entry.kind {
                    case .opening, .recordedBalance:
                        AccountsFormat.balanceText(entry.amountMinorUnits, kind: row.account.kind, currency: row.account.currency)
                    case .adjustment:
                        Text(AccountsFormat.signedMoney(entry.amountMinorUnits, currency: row.account.currency))
                            .figureText()
                            .foregroundStyle(entry.amountMinorUnits < 0 ? theme.expense : Color.primary)
                    }
                }
                .font(.callout.monospacedDigit())
                .help(entry.note ?? "")
                Divider()
            }
            if entries.count > historyLimit {
                Button(showAllHistory ? "Show fewer" : "Show all \(entries.count)") { showAllHistory.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    /// "Opening balance", "Recorded balance · Statement", "Market movement".
    private static func label(_ entry: AccountHistory.Entry) -> String {
        switch entry.kind {
        case .opening: return "Opening balance"
        case .recordedBalance: return ["Recorded balance", entry.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .adjustment(let categoryName): return categoryName
        }
    }
}

// MARK: - Formatting

enum AccountsFormat {
    private static func utcFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = pattern
        return formatter
    }
    private static let dayMonthFormatter = utcFormatter("d MMM")
    private static let dayMonthYearFormatter = utcFormatter("d MMM yyyy")
    private static let yearFormatter = utcFormatter("yyyy")

    /// "12 Oct" in the current year, "12 Oct 2025" otherwise (dates are UTC days).
    static func shortDay(_ date: Date, today: Date = AppClock.now) -> String {
        yearFormatter.string(from: date) == yearFormatter.string(from: today)
            ? dayMonthFormatter.string(from: date)
            : dayMonthYearFormatter.string(from: date)
    }

    static func kind(_ kind: AccountKind) -> String {
        switch kind {
        case .cash: return "Cash"
        case .investment: return "Investment"
        case .credit: return "Credit"
        }
    }

    /// Credit balances are stored signed (negative = owed) and shown as the amount owed,
    /// coloured by the stored sign so debt reads in the theme's expense colour — as the Net
    /// Worth screen did.
    /// `muted`: in the secondary style (an account left out of net worth, or a secondary
    /// GBP equivalent). `saysOwed`: false leaves "owed" off a debt — for an equivalent shown
    /// under the native amount, which already says it. Never wraps.
    static func balanceText(_ signedMinorUnits: Int, kind: AccountKind, currency: Currency, font: Font = .body.monospacedDigit(), muted: Bool = false,
                            saysOwed: Bool = true) -> some View {
        AccountBalanceText(signedMinorUnits: signedMinorUnits, kind: kind, currency: currency, font: font, muted: muted, saysOwed: saysOwed)
    }

    /// "Statement mismatch on 29 Sep 2026: +£12.00" (statement − computed) — nil when the
    /// account has none (spec 2026-10-14 §2).
    static func statementMismatch(_ account: Account) -> String? {
        guard let difference = account.statementMismatchMinorUnits, let date = account.statementMismatchDate else { return nil }
        return "Statement mismatch on \(DashboardFormat.day(date).unbroken): \(signedMoney(difference, currency: account.currency).unbroken)"
    }

    /// "+£12.00" / "-£12.00" / "£0.00".
    static func signedMoney(_ minorUnits: Int, currency: Currency) -> String {
        (minorUnits > 0 ? "+" : "") + Money.format(minorUnits, currency: currency)
    }

    /// A picked local calendar day as the stored snapshot date (that day, 00:00 UTC).
    static func snapshotDay(_ picked: Date) -> Date {
        PayCalendar.utcDay(sameDayAs: picked, in: .current)
    }

    /// The row's current balance as the user would enter it (amount owed for credit),
    /// as a `Money.formatInput` string for prefilling a text field: "1,234.56", "-12.00".
    static func enteredAmountText(_ row: AccountRow) -> String {
        Money.formatInput(NetWorthCalculator.enteredBalance(signedMinorUnits: row.nativeBalanceMinorUnits, accountKind: row.account.kind))
    }

    /// "today", "3 days ago", "2 months ago" — whole UTC days / calendar months.
    static func age(of date: Date, today: Date = AppClock.now) -> String {
        let calendar = MonthRange.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: today)).day ?? 0
        if days <= 0 { return "today" }
        if days < 60 { return days == 1 ? "1 day ago" : "\(days) days ago" }
        let months = calendar.dateComponents([.month], from: date, to: today).month ?? 0
        return months == 1 ? "1 month ago" : "\(months) months ago"
    }
}

/// `AccountsFormat.balanceText`: a balance, a credit debt as the amount "owed".
private struct AccountBalanceText: View {
    let signedMinorUnits: Int
    let kind: AccountKind
    let currency: Currency
    let font: Font
    var muted = false
    var saysOwed = true
    @Environment(\.theme) private var theme

    var body: some View {
        if kind == .credit && signedMinorUnits < 0 {
            HStack(spacing: 4) {
                MoneyText(minorUnits: NetWorthCalculator.enteredBalance(signedMinorUnits: signedMinorUnits, accountKind: .credit), currency: currency, font: font, colorOverride: signedMinorUnits,
                          tint: muted ? .secondary : nil)
                if saysOwed {
                    Text("owed").font(font).foregroundStyle(muted ? Color.secondary : theme.expense)
                        .lineLimit(1)
                }
            }
            .fixedSize()
        } else {
            MoneyText(minorUnits: signedMinorUnits, currency: currency, font: font, tint: muted ? .secondary : (signedMinorUnits < 0 ? theme.expense : .primary))
        }
    }
}

/// "Main account": the account Set as main account marks.
private struct MainAccountBadge: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Main account")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(theme.accent.opacity(0.15)))
            .foregroundStyle(theme.accent)
            .help(EditAccountSheet.mainAccountHelp)
    }
}

/// "Not in net worth": an account with Count toward net worth off.
private struct NotInNetWorthBadge: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Not in net worth")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(theme.neutralMoney.opacity(0.15)))
            .foregroundStyle(.secondary)
            .help(NetWorthToggle.help)
    }
}

/// "Resume review ›" while the importer reads or holds a review (files imported here join it).
private struct ImportUnderWayLink: View {
    @ObservedObject var center: ImportCenterModel
    let open: () -> Void

    var body: some View {
        switch center.phase {
        case .reading, .review, .applying:
            Button("Resume review ›", action: open)
                .buttonStyle(.link)
                .fixedSize()
        case .idle, .finished, .failed:
            EmptyView()
        }
    }
}
