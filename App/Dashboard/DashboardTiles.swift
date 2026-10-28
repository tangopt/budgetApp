// App/Dashboard/DashboardTiles.swift
import SwiftUI
import BudgetCore

// The Dashboard's building blocks: titled sections of compact tiles. A tile leads with one big figure and
// a small chart; its other text is one line. Tiles in a row share the row's height (`TileGrid`).

/// How many columns of the grid a tile takes (1 by default).
private struct TileSpanKey: LayoutValueKey {
    static let defaultValue = 1
}

extension View {
    /// The tile takes this many columns of its `TileGrid` (fewer when the window has fewer).
    func tileSpan(_ columns: Int) -> some View { layoutValue(key: TileSpanKey.self, value: columns) }
}

/// Tiles in columns of at least `minimumColumnWidth` (as many as fit, up to three), filled in order; every tile
/// in a row has that row's height. Always exactly full rows of its columns' width: no gaps on a wide window.
struct TileGrid: Layout {
    var minimumColumnWidth: CGFloat = 236
    var spacing: CGFloat = 12
    var maximumColumns = 3

    private func columnCount(_ width: CGFloat) -> Int {
        max(1, min(maximumColumns, Int(((width + spacing) / (minimumColumnWidth + spacing)).rounded(.down))))
    }

    /// The rows as (subview index, columns taken).
    private func rows(_ subviews: Subviews, columns: Int) -> [[(index: Int, span: Int)]] {
        var rows: [[(index: Int, span: Int)]] = [[]]
        var used = 0
        for (index, subview) in subviews.enumerated() {
            let span = min(max(1, subview[TileSpanKey.self]), columns)
            if used + span > columns, used > 0 { rows.append([]); used = 0 }
            rows[rows.count - 1].append((index, span))
            used += span
        }
        // A row that doesn't fill the columns gives the rest to its last tile.
        return rows.filter { !$0.isEmpty }.map { row in
            var row = row
            let spare = columns - row.reduce(0) { $0 + $1.span }
            if spare > 0 { row[row.count - 1].span += spare }
            return row
        }
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> (heights: [CGFloat], rows: [[(index: Int, span: Int)]], columnWidth: CGFloat) {
        let columns = columnCount(width)
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = rows(subviews, columns: columns)
        let heights = rows.map { row in
            row.map { item in
                subviews[item.index].sizeThatFits(ProposedViewSize(width: columnWidth * CGFloat(item.span) + spacing * CGFloat(item.span - 1), height: nil)).height
            }.max() ?? 0
        }
        return (heights, rows, columnWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumColumnWidth * 3
        let laid = layout(subviews, width: width)
        let height = laid.heights.reduce(0, +) + spacing * CGFloat(max(0, laid.heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = layout(subviews, width: bounds.width)
        var y = bounds.minY
        for (rowIndex, row) in laid.rows.enumerated() {
            var x = bounds.minX
            for item in row {
                let width = laid.columnWidth * CGFloat(item.span) + spacing * CGFloat(item.span - 1)
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                           proposal: ProposedViewSize(width: width, height: laid.heights[rowIndex]))
                x += width + spacing
            }
            y += laid.heights[rowIndex] + spacing
        }
    }
}

/// A titled section: its name, a rule, then its tiles.
struct DashboardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
            TileGrid { content }
        }
    }
}

/// One tile: a small title (with an optional "Name ›" link and accessory), then its content, filling the height
/// the grid gives it.
struct DashTile<Accessory: View, Content: View>: View {
    let title: String
    var linkTitle: String? = nil
    var onLink: (() -> Void)? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                accessory
                if let linkTitle, let onLink { PanelLink(title: linkTitle, action: onLink).lineLimit(1).fixedSize() }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

extension DashTile where Accessory == EmptyView {
    init(_ title: String, linkTitle: String? = nil, onLink: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, linkTitle: linkTitle, onLink: onLink, accessory: { EmptyView() }, content: content)
    }
}

/// The tile's one big figure with its one-line caption under it.
struct TileFigure: View {
    let value: String
    var caption: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(tint)
                .figureText(.shrink(minimumScale: 0.6))
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// A label with a figure at its trailing edge and, under them, a thin meter (the figure never wraps; the label
/// truncates in the middle).
struct MeterLine: View {
    let label: String
    let figure: String
    let fraction: Double
    var pace: Double? = nil
    let tint: Color
    var figureTint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(figure).font(.caption).monospacedDigit().foregroundStyle(figureTint).figureText()
            }
            PaceMeter(fraction: fraction, pace: pace, tint: tint)
        }
    }
}

/// A ring showing how far along something is, with its short label in the middle.
struct TileRing: View {
    let fraction: Double
    let label: String
    var tint: Color = .accentColor
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            Circle().stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 6)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label).font(.caption.weight(.semibold)).monospacedDigit().figureText(.shrink(minimumScale: 0.7))
                .padding(.horizontal, 8)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
