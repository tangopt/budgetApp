// App/Budget/BudgetGridView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import UniformTypeIdentifiers

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = "" }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct BudgetGridView: View {
    @ObservedObject var viewModel: BudgetGridViewModel
    @State private var showExporter = false
    /// Built only when "Export CSV…" is pressed: the export scans every
    /// category × pay month, so it must not be computed in `body`.
    @State private var exportDocument: CSVDocument?
    /// The clicked cell whose side panel is open (spec §2). Plain `@State` like `scrollOffset`:
    /// only the cells' outlines and the panel host observe it, so a click doesn't re-run `body`.
    @State fileprivate var cellSelection = CellSelection<GridCellTarget>()
    /// Held in `@State` (not `@StateObject`/`@ObservedObject`) on purpose: this view must not
    /// observe it, or every horizontal scroll frame would re-run this whole `body`. Only the
    /// header's `HorizontalOffsetFollower` observes it.
    @State private var scrollOffset = HorizontalScrollOffset()
    /// The body rows' width, adopted by the frozen header (`GridBodyWidth`); plain `@State`
    /// for the same reason as `scrollOffset`.
    @State private var bodyWidth = GridBodyWidth()
    /// Collapsed sections and expanded groups (`GridOutline`), remembered across launches.
    @AppStorage("budgetGrid.collapsedSections") private var collapsedSectionsStore = ""
    @AppStorage("budgetGrid.expandedGroups") private var expandedGroupsStore = ""
    @State private var closeTarget: CloseMonthTarget?
    @State private var addPlannedTarget: AddPlannedTarget?
    @State private var reserveSheet: ReserveSheet?
    @State private var renamingReserve: Category?
    @State private var deletingReserve: Category?
    /// A failed reserve save, shown inside the open reserve sheet.
    @State private var reserveError: String?

    private enum ReserveSheet: Identifiable {
        case newReserve
        case addAmount(Category)
        /// An empty month cell's Add amount: the start pre-filled to `date`.
        case addAmountOn(Category, date: Date)
        var id: String {
            switch self {
            case .newReserve: return "new-reserve"
            case .addAmount(let reserve): return "add-amount-\(reserve.id ?? -1)"
            case .addAmountOn(let reserve, let date): return "add-amount-\(reserve.id ?? -1)-\(date.timeIntervalSince1970)"
            }
        }
    }

    /// The section a header's "+ Add planned item" adds to (`.sheet(item:)`).
    private struct AddPlannedTarget: Identifiable {
        let type: CategoryType
        /// From an empty month cell: the category preselected and the one-off's date.
        var categoryId: Int64?
        var date: Date?
        var id: String { "\(type.rawValue)-\(categoryId ?? -1)-\(date?.timeIntervalSince1970 ?? 0)" }
    }

    /// Whether an empty cell of this pay month may be clicked to add: an open or future month,
    /// with All accounts or exactly one account ticked (the item gets that account, spec
    /// 2026-10-15 §3).
    private func canAdd(year: Int, month: Int) -> Bool {
        viewModel.accountFilter.count <= 1 && !viewModel.payCalendar.isClosed(PayMonth(year: year, month: month))
    }

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type && !$0.isReserved }
    }

    fileprivate enum GridRowKind: Identifiable {
        /// `type` is nil for the Accounts header (no planned items, no totals).
        case sectionHeader(String, CategoryType?)
        case category(Category)
        case groupHeader(CategoryGroup, categories: [Category])
        case groupChild(Category)
        case account(Account)
        /// Planned items with no effective account (account-forecast spec §2), so the account
        /// rows always sum to Net Worth.
        case unassignedAccount
        case netWorthTotal
        case reservedHeader
        case reserve(Category)
        case reservedTotal
        /// The Totals block (budget-totals spec §1): its header and Total in / Total out / Net.
        case totalsHeader
        case totals(BudgetTotals.Row)

        var id: String {
            switch self {
            case .sectionHeader(let title, _): return "header-\(title)"
            case .category(let category): return "cat-\(category.id ?? -1)"
            case .groupHeader(let group, let categories): return "group-\(group.id ?? -1)-\(categories.first?.type.rawValue ?? "")"
            case .groupChild(let category): return "groupchild-\(category.id ?? -1)"
            case .account(let account): return "account-\(account.id ?? -1)"
            case .unassignedAccount: return "account-unassigned"
            case .netWorthTotal: return "networth-total"
            case .reservedHeader: return "reserved-header"
            case .reserve(let reserve): return "reserve-\(reserve.id ?? -1)"
            case .reservedTotal: return "reserved-total"
            case .totalsHeader: return "totals-header"
            case .totals(let row): return "totals-\(row.rawValue)"
            }
        }
    }

    /// The collapsed sections and expanded groups, from their stored strings.
    private var outline: GridOutline {
        GridOutline(sectionsString: collapsedSectionsStore, groupsString: expandedGroupsStore)
    }

    /// Changes the outline and stores it; a selected cell whose row it hides loses its panel.
    private func updateOutline(_ change: (inout GridOutline) -> Void) {
        var updated = outline
        change(&updated)
        collapsedSectionsStore = updated.sectionsString
        expandedGroupsStore = updated.groupsString
        if let key = cellSelection.key, let rowId = key.split(separator: "|").first,
           !allRows(updated).contains(where: { $0.id == rowId }) {
            cellSelection.clear()
        }
    }

    /// A section's body rows (`GridOutline.rows`): a category group shows as one
    /// `.groupHeader` row, expanding to a `.groupChild` row per member; none while collapsed.
    private func rowKinds(for type: CategoryType, _ outline: GridOutline) -> [GridRowKind] {
        outline.rows(section: GridOutline.sectionKey(type), categories: categoriesByType(type), groups: viewModel.categoryGroups).map {
            switch $0 {
            case .category(let category): return .category(category)
            case .groupHeader(let group, let members): return .groupHeader(group, categories: members)
            case .groupChild(let category): return .groupChild(category)
            }
        }
    }

    /// The ids of a section's groups, for Expand all / Collapse all and ⌥-click.
    private func groupIds(_ type: CategoryType) -> [Int64] {
        GridOutline.groupIds(categories: categoriesByType(type), groups: viewModel.categoryGroups)
    }

    /// One grid row plus whether it should render with the alternating-shade
    /// background. Shading resets to `false` at the top of every section (Income /
    /// Expenses / Transfers) rather than carrying an arbitrary parity across the
    /// section boundary.
    private struct GridRow: Identifiable {
        let kind: GridRowKind
        let shaded: Bool
        var id: String { kind.id }
    }

    /// Every row shown for `outline`: a collapsed section keeps only its header row (Accounts
    /// and Reserved also keep their total row, as their headers show no totals).
    private func allRows(_ outline: GridOutline) -> [GridRow] {
        func section(_ title: String, _ type: CategoryType) -> [GridRow] {
            var rows: [GridRow] = [GridRow(kind: .sectionHeader(title, type), shaded: false)]
            for (index, kind) in rowKinds(for: type, outline).enumerated() {
                rows.append(GridRow(kind: kind, shaded: index % 2 == 1))
            }
            return rows
        }
        var accountRows: [GridRow] = [GridRow(kind: .sectionHeader("Accounts", nil), shaded: false)]
        if !outline.isCollapsed(GridOutline.accountsSection) {
            // Under an account filter, only the selected accounts (spec 2026-10-15 §4).
            for (index, account) in viewModel.shownAccounts.enumerated() {
                accountRows.append(GridRow(kind: .account(account), shaded: index % 2 == 1))
            }
            // All accounts only, and only when something is unassigned in a shown year.
            if viewModel.showsUnassignedRow {
                accountRows.append(GridRow(kind: .unassignedAccount, shaded: viewModel.shownAccounts.count % 2 == 1))
            }
        }
        // Kept when collapsed: the Accounts header shows no totals.
        accountRows.append(GridRow(kind: .netWorthTotal, shaded: false))
        var reservedRows: [GridRow] = [GridRow(kind: .reservedHeader, shaded: false)]
        if !outline.isCollapsed(GridOutline.reservedSection) {
            for (index, reserve) in viewModel.reserves.enumerated() {
                reservedRows.append(GridRow(kind: .reserve(reserve), shaded: index % 2 == 1))
            }
        }
        // Kept when collapsed: the Reserved header shows no totals.
        if !viewModel.reserves.isEmpty { reservedRows.append(GridRow(kind: .reservedTotal, shaded: false)) }
        // Adjustments (Balance adjustment, Market movement): their actuals only — never in
        // the income/expense/transfer totals or the plan; they reach net worth via balances.
        let adjustments = categoriesByType(.adjustment).isEmpty ? [] : section("Adjustments", .adjustment)
        // Total in / Total out / Net; collapsed, Net stays (the header shows no totals).
        let totalsRows = [GridRow(kind: .totalsHeader, shaded: false)]
            + BudgetTotals.Row.visible(collapsed: outline.isCollapsed(GridOutline.totalsSection)).map { GridRow(kind: .totals($0), shaded: false) }
        return section("Income", .income) + section("Expenses", .expense) + reservedRows + section("Transfers", .transfer) + adjustments + totalsRows + accountRows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            yearPicker

            // Close/reopen errors from the header menu (a failed Close month… shows in its
            // sheet instead), and "Saved, but…" after a side panel edit.
            if let error = viewModel.errorMessage, closeTarget == nil, addPlannedTarget == nil, reserveSheet == nil, renamingReserve == nil {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { viewModel.errorMessage = nil }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal)
            }

            // The account filter on the left; the grid narrows while it, or a cell's side
            // panel on the right, is open beside it.
            HStack(alignment: .top, spacing: 0) {
                AccountFilterPanel(viewModel: viewModel)
                Divider()
                SidePanelHost(selection: cellSelection) {
                    // spacing: 0 so the frozen header sits flush on the body, with no gap for
                    // scrolled rows to show through.
                    VStack(alignment: .leading, spacing: 0) {
                        // Frozen month-header row: lives outside the vertical scroll (so it never
                        // moves vertically), and mirrors the body's horizontal scroll offset (so it
                        // stays aligned with whichever columns are currently visible). The Year Total
                        // header is pinned on the right, outside the follower, like its column. The
                        // row takes the body's measured width, so the pinned Year Total header sits
                        // exactly over its column whatever the scroller style.
                        BodyWidthFollower(width: bodyWidth) {
                            HStack(spacing: 0) {
                                Text("Category").font(.headline).frame(width: 220, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                                if let year = viewModel.selectedYear {
                                    HorizontalOffsetFollower(offset: scrollOffset) {
                                        HStack(spacing: 0) {
                                            ForEach(1...12, id: \.self) { month in
                                                let payMonth = PayMonth(year: year, month: month)
                                                Text(GridMonthLabel.monthYear(year: year, month: month))
                                                    .frame(width: GridMetrics.cellWidth, alignment: .trailing)
                                                    .padding(.horizontal, GridMetrics.cellPadding).padding(.vertical, 6)
                                                    .contentShape(Rectangle())
                                                    // Columns are pay months: the tooltip shows the real range.
                                                    .help(PayMonthFormat.range(viewModel.payCalendar.range(of: payMonth)))
                                                    .contextMenu { monthMenu(payMonth) }
                                                    .monthSeparator(month)
                                            }
                                        }
                                    }
                                    // minWidth: 0 makes this frame take exactly the width it's offered
                                    // (what's left of the window after the Category and Year Total cells)
                                    // rather than growing to the 12 columns' full width, which would push
                                    // the whole screen wider than the window; the overflow is then clipped.
                                    // maxWidth matches the body's month scroller, so in a wide window the
                                    // Year Total sits right after December in both.
                                    .frame(minWidth: 0, maxWidth: GridMetrics.monthsWidth, alignment: .leading)
                                    .clipped()
                                    // Clipping hides the scrolled-off columns but not from clicks: without this they
                                    // catch clicks meant for whatever sits beside the grid (the account panel).
                                    .contentShape(Rectangle())
                                } else if isMultiYear {
                                    // Several years: each year's total, and after every year but the
                                    // first its change from the previous selected year. Clipped and
                                    // capped like the months, at however many columns there are.
                                    let years = viewModel.selectedYears
                                    HorizontalOffsetFollower(offset: scrollOffset) {
                                        HStack(spacing: 0) {
                                            ForEach(Array(years.enumerated()), id: \.element) { index, year in
                                                multiYearHeaderCell(String(year)).bold()
                                                    .yearGroupSeparator(index)
                                                if index > 0 {
                                                    multiYearHeaderCell("Δ vs \(String(years[index - 1]))")
                                                    multiYearHeaderCell("%")
                                                }
                                            }
                                        }
                                    }
                                    .frame(minWidth: 0, maxWidth: scrollingWidth, alignment: .leading)
                                    .clipped()
                                    // Clipping hides the scrolled-off columns but not from clicks: without this they
                                    // catch clicks meant for whatever sits beside the grid (the account panel).
                                    .contentShape(Rectangle())
                                }
                                if showsPinnedYearTotal {
                                    Text("Year Total").bold()
                                        .frame(width: GridMetrics.cellWidth, alignment: .trailing)
                                        .padding(.horizontal, GridMetrics.cellPadding).padding(.vertical, 6)
                                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .leading)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.headline)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay(Rectangle().frame(height: 1.5).foregroundStyle(Color.primary.opacity(0.18)), alignment: .bottom)
                        // A frozen row that floats above the scrolling body reads better with a
                        // little elevation; kept as a constant subtle shadow rather than toggled by
                        // scroll position, to avoid adding a second scroll-tracked PreferenceKey purely
                        // for a decorative effect.
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)

                        // Built once per render and shared by the label column and the cells.
                        let rows = allRows(outline)
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                // Frozen category column: not inside any horizontal scroll, so it
                                // never moves left/right; it rides this same vertical ScrollView as
                                // the body, so it stays aligned with its own row.
                                VStack(spacing: 0) {
                                    ForEach(rows) { entry in
                                        rowLabel(entry.kind, shaded: entry.shaded)
                                    }
                                }
                                // 236 = each label's 220pt frame + 8pt padding either side, matching
                                // the header's "Category" cell so the month columns line up.
                                .frame(width: 236, alignment: .leading)
                                .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)

                                ScrollView(.horizontal) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(rows) { entry in
                                            rowCells(entry.kind, shaded: entry.shaded)
                                        }
                                    }
                                }
                                // The header mirrors the content's offset (negated: content moves left).
                                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in scrollOffset.update(-x) }
                                // No wider than its columns (the twelve months, or the multi-year
                                // columns), so the pinned Year Total never floats away from December
                                // in a wide window.
                                .frame(maxWidth: scrollingWidth)

                                // Frozen Year Total column, pinned on the right like the category
                                // column on the left: outside the horizontal scroll, inside this
                                // vertical one. Every cell has its row's fixed height (24/28pt), the
                                // same as the label and month cells, so the three columns line up.
                                if showsPinnedYearTotal {
                                    VStack(spacing: 0) {
                                        ForEach(rows) { entry in
                                            if let year = viewModel.selectedYear {
                                                yearTotalCell(entry.kind, year: year, shaded: entry.shaded)
                                            }
                                        }
                                    }
                                    .frame(width: GridMetrics.columnWidth)
                                    .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // The width the rows get (less a legacy vertical scroller), for the header.
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { bodyWidth.update($0) }
                        }
                    }
                } panel: { target in
                    BudgetCellPanel(target: target, viewModel: viewModel) { cellSelection.clear() }
                }
                }

        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export CSV…") {
                    exportDocument = CSVDocument(text: viewModel.exportCSV())
                    showExporter = true
                }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: "budget-export") { _ in }
        // A panel's target belongs to the year it was opened in.
        .onChange(of: viewModel.selectedYears) { _, _ in
            cellSelection.clear()
            applyRevealRequest()
        }
        // Search's Show in Budget (`BudgetGridViewModel.reveal`).
        .onAppear { applyRevealRequest() }
        .onChange(of: viewModel.revealRequest) { _, _ in applyRevealRequest() }
        // ...and to the accounts it was opened under.
        .onChange(of: viewModel.accountFilter) { _, _ in cellSelection.clear() }
        // Assigning the last unassigned item hides that row: its panel goes with it.
        .onChange(of: viewModel.showsUnassignedRow) { _, shows in
            if !shows, cellSelection.key?.hasPrefix(GridRowKind.unassignedAccount.id + "|") == true { cellSelection.clear() }
        }
        .sheet(item: $addPlannedTarget) { target in
            AddPlannedItemSheet(type: target.type, scope: .budget, categories: viewModel.categories, plannedEntries: viewModel.plannedEntries,
                                accountOptions: viewModel.planAccountOptions, initialCategoryId: target.categoryId, initialDate: target.date,
                                initialAccountId: viewModel.singleFilteredAccountId) { category, amount, frequency, interval, start, end, accountId in
                switch category {
                case .existing(let id):
                    return viewModel.addPlannedItem(categoryId: id, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end, accountId: accountId)
                case .new(let name):
                    return viewModel.addPlannedItem(newCategoryName: name, type: target.type, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end, accountId: accountId)
                }
            }
        }
        // Reserve forms: a failed save keeps the sheet open with the error.
        .sheet(item: $reserveSheet, onDismiss: { reserveError = nil }) { sheet in
            switch sheet {
            case .newReserve:
                ReserveFormView(mode: .newReserve, errorMessage: reserveError, onEdit: clearReserveError) { target, amount, frequency, interval, start, end in
                    guard case .new(let name) = target else { return }
                    finishReserveSave(viewModel.addReserve(name: name, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end)) { reserveSheet = nil }
                }
            case .addAmount(let reserve):
                ReserveFormView(mode: .addAmount(reserve), errorMessage: reserveError, onEdit: clearReserveError) { _, amount, frequency, interval, start, end in
                    finishReserveSave(viewModel.addReserveAmount(to: reserve, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end)) { reserveSheet = nil }
                }
            case .addAmountOn(let reserve, let date):
                ReserveFormView(mode: .addAmount(reserve), errorMessage: reserveError, initialDate: date, onEdit: clearReserveError) { _, amount, frequency, interval, start, end in
                    finishReserveSave(viewModel.addReserveAmount(to: reserve, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end)) { reserveSheet = nil }
                }
            }
        }
        .sheet(item: $renamingReserve, onDismiss: { reserveError = nil }) { reserve in
            RenameReserveView(reserve: reserve, errorMessage: reserveError, onEdit: clearReserveError) { name in
                finishReserveSave(viewModel.renameReserve(reserve, to: name)) { renamingReserve = nil }
            }
        }
        .confirmationDialog("Delete “\(deletingReserve?.name ?? "")”?", isPresented: Binding(
            get: { deletingReserve != nil },
            set: { if !$0 { deletingReserve = nil } }
        ), titleVisibility: .visible) {
            Button("Delete reserve", role: .destructive) {
                if let reserve = deletingReserve, case .failed(let message) = viewModel.deleteReserve(reserve) {
                    viewModel.errorMessage = message
                }
                deletingReserve = nil
            }
            Button("Cancel", role: .cancel) { deletingReserve = nil }
        } message: {
            Text("Its allowances are removed from the plan and from every scenario.")
        }
        .sheet(item: $closeTarget, onDismiss: { viewModel.errorMessage = nil }) { target in
            CloseMonthView(month: target.month, calendar: viewModel.payCalendar, errorMessage: viewModel.errorMessage) { day in
                viewModel.closeMonth(target.month, on: day)
            }
        }
    }

    private func clearReserveError() {
        if reserveError != nil { reserveError = nil }
    }

    /// Closes the reserve sheet on success; keeps it open with the message on failure.
    private func finishReserveSave(_ outcome: SaveOutcome, close: () -> Void) {
        switch outcome {
        case .saved, .savedButReloadFailed: close()
        case .failed(let message): reserveError = message
        }
    }

    /// The month header's context menu: close an open month, reopen a manually closed one;
    /// a month closed by its imported salary can't be reopened (the salary *is* the close).
    @ViewBuilder
    private func monthMenu(_ month: PayMonth) -> some View {
        switch viewModel.payCalendar.closeSource(of: month) {
        case .projected:
            Button("Close month…") {
                viewModel.errorMessage = nil
                closeTarget = CloseMonthTarget(month: month)
            }
        case .manual:
            Button("Reopen") { viewModel.reopenMonth(month) }
        case .salary:
            Button("Closed by salary on \(PayMonthFormat.longDay(viewModel.payCalendar.closeDate(of: month)))") {}
                .disabled(true)
        }
    }

    private var yearPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(viewModel.availableYears, id: \.self) { year in
                    Button {
                        // ⌘-click adds or removes a year (to compare several); a plain click
                        // shows just that year.
                        if NSEvent.modifierFlags.contains(.command) {
                            viewModel.toggleYear(year)
                        } else {
                            viewModel.selectYear(year)
                        }
                    } label: {
                        yearCard(year)
                    }
                    .buttonStyle(.plain)
                    .help("⌘-click to compare several years")
                }
            }
            // Vertical padding, not just horizontal: the selected chip's 2pt stroke sits
            // right at the row's own edge, and ScrollView sizes its cross-axis tightly to
            // content — with no vertical breathing room the stroke's top/bottom pixel was
            // clipped by the scroll view's own bounds.
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    /// A year in the selector, all the same size: the year (" forecast" after it while its
    /// year-end is a forecast, " today" for this year with Show forecast off), its year-end
    /// net worth, and the change on the previous year-end as "↑ £24,953 · 16.4%" ("—"
    /// without a previous year).
    private func yearCard(_ year: Int) -> some View {
        let selected = viewModel.selectedYears.contains(year)
        let yearEnd = viewModel.yearEndNetWorth(year)
        let change = viewModel.yearEndChange(year)
        let percent = viewModel.yearEndChangePercent(year)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(String(year)).font(.subheadline).bold()
                if yearEnd?.isForecast == true {
                    Text(" forecast").font(.caption2).foregroundStyle(.secondary)
                } else if yearEnd != nil, !viewModel.showForecast, year == MonthRange.components(of: Date()).year {
                    Text(" today").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let yearEnd {
                MoneyText(minorUnits: yearEnd.valueMinorUnits)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            // No change (or less than shows in whole pounds) reads "—", not a green "↑ £0".
            if let change, DashboardFormat.pounds(abs(change)) != DashboardFormat.pounds(0) {
                Text(Self.yearChangeText(change: change, percent: percent))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(change >= 0 ? Color.green : Color.red)
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(8)
        .frame(width: Self.yearCardSize.width, height: Self.yearCardSize.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
        // The whole tile is the button: an unselected card's background is clear, which a plain
        // button otherwise doesn't hit-test (only its text was clickable).
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Every year card's size: fits the largest content (three lines; a seven-figure net worth).
    private static let yearCardSize = CGSize(width: 160, height: 66)

    /// "↑ £24,953 · 16.4%" (whole pounds); the percent is left out when there is none (a
    /// previous year-end of zero).
    static func yearChangeText(change: Int, percent: Double?) -> String {
        let arrow = change >= 0 ? "↑" : "↓"
        let amount = DashboardFormat.pounds(abs(change))
        guard let percent else { return "\(arrow) \(amount)" }
        return "\(arrow) \(amount) · \(String(format: "%.1f", abs(percent) * 100))%"
    }

    @ViewBuilder
    private func rowLabel(_ row: GridRowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(let title, let type):
            let key = type.map(GridOutline.sectionKey) ?? GridOutline.accountsSection
            let sectionGroups = type.map(groupIds) ?? []
            SectionHeaderCell(title: title, isCollapsed: outline.isCollapsed(key),
                              toggle: { updateOutline { $0.toggleSection(key) } },
                              setAllGroups: sectionGroups.isEmpty ? nil : { expand in updateOutline { $0.setGroups(sectionGroups, expanded: expand) } }) {
                if let type, type != .adjustment {
                    Button("+ Add planned item") {
                        viewModel.errorMessage = nil
                        addPlannedTarget = AddPlannedTarget(type: type)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        case .category(let category):
            CategoryRowLabel(category: category, shaded: shaded)
        case .groupHeader(let group, let categories):
            GroupNameCell(name: group.name, isExpanded: group.id.map(outline.isExpanded) ?? false) { allInSection in
                if let id = group.id {
                    let section = categories.first.map { groupIds($0.type) }
                    updateOutline { $0.toggleGroup(id, allIn: allInSection ? section : nil) }
                }
            }
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            .overlay(Rectangle().frame(width: 3).foregroundStyle(categories.first.map { $0.type.gridStripeColor } ?? .clear), alignment: .leading)
        case .groupChild(let category):
            CategoryRowLabel(category: category, shaded: shaded, isGroupChild: true)
        case .account(let account):
            Text(account.displayName)
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(Color.purple), alignment: .leading)
        case .unassignedAccount:
            Text("Not assigned to an account")
                .foregroundStyle(.secondary)
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(Color.purple), alignment: .leading)
                .help("Planned items with no account of their own, no category history and no main account. Set a main account on the Accounts screen to place them.")
        case .reservedHeader:
            SectionHeaderCell(title: "RESERVED", isCollapsed: outline.isCollapsed(GridOutline.reservedSection),
                              toggle: { updateOutline { $0.toggleSection(GridOutline.reservedSection) } }, setAllGroups: nil) {
                Button("+ Add reserve…") {
                    viewModel.errorMessage = nil
                    reserveSheet = .newReserve
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        case .reserve(let reserve):
            Text(reserve.name)
                .gridRowLabel(background: GridRowShade.background(shaded), stripe: .purple)
                .contentShape(Rectangle())
                .help("Right-click to add an amount, rename or delete. Click a month to edit its allowance.")
                .contextMenu {
                    Button("Add amount…") { viewModel.errorMessage = nil; reserveSheet = .addAmount(reserve) }
                    Button("Rename…") { viewModel.errorMessage = nil; renamingReserve = reserve }
                    Divider()
                    Button("Delete reserve…", role: .destructive) { deletingReserve = reserve }
                }
        case .reservedTotal:
            Text("Total reserved").bold()
                .gridRowLabel(background: Color.purple.opacity(0.08), stripe: .purple)
        case .totalsHeader:
            SectionHeaderCell(title: "Totals", isCollapsed: outline.isCollapsed(GridOutline.totalsSection),
                              toggle: { updateOutline { $0.toggleSection(GridOutline.totalsSection) } }, setAllGroups: nil) { EmptyView() }
        case .totals(let totalsRow):
            TotalsRowLabel(row: totalsRow)
        case .netWorthTotal:
            Text("Net Worth").bold()
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.purple.opacity(0.10))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(Color.purple), alignment: .leading)
        }
    }

    /// A row's cells inside the horizontal scroll: its twelve months for one year (its Year
    /// Total is `yearTotalCell`, in the pinned right-hand column), or its multi-year columns.
    @ViewBuilder
    private func rowCells(_ row: GridRowKind, shaded: Bool) -> some View {
        if isMultiYear {
            multiYearCells(row, shaded: shaded)
        } else {
            monthCells(row, shaded: shaded)
        }
    }

    /// Per selected year, the row's year total (`yearTotalCell`, so pending styling, help and
    /// the click-through match the Year Total column), then for every year after the first
    /// its change from the previous selected year (`deltaCells`).
    private func multiYearCells(_ row: GridRowKind, shaded: Bool) -> some View {
        let years = viewModel.selectedYears
        return HStack(spacing: 0) {
            ForEach(Array(years.enumerated()), id: \.element) { index, year in
                yearTotalCell(row, year: year, shaded: shaded)
                    .yearGroupSeparator(index)
                if index > 0 {
                    deltaCells(row, year: year, previous: years[index - 1], shaded: shaded)
                }
            }
        }
    }

    /// The Δ £ and Δ % cells: `year`'s figure against `previous`'s (`YearOverYear.delta`),
    /// green when the change is good for the line, red when bad, secondary when neutral
    /// (transfers, balances). Header bands stay empty; "—" when either year has no figure.
    @ViewBuilder
    private func deltaCells(_ row: GridRowKind, year: Int, previous: Int, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(_, nil), .reservedHeader, .totalsHeader:
            HStack(spacing: 0) { emptyBandCell; emptyBandCell }
                .background(Color.accentColor.opacity(0.08))
        case .category(let category) where category.id == nil, .groupChild(let category) where category.id == nil:
            // Nothing without an id, like `yearTotalCell`.
            EmptyView()
        default:
            let current = yearValue(row, year: year)
            let prior = yearValue(row, year: previous)
            let delta = current.flatMap { current in prior.map { YearOverYear.delta(current: current.amount, previous: $0.amount) } }
            let improvement = delta.flatMap { YearOverYear.isImprovement(amount: $0.amount, categoryType: yearOverYearType(row)) }
            let color = improvement.map { $0 ? Color.green : Color.red } ?? Color.secondary
            let isSectionHeader: Bool = { if case .sectionHeader = row { return true } else { return false } }()
            HStack(spacing: 0) {
                Group {
                    if let delta, delta.amount != 0 {
                        Text((delta.amount > 0 ? "+" : "") + Money.format(delta.amount, currency: current?.currency ?? .gbp))
                    } else {
                        Text("—")
                    }
                }
                .multiYearValueCell()
                Text(DashboardFormat.percent(delta?.amount == 0 ? nil : delta?.fraction))
                    .multiYearValueCell()
            }
            .font(isSectionHeader ? Self.captionMoneyFont : Self.bodyMoneyFont)
            .foregroundStyle(color)
            .frame(height: isSectionHeader ? 24 : 28)
            .background(rowBackground(row, shaded: shaded))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator).opacity(isSectionHeader ? 0 : 1), alignment: .bottom)
        }
    }

    /// The figure a row's year total shows (with its currency), for the Δ columns: the
    /// combined cells' value, a balance's December value. nil for header bands and a balance
    /// with no data that year.
    private func yearValue(_ row: GridRowKind, year: Int) -> (amount: Int, currency: Currency)? {
        switch row {
        case .sectionHeader(_, let type):
            return type.map { (viewModel.yearCell(categoriesByType($0), year: year).value, .gbp) }
        case .category(let category), .groupChild(let category):
            return (viewModel.yearCell([category], year: year).value, .gbp)
        case .groupHeader(_, let categories):
            return (viewModel.yearCell(categories, year: year).value, .gbp)
        case .reservedHeader, .totalsHeader:
            return nil
        case .totals(let totalsRow):
            return (viewModel.totalsYearCell(totalsRow, year: year).value, .gbp)
        case .reserve(let reserve):
            return (viewModel.reserveYearCell([reserve], year: year).value, .gbp)
        case .reservedTotal:
            return (viewModel.reserveYearCell(viewModel.reserves, year: year).value, .gbp)
        case .account(let account):
            // The Year Total's figure: December's balance, actual or forecast (today's with
            // Show forecast off this year).
            switch viewModel.accountYearEnd(account, year: year) {
            case .actual(let balance): return balance.map { ($0.nativeBalanceMinorUnits, $0.account.currency) }
            case .forecast(let balance, let currency): return (balance.nativeMinorUnits, currency)
            case .today(let native, let currency): return (native, currency)
            case .blank: return nil
            }
        case .unassignedAccount:
            return viewModel.unassignedForecast(year: year, month: 12).map { ($0, .gbp) }
        case .netWorthTotal:
            // The year card's figure (today's net worth this year with Show forecast off).
            return viewModel.yearEndNetWorth(year).map { ($0.valueMinorUnits, .gbp) }
        }
    }

    /// The line type that decides whether a change is good (`YearOverYear.isImprovement`);
    /// nil (neutral) for balances.
    private func yearOverYearType(_ row: GridRowKind) -> CategoryType? {
        switch row {
        case .sectionHeader(_, let type): return type
        case .category(let category), .groupChild(let category): return category.type
        case .groupHeader(_, let categories): return categories.first?.type
        case .reserve(let reserve): return reserve.type
        case .reservedTotal: return .expense
        // More in, and a higher net, are better; more out (a larger negative) is worse.
        case .totals(let totalsRow): return totalsRow == .totalOut ? .expense : .income
        case .reservedHeader, .totalsHeader, .account, .unassignedAccount, .netWorthTotal: return nil
        }
    }

    /// The row's background, as its month and Year Total cells draw it.
    private func rowBackground(_ row: GridRowKind, shaded: Bool) -> Color {
        switch row {
        case .sectionHeader, .reservedHeader, .totalsHeader: return Color.accentColor.opacity(0.08)
        case .totals(let totalsRow): return totalsRow.gridBackground
        case .groupHeader: return Color.orange.opacity(0.10)
        case .reservedTotal: return Color.purple.opacity(0.08)
        case .netWorthTotal: return Color.purple.opacity(0.10)
        case .category, .groupChild, .account, .unassignedAccount, .reserve: return shaded ? Color.primary.opacity(0.07) : Color.clear
        }
    }

    /// A multi-year header label, the width of a value column.
    private func multiYearHeaderCell(_ title: String) -> some View {
        Text(title)
            .frame(width: GridMetrics.cellWidth, alignment: .trailing)
            .padding(.horizontal, GridMetrics.cellPadding).padding(.vertical, 6)
    }

    /// A row's twelve month cells for the single selected year.
    @ViewBuilder
    private func monthCells(_ row: GridRowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(_, let type):
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    if let type {
                        // The section's total: every category of the type, combined.
                        let members = categoriesByType(type)
                        ForEach(1...12, id: \.self) { month in
                            planCell(viewModel.cell(members, year: year, month: month), font: Self.captionMoneyFont).bold()
                                .frame(height: 24)
                                .aggregateMonthCell(self, row: row, name: type.gridSectionName, members: members, year: year, month: month)
                        }
                    } else {
                        ForEach(1...12, id: \.self) { _ in emptyBandCell }
                    }
                }
                .background(Color.accentColor.opacity(0.08))
            }
        case .category(let category):
            categoryCells(row, category, shaded: shaded)
        case .reservedHeader:
            if viewModel.selectedYear != nil {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { _ in emptyBandCell }
                }
                .background(Color.accentColor.opacity(0.08))
            }
        case .reserve(let reserve):
            // Reserves hold no transactions: a month cell drills into its planned allowance
            // occurrences only (Edit… / Remove… as for a category).
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        planCell(viewModel.reserveCell([reserve], year: year, month: month))
                            .frame(height: 28)
                            .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .monthSeparator(month)
                            .selectable(cellSelection, key: cellKey(row, month: month)) {
                                // Reserves are planned money only: with Show forecast off, or
                                // nothing for the filter's accounts, the cell is empty. Allowances
                                // have no account, so adding one needs All accounts.
                                guard viewModel.showForecast, !viewModel.occurrences(category: reserve, year: year, month: month).isEmpty else {
                                    if canAdd(year: year, month: month), !viewModel.isAccountFiltered {
                                        viewModel.errorMessage = nil
                                        reserveSheet = .addAmountOn(reserve, date: CellAddDate.date(year: year, month: month))
                                    }
                                    return
                                }
                                var target = monthTarget(name: reserve.name, categories: [reserve], year: year, month: month)
                                target.showsTransactions = false
                                cellSelection.select(key: cellKey(row, month: month), target: target)
                            }
                    }
                }
            }
        case .reservedTotal:
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        planCell(viewModel.reserveCell(viewModel.reserves, year: year, month: month)).bold()
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .monthSeparator(month)
                    }
                }
                .background(Color.purple.opacity(0.08))
            }
        case .groupHeader(let group, let categories):
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        planCell(viewModel.cell(categories, year: year, month: month)).bold()
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .monthSeparator(month)
                            .aggregateMonthCell(self, row: row, name: group.name, members: categories, year: year, month: month)
                    }
                }
                .background(Color.orange.opacity(0.10))
            }
        case .groupChild(let category):
            categoryCells(row, category, shaded: shaded)
        case .account(let account):
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        accountBalanceCell(viewModel.accountCell(account, year: year, month: month))
                            .frame(height: 28)
                            .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .monthSeparator(month)
                    }
                }
            }
        case .unassignedAccount:
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        unassignedCell(viewModel.unassignedForecast(year: year, month: month))
                            .frame(height: 28)
                            .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .monthSeparator(month)
                            .selectable(cellSelection, key: cellKey(row, month: month)) { openUnassigned(row, year: year, month: month) }
                    }
                }
            }
        case .totalsHeader:
            if viewModel.selectedYear != nil {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { _ in emptyBandCell }
                }
                .background(Color.accentColor.opacity(0.08))
            }
        case .totals(let totalsRow):
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        planCell(viewModel.totalsCell(totalsRow, year: year, month: month)).fontWeight(totalsRow == .net ? .bold : .semibold)
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .monthSeparator(month)
                            .selectable(cellSelection, key: cellKey(row, month: month)) { openTotalsMonth(row, totalsRow, year: year, month: month) }
                    }
                }
                .background(totalsRow.gridBackground)
            }
        case .netWorthTotal:
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        calendarCell(viewModel.netWorthTotal(year: year, month: month)).bold()
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .monthSeparator(month)
                    }
                }
                .background(Color.purple.opacity(0.10))
            }
        }
    }

    /// A row's Year Total for `year`, for the pinned right-hand column (and each year's
    /// column when several are selected). Same height and row background as the row's label
    /// and month cells (24pt for section/reserved headers, 28pt otherwise).
    @ViewBuilder
    private func yearTotalCell(_ row: GridRowKind, year: Int, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(_, let type):
            Group {
                if let type {
                    let members = categoriesByType(type)
                    planCell(viewModel.yearCell(members, year: year), isYearTotal: true, font: Self.captionMoneyFont).bold()
                        .frame(height: 24)
                        .yearTotalCellPanel(self, row: row, name: type.gridSectionName, members: members, year: year)
                } else {
                    emptyBandCell
                }
            }
            .background(Color.accentColor.opacity(0.08))
        case .category(let category), .groupChild(let category):
            // Nothing without an id, as `categoryCells` renders no months then.
            if category.id != nil {
                let yearCell = viewModel.yearCell([category], year: year)
                planCell(yearCell, isYearTotal: true).bold()
                    .frame(height: 28)
                    .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                    .yearTotalCellPanel(self, row: row, name: category.name, members: [category], year: year)
            }
        case .reservedHeader:
            emptyBandCell
                .background(Color.accentColor.opacity(0.08))
        case .reserve(let reserve):
            planCell(viewModel.reserveYearCell([reserve], year: year), isYearTotal: true).bold()
                .frame(height: 28)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        case .reservedTotal:
            planCell(viewModel.reserveYearCell(viewModel.reserves, year: year), isYearTotal: true).bold()
                .frame(height: 28)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .background(Color.purple.opacity(0.08))
        case .groupHeader(let group, let categories):
            planCell(viewModel.yearCell(categories, year: year), isYearTotal: true).bold()
                .frame(height: 28)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .background(Color.orange.opacity(0.10))
                .yearTotalCellPanel(self, row: row, name: group.name, members: categories, year: year)
        case .account(let account):
            // Year Total shows the year-end (December) balance rather than a sum —
            // summing 12 monthly balances isn't a meaningful figure for a balance row. Like
            // the year card: actual for past years, the forecast December with Show forecast,
            // today's balance this year without it.
            accountBalanceCell(viewModel.accountYearEnd(account, year: year)).bold()
                .frame(height: 28)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        case .unassignedAccount:
            unassignedCell(viewModel.unassignedForecast(year: year, month: 12)).bold()
                .frame(height: 28)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .selectable(cellSelection, key: cellKey(row, year: year)) { openUnassigned(row, year: year, month: nil) }
        case .totalsHeader:
            emptyBandCell
                .background(Color.accentColor.opacity(0.08))
        case .totals(let totalsRow):
            planCell(viewModel.totalsYearCell(totalsRow, year: year), isYearTotal: true).bold()
                .frame(height: 28)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .background(totalsRow.gridBackground)
                .selectable(cellSelection, key: cellKey(row, year: year)) { openTotalsYear(row, totalsRow, year: year) }
        case .netWorthTotal:
            // The year card's figure (today's net worth this year with Show forecast off).
            calendarCell(viewModel.yearEndNetWorth(year)?.valueMinorUnits).bold()
                .frame(height: 28)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .background(Color.purple.opacity(0.10))
        }
    }

    /// An empty cell of a header band (Accounts, Reserved): a cell's footprint, 24pt high.
    private var emptyBandCell: some View {
        Color.clear.frame(width: GridMetrics.columnWidth, height: 24)
    }

    /// A category's twelve month cells (for `.category` and `.groupChild`). A month cell
    /// opens the side panel (transactions plus planned occurrences) when it has a value or
    /// anything planned; an empty one in an open or future month opens Add planned item. Its Year Total (`yearTotalCell`) lists the year's transactions.
    @ViewBuilder
    private func categoryCells(_ row: GridRowKind, _ category: Category, shaded: Bool) -> some View {
        if let year = viewModel.selectedYear, let categoryId = category.id {
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    let cell = viewModel.cell(category, year: year, month: month)
                    planCell(cell)
                        .frame(height: 28)
                        .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .monthSeparator(month)
                        .noteMarker(viewModel.hasNote([category], year: year, month: month))
                        .selectable(cellSelection, key: cellKey(row, month: month)) {
                            guard cell.value != 0 || (viewModel.showForecast && hasShownOccurrences(category, year: year, month: month)) else {
                                // Empty (no actual, nothing planned): an open or future month adds a planned item.
                                if canAdd(year: year, month: month), category.type != .adjustment {
                                    viewModel.errorMessage = nil
                                    addPlannedTarget = AddPlannedTarget(type: category.type, categoryId: categoryId, date: CellAddDate.date(year: year, month: month))
                                }
                                return
                            }
                            cellSelection.select(key: cellKey(row, month: month),
                                                 target: monthTarget(name: category.name, categories: [category], year: year, month: month))
                        }
                }
            }
        }
    }

    // MARK: Side panel

    /// Opens the requested category's month panel (Show in Budget): once its year is the one
    /// shown, with its section expanded and its group open so the cell is outlined.
    private func applyRevealRequest() {
        guard let request = viewModel.revealRequest else { return }
        guard viewModel.selectedYear == request.year else {
            // The year change re-applies this (`onChange(of: selectedYears)`).
            if viewModel.availableYears.contains(request.year) { viewModel.selectYear(request.year) } else { viewModel.revealRequest = nil }
            return
        }
        viewModel.revealRequest = nil
        guard let category = viewModel.categories.first(where: { $0.id == request.categoryId }), !category.isReserved else { return }
        let row: GridRowKind
        if let groupId = category.groupId {
            guard viewModel.categoryGroups.contains(where: { $0.id == groupId }) else { return }
            row = .groupChild(category)
        } else {
            row = .category(category)
        }
        updateOutline { outline in
            let section = GridOutline.sectionKey(category.type)
            if outline.isCollapsed(section) { outline.toggleSection(section) }
            if let groupId = category.groupId { outline.setGroups([groupId], expanded: true) }
        }
        cellSelection.select(key: cellKey(row, month: request.month),
                             target: monthTarget(name: category.name, categories: [category], year: request.year, month: request.month))
    }

    /// A cell's selection key: its row and its month (or year) column.
    fileprivate func cellKey(_ row: GridRowKind, month: Int) -> String { "\(row.id)|m\(month)" }
    fileprivate func cellKey(_ row: GridRowKind, year: Int) -> String { "\(row.id)|y\(year)" }

    /// A month cell's panel for `categories` (one category, or a group's or section's
    /// members, which name each transaction's category): the pay month's transactions and the
    /// calendar month's planned occurrences.
    fileprivate func monthTarget(name: String, categories: [Category], year: Int, month: Int) -> GridCellTarget {
        let range = viewModel.dateRange(forYear: year, month: month)
        return GridCellTarget(title: "\(name) — \(GridMonthLabel.shortMonthYear(year: year, month: month))", categoryIds: Set(categories.compactMap(\.id)),
                                start: range.start, end: range.end, showCategory: categories.count > 1,
                                plan: CellPlan(categories: categories, year: year, month: month))
    }

    /// A Year Total (or multi-year year column) cell's panel: the year's transactions only.
    fileprivate func yearTarget(name: String, categories: [Category], year: Int, showCategory: Bool) -> GridCellTarget {
        let range = viewModel.dateRange(forYear: year)
        return GridCellTarget(title: "\(name) — \(year)", categoryIds: Set(categories.compactMap(\.id)),
                                start: range.start, end: range.end, showCategory: showCategory, plan: nil)
    }

    /// Opens a group's or section's month panel when its members have any transaction or, with
    /// Show forecast on, planned occurrence there (an empty aggregate cell does nothing).
    fileprivate func openAggregateMonth(_ row: GridRowKind, name: String, members: [Category], year: Int, month: Int) {
        var target = monthTarget(name: name, categories: members, year: year, month: month)
        let hasTransactions = !viewModel.transactions(forCategoryIds: target.categoryIds, from: target.start, to: target.end).isEmpty
        guard hasTransactions || (viewModel.showForecast && members.contains(where: { hasShownOccurrences($0, year: year, month: month) })) else { return }
        target.showCategory = true
        cellSelection.select(key: cellKey(row, month: month), target: target)
    }

    /// Whether the cell's panel would list planned occurrences (the filter's accounts' only).
    fileprivate func hasShownOccurrences(_ category: Category, year: Int, month: Int) -> Bool {
        !viewModel.occurrences(category: category, year: year, month: month).isEmpty
    }

    /// Opens a Year Total's panel when the year has any of its transactions.
    fileprivate func openYear(_ row: GridRowKind, name: String, members: [Category], year: Int) {
        var showCategory = members.count > 1
        if case .groupHeader = row { showCategory = true }
        if case .sectionHeader = row { showCategory = true }
        let target = yearTarget(name: name, categories: members, year: year, showCategory: showCategory)
        guard !viewModel.transactions(forCategoryIds: target.categoryIds, from: target.start, to: target.end).isEmpty else { return }
        cellSelection.select(key: cellKey(row, year: year), target: target)
    }

    /// A Totals row's month panel (budget-totals spec §1): the transactions and planned
    /// occurrences it sums, when there are any (an empty cell does nothing).
    fileprivate func openTotalsMonth(_ row: GridRowKind, _ totalsRow: BudgetTotals.Row, year: Int, month: Int) {
        let range = viewModel.dateRange(forYear: year, month: month)
        let hasTransactions = !viewModel.totalsTransactions(totalsRow, from: range.start, to: range.end).isEmpty
        let hasPlan = viewModel.showForecast && (!viewModel.totalsOccurrences(totalsRow, year: year, month: month).isEmpty || viewModel.totalsReserved(totalsRow, year: year, month: month) != 0)
        guard hasTransactions || hasPlan else { return }
        var plan = CellPlan(categories: [], year: year, month: month)
        plan.totals = totalsRow
        var target = GridCellTarget(title: "\(totalsRow.title) — \(GridMonthLabel.shortMonthYear(year: year, month: month))", categoryIds: [],
                                      start: range.start, end: range.end, showCategory: true, plan: plan)
        target.totals = totalsRow
        cellSelection.select(key: cellKey(row, month: month), target: target)
    }

    /// A Totals row's Year Total panel: the year's transactions it sums.
    fileprivate func openTotalsYear(_ row: GridRowKind, _ totalsRow: BudgetTotals.Row, year: Int) {
        let range = viewModel.dateRange(forYear: year)
        guard !viewModel.totalsTransactions(totalsRow, from: range.start, to: range.end).isEmpty else { return }
        var target = GridCellTarget(title: "\(totalsRow.title) — \(year)", categoryIds: [], start: range.start, end: range.end, showCategory: true, plan: nil)
        target.totals = totalsRow
        cellSelection.select(key: cellKey(row, year: year), target: target)
    }

    /// A "Not assigned to an account" cell's panel (budget-totals spec §2): the period's
    /// unassigned planned items, to assign; nothing when there are none.
    fileprivate func openUnassigned(_ row: GridRowKind, year: Int, month: Int?) {
        guard viewModel.showForecast, !viewModel.unassignedRows(year: year, month: month).isEmpty else { return }
        let range = month.map { viewModel.dateRange(forYear: year, month: $0) } ?? viewModel.dateRange(forYear: year)
        let period = month.map { GridMonthLabel.shortMonthYear(year: year, month: $0) } ?? String(year)
        var target = GridCellTarget(title: "Not assigned to an account — \(period)", categoryIds: [], start: range.start, end: range.end, plan: nil)
        target.showsTransactions = false
        target.unassigned = UnassignedPeriod(year: year, month: month)
        cellSelection.select(key: month.map { cellKey(row, month: $0) } ?? cellKey(row, year: year), target: target)
    }

    /// Whether the Year Total column is pinned on the right (whenever a single year is shown;
    /// several years show each year's total in the scrolling area instead).
    private var showsPinnedYearTotal: Bool { viewModel.selectedYear != nil }

    /// Several years selected: the scrolling area shows the year-over-year columns.
    private var isMultiYear: Bool { viewModel.selectedYears.count > 1 }

    /// The scrolling area's full width (its cap): twelve months, or per selected year a total
    /// column plus Δ £ and Δ % after every year but the first.
    private var scrollingWidth: CGFloat {
        isMultiYear ? CGFloat(3 * viewModel.selectedYears.count - 2) * GridMetrics.columnWidth : GridMetrics.monthsWidth
    }

    private static let bodyMoneyFont = PlanCellView.bodyFont
    private static let captionMoneyFont = PlanCellView.captionFont

    /// A cell with its unconfirmed part shown (`PlanCellView`).
    private func planCell(_ cell: BudgetGridViewModel.PlanCell, isYearTotal: Bool = false, font: Font = bodyMoneyFont) -> some View {
        PlanCellView(value: cell.value, pending: cell.pending, state: cell.state, isYearTotal: isYearTotal, font: font)
    }

    /// An account row's month: an actual balance as it was; a forecast one italic in the
    /// pending colour, in the account's currency (GBP in the help for others); "—" without one.
    private func accountBalanceCell(_ cell: BudgetGridViewModel.AccountCell) -> some View {
        Group {
            switch cell {
            case .actual(let balance?):
                MoneyText(minorUnits: balance.nativeBalanceMinorUnits, currency: balance.account.currency, alignment: .trailing)
                    // Carried-forward balances (no fresh snapshot/transaction that month)
                    // read a bit lighter, so a stale figure doesn't look like a fresh update.
                    .opacity(balance.isCarriedForward ? 0.55 : 1.0)
            case .forecast(let balance, let currency):
                MoneyText(minorUnits: balance.nativeMinorUnits, currency: currency, font: Self.bodyMoneyFont.italic(), alignment: .trailing, tint: .pending)
                    .help(currency == .gbp ? "Forecast: today's balance plus this account's planned items"
                          : "Forecast: today's balance plus this account's planned items (\(Money.format(balance.gbpMinorUnits, currency: .gbp)))")
            case .today(let native, let currency):
                MoneyText(minorUnits: native, currency: currency, alignment: .trailing)
                    .help("Today's balance")
            case .actual(nil), .blank:
                Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: GridMetrics.cellWidth)
        .padding(.horizontal, GridMetrics.cellPadding)
    }

    /// A "Not assigned to an account" month: the unassigned planned items accumulated (a
    /// forecast, so italic in the pending colour); "—" for none.
    private func unassignedCell(_ total: Int?) -> some View {
        Group {
            if let total, total != 0 {
                MoneyText(minorUnits: total, font: Self.bodyMoneyFont.italic(), alignment: .trailing, tint: .pending)
            } else {
                Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: GridMetrics.cellWidth)
        .padding(.horizontal, GridMetrics.cellPadding)
    }

    /// A Net Worth cell; nil or 0 (no data, or a month past today with Show forecast off) reads "—".
    private func calendarCell(_ total: Int?) -> some View {
        Group {
            if let total, total != 0 {
                MoneyText(minorUnits: total, alignment: .trailing)
            } else {
                Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: GridMetrics.cellWidth)
        .padding(.horizontal, GridMetrics.cellPadding)
    }
}

private extension View {
    /// A group's or section's month cell: its note marker, outline and click-through to the
    /// aggregate panel.
    @MainActor
    func aggregateMonthCell(_ grid: BudgetGridView, row: BudgetGridView.GridRowKind, name: String, members: [Category], year: Int, month: Int) -> some View {
        noteMarker(grid.viewModel.hasNote(members, year: year, month: month))
            .selectable(grid.cellSelection, key: grid.cellKey(row, month: month)) { grid.openAggregateMonth(row, name: name, members: members, year: year, month: month) }
    }

    /// A Year Total (or multi-year year) cell: its note marker, outline and click-through to
    /// the year's transactions.
    @MainActor
    func yearTotalCellPanel(_ grid: BudgetGridView, row: BudgetGridView.GridRowKind, name: String, members: [Category], year: Int) -> some View {
        noteMarker(grid.viewModel.hasNote(members, year: year))
            .selectable(grid.cellSelection, key: grid.cellKey(row, year: year)) { grid.openYear(row, name: name, members: members, year: year) }
    }

    /// A multi-year value cell's footprint, right-aligned like the month cells.
    func multiYearValueCell() -> some View {
        frame(width: GridMetrics.cellWidth, alignment: .trailing)
            .padding(.horizontal, GridMetrics.cellPadding)
    }

    /// The leading 1pt separator between multi-year groups (none before the first year: the
    /// category column draws its own).
    func yearGroupSeparator(_ index: Int) -> some View {
        overlay(Rectangle().frame(width: 1).foregroundStyle(.separator).opacity(index > 0 ? 1 : 0), alignment: .leading)
    }
}
