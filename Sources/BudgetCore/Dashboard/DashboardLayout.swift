import Foundation

/// The Mac Dashboard's saved layout, fluid rather than a grid: each section is rows of tiles. Inside a row the
/// tiles share the width by fractions (a divider between two tiles moves the boundary continuously) and each row
/// has its own height in points (a divider under the row changes it). Fractions scale with the window; heights
/// don't. A per-device setting kept in `UserDefaults` under `storageKey` as JSON (never synced). Nothing saved is
/// the default arrangement. Hidden tiles are simply not passed in `natural`: their slot closes up.
///
/// The layout from before the fluid revision (snapped spans) is still read: its tile order, column spans (as
/// relative widths) and row height turn into the first fluid arrangement.
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

    public static let storageKey = "dashboardLayout"
    public static let spacing = 12.0
    /// A tile never gets narrower or shorter than this by dragging a divider.
    public static let minimumTileWidth = 170.0
    public static let minimumTileHeight = 100.0
    public static let maximumRowHeight = 640.0
    /// Tiles per row in the default arrangement (by weight: a wide tile counts 2).
    public static let defaultRowWeight = 3.0

    /// What a legacy (snapped-span) layout contributes until the user first changes the fluid one.
    public struct Legacy: Codable, Equatable, Sendable {
        public var order: [String] = []
        public var weights: [String: Double] = [:]
        public var minimumHeight = 0.0
    }

    public struct SectionLayout: Codable, Equatable, Sendable {
        /// Tile ids per row, top to bottom. Nil: the default arrangement.
        public var rows: [[String]]?
        /// Each tile's share of its row (summing to 1 per row).
        public var fractions: [String: Double] = [:]
        /// Height in points of each row, aligned with `rows`.
        public var heights: [Double] = []
        public var legacy: Legacy?

        public init() {}

        public var isEmpty: Bool { self == SectionLayout() }

        private enum CodingKeys: String, CodingKey { case rows, fractions, heights, legacy }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rows = try? c.decode([[String]].self, forKey: .rows)
            fractions = ((try? c.decode([String: Double].self, forKey: .fractions)) ?? [:]).filter { $0.value.isFinite && $0.value > 0 }
            heights = ((try? c.decode([Double].self, forKey: .heights)) ?? []).map { $0.isFinite ? $0 : 0 }
            legacy = try? c.decode(Legacy.self, forKey: .legacy)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(rows, forKey: .rows)
            if rows != nil {
                try c.encode(fractions, forKey: .fractions)
                try c.encode(heights, forKey: .heights)
            }
            try c.encodeIfPresent(legacy, forKey: .legacy)
        }
    }

    /// A row as it is shown: its tiles, their shares of the width and its height.
    public struct ResolvedRow: Equatable, Sendable {
        public var tiles: [String]
        public var fractions: [Double]
        public var height: Double
    }

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

    public var isDefault: Bool { sections.values.allSatisfy(\.isEmpty) }

    // MARK: Encoding (version 2; version 1 had `order`/`spans`/`columns`/`rowHeight` per section)

    private enum CodingKeys: String, CodingKey { case version = "v", sections }
    private struct LegacySection: Decodable {
        struct Span: Decodable { var columns: Int }
        var order: [String]?
        var spans: [String: Span]?
        var rowHeight: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if (try? c.decode(Int.self, forKey: .version)) == 2 {
            let raw = (try? c.decode([String: SectionLayout].self, forKey: .sections)) ?? [:]
            for (key, value) in raw { if let section = Section(rawValue: key), !value.isEmpty { sections[section] = value } }
        } else {
            let raw = (try? c.decode([String: LegacySection].self, forKey: .sections)) ?? [:]
            for (key, old) in raw {
                guard let section = Section(rawValue: key) else { continue }
                var legacy = Legacy()
                legacy.order = old.order ?? []
                legacy.weights = (old.spans ?? [:]).mapValues { Double(min(max($0.columns, 1), 3)) }
                legacy.minimumHeight = ["regular": 150.0, "tall": 230.0][old.rowHeight ?? ""] ?? 0
                var value = SectionLayout()
                if !legacy.order.isEmpty || !legacy.weights.isEmpty || legacy.minimumHeight > 0 { value.legacy = legacy }
                if !value.isEmpty { sections[section] = value }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .version)
        var raw: [String: SectionLayout] = [:]
        for (section, layout) in sections where !layout.isEmpty { raw[section.rawValue] = layout }
        try c.encode(raw, forKey: .sections)
    }

    // MARK: Reading

    public func layout(_ section: Section) -> SectionLayout { sections[section] ?? SectionLayout() }

    /// A tile's share of the default row: wide tiles count double.
    public static func defaultWeight(for tile: String) -> Double {
        tile == DashboardTile.netWorth || tile == DashboardTile.year || tile == DashboardTile.tenancyCashFlow ? 2 : 1
    }

    /// The height a tile needs to show its usual content (figure, chart or its first lines).
    public static func defaultHeight(for tile: String) -> Double {
        switch tile {
        case DashboardTile.netWorth, DashboardTile.currentMonth, DashboardTile.year, DashboardTile.yearChange,
             DashboardTile.taxYear, DashboardTile.evidence, DashboardTile.propertyMonth:
            return 184
        case DashboardTile.tenancyCashFlow, DashboardTile.propertyReturn:
            return 230
        default: return 164
        }
    }

    /// Tiles in order into rows of about three tiles' width, as evenly as the weights allow (four tiles are 2 + 2,
    /// not 3 + 1).
    public static func defaultRows(_ tiles: [String], weights: [String: Double] = [:]) -> [[String]] {
        func weight(_ tile: String) -> Double { weights[tile] ?? defaultWeight(for: tile) }
        let total = tiles.reduce(0) { $0 + weight($1) }
        guard total > 0 else { return [] }
        let rowCount = max(1, Int((total / defaultRowWeight).rounded(.up)))
        let target = (total / Double(rowCount)).rounded(.up)
        var rows: [[String]] = [], current: [String] = [], used = 0.0
        for tile in tiles {
            if !current.isEmpty, used + weight(tile) > target, rows.count < rowCount - 1 {
                rows.append(current); current = []; used = 0
            }
            current.append(tile); used += weight(tile)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private static func row(_ tiles: [String], fractions: [String: Double], height: Double?) -> ResolvedRow {
        var shares = tiles.map { fractions[$0] ?? 0 }
        if shares.contains(where: { $0 <= 0 }) { shares = tiles.map { _ in 1.0 } }
        let sum = shares.reduce(0, +)
        return ResolvedRow(tiles: tiles, fractions: shares.map { $0 / sum },
                           height: min(max(height ?? tiles.map(defaultHeight(for:)).max() ?? 164, minimumTileHeight), maximumRowHeight))
    }

    /// The rows to show for the visible tiles (`natural`, in their natural order).
    public func rows(_ section: Section, natural: [String]) -> [ResolvedRow] {
        let saved = layout(section)
        var seen = Set<String>()
        var result: [ResolvedRow] = []
        if let rows = saved.rows {
            for (index, ids) in rows.enumerated() {
                let tiles = ids.filter { natural.contains($0) && seen.insert($0).inserted }
                guard !tiles.isEmpty else { continue }
                // A row that lost a tile (hidden) keeps its other shares, renormalised.
                result.append(Self.row(tiles, fractions: saved.fractions, height: index < saved.heights.count && saved.heights[index] > 0 ? saved.heights[index] : nil))
            }
            let extra = natural.filter { !seen.contains($0) }
            for ids in Self.defaultRows(extra) { result.append(Self.row(ids, fractions: [:], height: nil)) }
        } else {
            let legacy = saved.legacy
            let known = (legacy?.order ?? []).filter { natural.contains($0) }
            let ordered = known + natural.filter { !known.contains($0) }
            for ids in Self.defaultRows(ordered, weights: legacy?.weights ?? [:]) {
                let weights = ids.map { legacy?.weights[$0] ?? Self.defaultWeight(for: $0) }
                var fractions: [String: Double] = [:]
                for (id, weight) in zip(ids, weights) { fractions[id] = weight }
                let height = max(ids.map(Self.defaultHeight(for:)).max() ?? 164, legacy?.minimumHeight ?? 0)
                result.append(Self.row(ids, fractions: fractions, height: height))
            }
        }
        return result
    }

    // MARK: Geometry

    public struct TileFrame: Equatable, Sendable {
        public let tile: String
        public let row: Int
        public let index: Int
        public let x: Double, y: Double, width: Double, height: Double
    }

    /// Where each tile goes in a section `width` wide.
    public static func frames(_ rows: [ResolvedRow], width: Double, spacing: Double = spacing) -> [TileFrame] {
        var result: [TileFrame] = []
        var y = 0.0
        for (r, row) in rows.enumerated() {
            let usable = max(0, width - spacing * Double(row.tiles.count - 1))
            var x = 0.0
            for (i, tile) in row.tiles.enumerated() {
                let w = usable * row.fractions[i]
                result.append(TileFrame(tile: tile, row: r, index: i, x: x, y: y, width: w, height: row.height))
                x += w + spacing
            }
            y += row.height + spacing
        }
        return result
    }

    public static func totalHeight(_ rows: [ResolvedRow], spacing: Double = spacing) -> Double {
        rows.reduce(0) { $0 + $1.height } + spacing * Double(max(0, rows.count - 1))
    }

    /// The row's fractions with the divider after tile `divider` dragged `delta` points: only that pair changes,
    /// and neither tile goes below `minimumWidth` (or half the pair, in a row too narrow for both).
    public static func draggedFractions(_ start: [Double], divider: Int, delta: Double, width: Double,
                                        spacing: Double = spacing, minimumWidth: Double = minimumTileWidth) -> [Double] {
        guard divider >= 0, divider + 1 < start.count else { return start }
        let usable = max(1, width - spacing * Double(start.count - 1))
        let pair = start[divider] + start[divider + 1]
        let minimum = min(minimumWidth / usable, pair / 2)
        let left = min(max(start[divider] + delta / usable, minimum), pair - minimum)
        var result = start
        result[divider] = left
        result[divider + 1] = pair - left
        return result
    }

    public static func draggedHeight(_ start: Double, delta: Double) -> Double {
        min(max(start + delta, minimumTileHeight), maximumRowHeight)
    }

    // MARK: Changing

    /// Saves the rows as shown, so a change to one row keeps every other row as it looked (and the first change to a
    /// default or legacy layout fixes it).
    private mutating func store(_ shown: [ResolvedRow], _ section: Section) {
        var value = SectionLayout()
        value.rows = shown.map(\.tiles)
        value.heights = shown.map { ($0.height * 10).rounded() / 10 }
        for row in shown { for (tile, fraction) in zip(row.tiles, row.fractions) { value.fractions[tile] = (fraction * 10_000).rounded() / 10_000 } }
        sections[section] = value
    }

    public mutating func setFractions(_ fractions: [Double], row: Int, in section: Section, natural: [String]) {
        var shown = rows(section, natural: natural)
        guard shown.indices.contains(row), fractions.count == shown[row].tiles.count else { return }
        shown[row].fractions = fractions
        store(shown, section)
    }

    public mutating func setHeight(_ height: Double, row: Int, in section: Section, natural: [String]) {
        var shown = rows(section, natural: natural)
        guard shown.indices.contains(row) else { return }
        shown[row].height = min(max(height, Self.minimumTileHeight), Self.maximumRowHeight)
        store(shown, section)
    }

    public enum Direction: Sendable { case left, right, up, down }

    /// Whether `move` would do something for the tile.
    public func canMove(_ tile: String, _ direction: Direction, in section: Section, natural: [String]) -> Bool {
        let shown = rows(section, natural: natural)
        guard let r = shown.firstIndex(where: { $0.tiles.contains(tile) }), let i = shown[r].tiles.firstIndex(of: tile) else { return false }
        switch direction {
        case .left: return i > 0
        case .right: return i + 1 < shown[r].tiles.count
        case .up: return r > 0 || shown[r].tiles.count > 1
        case .down: return r + 1 < shown.count || shown[r].tiles.count > 1
        }
    }

    /// Left/right swap the tile with its neighbour (each place keeps its width). Up/down take it to the row
    /// above/below, sharing that row's width equally; from the first/last row they start a row of its own.
    public mutating func move(_ tile: String, _ direction: Direction, in section: Section, natural: [String]) {
        guard canMove(tile, direction, in: section, natural: natural) else { return }
        var shown = rows(section, natural: natural)
        let r = shown.firstIndex { $0.tiles.contains(tile) }!
        let i = shown[r].tiles.firstIndex(of: tile)!
        switch direction {
        case .left, .right:
            let j = direction == .left ? i - 1 : i + 1
            shown[r].tiles.swapAt(i, j)
        case .up, .down:
            let n = shown[r].tiles.count
            var from = shown[r]
            from.tiles.remove(at: i)
            let removed = from.fractions.remove(at: i)
            if !from.tiles.isEmpty { from.fractions = from.fractions.map { $0 / max(1 - removed, 0.0001) } }
            let target = direction == .up ? r - 1 : r + 1
            if shown.indices.contains(target) {
                var into = shown[target]
                let share = 1.0 / Double(into.tiles.count + 1)
                let at = min(i, into.tiles.count)
                into.fractions = into.fractions.map { $0 * (1 - share) }
                into.tiles.insert(tile, at: at)
                into.fractions.insert(share, at: at)
                shown[target] = into
                shown[r] = from
                if from.tiles.isEmpty { shown.remove(at: r) }
            } else {
                precondition(n > 1)
                let own = ResolvedRow(tiles: [tile], fractions: [1], height: Self.defaultHeight(for: tile))
                shown[r] = from
                shown.insert(own, at: direction == .up ? r : r + 1)
            }
        }
        store(shown, section)
    }

    // MARK: Dragging a tile

    /// Where a dragged tile lands. Indices refer to the rows as shown before the move: `row(r, at: i)` puts the
    /// tile into row `r` before that row's tile `i` (`i` = the row's tile count puts it last); `newRow(at: k)` makes
    /// a row of its own before row `k` (`k` = the row count puts it at the bottom).
    public enum Drop: Equatable, Sendable {
        case row(Int, at: Int)
        case newRow(at: Int)
    }

    /// How far into a row (from its top and bottom edges) the "new row" zone around the gap between rows reaches.
    public static let newRowZone = 8.0

    /// Where a tile dropped with the pointer at (`x`, `y`) in a section `width` wide would land: between two rows
    /// (or above the first / below the last) it starts a new row, over a row it goes in at the pointer's side of each
    /// tile's middle. Nil when there are no rows.
    public static func dropTarget(x: Double, y: Double, rows: [ResolvedRow], width: Double, spacing: Double = spacing) -> Drop? {
        guard !rows.isEmpty else { return nil }
        let frames = Self.frames(rows, width: width, spacing: spacing)
        if y < newRowZone { return .newRow(at: 0) }
        var top = 0.0
        for (r, row) in rows.enumerated() {
            let bottom = top + row.height
            let isLast = r + 1 == rows.count
            // Around the gap under this row (or the bottom edge of the last one): a row of its own.
            if y >= bottom - newRowZone && (isLast || y < bottom + spacing + newRowZone) { return .newRow(at: r + 1) }
            if y < bottom {
                let middles = frames.filter { $0.row == r }.map { $0.x + $0.width / 2 }
                return .row(r, at: middles.filter { $0 < x }.count)
            }
            top = bottom + spacing
        }
        return .newRow(at: rows.count)
    }

    /// Whether `drop` would change the arrangement for the tile.
    public func canMove(_ tile: String, to drop: Drop, in section: Section, natural: [String]) -> Bool {
        Self.arranged(rows(section, natural: natural), moving: tile, to: drop) != nil
    }

    /// The rows after the move; nil when it changes nothing (or the tile or target isn't there).
    private static func arranged(_ shown: [ResolvedRow], moving tile: String, to drop: Drop) -> [ResolvedRow]? {
        guard let r = shown.firstIndex(where: { $0.tiles.contains(tile) }), let i = shown[r].tiles.firstIndex(of: tile) else { return nil }
        var rows = shown
        switch drop {
        case .row(let target, let at):
            guard rows.indices.contains(target) else { return nil }
            if target == r {
                // Within the row the places keep their widths and the tiles change places.
                var tiles = rows[r].tiles
                tiles.remove(at: i)
                tiles.insert(tile, at: min(max(at > i ? at - 1 : at, 0), tiles.count))
                guard tiles != rows[r].tiles else { return nil }
                rows[r].tiles = tiles
                return rows
            }
            var from = rows[r]
            from.tiles.remove(at: i)
            let removed = from.fractions.remove(at: i)
            if !from.tiles.isEmpty { from.fractions = from.fractions.map { $0 / max(1 - removed, 0.0001) } }
            var into = rows[target]
            let share = 1.0 / Double(into.tiles.count + 1)
            let position = min(max(at, 0), into.tiles.count)
            into.fractions = into.fractions.map { $0 * (1 - share) }
            into.tiles.insert(tile, at: position)
            into.fractions.insert(share, at: position)
            rows[target] = into
            rows[r] = from
            if from.tiles.isEmpty { rows.remove(at: r) }
            return rows
        case .newRow(let k):
            guard k >= 0, k <= rows.count else { return nil }
            // A tile already alone in the row that is (or would stay) where it is changes nothing.
            if rows[r].tiles.count == 1 && (k == r || k == r + 1) { return nil }
            var from = rows[r]
            from.tiles.remove(at: i)
            let removed = from.fractions.remove(at: i)
            if !from.tiles.isEmpty { from.fractions = from.fractions.map { $0 / max(1 - removed, 0.0001) } }
            rows[r] = from
            rows.insert(ResolvedRow(tiles: [tile], fractions: [1], height: defaultHeight(for: tile)), at: k)
            // The emptied row is where it was, unless the new one went in above it.
            if from.tiles.isEmpty { rows.remove(at: k <= r ? r + 1 : r) }
            return rows
        }
    }

    /// Moves the tile to `drop` (see `Drop`) within its section; the first change to a default layout fixes it as
    /// shown. A drop that changes nothing leaves the layout alone.
    public mutating func move(tile: String, to drop: Drop, in section: Section, natural: [String]) {
        guard let rows = Self.arranged(self.rows(section, natural: natural), moving: tile, to: drop) else { return }
        store(rows, section)
    }

    /// Back to the default layout.
    public mutating func reset() { sections = [:] }
    public mutating func reset(_ section: Section) { sections[section] = nil }
}

/// What a tile has room to show, by its size. Content is added in priority order as the tile grows; the big figure
/// always stays, the chart goes first when space runs out.
public struct TileBudget: Equatable, Sendable {
    /// Padding, title row and the gap under it.
    public static let chrome = 56.0
    /// The tile's big figure with its caption.
    public static let figure = 44.0
    /// A label + figure line with a meter under it.
    public static let meterLine = 29.0
    /// One line of caption text, or a text row of a list.
    public static let textLine = 20.0
    public static let listRow = 22.0
    public static let minimumChartHeight = 70.0
    public static let minimumBesideChartWidth = 110.0
    public static let besideFigureWidth = 168.0

    public private(set) var remaining: Double

    /// The room left in a tile of this height after its chrome (and `reserved` points of fixed content).
    public init(height: Double, reserved: Double = 0) { remaining = height - Self.chrome - reserved }

    /// Spends `cost` if it is there.
    public mutating func take(_ cost: Double) -> Bool {
        guard remaining >= cost else { return false }
        remaining -= cost
        return true
    }

    /// How many of up to `maximum` items of `cost` each fit (and spends their room).
    public mutating func count(upTo maximum: Int, cost: Double) -> Int {
        let n = max(0, min(maximum, Int((remaining / cost).rounded(.down))))
        remaining -= Double(n) * cost
        return n
    }

    /// Like `count(upTo:cost:)`, but when not all `maximum` items fit, keeps room for a "+ n more" line of
    /// `trailer` points after them (one item fewer if need be).
    public mutating func count(upTo maximum: Int, cost: Double, trailer: Double) -> Int {
        let all = Int((remaining / cost).rounded(.down))
        if all >= maximum { return count(upTo: maximum, cost: cost) }
        let n = max(0, Int(((remaining - trailer) / cost).rounded(.down)))
        remaining -= Double(n) * cost + (n > 0 ? trailer : 0)
        return n
    }

    public enum ChartPlacement: Equatable, Sendable { case beside, below, hidden }

    public struct ChartPlan: Equatable, Sendable {
        public var placement: ChartPlacement
        /// Height the chart has (0 when hidden).
        public var chartHeight: Double
        /// Secondary lines (text lines under the figure) that fit.
        public var lines: Int
    }

    /// Chart beside the figures when the tile is wide enough, under them when it is tall enough, else none (the figure
    /// always stays). `footer` is room kept for a line under the whole thing; `maximumLines` how many secondary
    /// lines exist.
    public static func chartPlan(width: Double, height: Double, footer: Double = 0, maximumLines: Int, lineCost: Double = textLine) -> ChartPlan {
        let contentWidth = width - 24
        let room = height - chrome - footer
        func lines(_ available: Double) -> Int { max(0, min(maximumLines, Int(((available - figure) / lineCost).rounded(.down)))) }
        if contentWidth >= besideFigureWidth + 12 + minimumBesideChartWidth, room >= minimumChartHeight {
            return ChartPlan(placement: .beside, chartHeight: room, lines: lines(room))
        }
        if contentWidth >= 130, room - figure >= minimumChartHeight + 6 {
            let chart = room - figure - 6
            // Lines only take what the chart leaves above its minimum.
            return ChartPlan(placement: .below, chartHeight: chart, lines: max(0, min(maximumLines, Int(((chart - minimumChartHeight) / lineCost).rounded(.down)))))
        }
        return ChartPlan(placement: .hidden, chartHeight: 0, lines: lines(room))
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
    public static let tenancyCashFlow = "tenancyCashFlow"
    public static let propertyReturn = "propertyReturn"
    public static func mortgage(_ propertyName: String) -> String { "mortgage:" + propertyName }
    public static let taxYear = "taxYear"
    public static let evidence = "evidence"
    public static let importsWaiting = "importsWaiting"
    public static let attention = "attention"

    /// The name a menu gives a tile.
    public static func title(_ id: String) -> String {
        switch id {
        case netWorth: return "Net worth"
        case currentMonth: return "Current month"
        case year: return "Year at a glance"
        case yearChange: return "Net worth change a year"
        case topCategories: return "Top categories"
        case upcomingBills: return "Bills"
        case accounts: return "Accounts"
        case propertyMonth: return "Property month"
        case tenancyCashFlow: return "Tenancy cash flow by month"
        case propertyReturn: return "Property return for the year"
        case taxYear: return "Tax year"
        case evidence: return "Evidence and documents"
        case importsWaiting: return "Imports waiting"
        case attention: return "Needs attention"
        default: return id.hasPrefix("mortgage:") ? "Mortgage · " + id.dropFirst("mortgage:".count) : id
        }
    }
}
