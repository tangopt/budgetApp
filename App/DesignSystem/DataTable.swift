// App/DesignSystem/DataTable.swift
import SwiftUI
import BudgetCore

/// How wide a `DataTable` column is.
enum DataTableWidth: Equatable {
    /// As wide as its widest cell.
    case fit
    /// At least this wide (wider when a cell needs it).
    case min(CGFloat)
    /// Exactly this wide.
    case fixed(CGFloat)
    /// Takes the width left over (shared with any other fill column); at least `min`.
    case fill(min: CGFloat = 120)
}

/// One column of a `DataTable`: its header, how wide it is, how its cells align, and the cell.
struct DataTableColumn<Row> {
    typealias Width = DataTableWidth

    var title: String
    var alignment: Alignment
    var width: Width
    /// What the cell says to VoiceOver, read as part of its row ("Rent €1,200.00"); a column
    /// without one (actions, custom controls) stays its own element.
    var accessibilityValue: ((Row) -> String?)?
    /// The header's tooltip (what the column's marks mean), when given.
    var headerHelp: String? = nil
    var cell: (Row, DataTableRowKind) -> AnyView
    /// When the table is narrower than its columns (a side panel open beside it), the column
    /// gives way at this step — 1 first, then 2, and so on: it hides, or (with a compact cell
    /// or width) narrows. Nil: it never gives way. Its value is still read with its row.
    var giveWayPriority: Int? = nil
    /// The narrower width the column takes when it gives way (nil: its own).
    var compactWidth: Width? = nil
    /// The shorter cell the column shows when it gives way (nil: its own).
    var compactCell: ((Row, DataTableRowKind) -> AnyView)? = nil

    init<Cell: View>(_ title: String, alignment: Alignment = .leading, width: Width = .fit,
                     accessibilityValue: ((Row) -> String?)? = nil,
                     @ViewBuilder cell: @escaping (Row, DataTableRowKind) -> Cell) {
        self.title = title
        self.alignment = alignment
        self.width = width
        self.accessibilityValue = accessibilityValue
        self.cell = { AnyView(cell($0, $1)) }
    }

    /// The column with a header tooltip.
    func headerHelp(_ text: String) -> Self {
        var column = self
        column.headerHelp = text
        return column
    }

    /// A low-priority column that hides when the table is too narrow, at step `priority`
    /// (1 hides first).
    func hidesWhenNarrow(_ priority: Int) -> Self {
        var column = self
        column.giveWayPriority = priority
        return column
    }

    /// A column that narrows when the table is too narrow, at step `priority`: to `width`
    /// (a text column truncating in less room), keeping its cell.
    func narrowsWhenNarrow(_ priority: Int, to width: Width) -> Self {
        var column = self
        column.giveWayPriority = priority
        column.compactWidth = width
        return column
    }

    /// A column that shows a shorter cell when the table is too narrow, at step `priority`
    /// (an amount without its day, a period in fewer words), `width` wide.
    func compactsWhenNarrow<Cell: View>(_ priority: Int, width: Width = .fit,
                                        @ViewBuilder cell: @escaping (Row, DataTableRowKind) -> Cell) -> Self {
        var column = self
        column.giveWayPriority = priority
        column.compactWidth = width
        column.compactCell = { AnyView(cell($0, $1)) }
        return column
    }

    /// Whether the column has a compact form (a narrower width or a shorter cell).
    fileprivate var compacts: Bool { compactWidth != nil || compactCell != nil }

    /// Whether the column's width depends on its cells (what `DataTable` measures to choose its step).
    fileprivate var isMeasured: Bool {
        switch width {
        case .fit, .min: return true
        case .fixed, .fill: return false
        }
    }

    /// The column at give-way step `step`: itself, its compact form, or nil (hidden).
    fileprivate func at(step: Int) -> Self? {
        guard let priority = giveWayPriority, priority <= step else { return self }
        guard compactWidth != nil || compactCell != nil else { return nil }
        var column = self
        if let compactWidth { column.width = compactWidth }
        if let compactCell { column.cell = compactCell }
        column.giveWayPriority = nil
        return column
    }
}

/// Whether a row is an ordinary row or a group's total (semibold, on the totals tint).
enum DataTableRowKind {
    case row
    case total
}

/// A row's trailing action: an icon button, or an item of the row's ••• menu.
struct DataTableAction {
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    /// Shown as an icon button; otherwise listed in the ••• menu.
    var isInline = false
    let action: () -> Void

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, inline: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isInline = inline
        self.action = action
    }
}

extension DataTableColumn {
    /// Text, one line, with an optional `.caption` secondary line under it. `figure`: the text
    /// is a figure (a month, a receipt number), in monospaced digits, that shrinks a little
    /// rather than truncate when its column can't give it room (spec §6.3).
    static func text(_ title: String, width: Width = .fill(), figure: Bool = false, _ value: @escaping (Row) -> String,
                     detail: ((Row) -> String?)? = nil) -> Self {
        Self(title, width: width, accessibilityValue: { row in [value(row), detail?(row) ?? nil].compactMap { $0 }.joined(separator: ", ") }) { row, kind in
            VStack(alignment: .leading, spacing: 1) {
                if figure {
                    Text(value(row)).fontWeight(kind == .total ? .semibold : .regular).monospacedDigit().figureText(.shrink())
                } else {
                    Text(value(row)).fontWeight(kind == .total ? .semibold : .regular).lineLimit(1)
                }
                if let detail, let text = detail(row) {
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    /// A stored day, fixed width (`DateText`).
    static func date(_ title: String, _ value: @escaping (Row) -> Date?) -> Self {
        Self(title, accessibilityValue: { value($0).map(DocumentFormat.day) }) { row, kind in
            if kind == .total { Text("") } else { DateText(date: value(row)) }
        }
    }

    /// An amount, right-aligned, in monospaced digits, read as `role` (`MoneyRole`: a money
    /// table shows costs as `.cost`); `nil` shows "—".
    static func money(_ title: String, role: MoneyRole = .signed, minWidth: CGFloat = 96,
                      currency: @escaping (Row) -> Currency, _ value: @escaping (Row) -> Int?) -> Self {
        money(title, role: { _ in role }, minWidth: minWidth, currency: currency, value)
    }

    /// An amount whose role depends on its row (a table of figures: rent, costs, net).
    static func money(_ title: String, role: @escaping (Row) -> MoneyRole, minWidth: CGFloat = 96,
                      currency: @escaping (Row) -> Currency, _ value: @escaping (Row) -> Int?) -> Self {
        Self(title, alignment: .trailing, width: .min(minWidth),
             accessibilityValue: { row in value(row).map { Money.format(role(row).displayed($0), currency: currency(row)) } }) { row, kind in
            if let amount = value(row) {
                MoneyText(minorUnits: amount, currency: currency(row),
                          font: kind == .total ? .body.monospacedDigit().weight(.semibold) : .body.monospacedDigit(), role: role(row))
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    /// A status pill (nothing when `nil`).
    static func status(_ title: String, _ value: @escaping (Row) -> StatusPill?) -> Self {
        Self(title, accessibilityValue: { value($0)?.title }) { row, _ in
            if let pill = value(row) { pill }
        }
    }

    /// The paperclip and document count; the cell keeps its width when there are none.
    static func documents(_ count: @escaping (Row) -> Int) -> Self {
        Self("", alignment: .center, width: .fixed(36),
             accessibilityValue: { row in let n = count(row); return n == 0 ? nil : (n == 1 ? "1 document" : "\(n) documents") }) { row, kind in
            if kind == .row { DocumentCountBadge(count: count(row)) }
        }
    }

    /// The row's actions: icon buttons, then a ••• menu with the rest.
    static func actions(_ actions: @escaping (Row) -> [DataTableAction]) -> Self {
        Self("", alignment: .trailing) { row, kind in
            if kind == .row { DataTableActions(actions: actions(row)) }
        }
    }
}

/// A group of rows under an optional title strip, with an optional total row.
struct DataTableSection<Row: Identifiable> {
    var title: String?
    var rows: [Row]
    var total: Row?

    init(_ title: String? = nil, rows: [Row], total: Row? = nil) {
        self.title = title
        self.rows = rows
        self.total = total
    }
}

/// The app's table for records and figures (spec §4.1): one column layout for every group, so
/// figures line up across the whole table (C3); a header strip in `.caption` secondary on
/// `theme.gridHeaderBackground`; rows at least 28 pt with a separator under each and the
/// theme's alternating shade; group strips in `theme.sectionHeaderTint`; totals semibold on
/// `theme.totalsTint`. Amounts go in `money` columns (right-aligned `MoneyText`), days in
/// `date` columns, row actions in `actions` (icons and a ••• menu, never words).
struct DataTable<Row: Identifiable>: View {
    let columns: [DataTableColumn<Row>]
    let sections: [DataTableSection<Row>]
    var zebra = true
    var showsHeader = true
    var minRowHeight: CGFloat = 28
    /// Clicking a row (anywhere but its buttons) opens it — e.g. a side panel; VoiceOver
    /// activates it. Nil: rows aren't clickable.
    var onSelect: ((Row) -> Void)? = nil
    /// The row whose details are open: drawn in the selection colours.
    var selectedId: Row.ID? = nil
    /// What activating a row does, for VoiceOver ("Show details").
    var selectHint = "Shows its details"
    /// What the cells show besides their rows (`cellsRebuilt(when:)`), and each row as its
    /// cells compare it: while both are unchanged, a cell isn't built again — selecting another
    /// row redraws the rows' backgrounds only.
    private var cellsKey: DataTableContentKey?
    private var rowKey: ((Row) -> DataTableContentKey)?
    @Environment(\.theme) private var theme
    @Environment(\.selectedRowScroller) private var selectedRowScroller
    /// How far the columns give way (a table with give-way steps): chosen from the width there
    /// is and the columns' measured widths, so only that one grid is ever built.
    @State private var fit = DataTableFit()
    /// The columns' widths as their cells need them, the width the table is given, and whether
    /// the open row is in view: read when choosing, never drawn, so not observed.
    @State private var measured = DataTableMeasurements()

    init(columns: [DataTableColumn<Row>], sections: [DataTableSection<Row>], zebra: Bool = true, showsHeader: Bool = true,
         onSelect: ((Row) -> Void)? = nil, selectedId: Row.ID? = nil) {
        self.columns = columns
        self.sections = sections
        self.zebra = zebra
        self.showsHeader = showsHeader
        self.onSelect = onSelect
        self.selectedId = selectedId
    }

    init(columns: [DataTableColumn<Row>], rows: [Row], total: Row? = nil, zebra: Bool = true, showsHeader: Bool = true,
         onSelect: ((Row) -> Void)? = nil, selectedId: Row.ID? = nil) {
        self.init(columns: columns, sections: [DataTableSection(rows: rows, total: total)], zebra: zebra, showsHeader: showsHeader,
                  onSelect: onSelect, selectedId: selectedId)
    }

    /// The table whose cells are built again only when their row or `key` changes: `key` must
    /// hold everything else the columns' cells show (a currency, the theme), but not the
    /// selection. Rule: any state outside the rows that changes what a column's cells show
    /// (or which columns there are, beyond their titles and widths) must be in `key`, or those
    /// cells keep showing the old state.
    func cellsRebuilt<Key: Equatable>(when key: Key) -> Self where Row: Equatable {
        var table = self
        table.cellsKey = DataTableContentKey(key)
        table.rowKey = { DataTableContentKey($0) }
        return table
    }

    private enum Line {
        case header
        case section(String)
        case row(Row, shaded: Bool)
        case total(Row)
    }

    /// A line's identity: rows and totals by their row's id (and section), so a row's cells
    /// keep their state when rows come and go; the header and group strips by position.
    fileprivate enum LineKey: Hashable {
        case header
        case section(Int)
        case row(section: Int, id: AnyHashable)
        case total(section: Int, id: AnyHashable)
    }

    private struct Entry: Identifiable {
        let index: Int
        let line: Line
        let id: LineKey
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        func add(_ line: Line, _ key: LineKey) { entries.append(Entry(index: entries.count, line: line, id: key)) }
        if showsHeader { add(.header, .header) }
        for (number, section) in sections.enumerated() {
            if let title = section.title { add(.section(title), .section(number)) }
            for (index, row) in section.rows.enumerated() {
                add(.row(row, shaded: zebra && index % 2 == 1), .row(section: number, id: AnyHashable(row.id)))
            }
            if let total = section.total { add(.total(total), .total(section: number, id: AnyHashable(total.id))) }
        }
        return entries
    }

    /// The give-way steps the columns have, in order (empty: the table never gives way).
    private var steps: [Int] {
        Array(Set(columns.compactMap(\.giveWayPriority))).sorted()
    }

    var body: some View {
        // A column's measured width changing (its cells narrowed or widened) chooses the step
        // again, so the table can widen back too (with this table's current columns).
        let _ = measured.onWidthsChanged = steps.isEmpty ? nil : { chooseFit() }
        content
            // Once it has settled (a side panel opening narrows the page, and the table gives
            // way), the open row is brought into view by its page's scroll view: once, a moment
            // after the last change of row or columns (a no-op when the row is already in view).
            .task(id: DataTableScrollKey(selected: selectedId.map(AnyHashable.init), fit: fit)) {
                guard let selectedId, let selectedRowScroller else { return }
                try? await Task.sleep(for: .milliseconds(120))
                // Scrolling lays the whole page out again: not when the row is in view already.
                guard !Task.isCancelled, measured.visibleSelection != AnyHashable(selectedId) else { return }
                selectedRowScroller.scrollTo(DataTableSelection.scrollID)
            }
    }

    @ViewBuilder
    private var content: some View {
        if steps.isEmpty {
            grid(columns.enumerated().map { ($0.element, $0.offset * 2) }, idealAtMinimum: false)
        } else {
            // Too narrow for every column (a side panel open beside it): low-priority columns
            // hide or narrow, step by step, until it fits; past the last step it scrolls
            // sideways rather than make the page wider than the window. The step comes from
            // the width the table is given and its columns' widths (each form measured: the
            // shown ones by the grid, the others by a hidden probe), so only one grid is built.
            let shown = shown(atLevel: fit.level)
            DataTableFitLayout {
                Group {
                    if fit.scrolls {
                        ScrollView(.horizontal) {
                            grid(shown, idealAtMinimum: true)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .wrapProbeScrollsHorizontally()
                    } else {
                        grid(shown, idealAtMinimum: true)
                    }
                }
                // Wider than given when its columns don't fit: choose again.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in chooseFit() }
            }
            .background(alignment: .topLeading) {
                let excluded = Set(shown.compactMap(\.key))
                if let cellsKey, let rowKey {
                    let rows = entries.compactMap { entry -> DataTableContentKey? in
                        switch entry.line {
                        case let .row(row, _), let .total(row): return rowKey(row)
                        case .header, .section: return nil
                        }
                    }
                    EquatableContent(DataTableProbeKey(content: cellsKey, rows: rows, forms: excluded.sorted())) { probe(excluding: excluded) }
                        .equatable()
                } else {
                    probe(excluding: excluded)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                measured.available = width
                chooseFit()
            }
        }
    }

    /// The give-way levels: 0 (every column), then each step in turn.
    private var levels: Int { steps.count }

    /// The columns at `level` (0: every column; n: give-way step n), each with its measured
    /// form's key (nil for the empty filler column).
    private func shown(atLevel level: Int) -> [(column: DataTableColumn<Row>, key: Int?)] {
        level == 0 ? columns.enumerated().map { ($0.element, $0.offset * 2) } : shown(at: steps[level - 1])
    }

    /// The width `level`'s columns need (fill columns at their minimum), or nil while a column
    /// in it hasn't been measured yet.
    private func required(atLevel level: Int) -> CGFloat? {
        var total: CGFloat = 0
        for (column, key) in shown(atLevel: level) {
            switch column.width {
            case let .fixed(value): total += value
            case let .fill(min): total += Swift.max(min, 0)
            case .fit:
                guard let key, let width = measured.widths[key] else { return nil }
                total += width
            case let .min(value):
                guard let key, let width = measured.widths[key] else { return nil }
                total += Swift.max(width, value)
            }
        }
        return total
    }

    /// The first level whose columns fit the width there is; scrolling at the last when none does.
    private func chooseFit() {
        guard let available = measured.available else { return }
        var choice = DataTableFit(level: levels, scrolls: true)
        for level in 0...levels {
            // Not measured yet: the probe or the grid reports it, and this runs again.
            guard let width = required(atLevel: level) else { return }
            if width <= available + 0.5 {
                choice = DataTableFit(level: level, scrolls: false)
                break
            }
        }
        if choice != fit { fit = choice }
    }

    /// Every form of the measured columns (fit and minimum widths) that the grid doesn't
    /// show, laid out hidden for their widths only: what choosing the step needs.
    @ViewBuilder
    private func probe(excluding shownKeys: Set<Int>) -> some View {
        let forms: [(column: DataTableColumn<Row>, key: Int)] = columns.enumerated().flatMap { index, column in
            var forms: [(DataTableColumn<Row>, Int)] = [(column, index * 2)]
            if column.compacts, let step = column.giveWayPriority, let compact = column.at(step: step) { forms.append((compact, index * 2 + 1)) }
            return forms.filter { $0.0.isMeasured && !shownKeys.contains($0.1) }
        }
        if !forms.isEmpty {
            DataTableLayout(widths: forms.map { _ in .fit }, keys: forms.map(\.key), measured: measured) {
                ForEach(entries) { entry in
                    let index = entry.index
                    switch entry.line {
                    case .header:
                        ForEach(Array(forms.enumerated()), id: \.offset) { column, form in
                            headerCell(form.column).layoutValue(key: DataTableSlot.self, value: .cell(line: index, column: column))
                        }
                    case .section: EmptyView()
                    case let .row(row, _): probeCells(row, forms.map(\.column), kind: .row, line: index)
                    case let .total(row): probeCells(row, forms.map(\.column), kind: .total, line: index)
                    }
                }
            }
            .fixedSize()
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .wrapProbeIgnored()
            // Measured anew (rows changed): choose again.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in chooseFit() }
        }
    }

    /// The columns at give-way step `step`. When the column that took the spare width hides
    /// or stops filling, an empty one takes the spare width there, so the table still spans
    /// its width with its figures and actions where they were.
    private func shown(at step: Int) -> [(column: DataTableColumn<Row>, key: Int?)] {
        func fills(_ column: DataTableColumn<Row>) -> Bool {
            if case .fill = column.width { return true }
            return false
        }
        var shown: [(column: DataTableColumn<Row>, key: Int?)] = []
        var filler: Int?
        for (index, column) in columns.enumerated() {
            let given = column.at(step: step)
            // Its key: its own form (even), or its compact form (odd).
            if let given { shown.append((given, index * 2 + (column.compacts && (column.giveWayPriority ?? .max) <= step ? 1 : 0))) }
            // Where the spare width went: in place of a hidden fill column, after a narrowed one.
            if fills(column), filler == nil, given.map(fills) != true { filler = shown.count }
        }
        if let filler, !shown.contains(where: { fills($0.column) }) {
            shown.insert((DataTableColumn("", width: .fill(min: 0)) { _, _ in EmptyView() }, nil), at: filler)
        }
        return shown
    }

    /// The table with `shown` columns. `idealAtMinimum`: its ideal width has its fill columns
    /// at their minimum (what the table compares with the room there is).
    private func grid(_ keyed: [(column: DataTableColumn<Row>, key: Int?)], idealAtMinimum: Bool) -> some View {
        let shown = keyed.map(\.column)
        return DataTableLayout(widths: shown.map(\.width), idealAtMinimum: idealAtMinimum, keys: keyed.map(\.key),
                               measured: steps.isEmpty ? nil : measured) {
            ForEach(entries) { entry in
                let index = entry.index, line = entry.line
                // The lines' backgrounds first, so they draw under the cells; for a row it is
                // also the row's one VoiceOver element. It carries the line's minimum height:
                // rows and totals at least `minRowHeight`, header and group strips their text's.
                background(line)
                    // The open row can be scrolled to: a marker over it (its own identity, and
                    // VoiceOver's focus, stay put).
                    .overlay { if case let .row(row, _) = line, isSelected(line) { selectionMarker(AnyHashable(row.id)) } }
                    .layoutValue(key: DataTableSlot.self, value: .background(line: index, minHeight: minHeight(line)))
            }
            lineCells(keyed)
        }
    }

    private func lineCells(_ keyed: [(column: DataTableColumn<Row>, key: Int?)]) -> some View {
        let shown = keyed.map(\.column)
        return ForEach(entries) { entry in
            let index = entry.index, line = entry.line
            switch line {
            case .header:
                ForEach(Array(shown.enumerated()), id: \.offset) { column, spec in
                    headerCell(spec)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: spec.alignment)
                        .contentShape(Rectangle())
                        .help(spec.headerHelp ?? "")
                        .accessibilityHidden(true)
                        .layoutValue(key: DataTableSlot.self, value: .cell(line: index, column: column))
                }
            case let .section(title):
                Text(title)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .layoutValue(key: DataTableSlot.self, value: .span(line: index))
            case let .row(row, _):
                cells(row, keyed, kind: .row, line: index)
            case let .total(row):
                cells(row, keyed, kind: .total, line: index)
            }
        }
    }

    /// A row's cells in the probe: as the grid lays them out, for their widths only.
    private func probeCells(_ row: Row, _ forms: [DataTableColumn<Row>], kind: DataTableRowKind, line: Int) -> some View {
        ForEach(Array(forms.enumerated()), id: \.offset) { column, spec in
            spec.cell(row, kind)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .layoutValue(key: DataTableSlot.self, value: .cell(line: line, column: column))
        }
    }

    private func headerCell(_ spec: DataTableColumn<Row>) -> some View {
        Text(spec.title)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
    }

    /// Over the open row: what its page's scroll view scrolls to, and whether it's in view.
    private func selectionMarker(_ id: AnyHashable) -> some View {
        Color.clear
            .id(DataTableSelection.scrollID)
            .accessibilityHidden(true)
            .onScrollVisibilityChange(threshold: 0.99) { [measured] visible in
                if visible { measured.visibleSelection = id } else if measured.visibleSelection == id { measured.visibleSelection = nil }
            }
            // Gone (another row opened, the table rebuilt): no longer known to be in view.
            .onDisappear { [measured] in if measured.visibleSelection == id { measured.visibleSelection = nil } }
    }

    private func isSelected(_ line: Line) -> Bool {
        if case let .row(row, _) = line, let selectedId { return row.id == selectedId }
        return false
    }

    private func minHeight(_ line: Line) -> CGFloat {
        switch line {
        case .row, .total: return minRowHeight
        case .header, .section: return 0
        }
    }

    /// A row as VoiceOver reads it: each described cell, titled ("Rent €1,200.00") — also
    /// the columns hidden while the table is narrow.
    private func accessibilityLabel(_ row: Row, kind: DataTableRowKind) -> String {
        let parts = columns.compactMap { column -> String? in
            guard let value = column.accessibilityValue?(row), !value.isEmpty else { return nil }
            return column.title.isEmpty ? value : "\(column.title) \(value)"
        }
        // Nothing described: no label (the line then leaves its cells to VoiceOver).
        guard !parts.isEmpty else { return "" }
        return ((kind == .total ? ["Total"] : []) + parts).joined(separator: ", ")
    }

    @ViewBuilder
    private func cells(_ row: Row, _ keyed: [(column: DataTableColumn<Row>, key: Int?)], kind: DataTableRowKind, line: Int) -> some View {
        // By column (its form): when the table gives way, the cells of the columns that stay
        // are kept, only those of the columns that hide or change form go.
        ForEach(Array(keyed.enumerated()), id: \.element.key) { column, form in
            // With `cellsRebuilt(when:)`: built again only when its row, column or the table's
            // key changes.
            if let cellsKey, let rowKey {
                EquatableContent(DataTableCellKey(table: cellsKey, row: rowKey(row), kind: kind, form: form.key,
                                                  title: form.column.title, width: form.column.width, alignment: form.column.alignment)) {
                    cell(row, form.column, kind: kind)
                }
                .equatable()
                .layoutValue(key: DataTableSlot.self, value: .cell(line: line, column: column))
            } else {
                cell(row, form.column, kind: kind)
                    .layoutValue(key: DataTableSlot.self, value: .cell(line: line, column: column))
            }
        }
    }

    private func cell(_ row: Row, _ spec: DataTableColumn<Row>, kind: DataTableRowKind) -> some View {
        spec.cell(row, kind)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: spec.alignment)
            .modifier(DataTableRowTap(action: kind == .row ? onSelect.map { select in { select(row) } } : nil))
            // Described cells are read with their row (its background's label).
            .accessibilityHidden(spec.accessibilityValue != nil)
    }

    @ViewBuilder
    private func background(_ line: Line) -> some View {
        let fill: Color = switch line {
        case .header: theme.gridHeaderBackground
        case .section: theme.sectionHeaderTint
        case let .row(row, shaded): selectedId.map { $0 == row.id } == true ? theme.selectionFill : theme.rowBackground(shaded)
        case .total: theme.totalsTint
        }
        let base = fill.overlay(alignment: .bottom) {
            Rectangle().frame(height: 1).foregroundStyle(.separator)
        }
        // A row or total with nothing described (every cell its own element) leaves its cells
        // to VoiceOver: an empty element would only be a stop with nothing to say.
        switch line {
        case let .row(row, _):
            let label = accessibilityLabel(row, kind: .row)
            if let onSelect {
                base.modifier(DataTableRowTap(action: { onSelect(row) }))
                    .accessibilityElement(children: .ignore).accessibilityLabel(label)
                    .accessibilityAddTraits(selectedId.map { $0 == row.id } == true ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(selectHint)
                    .accessibilityAction { onSelect(row) }
            } else {
                base.accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityHidden(label.isEmpty)
            }
        case let .total(row):
            let label = accessibilityLabel(row, kind: .total)
            base.accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityHidden(label.isEmpty)
        case .header, .section:
            base.accessibilityHidden(true)
        }
    }
}

/// How far a `DataTable`'s columns give way: `level` 0 shows every column, n the columns at
/// give-way step n; `scrolls` when even the last step is too wide (the table scrolls sideways).
struct DataTableFit: Equatable {
    var level = 0
    var scrolls = false
}

/// A `DataTable`'s `cellsRebuilt(when:)` key, of any equatable type.
struct DataTableContentKey: Equatable {
    private let value: Any
    private let equals: (Any) -> Bool

    init<Value: Equatable>(_ value: Value) {
        self.value = value
        self.equals = { ($0 as? Value) == value }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.equals(rhs.value) }
}

/// A cell of a table with `cellsRebuilt(when:)`: what it shows and where.
private struct DataTableCellKey: Equatable {
    let table: DataTableContentKey
    let row: DataTableContentKey
    let kind: DataTableRowKind
    let form: Int?
    let title: String
    let width: DataTableWidth
    let alignment: Alignment
}

/// The probe of a table with `cellsRebuilt(when:)`: the rows and the forms it measures.
private struct DataTableProbeKey: Equatable {
    let content: DataTableContentKey
    let rows: [DataTableContentKey]
    let forms: [Int]
}

/// What brings the open row into view: the row, and the columns it is laid out with.
private struct DataTableScrollKey: Equatable {
    let selected: AnyHashable?
    let fit: DataTableFit
}

/// What a `DataTable` measures and tracks without drawing it (not observed, so updating it
/// doesn't redraw the table): the widths its measured columns need, by column form (its index
/// × 2, + 1 for its compact form), written as its grid and probe lay out; the width it is
/// given; and the open row, while it's in view.
final class DataTableMeasurements: @unchecked Sendable {
    var widths: [Int: CGFloat] = [:]
    var available: CGFloat?
    var visibleSelection: AnyHashable?
    /// Chooses the table's step again (set by the table as it draws).
    var onWidthsChanged: (() -> Void)?
}

/// A table that gives way: as wide as it is given (never wider, so the page doesn't grow) and
/// as tall as its grid; the grid is laid out in that width, overflowing it only until the
/// table has chosen its columns.
struct DataTableFitLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let grid = subviews.first else { return .zero }
        let size = grid.sizeThatFits(proposal)
        guard let width = proposal.width, width.isFinite else { return size }
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
    }

    // No alignment guides of its own (`DataTableLayout`'s note).
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// The row whose details are open (`DataTable.selectedId`), for a `ScrollViewReader`: a page
/// that narrows for a side panel scrolls it back into view when its rows move.
enum DataTableSelection {
    static let scrollID = "DataTable.selectedRow"
}

extension EnvironmentValues {
    /// The page's scroll view, which brings the open row (`DataTableSelection.scrollID`) into view.
    @Entry var selectedRowScroller: ScrollViewProxy? = nil
}

/// A clickable row's cell or background: the whole area takes the click (buttons in it keep theirs).
private struct DataTableRowTap: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.contentShape(Rectangle()).onTapGesture(perform: action)
        } else {
            content
        }
    }
}

/// A row's actions: inline icon buttons, then a ••• menu with the rest.
struct DataTableActions: View {
    let actions: [DataTableAction]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(actions.filter(\.isInline).enumerated()), id: \.offset) { _, action in
                Button(role: action.role, action: action.action) { Image(systemName: action.systemImage) }
                    .buttonStyle(.borderless)
                    .help(action.title)
                    .accessibilityLabel(action.title)
            }
            let menu = actions.filter { !$0.isInline }
            if !menu.isEmpty {
                Menu {
                    ForEach(Array(menu.enumerated()), id: \.offset) { _, action in
                        Button(role: action.role, action: action.action) { Label(action.title, systemImage: action.systemImage) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
            }
        }
        .fixedSize()
    }
}

/// Where a `DataTableLayout` subview goes.
enum DataTableSlot: LayoutValueKey {
    case cell(line: Int, column: Int)
    /// A view across every column (a group's title).
    case span(line: Int)
    /// A line's background, across every column, under its cells, and the line's minimum height.
    case background(line: Int, minHeight: CGFloat)
    case none

    static let defaultValue = DataTableSlot.none

    var line: Int? {
        switch self {
        case let .cell(line, _), let .span(line), let .background(line, _): return line
        case .none: return nil
        }
    }
}

/// Lays a `DataTable` out: one width per column for every line (the widest cell, a minimum or
/// a fixed width; fill columns share what's left), each line as tall as its tallest cell (at
/// least the minimum its background carries), backgrounds and spans across the full width.
struct DataTableLayout: Layout {
    let widths: [DataTableWidth]
    /// Its ideal width (no width proposed) has the fill columns at their minimum, not as
    /// wide as their widest cell.
    var idealAtMinimum = false
    /// Each column's form (`DataTableMeasurements`), when its measured width is reported.
    var keys: [Int?] = []
    var measured: DataTableMeasurements?

    /// What the layout has measured since its cells last changed: each column's widest cell
    /// (what doesn't depend on the width proposed), each column's cell heights at the width it
    /// was last given, and the layout at the widths proposed lately — so a new width proposed
    /// (a side panel opening, the window's minimum worked out) measures again only the columns
    /// whose width changes.
    struct Cache {
        var ideal: [CGFloat]?
        /// By column: its width, and its cells' heights by line at that width.
        var columnHeights: [Int: (width: CGFloat, heights: [Int: CGFloat])] = [:]
        /// The group strips' heights by line, at the table's width.
        var spanHeights: (width: CGFloat, heights: [Int: CGFloat])?
        /// The lines' minimum heights (their backgrounds').
        var minimumHeights: [Int: CGFloat]?
        /// The layout by width proposed.
        var layouts: [CGFloat?: Laid] = [:]
        var columnWidths: [CGFloat] = []
        var lineHeights: [Int: CGFloat] = [:]
    }

    struct Laid {
        var columnWidths: [CGFloat]
        var lineHeights: [Int: CGFloat]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// Each column's widest cell (unconstrained), reported to `measured`.
    private func idealWidths(_ subviews: Subviews) -> [CGFloat] {
        var ideal = Array(repeating: CGFloat(0), count: widths.count)
        for subview in subviews {
            guard case let .cell(_, column) = subview[DataTableSlot.self], column < widths.count else { continue }
            ideal[column] = max(ideal[column], subview.sizeThatFits(.unspecified).width)
        }
        if let measured {
            var changed = false
            for (index, key) in keys.enumerated() where index < ideal.count {
                guard let key else { continue }
                switch widths[index] {
                case .fit, .min:
                    if measured.widths[key] != ideal[index] { changed = true }
                    measured.widths[key] = ideal[index]
                case .fixed, .fill: break
                }
            }
            // Choose the step again once this layout is over (not during it).
            if changed { DispatchQueue.main.async { measured.onWidthsChanged?() } }
        }
        return ideal
    }

    private func columnWidths(ideal: [CGFloat], proposedWidth: CGFloat?) -> [CGFloat] {
        var result = ideal
        var fillColumns: [Int] = []
        for (index, width) in widths.enumerated() {
            switch width {
            case .fit: break
            case let .min(value): result[index] = max(ideal[index], value)
            case let .fixed(value): result[index] = value
            case let .fill(min):
                result[index] = Swift.max(min, 0)
                fillColumns.append(index)
            }
        }
        guard !fillColumns.isEmpty else { return result }
        let fixedTotal = result.enumerated().filter { !fillColumns.contains($0.offset) }.reduce(0) { $0 + $1.element }
        let available = (proposedWidth ?? (fixedTotal + fillColumns.reduce(0) { $0 + (idealAtMinimum ? 0 : ideal[$1]) })) - fixedTotal
        let share = available / CGFloat(fillColumns.count)
        for index in fillColumns {
            let minimum: CGFloat
            if case let .fill(min) = widths[index] { minimum = min } else { minimum = 0 }
            result[index] = Swift.max(minimum, proposedWidth == nil ? (idealAtMinimum ? minimum : ideal[index]) : share)
        }
        return result
    }

    /// Each line's height at `columnWidths`: its tallest cell, at least its minimum. Only the
    /// columns whose width changed since they were last measured are measured again.
    private func lineHeights(_ subviews: Subviews, columnWidths: [CGFloat], cache: inout Cache) -> [Int: CGFloat] {
        let total = columnWidths.reduce(0, +)
        if cache.minimumHeights == nil {
            var minimums: [Int: CGFloat] = [:]
            for subview in subviews {
                if case let .background(line, minHeight) = subview[DataTableSlot.self] { minimums[line] = Swift.max(minimums[line] ?? 0, minHeight) }
            }
            cache.minimumHeights = minimums
        }
        let stale = Set(columnWidths.indices.filter { cache.columnHeights[$0]?.width != columnWidths[$0] })
        let spansStale = cache.spanHeights?.width != total
        if !stale.isEmpty || spansStale {
            var fresh: [Int: [Int: CGFloat]] = [:]
            var spans: [Int: CGFloat] = [:]
            for subview in subviews {
                switch subview[DataTableSlot.self] {
                case let .cell(line, column) where stale.contains(column):
                    let height = subview.sizeThatFits(ProposedViewSize(width: columnWidths[column], height: nil)).height
                    fresh[column, default: [:]][line] = Swift.max(fresh[column]?[line] ?? 0, height)
                case let .span(line) where spansStale:
                    spans[line] = Swift.max(spans[line] ?? 0, subview.sizeThatFits(ProposedViewSize(width: total, height: nil)).height)
                default: break
                }
            }
            for column in stale { cache.columnHeights[column] = (columnWidths[column], fresh[column] ?? [:]) }
            if spansStale { cache.spanHeights = (total, spans) }
        }
        var heights = cache.minimumHeights ?? [:]
        for (_, entry) in cache.columnHeights {
            for (line, height) in entry.heights { heights[line] = Swift.max(heights[line] ?? 0, height) }
        }
        for (line, height) in cache.spanHeights?.heights ?? [:] { heights[line] = Swift.max(heights[line] ?? 0, height) }
        return heights
    }

    private func prepare(_ proposal: ProposedViewSize, _ subviews: Subviews, _ cache: inout Cache) {
        if let laid = cache.layouts[proposal.width] {
            cache.columnWidths = laid.columnWidths
            cache.lineHeights = laid.lineHeights
            return
        }
        let ideal = cache.ideal ?? idealWidths(subviews)
        cache.ideal = ideal
        cache.columnWidths = columnWidths(ideal: ideal, proposedWidth: proposal.width)
        cache.lineHeights = lineHeights(subviews, columnWidths: cache.columnWidths, cache: &cache)
        // A few widths are proposed in turn (the window's minimum, the page's width…).
        if cache.layouts.count >= 8 { cache.layouts.removeAll() }
        cache.layouts[proposal.width] = Laid(columnWidths: cache.columnWidths, lineHeights: cache.lineHeights)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    // The table has no alignment guides of its own: without these, a stack aligning it would
    // ask every cell for its guides (the default merges its subviews'), on every layout.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        prepare(proposal, subviews, &cache)
        return CGSize(width: cache.columnWidths.reduce(0, +), height: cache.lineHeights.values.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        prepare(ProposedViewSize(width: bounds.width, height: proposal.height), subviews, &cache)
        var lineY: [Int: CGFloat] = [:]
        var y = bounds.minY
        for line in cache.lineHeights.keys.sorted() {
            lineY[line] = y
            y += cache.lineHeights[line] ?? 0
        }
        var columnX: [CGFloat] = []
        var x = bounds.minX
        for width in cache.columnWidths {
            columnX.append(x)
            x += width
        }
        for subview in subviews {
            let slot = subview[DataTableSlot.self]
            guard let line = slot.line, let top = lineY[line], let height = cache.lineHeights[line] else { continue }
            switch slot {
            case let .cell(_, column):
                guard column < columnX.count else { continue }
                subview.place(at: CGPoint(x: columnX[column], y: top), anchor: .topLeading,
                              proposal: ProposedViewSize(width: cache.columnWidths[column], height: height))
            case .span, .background:
                subview.place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: height))
            case .none: break
            }
        }
    }
}
