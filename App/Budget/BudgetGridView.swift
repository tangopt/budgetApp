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
    @State private var drillDownTarget: GridDrillDownTarget?
    /// Held in `@State` (not `@StateObject`/`@ObservedObject`) on purpose: this view must not
    /// observe it, or every horizontal scroll frame would re-run this whole `body`. Only the
    /// header's `HorizontalOffsetFollower` observes it.
    @State private var scrollOffset = HorizontalScrollOffset()
    @State private var expandedGroupIds: Set<Int64> = []
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
        var id: String {
            switch self {
            case .newReserve: return "new-reserve"
            case .addAmount(let reserve): return "add-amount-\(reserve.id ?? -1)"
            }
        }
    }

    /// The section a header's "+ Add planned item" adds to (`.sheet(item:)`).
    private struct AddPlannedTarget: Identifiable {
        let type: CategoryType
        var id: String { type.rawValue }
    }

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type && !$0.isReserved }
    }

    private enum GridRowKind: Identifiable {
        /// `type` is nil for the Accounts header (no planned items, no totals).
        case sectionHeader(String, CategoryType?)
        case category(Category)
        case groupHeader(CategoryGroup, categories: [Category])
        case groupChild(Category)
        case account(Account)
        case netWorthTotal
        case reservedHeader
        case reserve(Category)
        case reservedTotal

        var id: String {
            switch self {
            case .sectionHeader(let title, _): return "header-\(title)"
            case .category(let category): return "cat-\(category.id ?? -1)"
            case .groupHeader(let group, let categories): return "group-\(group.id ?? -1)-\(categories.first?.type.rawValue ?? "")"
            case .groupChild(let category): return "groupchild-\(category.id ?? -1)"
            case .account(let account): return "account-\(account.id ?? -1)"
            case .netWorthTotal: return "networth-total"
            case .reservedHeader: return "reserved-header"
            case .reserve(let reserve): return "reserve-\(reserve.id ?? -1)"
            case .reservedTotal: return "reserved-total"
            }
        }
    }

    /// Categories sharing a `groupId` collapse into one `.groupHeader` row (first-seen
    /// order wins for where the group appears), expanding to a `.groupChild` row per
    /// member only when its id is in `expandedGroupIds`. Ungrouped categories render
    /// exactly as `.category`, interleaved in the section's existing order.
    private func rowKinds(for type: CategoryType) -> [GridRowKind] {
        let cats = categoriesByType(type)
        var rows: [GridRowKind] = []
        var seenGroupIds: Set<Int64> = []
        for category in cats {
            if let groupId = category.groupId {
                guard !seenGroupIds.contains(groupId) else { continue }
                seenGroupIds.insert(groupId)
                guard let group = viewModel.categoryGroups.first(where: { $0.id == groupId }) else { continue }
                let members = cats.filter { $0.groupId == groupId }
                rows.append(.groupHeader(group, categories: members))
                if expandedGroupIds.contains(groupId) {
                    rows += members.map { .groupChild($0) }
                }
            } else {
                rows.append(.category(category))
            }
        }
        return rows
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

    private func rowColor(for type: CategoryType) -> Color {
        switch type {
        case .income: return .green
        case .expense: return .red
        case .transfer: return .blue
        }
    }

    private var allRows: [GridRow] {
        func section(_ title: String, _ type: CategoryType) -> [GridRow] {
            var rows: [GridRow] = [GridRow(kind: .sectionHeader(title, type), shaded: false)]
            for (index, kind) in rowKinds(for: type).enumerated() {
                rows.append(GridRow(kind: kind, shaded: index % 2 == 1))
            }
            return rows
        }
        var accountRows: [GridRow] = [GridRow(kind: .sectionHeader("Accounts", nil), shaded: false)]
        for (index, account) in viewModel.accounts.enumerated() {
            accountRows.append(GridRow(kind: .account(account), shaded: index % 2 == 1))
        }
        accountRows.append(GridRow(kind: .netWorthTotal, shaded: false))
        var reservedRows: [GridRow] = [GridRow(kind: .reservedHeader, shaded: false)]
        for (index, reserve) in viewModel.reserves.enumerated() {
            reservedRows.append(GridRow(kind: .reserve(reserve), shaded: index % 2 == 1))
        }
        if !viewModel.reserves.isEmpty { reservedRows.append(GridRow(kind: .reservedTotal, shaded: false)) }
        return section("Income", .income) + section("Expenses", .expense) + reservedRows + section("Transfers", .transfer) + accountRows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            yearPicker

            // Close/reopen errors from the header menu (a failed Close month… shows in its
            // sheet instead; the drill-down sheet shows recategorize errors itself).
            if let error = viewModel.errorMessage, drillDownTarget == nil, closeTarget == nil, addPlannedTarget == nil, reserveSheet == nil, renamingReserve == nil {
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

            // spacing: 0 so the frozen header sits flush on the body, with no gap for
            // scrolled rows to show through.
            VStack(alignment: .leading, spacing: 0) {
                // Frozen month-header row: lives outside the vertical scroll (so it never
                // moves vertically), and mirrors the body's horizontal scroll offset (so it
                // stays aligned with whichever columns are currently visible).
                HStack(spacing: 0) {
                    Text("Category").font(.headline).frame(width: 220, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    if let year = viewModel.selectedYear {
                        HorizontalOffsetFollower(offset: scrollOffset) {
                            HStack(spacing: 0) {
                                ForEach(1...12, id: \.self) { month in
                                    let payMonth = PayMonth(year: year, month: month)
                                    Text(Self.monthYearLabel(year: year, month: month))
                                        .frame(width: 120, alignment: .trailing)
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                        // Columns are pay months: the tooltip shows the real range.
                                        .help(PayMonthFormat.range(viewModel.payCalendar.range(of: payMonth)))
                                        .contextMenu { monthMenu(payMonth) }
                                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                                }
                                Text("Year Total").bold()
                                    .frame(width: 120, alignment: .trailing)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                            }
                        }
                        // minWidth: 0 makes this frame take exactly the width it's offered
                        // (what's left of the window after the Category cell) rather than
                        // growing to the 13 columns' full width, which would push the whole
                        // screen wider than the window; the overflow is then clipped.
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .clipped()
                    }
                }
                .font(.headline)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(Rectangle().frame(height: 1.5).foregroundStyle(Color.primary.opacity(0.18)), alignment: .bottom)
                // A frozen row that floats above the scrolling body reads better with a
                // little elevation; kept as a constant subtle shadow rather than toggled by
                // scroll position, to avoid adding a second scroll-tracked PreferenceKey purely
                // for a decorative effect.
                .shadow(color: .black.opacity(0.08), radius: 3, y: 2)

                // Built once per render and shared by the label column and the cells.
                let rows = allRows
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
                    }
                }
            }

            if let year = viewModel.selectedYear, hasPending(year: year) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Image(systemName: "circle.lefthalf.filled")
                    Text("Italic amounts include planned money not yet confirmed. Hover a cell (or a Year Total) for how much.")
                }
                .font(.caption)
                .foregroundStyle(Color.pending)
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
        // onDismiss clears any recategorize error so it can't bleed into the next,
        // unrelated drill-down.
        .sheet(item: $drillDownTarget, onDismiss: { viewModel.errorMessage = nil }) { target in
            GridDrillDownSheet(target: target, viewModel: viewModel)
        }
        .sheet(item: $addPlannedTarget) { target in
            AddPlannedItemSheet(type: target.type, scope: .budget, categories: viewModel.categories, plannedEntries: viewModel.plannedEntries) { category, amount, frequency, interval, start, end in
                switch category {
                case .existing(let id):
                    return viewModel.addPlannedItem(categoryId: id, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end)
                case .new(let name):
                    return viewModel.addPlannedItem(newCategoryName: name, type: target.type, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end)
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
            }
        }
        .sheet(item: $renamingReserve, onDismiss: { reserveError = nil }) { reserve in
            RenameReserveView(reserve: reserve, errorMessage: reserveError, onEdit: clearReserveError) { name in
                finishReserveSave(viewModel.renameReserve(reserve, to: name)) { renamingReserve = nil }
            }
        }
        .confirmationDialog("Delete “\(deletingReserve?.name ?? "")”? Its allowances are removed from the plan and from every scenario.", isPresented: Binding(
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
                        viewModel.selectedYear = year
                    } label: {
                        VStack(spacing: 2) {
                            Text(String(year)).font(.subheadline).bold()
                            // Year-over-year change in total net worth, not income minus
                            // expenses minus transfers — money moved into the user's own
                            // ISA/savings accounts doesn't reduce net worth, so this doesn't
                            // swing hugely negative in a year with a big internal transfer.
                            if let change = viewModel.netWorthChange(year) {
                                MoneyText(minorUnits: change)
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                            if let percent = viewModel.netWorthChangePercent(year) {
                                Text("\(percent >= 0 ? "↑" : "↓") \(String(format: "%.1f", abs(percent) * 100))%")
                                    .font(.caption2)
                                    .foregroundStyle(percent >= 0 ? Color.green : Color.red)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(viewModel.selectedYear == year ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(viewModel.selectedYear == year ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
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

    @ViewBuilder
    private func rowLabel(_ row: GridRowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(let title, let type):
            HStack {
                Text(title)
                    .font(.caption).bold()
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if let type {
                    Button("+ Add planned item") {
                        viewModel.errorMessage = nil
                        addPlannedTarget = AddPlannedTarget(type: type)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .frame(width: 220, height: 24, alignment: .leading)
            .padding(.horizontal, 8)
            .background(Color.accentColor.opacity(0.08))
        case .category(let category):
            Text(category.name)
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(rowColor(for: category.type)), alignment: .leading)
        case .groupHeader(let group, let categories):
            Button {
                if let id = group.id {
                    if expandedGroupIds.contains(id) { expandedGroupIds.remove(id) } else { expandedGroupIds.insert(id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: (group.id.map { expandedGroupIds.contains($0) } ?? false) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(group.name).bold()
                }
            }
            .buttonStyle(.plain)
            .frame(width: 220, height: 28, alignment: .leading)
            .padding(.horizontal, 8)
            .background(Color.orange.opacity(0.10))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            .overlay(Rectangle().frame(width: 3).foregroundStyle(categories.first.map { rowColor(for: $0.type) } ?? .clear), alignment: .leading)
        case .groupChild(let category):
            Text(category.name).foregroundStyle(.secondary)
                .frame(width: 200, height: 28, alignment: .leading)
                .padding(.leading, 28).padding(.trailing, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(rowColor(for: category.type)), alignment: .leading)
        case .account(let account):
            Text(account.name)
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(Color.purple), alignment: .leading)
        case .reservedHeader:
            HStack {
                Text("RESERVED")
                    .font(.caption).bold()
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("+ Add reserve…") {
                    viewModel.errorMessage = nil
                    reserveSheet = .newReserve
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .frame(width: 220, height: 24, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.08))
        case .reserve(let reserve):
            Text(reserve.name)
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(.purple), alignment: .leading)
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
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.purple.opacity(0.08))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(.purple), alignment: .leading)
        case .netWorthTotal:
            Text("Net Worth").bold()
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.purple.opacity(0.10))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(Color.purple), alignment: .leading)
        }
    }

    @ViewBuilder
    private func rowCells(_ row: GridRowKind, shaded: Bool) -> some View {
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
                        }
                        planCell(viewModel.yearCell(members, year: year), isYearTotal: true, font: Self.captionMoneyFont).bold()
                            .frame(height: 24)
                    } else {
                        ForEach(1...(12 + 1), id: \.self) { _ in
                            // Same footprint as a cell: 120pt frame + 8pt padding either
                            // side, so the band spans exactly the 13 columns.
                            Color.clear.frame(width: 120, height: 24).padding(.horizontal, 8)
                        }
                    }
                }
                .background(Color.accentColor.opacity(0.08))
            }
        case .category(let category):
            categoryCells(category, shaded: shaded)
        case .reservedHeader:
            if viewModel.selectedYear != nil {
                HStack(spacing: 0) {
                    ForEach(1...(12 + 1), id: \.self) { _ in
                        Color.clear.frame(width: 120, height: 24).padding(.horizontal, 8)
                    }
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
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !viewModel.occurrences(category: reserve, year: year, month: month).isEmpty else { return }
                                drillDownTarget = .planned(title: "\(reserve.name) — \(Self.monthYearLabel(year: year, month: month))",
                                                           plan: DrillDownPlan(category: reserve, year: year, month: month))
                            }
                    }
                    planCell(PlanStatus.combine((1...12).map { viewModel.reserveCell([reserve], year: year, month: $0) }), isYearTotal: true).bold()
                        .frame(height: 28)
                        .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                }
            }
        case .reservedTotal:
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        planCell(viewModel.reserveCell(viewModel.reserves, year: year, month: month)).bold()
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    }
                    planCell(PlanStatus.combine((1...12).map { viewModel.reserveCell(viewModel.reserves, year: year, month: $0) }), isYearTotal: true).bold()
                        .frame(height: 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                }
                .background(Color.purple.opacity(0.08))
            }
        case .groupHeader(_, let categories):
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        planCell(viewModel.cell(categories, year: year, month: month)).bold()
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    }
                    planCell(viewModel.yearCell(categories, year: year), isYearTotal: true).bold()
                        .frame(height: 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                }
                .background(Color.orange.opacity(0.10))
            }
        case .groupChild(let category):
            categoryCells(category, shaded: shaded)
        case .account(let account):
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        accountBalanceCell(viewModel.accountBalance(account, year: year, month: month))
                            .frame(height: 28)
                            .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    }
                    // Year Total shows the year-end (December) balance rather than a sum —
                    // summing 12 monthly balances isn't a meaningful figure for a balance row.
                    accountBalanceCell(viewModel.accountBalance(account, year: year, month: 12)).bold()
                        .frame(height: 28)
                        .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                }
            }
        case .netWorthTotal:
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        calendarCell(viewModel.netWorthTotal(year: year, month: month)).bold()
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    }
                    calendarCell(viewModel.netWorthTotal(year: year, month: 12)).bold()
                        .frame(height: 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                }
                .background(Color.purple.opacity(0.10))
            }
        }
    }

    /// A category's twelve month cells and Year Total (for `.category` and `.groupChild`).
    /// A month cell opens the drill-down (transactions plus planned occurrences) when it has
    /// a value or anything planned; the Year Total lists the year's transactions.
    @ViewBuilder
    private func categoryCells(_ category: Category, shaded: Bool) -> some View {
        if let year = viewModel.selectedYear, let categoryId = category.id {
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    let cell = viewModel.cell(category, year: year, month: month)
                    planCell(cell)
                        .frame(height: 28)
                        .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard cell.value != 0 || !viewModel.occurrences(category: category, year: year, month: month).isEmpty else { return }
                            let range = viewModel.dateRange(forYear: year, month: month)
                            let matching = viewModel.transactions(forCategoryId: categoryId, from: range.start, to: range.end)
                            drillDownTarget = .transactions(title: "\(category.name) — \(Self.monthYearLabel(year: year, month: month))", transactions: matching,
                                                            plan: DrillDownPlan(category: category, year: year, month: month))
                        }
                }
                let yearCell = viewModel.yearCell([category], year: year)
                planCell(yearCell, isYearTotal: true).bold()
                    .frame(height: 28)
                    .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let range = viewModel.dateRange(forYear: year)
                        let matching = viewModel.transactions(forCategoryId: categoryId, from: range.start, to: range.end)
                        guard !matching.isEmpty else { return }
                        drillDownTarget = .transactions(title: "\(category.name) — \(year)", transactions: matching, plan: nil)
                    }
            }
        }
    }

    private static let bodyMoneyFont = PlanCellView.bodyFont
    private static let captionMoneyFont = PlanCellView.captionFont

    /// A cell with its unconfirmed part shown (`PlanCellView`).
    private func planCell(_ cell: BudgetGridViewModel.PlanCell, isYearTotal: Bool = false, font: Font = bodyMoneyFont) -> some View {
        PlanCellView(value: cell.value, pending: cell.pending, state: cell.state, isYearTotal: isYearTotal, font: font)
    }

    /// Whether any row of `year` still carries unconfirmed money (for the footnote).
    private func hasPending(year: Int) -> Bool {
        let planned = viewModel.categories.filter { !$0.isReserved }
        return (1...12).contains { month in
            viewModel.cell(planned, year: year, month: month).state != .none
                || viewModel.reserveCell(viewModel.reserves, year: year, month: month).state != .none
        }
    }

    private func accountBalanceCell(_ balance: MonthlyAccountBalance?) -> some View {
        Group {
            if let balance {
                MoneyText(minorUnits: balance.nativeBalanceMinorUnits, currency: balance.account.currency, alignment: .trailing)
                    // Carried-forward balances (no fresh snapshot/transaction that month)
                    // read a bit lighter, so a stale figure doesn't look like a fresh update.
                    .opacity(balance.isCarriedForward ? 0.55 : 1.0)
            } else {
                Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: 120)
        .padding(.horizontal, 8)
    }

    private func calendarCell(_ total: Int) -> some View {
        Group {
            if total == 0 {
                Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                MoneyText(minorUnits: total, alignment: .trailing)
            }
        }
        .frame(width: 120)
        .padding(.horizontal, 8)
    }

    private static func monthYearLabel(year: Int, month: Int) -> String {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return "\(month)/\(year)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
