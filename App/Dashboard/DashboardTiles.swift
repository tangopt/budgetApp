// App/Dashboard/DashboardTiles.swift
import SwiftUI
import BudgetCore

// The Dashboard's building blocks: titled sections of compact tiles. A tile leads with one big figure and
// a small chart; its other text is one line. Tiles in a row share the row's height (`TileGrid`).

/// The tile's id in a saved layout (`DashboardTile`), read by `TileGrid`.
private struct TileIDKey: LayoutValueKey {
    static let defaultValue = ""
}

/// What the Dashboard's grids need to lay tiles out and edit them: the saved layout, and (while editing) a way
/// to change it. Absent outside the Dashboard: the default layout, no editing.
struct DashboardLayoutContext {
    var layout = DashboardLayout()
    var isEditing = false
    var change: (@MainActor (DashboardLayout.Section, (inout DashboardLayout) -> Void) -> Void)?
    /// The width the current section's grid has (set by `DashboardSection`).
    var sectionWidth: CGFloat = 0
    /// The ids of the tiles the current section shows, in their natural order.
    var naturalIDs: [String] = []
}

private struct DashboardLayoutContextKey: EnvironmentKey {
    static let defaultValue = DashboardLayoutContext()
}

extension EnvironmentValues {
    var dashboardLayoutContext: DashboardLayoutContext {
        get { self[DashboardLayoutContextKey.self] }
        set { self[DashboardLayoutContextKey.self] = newValue }
    }
}

extension View {
    /// Makes this view the tile `id` of `section`'s grid: sized and placed by the saved layout, and (in edit mode)
    /// resizable by its corner and draggable to reorder.
    func dashSlot(_ section: DashboardLayout.Section, _ id: String) -> some View {
        modifier(DashSlot(section: section, id: id))
    }
}

/// Tiles on a grid of columns whose count and rows' least height come from the saved layout (`DashboardLayout`).
/// Tiles take their spans in the user's order; a row is as tall as its tallest single-row tile needs (and at least
/// the section's row height), and a tile spanning two rows takes both. Always full rows of columns: no gaps at the
/// right edge.
struct TileGrid: Layout {
    var section: DashboardLayout.Section
    var layout: DashboardLayout
    var spacing: CGFloat = 12

    private struct Laid {
        var placements: [DashboardLayout.Placement]
        var indexOf: [String: Int]
        var columnWidth: CGFloat
        var rowHeights: [CGFloat]
    }

    private func laid(_ subviews: Subviews, width: CGFloat) -> Laid {
        var ids: [String] = []
        var indexOf: [String: Int] = [:]
        for (index, subview) in subviews.enumerated() {
            var id = subview[TileIDKey.self]
            if id.isEmpty || indexOf[id] != nil { id = "tile\(index)" }
            ids.append(id)
            indexOf[id] = index
        }
        let placements = layout.placements(section, natural: ids, width: Double(width), spacing: Double(spacing))
        let columns = max(1, layout.columnCount(section, width: Double(width), spacing: Double(spacing)))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let minimum = CGFloat(layout.layout(section).rowHeight.minimumHeight)
        var heights = [CGFloat](repeating: minimum, count: (placements.map { $0.row + $0.rows }.max() ?? 0))
        func tileWidth(_ placement: DashboardLayout.Placement) -> CGFloat {
            columnWidth * CGFloat(placement.columns) + spacing * CGFloat(placement.columns - 1)
        }
        func ideal(_ placement: DashboardLayout.Placement) -> CGFloat {
            subviews[indexOf[placement.tile]!].sizeThatFits(ProposedViewSize(width: tileWidth(placement), height: nil)).height
        }
        for placement in placements where placement.rows == 1 { heights[placement.row] = max(heights[placement.row], ideal(placement)) }
        for placement in placements where placement.rows > 1 {
            let have = (placement.row..<(placement.row + placement.rows)).reduce(0) { $0 + heights[$1] } + spacing * CGFloat(placement.rows - 1)
            let need = ideal(placement)
            if need > have { heights[placement.row + placement.rows - 1] += need - have }
        }
        return Laid(placements: placements, indexOf: indexOf, columnWidth: columnWidth, rowHeights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 236 * 3
        let laid = laid(subviews, width: width)
        return CGSize(width: width, height: laid.rowHeights.reduce(0, +) + spacing * CGFloat(max(0, laid.rowHeights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = laid(subviews, width: bounds.width)
        var rowTops: [CGFloat] = []
        var y = bounds.minY
        for height in laid.rowHeights { rowTops.append(y); y += height + spacing }
        for placement in laid.placements {
            let width = laid.columnWidth * CGFloat(placement.columns) + spacing * CGFloat(placement.columns - 1)
            let height = (placement.row..<(placement.row + placement.rows)).reduce(0) { $0 + laid.rowHeights[$1] } + spacing * CGFloat(placement.rows - 1)
            subviews[laid.indexOf[placement.tile]!].place(
                at: CGPoint(x: bounds.minX + (laid.columnWidth + spacing) * CGFloat(placement.column), y: rowTops[placement.row]),
                anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
        }
    }
}

/// A titled section: its name, a rule, then its tiles. In edit mode a menu sets the section's columns and row height.
struct DashboardSection<Content: View>: View {
    let section: DashboardLayout.Section
    /// The ids of the tiles shown, in their natural order.
    let tiles: [String]
    @ViewBuilder let content: Content
    @Environment(\.dashboardLayoutContext) private var context
    @State private var width: CGFloat = 0

    var body: some View {
        let layout = context.layout.layout(section)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(section.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                if context.isEditing {
                    Menu {
                        Picker("Columns", selection: Binding(get: { layout.columns ?? 0 }, set: { value in
                            context.change?(section) { $0.setColumns(value == 0 ? nil : value, in: section) }
                        })) {
                            Text("Auto").tag(0)
                            ForEach(Array(DashboardLayout.SectionLayout.columnChoices), id: \.self) { Text("\($0) columns").tag($0) }
                        }
                        Picker("Row height", selection: Binding(get: { layout.rowHeight }, set: { value in
                            context.change?(section) { $0.setRowHeight(value, in: section) }
                        })) {
                            ForEach(DashboardLayout.RowHeight.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label("\(layout.columns.map { "\($0) columns" } ?? "Auto columns") · \(layout.rowHeight.title) rows", systemImage: "slider.horizontal.3")
                            .font(.caption).lineLimit(1).fixedSize()
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("\(section.title) layout")
                }
            }
            TileGrid(section: section, layout: context.layout) { content }
                .environment(\.dashboardLayoutContext, { var inner = context; inner.sectionWidth = width; inner.naturalIDs = tiles; return inner }())
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }
}

/// Edit mode for one tile: a layer over it that takes the clicks, drags the tile to reorder, and a corner handle that
/// resizes it in whole grid cells.
private struct DashSlot: ViewModifier {
    let section: DashboardLayout.Section
    let id: String
    @Environment(\.dashboardLayoutContext) private var context
    @State private var dragged: DashboardLayout.Span?
    @State private var dropTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay { if context.isEditing { editLayer } }
            .zIndex(dragged == nil ? 0 : 1)
            .layoutValue(key: TileIDKey.self, value: id)
    }

    private var editLayer: some View {
        GeometryReader { proxy in
            let spacing = 12.0
            let columns = max(1, context.layout.columnCount(section, width: Double(context.sectionWidth), spacing: spacing))
            let columnPitch = (Double(context.sectionWidth) + spacing) / Double(columns)
            let stored = context.layout.span(id, in: section)
            let shownColumns = max(1, Int(((Double(proxy.size.width) + spacing) / columnPitch).rounded()))
            let start = DashboardLayout.Span(columns: shownColumns, rows: stored.rows)
            let rowPitch = (Double(proxy.size.height) + spacing) / Double(start.rows)
            let shape = RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius)
            ZStack(alignment: .bottomTrailing) {
                shape.fill(Color.accentColor.opacity(dropTargeted ? 0.25 : 0.06))
                shape.strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                if let dragged {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: columnPitch * Double(dragged.columns) - spacing, height: rowPitch * Double(dragged.rows) - spacing)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
                Text("\(dragged?.columns ?? start.columns) × \(dragged?.rows ?? start.rows)")
                    .font(.caption.monospacedDigit().weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(6)
                    .allowsHitTesting(false)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor)).padding(6)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
                        .onChanged { value in
                            dragged = DashboardLayout.draggedSpan(from: start, dx: Double(value.translation.width), dy: Double(value.translation.height),
                                                                  cellWidth: columnPitch, cellHeight: rowPitch, maximumColumns: columns)
                        }
                        .onEnded { value in
                            let span = DashboardLayout.draggedSpan(from: start, dx: Double(value.translation.width), dy: Double(value.translation.height),
                                                                   cellWidth: columnPitch, cellHeight: rowPitch, maximumColumns: columns)
                            dragged = nil
                            if span != start { context.change?(section) { $0.setSpan(id, in: section, to: span) } }
                        })
                    .help("Drag to resize")
                    .accessibilityLabel("Resize tile")
            }
            .contentShape(Rectangle())
            .draggable(id) {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.5)).frame(width: 120, height: 60)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let other = items.first, other != id else { return false }
                context.change?(section) { $0.move(other, onto: id, in: section, natural: context.naturalIDs) }
                return true
            } isTargeted: { dropTargeted = $0 }
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

/// A tile's figures on the left and its chart on the right. The chart fills the height the tile gives it (at least
/// `minimumHeight`) and needs `minimumChartWidth`; a tile too narrow for both shows the figures alone.
struct ChartBeside<Figures: View, Chart: View>: View {
    var minimumHeight: CGFloat = 84
    var minimumChartWidth: CGFloat = 110
    @ViewBuilder let figures: Figures
    @ViewBuilder let chart: (CGFloat) -> Chart

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                figures.frame(width: 168, alignment: .leading)
                GeometryReader { proxy in chart(max(minimumHeight, proxy.size.height)) }
                    .frame(minWidth: minimumChartWidth, minHeight: minimumHeight, maxHeight: .infinity)
            }
            figures.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
