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
    let cell: (Row, DataTableRowKind) -> AnyView

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
    @Environment(\.theme) private var theme

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

    private enum Line {
        case header
        case section(String)
        case row(Row, shaded: Bool)
        case total(Row)
    }

    /// A line's identity: rows and totals by their row's id (and section), so a row's cells
    /// keep their state when rows come and go; the header and group strips by position.
    private enum LineKey: Hashable {
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

    var body: some View {
        DataTableLayout(widths: columns.map(\.width)) {
            ForEach(entries) { entry in
                let index = entry.index, line = entry.line
                // Each line's background first, so it draws under the line's cells; for a row it
                // is also the row's one VoiceOver element. It carries the line's minimum height:
                // rows and totals at least `minRowHeight`, header and group strips their text's.
                background(line).layoutValue(key: DataTableSlot.self, value: .background(line: index, minHeight: minHeight(line)))
                switch line {
                case .header:
                    ForEach(Array(columns.enumerated()), id: \.offset) { column, spec in
                        Text(spec.title)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
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
                    cells(row, kind: .row, line: index)
                case let .total(row):
                    cells(row, kind: .total, line: index)
                }
            }
        }
    }

    private func minHeight(_ line: Line) -> CGFloat {
        switch line {
        case .row, .total: return minRowHeight
        case .header, .section: return 0
        }
    }

    /// A row as VoiceOver reads it: each described cell, titled ("Rent €1,200.00").
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
    private func cells(_ row: Row, kind: DataTableRowKind, line: Int) -> some View {
        ForEach(Array(columns.enumerated()), id: \.offset) { column, spec in
            spec.cell(row, kind)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: spec.alignment)
                .modifier(DataTableRowTap(action: kind == .row ? onSelect.map { select in { select(row) } } : nil))
                // Described cells are read with their row (its background's label).
                .accessibilityHidden(spec.accessibilityValue != nil)
                .layoutValue(key: DataTableSlot.self, value: .cell(line: line, column: column))
        }
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

    struct Cache {
        var columnWidths: [CGFloat] = []
        var lineHeights: [Int: CGFloat] = [:]
        var proposedWidth: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func columnWidths(_ subviews: Subviews, proposedWidth: CGFloat?) -> [CGFloat] {
        var ideal = Array(repeating: CGFloat(0), count: widths.count)
        for subview in subviews {
            guard case let .cell(_, column) = subview[DataTableSlot.self], column < widths.count else { continue }
            ideal[column] = max(ideal[column], subview.sizeThatFits(.unspecified).width)
        }
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
        let available = (proposedWidth ?? (fixedTotal + fillColumns.reduce(0) { $0 + ideal[$1] })) - fixedTotal
        let share = available / CGFloat(fillColumns.count)
        for index in fillColumns {
            let minimum: CGFloat
            if case let .fill(min) = widths[index] { minimum = min } else { minimum = 0 }
            result[index] = Swift.max(minimum, proposedWidth == nil ? ideal[index] : share)
        }
        return result
    }

    private func lineHeights(_ subviews: Subviews, columnWidths: [CGFloat]) -> [Int: CGFloat] {
        let total = columnWidths.reduce(0, +)
        var heights: [Int: CGFloat] = [:]
        for subview in subviews {
            let slot = subview[DataTableSlot.self]
            switch slot {
            case let .cell(line, column):
                let width = column < columnWidths.count ? columnWidths[column] : 0
                let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                heights[line] = Swift.max(heights[line] ?? 0, height)
            case let .span(line):
                let height = subview.sizeThatFits(ProposedViewSize(width: total, height: nil)).height
                heights[line] = Swift.max(heights[line] ?? 0, height)
            case let .background(line, minHeight):
                heights[line] = Swift.max(heights[line] ?? 0, minHeight)
            case .none: break
            }
        }
        return heights
    }

    private func prepare(_ proposal: ProposedViewSize, _ subviews: Subviews, _ cache: inout Cache) {
        if cache.columnWidths.isEmpty || cache.proposedWidth != proposal.width {
            cache.columnWidths = columnWidths(subviews, proposedWidth: proposal.width)
            cache.lineHeights = lineHeights(subviews, columnWidths: cache.columnWidths)
            cache.proposedWidth = proposal.width
        }
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

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
