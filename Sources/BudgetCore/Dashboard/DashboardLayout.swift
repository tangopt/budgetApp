import Foundation

/// The Mac Dashboard's saved layout: per section, the tiles' order and sizes, the column count and the row
/// height. A per-device setting kept in `UserDefaults` under `storageKey` as JSON (never synced). An empty
/// layout is the default: natural tile order, default spans, Auto columns, Compact rows. Hidden tiles are simply
/// not passed to `order`/`pack`, so their slot closes up and their saved size is kept for when they return.
public struct DashboardLayout: Codable, Equatable, Sendable {
    public enum Section: String, CaseIterable, Codable, Sendable {
        case money, property, tax

        public var title: String {
            switch self {
            case .money: return "Money"
            case .property: return "Property"
            case .tax: return "Tax & documents"
            }
        }
    }

    public enum RowHeight: String, CaseIterable, Codable, Sendable {
        case compact, regular, tall

        public var title: String { rawValue.capitalized }
        /// The least height of one grid row; a row grows to fit its tiles' content.
        public var minimumHeight: Double {
            switch self {
            case .compact: return 0
            case .regular: return 150
            case .tall: return 230
            }
        }
    }

    /// Columns and rows a tile takes.
    public struct Span: Codable, Equatable, Sendable {
        public static let maximumColumns = 3
        public static let maximumRows = 2
        public var columns: Int
        public var rows: Int

        public init(columns: Int, rows: Int) {
            self.columns = min(max(1, columns), Self.maximumColumns)
            self.rows = min(max(1, rows), Self.maximumRows)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(columns: try container.decode(Int.self, forKey: .columns), rows: try container.decode(Int.self, forKey: .rows))
        }
    }

    public struct SectionLayout: Codable, Equatable, Sendable {
        /// Tile ids in the user's order (may list tiles not shown now; unknown ones are ignored).
        public var order: [String] = []
        public var spans: [String: Span] = [:]
        /// 2...4, or nil for Auto (by the window's width).
        public var columns: Int?
        public var rowHeight: RowHeight = .compact
        public init() {}

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            order = (try? container.decode([String].self, forKey: .order)) ?? []
            spans = (try? container.decode([String: Span].self, forKey: .spans)) ?? [:]
            columns = (try? container.decode(Int?.self, forKey: .columns)).flatMap { $0 }.flatMap { Self.columnChoices.contains($0) ? $0 : nil }
            rowHeight = (try? container.decode(RowHeight.self, forKey: .rowHeight)) ?? .compact
        }

        public static let columnChoices = 2...4
    }

    public static let storageKey = "dashboardLayout"
    /// Smallest column the grid goes to when the user picks a column count the window can't fit at the Auto width.
    public static let autoMinimumColumnWidth = 236.0
    public static let chosenMinimumColumnWidth = 150.0
    public static let autoMaximumColumns = 3

    public var sections: [Section: SectionLayout] = [:]

    public init() {}

    /// From the stored JSON; anything unreadable or empty is the default layout.
    public init(storedString: String) {
        if let data = storedString.data(using: .utf8), !storedString.isEmpty,
           let decoded = try? JSONDecoder().decode(DashboardLayout.self, from: data) {
            self = decoded
        } else {
            self.init()
        }
    }

    public var storedString: String {
        if isDefault { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public var isDefault: Bool { sections.values.allSatisfy { $0 == SectionLayout() } }

    /// Back to the default layout.
    public mutating func reset() { sections = [:] }

    // MARK: Encoding keys (sections are keyed by raw value so the JSON is a plain object)

    private enum CodingKeys: String, CodingKey { case sections }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decode([String: SectionLayout].self, forKey: .sections)) ?? [:]
        for (key, value) in raw { if let section = Section(rawValue: key) { sections[section] = value } }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: SectionLayout] = [:]
        for (section, layout) in sections where layout != SectionLayout() { raw[section.rawValue] = layout }
        try container.encode(raw, forKey: .sections)
    }

    // MARK: Reading

    public func layout(_ section: Section) -> SectionLayout { sections[section] ?? SectionLayout() }

    /// The size a tile has until the user resizes it.
    public static func defaultSpan(for tile: String) -> Span {
        switch tile {
        case DashboardTile.netWorth, DashboardTile.year: return Span(columns: 2, rows: 1)
        default: return Span(columns: 1, rows: 1)
        }
    }

    public func span(_ tile: String, in section: Section) -> Span {
        layout(section).spans[tile] ?? Self.defaultSpan(for: tile)
    }

    /// The shown tiles (`natural`, in their natural order) in the user's order: saved order first, then any tile
    /// the saved order doesn't know, in natural order.
    public func order(_ section: Section, natural: [String]) -> [String] {
        let saved = layout(section).order
        let known = saved.filter(natural.contains)
        return known + natural.filter { !known.contains($0) }
    }

    /// Columns for a section given the width it has. Auto: as many as fit at 236 pt, up to 3. Chosen: that many,
    /// fewer only if the window can't hold them at 150 pt.
    public func columnCount(_ section: Section, width: Double, spacing: Double = 12) -> Int {
        func fit(_ minimum: Double) -> Int { max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down))) }
        if let chosen = layout(section).columns { return max(1, min(chosen, fit(Self.chosenMinimumColumnWidth))) }
        return min(Self.autoMaximumColumns, fit(Self.autoMinimumColumnWidth))
    }

    // MARK: Changing

    public mutating func setSpan(_ tile: String, in section: Section, to span: Span) {
        var value = layout(section)
        if span == Self.defaultSpan(for: tile) { value.spans[tile] = nil } else { value.spans[tile] = span }
        sections[section] = value
    }

    public mutating func setColumns(_ columns: Int?, in section: Section) {
        var value = layout(section)
        value.columns = columns.flatMap { SectionLayout.columnChoices.contains($0) ? $0 : nil }
        sections[section] = value
    }

    public mutating func setRowHeight(_ rowHeight: RowHeight, in section: Section) {
        var value = layout(section)
        value.rowHeight = rowHeight
        sections[section] = value
    }

    /// Moves `tile` to the place `target` has in the shown order (before it when moving up, after it when moving
    /// down, as a list reorder does).
    public mutating func move(_ tile: String, onto target: String, in section: Section, natural: [String]) {
        var shown = order(section, natural: natural)
        guard tile != target, let from = shown.firstIndex(of: tile), let to = shown.firstIndex(of: target) else { return }
        shown.remove(at: from)
        shown.insert(tile, at: to)
        var value = layout(section)
        // Keep saved positions of hidden tiles: they trail the shown ones.
        value.order = shown + value.order.filter { !shown.contains($0) }
        sections[section] = value
    }

    /// The span a corner drag lands on: the starting span plus the drag in whole cells, clamped.
    public static func draggedSpan(from start: Span, dx: Double, dy: Double, cellWidth: Double, cellHeight: Double, maximumColumns: Int) -> Span {
        let columns = start.columns + Int((dx / max(cellWidth, 1)).rounded())
        let rows = start.rows + Int((dy / max(cellHeight, 1)).rounded())
        return Span(columns: min(columns, max(1, maximumColumns)), rows: rows)
    }

    // MARK: Packing

    public struct Placement: Equatable, Sendable {
        public let tile: String
        public let column: Int
        public let row: Int
        public let columns: Int
        public let rows: Int
    }

    /// Places tiles (in order, with their spans) on a grid of `columns`: each at the first free spot at or after the
    /// previous tile's, so order reads left to right, top to bottom and a short tile leaves room for the next beside
    /// or under it. A tile wider than the grid is cut to it. A tile with free cells to its right (same rows) grows
    /// into them, so a row of tiles never ends short of the right edge unless a taller neighbour above holds it.
    public static func pack(_ tiles: [(id: String, span: Span)], columns: Int) -> [Placement] {
        let columns = max(1, columns)
        var occupied: [[Bool]] = []
        func ensure(_ rows: Int) { while occupied.count < rows { occupied.append(Array(repeating: false, count: columns)) } }
        func fits(_ row: Int, _ column: Int, _ width: Int, _ height: Int) -> Bool {
            guard column + width <= columns else { return false }
            ensure(row + height)
            for r in row..<(row + height) { for c in column..<(column + width) where occupied[r][c] { return false } }
            return true
        }
        var placed: [(id: String, row: Int, column: Int, width: Int, height: Int)] = []
        var cursor = 0
        for tile in tiles {
            let width = min(tile.span.columns, columns), height = tile.span.rows
            var index = cursor
            while !fits(index / columns, index % columns, width, height) { index += 1 }
            let row = index / columns, column = index % columns
            for r in row..<(row + height) { for c in column..<(column + width) { occupied[r][c] = true } }
            placed.append((tile.id, row, column, width, height))
            cursor = index
        }
        var result: [Placement] = []
        for tile in placed {
            var width = tile.width
            while tile.column + width < columns,
                  (tile.row..<(tile.row + tile.height)).allSatisfy({ !occupied[$0][tile.column + width] }) {
                for r in tile.row..<(tile.row + tile.height) { occupied[r][tile.column + width] = true }
                width += 1
            }
            result.append(Placement(tile: tile.id, column: tile.column, row: tile.row, columns: width, rows: tile.height))
        }
        return result
    }

    /// Placements for the shown tiles of a section at a width.
    public func placements(_ section: Section, natural: [String], width: Double, spacing: Double = 12) -> [Placement] {
        let columns = columnCount(section, width: width, spacing: spacing)
        return Self.pack(order(section, natural: natural).map { ($0, span($0, in: section)) }, columns: columns)
    }
}

/// Ids of the Dashboard's tiles in a saved layout.
public enum DashboardTile {
    public static let netWorth = "netWorth"
    public static let currentMonth = "currentMonth"
    public static let year = "year"
    public static let yearChange = "yearChange"
    public static let topCategories = "topCategories"
    public static let upcomingBills = "upcomingBills"
    public static let accounts = "accounts"
    public static let propertyMonth = "propertyMonth"
    public static func mortgage(_ propertyName: String) -> String { "mortgage:" + propertyName }
    public static let taxYear = "taxYear"
    public static let evidence = "evidence"
    public static let importsWaiting = "importsWaiting"
    public static let attention = "attention"
}
