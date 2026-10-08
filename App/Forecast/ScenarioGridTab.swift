// App/Forecast/ScenarioGridTab.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// The Grid chips (one plan: the Budget or a scenario), a header bar in that plan's colour,
/// then the plan month by month (categories × the twelve months of a year within the
/// horizon), valued as the Budget grid values it (`ScenarioComparison.gridCells`). For a
/// scenario, cells that differ from the Budget are shaded in a light tint of the scenario's
/// colour, a month cell opens its
/// planned occurrences with Edit… / Remove…, and section headers add items — the Budget
/// grid's own sheets, scoped to the scenario. The Budget shows read-only.
///
/// Same frozen header / frozen columns (category left, Year Total right) technique as
/// `BudgetGridView`: the horizontal offset lives in a `HorizontalScrollOffset` held in plain
/// `@State` and observed only by the header's `HorizontalOffsetFollower`, so scrolling never
/// re-runs this `body`.
struct ScenarioGridTab: View {
    @ObservedObject var viewModel: ScenarioLabViewModel
    @Binding var chipPrompts: ScenarioChipPrompts
    @State private var scrollOffset = HorizontalScrollOffset()
    @State private var bodyWidth = GridBodyWidth()
    @State private var expandedGroupIds: Set<Int64> = []
    @State private var drillDown: DrillDownTarget?
    @State private var addTarget: AddTarget?
    @State private var addingAllowance = false
    /// An empty reserve cell's Add allowance: the reserve and the start date.
    @State private var cellAllowance: CellAllowance?
    /// A failed allowance save, shown inside the open form.
    @State private var allowanceError: String?

    private struct DrillDownTarget: Identifiable {
        let category: Category
        let year: Int
        let month: Int
        var id: String { "\(category.id ?? -1)-\(year)-\(month)" }
    }

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

        var id: String {
            switch self {
            case .sectionHeader(let title, _): return "header-\(title)"
            case .category(let category): return "cat-\(category.id ?? -1)"
            case .groupHeader(let group, let categories): return "group-\(group.id ?? -1)-\(categories.first?.type.rawValue ?? "")"
            case .groupChild(let category): return "groupchild-\(category.id ?? -1)"
            case .reservedHeader: return "reserved-header"
            case .reserve(let reserve): return "reserve-\(reserve.id ?? -1)"
            case .reservedTotal: return "reserved-total"
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
        VStack(alignment: .leading, spacing: 8) {
            ScenarioChips(viewModel: viewModel, mode: .single(selected: $viewModel.gridSelection), prompts: $chipPrompts)
            headerBar
            Picker("Year", selection: $viewModel.gridYear) {
                ForEach(viewModel.gridYears, id: \.self) { year in Text(String(year)).tag(year) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            grid
        }
        .sheet(item: $drillDown) { target in
            ScenarioDrillDownSheet(viewModel: viewModel, category: target.category, year: target.year, month: target.month)
        }
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
                                initialCategoryId: target.categoryId, initialDate: target.date) { category, amount, frequency, interval, start, end in
                viewModel.addPlannedItem(category, type: target.type, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end)
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
        let rows = allRows
        return VStack(alignment: .leading, spacing: 0) {
            // The header row takes the body's measured width (`GridBodyWidth`), so the pinned
            // Year Total header sits exactly over its column whatever the scroller style.
            BodyWidthFollower(width: bodyWidth) {
                HStack(spacing: 0) {
                    Text("Category").font(.headline).frame(width: 220, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    HorizontalOffsetFollower(offset: scrollOffset) {
                        HStack(spacing: 0) {
                            ForEach(1...12, id: \.self) { month in
                                Text(PayMonthFormat.name(PayMonth(year: year, month: month)))
                                    .frame(width: GridMetrics.cellWidth, alignment: .trailing)
                                    .padding(.horizontal, GridMetrics.cellPadding).padding(.vertical, 6)
                                    .help(PayMonthFormat.range(viewModel.payCalendar.range(of: PayMonth(year: year, month: month))))
                                    .monthSeparator(month)
                            }
                        }
                    }
                    // As in `BudgetGridView`: no wider than the body's month scroller, so the
                    // pinned Year Total sits right after December in a wide window.
                    .frame(minWidth: 0, maxWidth: GridMetrics.monthsWidth, alignment: .leading)
                    .clipped()
                    Text("Year Total").bold()
                        .frame(width: GridMetrics.cellWidth, alignment: .trailing)
                        .padding(.horizontal, GridMetrics.cellPadding).padding(.vertical, 6)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.headline)
            .background(Color(nsColor: .controlBackgroundColor))
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
                            ForEach(rows) { row in rowCells(row.kind, shaded: row.shaded, year: year) }
                        }
                    }
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in scrollOffset.update(-x) }
                    .frame(maxWidth: GridMetrics.monthsWidth)

                    // Frozen Year Total column, pinned on the right (fixed row heights, as
                    // the label and month cells, so the three columns line up).
                    VStack(spacing: 0) {
                        ForEach(rows) { row in yearTotalCell(row.kind, shaded: row.shaded) }
                    }
                    .frame(width: GridMetrics.columnWidth)
                    .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { bodyWidth.update($0) }
            }
        }
    }

    // MARK: Rows

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type && !$0.isReserved }
    }

    /// As `BudgetGridView.rowKinds(for:)`: a category group collapses into one header row,
    /// expanding to its members.
    private func rowKinds(for type: CategoryType) -> [RowKind] {
        let cats = categoriesByType(type)
        var rows: [RowKind] = []
        var seenGroupIds: Set<Int64> = []
        for category in cats {
            if let groupId = category.groupId {
                guard seenGroupIds.insert(groupId).inserted,
                      let group = viewModel.categoryGroups.first(where: { $0.id == groupId }) else { continue }
                let members = cats.filter { $0.groupId == groupId }
                rows.append(.groupHeader(group, categories: members))
                if expandedGroupIds.contains(groupId) { rows += members.map { .groupChild($0) } }
            } else {
                rows.append(.category(category))
            }
        }
        return rows
    }

    private var allRows: [Row] {
        func section(_ title: String, _ type: CategoryType) -> [Row] {
            [Row(kind: .sectionHeader(title, type), shaded: false)]
                + rowKinds(for: type).enumerated().map { Row(kind: $1, shaded: $0 % 2 == 1) }
        }
        let reserves = viewModel.reserves
        var reservedRows = [Row(kind: .reservedHeader, shaded: false)]
        reservedRows += reserves.enumerated().map { Row(kind: .reserve($1), shaded: $0 % 2 == 1) }
        if !reserves.isEmpty { reservedRows.append(Row(kind: .reservedTotal, shaded: false)) }
        return section("Income", .income) + section("Expenses", .expense) + reservedRows + section("Transfers", .transfer)
    }

    private func rowColor(for type: CategoryType) -> Color {
        switch type {
        case .income: return .green
        case .expense: return .red
        case .transfer: return .blue
        }
    }

    @ViewBuilder
    private func rowLabel(_ row: RowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(let title, let type):
            HStack {
                Text(title).font(.caption).bold().tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                if let scope = viewModel.editScope {
                    Button("+ Add item") { addTarget = AddTarget(type: type, scope: scope) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .frame(width: 220, height: 24, alignment: .leading)
            .padding(.horizontal, 8)
            .background(Color.accentColor.opacity(0.08))
        case .category(let category):
            label(category.name, shaded: shaded, stripe: rowColor(for: category.type))
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
        case .reservedHeader:
            HStack {
                Text("RESERVED").font(.caption).bold().tracking(0.6).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if viewModel.editScope != nil {
                    Button("+ Add allowance…") { allowanceError = nil; addingAllowance = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .frame(width: 220, height: 24, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.08))
        case .reserve(let reserve):
            label(reserve.name, shaded: shaded, stripe: .purple)
        case .reservedTotal:
            Text("Total reserved").bold()
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.purple.opacity(0.08))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(.purple), alignment: .leading)
        }
    }

    private func label(_ name: String, shaded: Bool, stripe: Color) -> some View {
        Text(name)
            .frame(width: 220, height: 28, alignment: .leading)
            .padding(.horizontal, 8)
            .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            .overlay(Rectangle().frame(width: 3).foregroundStyle(stripe), alignment: .leading)
    }

    @ViewBuilder
    private func rowCells(_ row: RowKind, shaded: Bool, year: Int) -> some View {
        switch row {
        case .sectionHeader(_, let type):
            let members = categoriesByType(type)
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    cellView(cell(members, month: month), font: PlanCellView.captionFont, height: 24).bold()
                }
            }
            .background(Color.accentColor.opacity(0.08))
        case .category(let category), .groupChild(let category), .reserve(let category):
            let isReserve = category.isReserved
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    cellView(cell([category], month: month))
                        .frame(height: 28)
                        .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .monthSeparator(month)
                        .contentShape(Rectangle())
                        .onTapGesture { cellTapped(category, year: year, month: month, isReserve: isReserve) }
                }
            }
        case .groupHeader(_, let categories):
            combinedRow(categories, background: Color.orange.opacity(0.10))
        case .reservedHeader:
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { _ in Color.clear.frame(width: GridMetrics.columnWidth, height: 24) }
            }
            .background(Color.accentColor.opacity(0.08))
        case .reservedTotal:
            combinedRow(viewModel.reserves, background: Color.purple.opacity(0.08))
        }
    }

    private func combinedRow(_ categories: [Category], background: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(1...12, id: \.self) { month in
                cellView(cell(categories, month: month)).bold()
                    .frame(height: 28)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                    .monthSeparator(month)
            }
        }
        .background(background)
    }

    /// A row's Year Total, for the pinned right-hand column: the row's height and background,
    /// and the differs fill (from `cellView`) when it differs from the budget.
    @ViewBuilder
    private func yearTotalCell(_ row: RowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(_, let type):
            cellView(yearCell(categoriesByType(type)), isYearTotal: true, font: PlanCellView.captionFont, height: 24).bold()
                .background(Color.accentColor.opacity(0.08))
        case .category(let category), .groupChild(let category), .reserve(let category):
            cellView(yearCell([category]), isYearTotal: true).bold()
                .frame(height: 28)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        case .groupHeader(_, let categories):
            combinedYearTotal(categories, background: Color.orange.opacity(0.10))
        case .reservedHeader:
            Color.clear.frame(width: GridMetrics.columnWidth, height: 24)
                .background(Color.accentColor.opacity(0.08))
        case .reservedTotal:
            combinedYearTotal(viewModel.reserves, background: Color.purple.opacity(0.08))
        }
    }

    private func combinedYearTotal(_ categories: [Category], background: Color) -> some View {
        cellView(yearCell(categories), isYearTotal: true).bold()
            .frame(height: 28)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            .background(background)
    }

    // MARK: Cells

    /// The Grid tab's plan's `PlanPalette` colour (the Budget's blue when it is selected).
    private var planColor: Color { PlanPalette.color(viewModel.colorIndex(of: viewModel.gridSelection)) }

    /// A differing cell's shading: a light tint of the scenario's colour.
    private var differsFill: Color { planColor.opacity(0.22) }

    /// Members' cells combined (`PlanStatus.combine`), with the Budget's values summed.
    private func cell(_ categories: [Category], month: Int) -> Cell {
        let cells = categories.compactMap { $0.id.flatMap { viewModel.gridCells[$0]?[month] } }
        let combined = PlanStatus.combine(cells.map { ($0.value, $0.pending, $0.state) })
        return (combined.value, combined.pending, combined.state, cells.reduce(0) { $0 + $1.budgetValue })
    }

    private func yearCell(_ categories: [Category]) -> Cell {
        let months = (1...12).map { cell(categories, month: $0) }
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

    /// A month cell: its planned occurrences open the drill-down; an empty one (no value, nothing
    /// planned) in an open or future month adds an item (a reserve: an allowance) to the selected
    /// scenario. Nothing while the Budget is selected.
    private func cellTapped(_ category: Category, year: Int, month: Int, isReserve: Bool) {
        guard !isReadOnly else { return }
        guard viewModel.occurrences(category: category, year: year, month: month).isEmpty,
              (viewModel.gridCells[category.id ?? -1]?[month]?.value ?? 0) == 0 else {
            openDrillDown(category, year: year, month: month)
            return
        }
        guard !viewModel.payCalendar.isClosed(PayMonth(year: year, month: month)), let scope = viewModel.editScope else { return }
        let date = CellAddDate.date(year: year, month: month)
        if isReserve {
            allowanceError = nil
            cellAllowance = CellAllowance(reserve: category, date: date)
        } else if let id = category.id {
            addTarget = AddTarget(type: category.type, scope: scope, categoryId: id, date: date)
        }
    }

    private func openDrillDown(_ category: Category, year: Int, month: Int) {
        guard !isReadOnly, !viewModel.occurrences(category: category, year: year, month: month).isEmpty else { return }
        drillDown = DrillDownTarget(category: category, year: year, month: month)
    }
}

/// A scenario cell's planned occurrences with Edit… / Remove… (the Budget grid's sheets).
private struct ScenarioDrillDownSheet: View {
    @ObservedObject var viewModel: ScenarioLabViewModel
    let category: Category
    let year: Int
    let month: Int
    @Environment(\.dismiss) private var dismiss

    @State private var editing: PlannedRow?
    @State private var removing: PlannedRow?
    @State private var planError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(category.name) — \(PayMonthFormat.name(PayMonth(year: year, month: month)))").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let scenario = viewModel.gridScenario {
                Text("In “\(scenario.name)”. Changes stay in the scenario until you apply them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                PlannedOccurrencesSection(
                    rows: viewModel.occurrences(category: category, year: year, month: month),
                    inScenario: true,
                    errorMessage: planError,
                    onEdit: { row in planError = nil; editing = row },
                    onRemove: { row in planError = nil; removing = row }
                )
            }
        }
        .padding()
        .frame(width: 560, height: 420)
        .plannedOccurrenceEditing(editing: $editing, removing: $removing, planError: $planError,
                                  categories: viewModel.categories, actions: viewModel.planEditActions)
    }
}
