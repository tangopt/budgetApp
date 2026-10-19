// App/Forecast/ScenarioGridTab.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// The Grid chips (one plan: the Budget or a scenario), a header bar in that plan's colour,
/// the year cards (`YearCard`: each horizon year captioned " forecast", with the plan's
/// year-end net worth and its change on the previous year-end; ⌘-click compares several
/// years, shown as the Budget grid's multi-year columns), then the plan month by month
/// (categories × the twelve months of a year within the horizon), valued as the Budget grid values it (`ScenarioComparison.grid`), with the Budget
/// grid's look and behaviour (spec 2026-10-15-forecast-grid-parity-design.md): category
/// icons, collapsible sections and groups, the Totals block, and cell selection with the
/// shared side panel (`GridCellPanel`: the cell's actual transactions and the plan's
/// occurrences, with Edit… / Remove… for a scenario's). For a scenario, cells that differ from
/// the Budget are shaded in a light tint of the scenario's colour, an empty open-month cell
/// adds an item and section headers add items — the Budget grid's own sheets, scoped to the
/// scenario. The Budget shows read-only.
///
/// Same frozen header / frozen columns (category left, Year Total right) technique as
/// `BudgetGridView`: the horizontal offset lives in a `HorizontalScrollOffset` held in plain
/// `@State` and observed only by the header's `HorizontalOffsetFollower`, so scrolling never
/// re-runs this `body`.
struct ScenarioGridTab: View {
    @ObservedObject var viewModel: ScenarioLabViewModel
    @Environment(\.theme) private var theme
    @Binding var chipPrompts: ScenarioChipPrompts
    @State private var scrollOffset = HorizontalScrollOffset()
    @State private var bodyWidth = GridBodyWidth()
    /// Collapsed sections and expanded groups (`GridOutline`), remembered across launches
    /// (one outline for every scenario).
    @AppStorage("forecastGrid.collapsedSections") private var collapsedSectionsStore = ""
    @AppStorage("forecastGrid.expandedGroups") private var expandedGroupsStore = ""
    /// The clicked cell whose side panel is open. Plain `@State` like `scrollOffset`: only the
    /// cells' outlines and the panel host observe it, so a click doesn't re-run `body`.
    @State private var cellSelection = CellSelection<GridCellTarget>()
    @State private var addTarget: AddTarget?
    @State private var addingAllowance = false
    /// An empty reserve cell's Add allowance: the reserve and the start date.
    @State private var cellAllowance: CellAllowance?
    /// A failed allowance save, shown inside the open form.
    @State private var allowanceError: String?

    private struct AddTarget: Identifiable {
        let type: CategoryType
        let scope: PlanScope
        /// From an empty cell: the category preselected and the one-off's date.
        var categoryId: Int64?
        var date: Date?
        var id: String { "\(type.rawValue)-\(categoryId ?? -1)-\(date?.timeIntervalSince1970 ?? 0)" }
    }

    private struct CellAllowance: Identifiable {
        let reserve: Category
        let date: Date
        var id: String { "\(reserve.id ?? -1)-\(date.timeIntervalSince1970)" }
    }

    private enum RowKind: Identifiable {
        case sectionHeader(String, CategoryType)
        case category(Category)
        case groupHeader(CategoryGroup, categories: [Category])
        case groupChild(Category)
        case reservedHeader
        case reserve(Category)
        case reservedTotal
        /// The Totals block: its header and Total in / Total out / Net.
        case totalsHeader
        case totals(BudgetTotals.Row)

        var id: String {
            switch self {
            case .sectionHeader(let title, _): return "header-\(title)"
            case .category(let category): return "cat-\(category.id ?? -1)"
            case .groupHeader(let group, let categories): return "group-\(group.id ?? -1)-\(categories.first?.type.rawValue ?? "")"
            case .groupChild(let category): return "groupchild-\(category.id ?? -1)"
            case .reservedHeader: return "reserved-header"
            case .reserve(let reserve): return "reserve-\(reserve.id ?? -1)"
            case .reservedTotal: return "reserved-total"
            case .totalsHeader: return "totals-header"
            case .totals(let row): return "totals-\(row.rawValue)"
            }
        }
    }

    private struct Row: Identifiable {
        let kind: RowKind
        let shaded: Bool
        var id: String { kind.id }
    }

    /// A combined cell: the plan's value, pending part and state, and the Budget's value.
    private typealias Cell = (value: Int, pending: Int, state: PendingState, budgetValue: Int)

    private var isReadOnly: Bool { viewModel.editScope == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScenarioChips(viewModel: viewModel, mode: .single(selected: $viewModel.gridSelection), prompts: $chipPrompts)
            headerBar
                .padding(.bottom, 12)  // the chips' own 16pt bottom padding sits above the bar
            YearCardRow(years: viewModel.gridYears, onSelect: { year in
                // ⌘-click adds or removes a year (to compare several); a plain click shows
                // just that year.
                if NSEvent.modifierFlags.contains(.command) {
                    viewModel.toggleGridYear(year)
                } else {
                    viewModel.selectGridYear(year)
                }
            }, help: "⌘-click to compare several years") { year in
                // Every year-end on the Forecast screen is a forecast (today's year included).
                YearCard(year: year, caption: " forecast",
                         yearEnd: viewModel.gridYearEnds[year], change: viewModel.gridYearEndChange(year),
                         percent: viewModel.gridYearEndChangePercent(year), isSelected: viewModel.gridSelectedYears.contains(year))
            }
            .padding(.bottom, 8)
            SidePanelHost(selection: cellSelection) {
                grid
            } panel: { target in
                GridCellPanel(target: target, model: viewModel) { cellSelection.clear() }
            }
        }
        // A panel belongs to the plan and the years it was opened in.
        .onChange(of: viewModel.gridSelection) { _, _ in cellSelection.clear() }
        .onChange(of: viewModel.gridSelectedYears) { _, _ in cellSelection.clear() }
        .sheet(isPresented: $addingAllowance, onDismiss: { allowanceError = nil }) {
            ReserveFormView(mode: .chooseReserve(reserves: viewModel.reserves, scenarioName: viewModel.gridScenario?.name ?? ""),
                            errorMessage: allowanceError, onEdit: { if allowanceError != nil { allowanceError = nil } }) { target, amount, frequency, interval, start, end in
                switch viewModel.addReserveAllowance(target, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end) {
                case .saved, .savedButReloadFailed: addingAllowance = false
                case .failed(let message): allowanceError = message
                }
            }
        }
        .sheet(item: $cellAllowance, onDismiss: { allowanceError = nil }) { cell in
            ReserveFormView(mode: .addAmountInScenario(cell.reserve, scenarioName: viewModel.gridScenario?.name ?? ""), errorMessage: allowanceError, initialDate: cell.date,
                            onEdit: { if allowanceError != nil { allowanceError = nil } }) { target, amount, frequency, interval, start, end in
                switch viewModel.addReserveAllowance(target, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end) {
                case .saved, .savedButReloadFailed: cellAllowance = nil
                case .failed(let message): allowanceError = message
                }
            }
        }
        .sheet(item: $addTarget) { target in
            AddPlannedItemSheet(type: target.type, scope: target.scope, categories: viewModel.categories, plannedEntries: viewModel.scenarioPlanEntries,
                                accountOptions: viewModel.accountOptions, initialCategoryId: target.categoryId, initialDate: target.date) { category, amount, frequency, interval, start, end, accountId in
                viewModel.addPlannedItem(category, type: target.type, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end, accountId: accountId)
            }
        }
    }

    /// "Editing <name>" (with the differs legend) or "Budget — read-only", in the plan's colour.
    private var headerBar: some View {
        let color = planColor
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            if let scenario = viewModel.gridScenario {
                Text("Editing \(Text(scenario.name).bold())")
                Spacer()
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(differsFill).frame(width: 14, height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.5), lineWidth: 0.5))
                    Text("differs from the budget")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(Text("Budget").bold()) — read-only, edit it in the Budget grid")
                Spacer()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.6), lineWidth: 1))
    }

    private var grid: some View {
        let year = viewModel.gridYear
        let years = viewModel.gridSelectedYears
        let isMultiYear = years.count > 1
        let scrollingWidth = isMultiYear ? MultiYearColumns.width(yearCount: years.count) : GridMetrics.monthsWidth
        let rows = allRows(outline)
        return VStack(alignment: .leading, spacing: 0) {
            // The header row takes the body's measured width (`GridBodyWidth`), so the pinned
            // Year Total header sits exactly over its column whatever the scroller style.
            BodyWidthFollower(width: bodyWidth) {
                HStack(spacing: 0) {
                    Text("Category").font(.headline).frame(width: 220, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    HorizontalOffsetFollower(offset: scrollOffset) {
                        if isMultiYear {
                            // Several years: each year's total, and after every year but the
                            // first its change from the previous selected year.
                            MultiYearHeaderRow(years: years)
                        } else {
                            monthHeaders(year)
                        }
                    }
                    // As in `BudgetGridView`: no wider than the body's scroller, so the pinned
                    // Year Total sits right after December in a wide window.
                    .frame(minWidth: 0, maxWidth: scrollingWidth, alignment: .leading)
                    .clipped()
                    // Clipping hides the scrolled-off columns but not from clicks: without this they
                    // catch clicks meant for whatever sits beside the grid (the account panel).
                    .contentShape(Rectangle())
                    if !isMultiYear {
                        Text("Year Total").bold()
                            .frame(width: GridMetrics.cellWidth, alignment: .trailing)
                            .padding(.horizontal, GridMetrics.cellPadding).padding(.vertical, 6)
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.headline)
            .background(theme.gridHeaderBackground)
            .overlay(Rectangle().frame(height: 1.5).foregroundStyle(Color.primary.opacity(0.18)), alignment: .bottom)
            .shadow(color: .black.opacity(0.08), radius: 3, y: 2)

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in rowLabel(row.kind, shaded: row.shaded) }
                    }
                    .frame(width: 236, alignment: .leading)
                    .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)

                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            if isMultiYear {
                                ForEach(rows) { row in multiYearCells(row.kind, shaded: row.shaded, years: years) }
                            } else {
                                ForEach(rows) { row in rowCells(row.kind, shaded: row.shaded, year: year) }
                            }
                        }
                        .wrapProbeScrollsHorizontally()
                    }
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in scrollOffset.update(-x) }
                    .frame(maxWidth: scrollingWidth)

                    if !isMultiYear {
                        // Frozen Year Total column, pinned on the right (fixed row heights, as
                        // the label and month cells, so the three columns line up).
                        VStack(spacing: 0) {
                            ForEach(rows) { row in yearTotalCell(row.kind, shaded: row.shaded, year: year) }
                        }
                        .frame(width: GridMetrics.columnWidth)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { bodyWidth.update($0) }
            }
        }
    }

    /// The single year's twelve pay-month headers.
    private func monthHeaders(_ year: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(1...12, id: \.self) { month in
                Text(PayMonthFormat.name(PayMonth(year: year, month: month)))
                    .figureText(.shrink())
                    .frame(width: GridMetrics.cellWidth, alignment: .trailing)
                    .padding(.horizontal, GridMetrics.cellPadding).padding(.vertical, 6)
                    .help(PayMonthFormat.range(viewModel.payCalendar.range(of: PayMonth(year: year, month: month))))
                    .monthSeparator(month)
            }
        }
    }

    // MARK: Rows

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type && !$0.isReserved }
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

    /// As `BudgetGridView.rowKinds(for:_:)` (`GridOutline.rows`): a category group shows as one
    /// header row, expanding to its members; none while the section is collapsed.
    private func rowKinds(for type: CategoryType, _ outline: GridOutline) -> [RowKind] {
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

    /// Every row shown for `outline`: a collapsed section keeps only its header row (Reserved
    /// also keeps its total row, and Totals its Net, as their headers show no totals). The
    /// Totals block comes last, where the Budget grid has it after its Adjustments (this grid
    /// has no Adjustments or Accounts sections).
    private func allRows(_ outline: GridOutline) -> [Row] {
        func section(_ title: String, _ type: CategoryType) -> [Row] {
            [Row(kind: .sectionHeader(title, type), shaded: false)]
                + rowKinds(for: type, outline).enumerated().map { Row(kind: $1, shaded: $0 % 2 == 1) }
        }
        let reserves = viewModel.reserves
        var reservedRows = [Row(kind: .reservedHeader, shaded: false)]
        if !outline.isCollapsed(GridOutline.reservedSection) {
            reservedRows += reserves.enumerated().map { Row(kind: .reserve($1), shaded: $0 % 2 == 1) }
        }
        // Kept when collapsed: the Reserved header shows no totals.
        if !reserves.isEmpty { reservedRows.append(Row(kind: .reservedTotal, shaded: false)) }
        let totalsRows = [Row(kind: .totalsHeader, shaded: false)]
            + BudgetTotals.Row.visible(collapsed: outline.isCollapsed(GridOutline.totalsSection)).map { Row(kind: .totals($0), shaded: false) }
        return section("Income", .income) + section("Expenses", .expense) + reservedRows + section("Transfers", .transfer) + totalsRows
    }

    @ViewBuilder
    private func rowLabel(_ row: RowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(let title, let type):
            let key = GridOutline.sectionKey(type)
            let sectionGroups = groupIds(type)
            SectionHeaderCell(title: title, isCollapsed: outline.isCollapsed(key),
                              toggle: { updateOutline { $0.toggleSection(key) } },
                              setAllGroups: sectionGroups.isEmpty ? nil : { expand in updateOutline { $0.setGroups(sectionGroups, expanded: expand) } }) {
                if let scope = viewModel.editScope {
                    Button("+ Add item") { addTarget = AddTarget(type: type, scope: scope) }
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
            .overlay(Rectangle().frame(width: 3).foregroundStyle(categories.first.map { theme.stripe($0.type) } ?? .clear), alignment: .leading)
        case .groupChild(let category):
            CategoryRowLabel(category: category, shaded: shaded, isGroupChild: true)
        case .reservedHeader:
            SectionHeaderCell(title: "RESERVED", isCollapsed: outline.isCollapsed(GridOutline.reservedSection),
                              toggle: { updateOutline { $0.toggleSection(GridOutline.reservedSection) } }, setAllGroups: nil) {
                if viewModel.editScope != nil {
                    Button("+ Add allowance…") { allowanceError = nil; addingAllowance = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        case .reserve(let reserve):
            Text(reserve.name)
                .gridRowLabel(background: theme.rowBackground(shaded), stripe: theme.reserved)
        case .reservedTotal:
            Text("Total reserved").bold()
                .gridRowLabel(background: theme.reservedTint, stripe: theme.reserved)
        case .totalsHeader:
            SectionHeaderCell(title: "Totals", isCollapsed: outline.isCollapsed(GridOutline.totalsSection),
                              toggle: { updateOutline { $0.toggleSection(GridOutline.totalsSection) } }, setAllGroups: nil) { EmptyView() }
        case .totals(let totalsRow):
            TotalsRowLabel(row: totalsRow)
        }
    }

    @ViewBuilder
    private func rowCells(_ row: RowKind, shaded: Bool, year: Int) -> some View {
        switch row {
        case .sectionHeader(let title, let type):
            let members = categoriesByType(type)
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    cellView(cell(members, month: month), font: PlanCellView.captionFont, height: 24).bold()
                        .selectable(cellSelection, key: cellKey(row, month: month)) {
                            openAggregateMonth(row, name: title, members: members, year: year, month: month)
                        }
                }
            }
            .background(theme.sectionHeaderTint)
        case .category(let category), .groupChild(let category), .reserve(let category):
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    cellView(cell([category], month: month))
                        .frame(height: 28)
                        .background(theme.rowBackground(shaded))
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .monthSeparator(month)
                        .selectable(cellSelection, key: cellKey(row, month: month)) {
                            cellTapped(row, category, year: year, month: month)
                        }
                }
            }
        case .groupHeader(let group, let categories):
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    cellView(cell(categories, month: month)).bold()
                        .frame(height: 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .monthSeparator(month)
                        .selectable(cellSelection, key: cellKey(row, month: month)) {
                            openAggregateMonth(row, name: group.name, members: categories, year: year, month: month)
                        }
                }
            }
            .background(theme.groupRowTint)
        case .reservedHeader, .totalsHeader:
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { _ in Color.clear.frame(width: GridMetrics.columnWidth, height: 24) }
            }
            .background(theme.sectionHeaderTint)
        case .reservedTotal:
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    cellView(cell(viewModel.reserves, month: month)).bold()
                        .frame(height: 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .monthSeparator(month)
                }
            }
            .background(theme.reservedTint)
        case .totals(let totalsRow):
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    cellView(totalsCell(totalsRow, month: month)).fontWeight(totalsRow == .net ? .bold : .semibold)
                        .frame(height: 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .monthSeparator(month)
                        .selectable(cellSelection, key: cellKey(row, month: month)) {
                            openTotalsMonth(row, totalsRow, year: year, month: month)
                        }
                }
            }
            .background(theme.totalsBackground(totalsRow))
        }
    }

    /// A row's Year Total, for the pinned right-hand column: the row's height and background,
    /// and the differs fill (from `cellView`) when it differs from the budget.
    @ViewBuilder
    private func yearTotalCell(_ row: RowKind, shaded: Bool, year: Int) -> some View {
        switch row {
        case .sectionHeader(let title, let type):
            let members = categoriesByType(type)
            cellView(yearCell(members, year: year), isYearTotal: true, font: PlanCellView.captionFont, height: 24).bold()
                .background(theme.sectionHeaderTint)
                .selectable(cellSelection, key: cellKey(row, year: year)) { openYear(row, name: title, members: members, year: year) }
        case .category(let category), .groupChild(let category):
            cellView(yearCell([category], year: year), isYearTotal: true).bold()
                .frame(height: 28)
                .background(theme.rowBackground(shaded))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .selectable(cellSelection, key: cellKey(row, year: year)) { openYear(row, name: category.name, members: [category], year: year) }
        case .reserve(let reserve):
            cellView(yearCell([reserve], year: year), isYearTotal: true).bold()
                .frame(height: 28)
                .background(theme.rowBackground(shaded))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        case .groupHeader(let group, let categories):
            combinedYearTotal(yearCell(categories, year: year), background: theme.groupRowTint)
                .selectable(cellSelection, key: cellKey(row, year: year)) { openYear(row, name: group.name, members: categories, year: year) }
        case .reservedHeader, .totalsHeader:
            Color.clear.frame(width: GridMetrics.columnWidth, height: 24)
                .background(theme.sectionHeaderTint)
        case .reservedTotal:
            combinedYearTotal(yearCell(viewModel.reserves, year: year), background: theme.reservedTint)
        case .totals(let totalsRow):
            combinedYearTotal(totalsYearCell(totalsRow, year: year), background: theme.totalsBackground(totalsRow))
                .selectable(cellSelection, key: cellKey(row, year: year)) { openTotalsYear(row, totalsRow, year: year) }
        }
    }

    /// Several years: per selected year the row's year total (`yearTotalCell`, so the panel
    /// click-through matches the Year Total column), then for every year after the first its
    /// change from the previous selected year (`deltaCells`).
    private func multiYearCells(_ row: RowKind, shaded: Bool, years: [Int]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(years.enumerated()), id: \.element) { index, year in
                HStack(spacing: 0) {
                    yearTotalCell(row, shaded: shaded, year: year)
                    if index > 0 {
                        deltaCells(row, year: year, previous: years[index - 1], shaded: shaded)
                    }
                }
                .yearGroupBand(index)
                .yearGroupSeparator(index)
            }
        }
    }

    /// The Δ £ and Δ % cells (`YearDeltaCells`); empty bands on the Reserved and Totals headers.
    @ViewBuilder
    private func deltaCells(_ row: RowKind, year: Int, previous: Int, shaded: Bool) -> some View {
        switch row {
        case .reservedHeader, .totalsHeader:
            HStack(spacing: 0) {
                Color.clear.frame(width: GridMetrics.columnWidth, height: 24)
                Color.clear.frame(width: GridMetrics.columnWidth, height: 24)
            }
            .background(theme.sectionHeaderTint)
        default:
            let isSectionHeader: Bool = { if case .sectionHeader = row { return true } else { return false } }()
            YearDeltaCells(current: yearValue(row, year: year), previous: yearValue(row, year: previous),
                           categoryType: yearOverYearType(row), isSectionHeader: isSectionHeader, background: rowBackground(row, shaded: shaded))
        }
    }

    /// The figure a row's year total shows, for the Δ columns; nil for header bands.
    private func yearValue(_ row: RowKind, year: Int) -> Int? {
        switch row {
        case .sectionHeader(_, let type): return yearCell(categoriesByType(type), year: year).value
        case .category(let category), .groupChild(let category), .reserve(let category): return yearCell([category], year: year).value
        case .groupHeader(_, let categories): return yearCell(categories, year: year).value
        case .reservedTotal: return yearCell(viewModel.reserves, year: year).value
        case .totals(let totalsRow): return totalsYearCell(totalsRow, year: year).value
        case .reservedHeader, .totalsHeader: return nil
        }
    }

    /// The line type that decides whether a change is good (`YearOverYear.isImprovement`), as
    /// the Budget grid decides it.
    private func yearOverYearType(_ row: RowKind) -> CategoryType? {
        switch row {
        case .sectionHeader(_, let type): return type
        case .category(let category), .groupChild(let category), .reserve(let category): return category.type
        case .groupHeader(_, let categories): return categories.first?.type
        case .reservedTotal: return .expense
        // More in, and a higher net, are better; more out (a larger negative) is worse.
        case .totals(let totalsRow): return totalsRow == .totalOut ? .expense : .income
        case .reservedHeader, .totalsHeader: return nil
        }
    }

    /// The row's background, as its month and Year Total cells draw it.
    private func rowBackground(_ row: RowKind, shaded: Bool) -> Color {
        switch row {
        case .sectionHeader, .reservedHeader, .totalsHeader: return theme.sectionHeaderTint
        case .totals(let totalsRow): return theme.totalsBackground(totalsRow)
        case .groupHeader: return theme.groupRowTint
        case .reservedTotal: return theme.reservedTint
        case .category, .groupChild, .reserve: return theme.rowBackground(shaded)
        }
    }

    private func combinedYearTotal(_ cell: Cell, background: Color) -> some View {
        cellView(cell, isYearTotal: true).bold()
            .frame(height: 28)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            .background(background)
    }

    // MARK: Cells

    /// The Grid tab's plan's chart series colour (`Theme.series`; the Budget's first, Classic's
    /// blue, when it is selected).
    private var planColor: Color { theme.series(viewModel.colorIndex(of: viewModel.gridSelection)) }

    /// A differing cell's shading: a light tint of the scenario's colour (`Theme.differsFill`;
    /// Classic's 22%).
    private var differsFill: Color { theme.differsFill(viewModel.colorIndex(of: viewModel.gridSelection)) }

    /// Members' cells combined (`PlanStatus.combine`), with the Budget's values summed.
    private func cell(_ categories: [Category], month: Int, year: Int? = nil) -> Cell {
        let gridCells = year.flatMap { viewModel.yearGrids[$0]?.cells } ?? viewModel.gridCells
        let cells = categories.compactMap { $0.id.flatMap { gridCells[$0]?[month] } }
        let combined = PlanStatus.combine(cells.map { ($0.value, $0.pending, $0.state) })
        return (combined.value, combined.pending, combined.state, cells.reduce(0) { $0 + $1.budgetValue })
    }

    private func yearCell(_ categories: [Category], year: Int) -> Cell {
        combinedYear((1...12).map { cell(categories, month: $0, year: year) })
    }

    /// A Totals row's month (`ScenarioComparison.grid`'s Totals block), with the Budget's.
    private func totalsCell(_ row: BudgetTotals.Row, month: Int, year: Int? = nil) -> Cell {
        let grid = year.flatMap { viewModel.yearGrids[$0] } ?? viewModel.grid
        guard let cell = grid.totals[row]?[month] else { return (0, 0, .none, 0) }
        return (cell.value, cell.pending, cell.state, cell.budgetValue)
    }

    private func totalsYearCell(_ row: BudgetTotals.Row, year: Int) -> Cell {
        combinedYear((1...12).map { totalsCell(row, month: $0, year: year) })
    }

    private func combinedYear(_ months: [Cell]) -> Cell {
        let combined = PlanStatus.combine(months.map { ($0.value, $0.pending, $0.state) })
        return (combined.value, combined.pending, combined.state, months.reduce(0) { $0 + $1.budgetValue })
    }

    /// A plan cell; for a scenario, shaded with the Budget's value in its help when it differs.
    private func cellView(_ cell: Cell, isYearTotal: Bool = false, font: Font = PlanCellView.bodyFont, height: CGFloat = 28) -> some View {
        let differs = !isReadOnly && cell.value != cell.budgetValue
        return PlanCellView(value: cell.value, pending: cell.pending, state: cell.state, isYearTotal: isYearTotal, font: font,
                            extraHelp: differs ? "Budget: \(Money.format(cell.budgetValue, currency: .gbp))" : nil)
            // The fill covers the whole cell (full width and row height), not just the text.
            .frame(height: height)
            .background(differs ? differsFill : Color.clear)
    }

    // MARK: Side panel

    /// A cell's selection key: its row and its month (or year) column.
    private func cellKey(_ row: RowKind, month: Int) -> String { "\(row.id)|m\(month)" }
    private func cellKey(_ row: RowKind, year: Int) -> String { "\(row.id)|y\(year)" }

    private func monthRange(year: Int, month: Int) -> (start: Date, end: Date) {
        viewModel.payCalendar.range(of: PayMonth(year: year, month: month))
    }

    /// January's pay month start ... December's pay month end, matching the Year Total column.
    private func yearRange(_ year: Int) -> (start: Date, end: Date) {
        (monthRange(year: year, month: 1).start, monthRange(year: year, month: 12).end)
    }

    /// A month cell's panel for `categories` (one category, or a group's or section's members,
    /// which name each transaction's category): the pay month's transactions and the calendar
    /// month's planned occurrences.
    private func monthTarget(name: String, categories: [Category], year: Int, month: Int) -> GridCellTarget {
        let range = monthRange(year: year, month: month)
        return GridCellTarget(title: "\(name) — \(GridMonthLabel.shortMonthYear(year: year, month: month))", categoryIds: Set(categories.compactMap(\.id)),
                              start: range.start, end: range.end, showCategory: categories.count > 1,
                              plan: CellPlan(categories: categories, year: year, month: month))
    }

    /// A category's or reserve's month cell: with a value or anything planned, its panel (a
    /// reserve's planned allowances only); an empty one (no value, nothing planned) in an open
    /// or future month adds an item (a reserve: an allowance) to the selected scenario —
    /// nothing while the Budget is selected.
    private func cellTapped(_ row: RowKind, _ category: Category, year: Int, month: Int) {
        let hasOccurrences = !viewModel.occurrences(category: category, year: year, month: month).isEmpty
        let hasValue = (viewModel.gridCells[category.id ?? -1]?[month]?.value ?? 0) != 0
        if hasOccurrences || (hasValue && !category.isReserved) {
            var target = monthTarget(name: category.name, categories: [category], year: year, month: month)
            target.showsTransactions = !category.isReserved
            cellSelection.select(key: cellKey(row, month: month), target: target)
            return
        }
        // A reserve with a value but no allowance occurrences isn't empty: nothing to add.
        guard !hasValue else { return }
        guard !viewModel.payCalendar.isClosed(PayMonth(year: year, month: month)), let scope = viewModel.editScope else { return }
        let date = CellAddDate.date(year: year, month: month)
        if category.isReserved {
            allowanceError = nil
            cellAllowance = CellAllowance(reserve: category, date: date)
        } else if let id = category.id {
            addTarget = AddTarget(type: category.type, scope: scope, categoryId: id, date: date)
        }
    }

    /// Opens a group's or section's month panel when its members have any transaction or
    /// planned occurrence there (an empty aggregate cell does nothing).
    private func openAggregateMonth(_ row: RowKind, name: String, members: [Category], year: Int, month: Int) {
        var target = monthTarget(name: name, categories: members, year: year, month: month)
        let hasTransactions = !viewModel.transactions(forCategoryIds: target.categoryIds, from: target.start, to: target.end).isEmpty
        guard hasTransactions || members.contains(where: { !viewModel.occurrences(category: $0, year: year, month: month).isEmpty }) else { return }
        target.showCategory = true
        cellSelection.select(key: cellKey(row, month: month), target: target)
    }

    /// Opens a Year Total's panel (the year's transactions) when there are any.
    private func openYear(_ row: RowKind, name: String, members: [Category], year: Int) {
        var showCategory = members.count > 1
        if case .groupHeader = row { showCategory = true }
        if case .sectionHeader = row { showCategory = true }
        let range = yearRange(year)
        let target = GridCellTarget(title: "\(name) — \(year)", categoryIds: Set(members.compactMap(\.id)),
                                    start: range.start, end: range.end, showCategory: showCategory, plan: nil)
        guard !viewModel.transactions(forCategoryIds: target.categoryIds, from: target.start, to: target.end).isEmpty else { return }
        cellSelection.select(key: cellKey(row, year: year), target: target)
    }

    /// A Totals row's month panel: the transactions and planned occurrences it sums, when
    /// there are any (an empty cell does nothing).
    private func openTotalsMonth(_ row: RowKind, _ totalsRow: BudgetTotals.Row, year: Int, month: Int) {
        let range = monthRange(year: year, month: month)
        let hasTransactions = !viewModel.totalsTransactions(totalsRow, from: range.start, to: range.end).isEmpty
        let hasPlan = !viewModel.totalsOccurrences(totalsRow, year: year, month: month).isEmpty || viewModel.totalsReserved(totalsRow, year: year, month: month) != 0
        guard hasTransactions || hasPlan else { return }
        var plan = CellPlan(categories: [], year: year, month: month)
        plan.totals = totalsRow
        var target = GridCellTarget(title: "\(totalsRow.title) — \(GridMonthLabel.shortMonthYear(year: year, month: month))", categoryIds: [],
                                    start: range.start, end: range.end, showCategory: true, plan: plan)
        target.totals = totalsRow
        cellSelection.select(key: cellKey(row, month: month), target: target)
    }

    /// A Totals row's Year Total panel: the year's transactions it sums.
    private func openTotalsYear(_ row: RowKind, _ totalsRow: BudgetTotals.Row, year: Int) {
        let range = yearRange(year)
        guard !viewModel.totalsTransactions(totalsRow, from: range.start, to: range.end).isEmpty else { return }
        var target = GridCellTarget(title: "\(totalsRow.title) — \(year)", categoryIds: [], start: range.start, end: range.end, showCategory: true, plan: nil)
        target.totals = totalsRow
        cellSelection.select(key: cellKey(row, year: year), target: target)
    }
}
