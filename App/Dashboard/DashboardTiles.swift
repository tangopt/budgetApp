// App/Dashboard/DashboardTiles.swift
import SwiftUI
import BudgetCore

// The Dashboard's building blocks: titled sections of tiles laid out fluidly. A tile leads with one big figure and
// a small chart; the rest of what it shows depends on the room its size gives it (`TileBudget`). Between tiles
// there are draggable dividers; the proportions are saved (`DashboardLayout`).

/// The tile's id in a saved layout (`DashboardTile`), read by `FluidTiles`.
private struct TileIDKey: LayoutValueKey {
    static let defaultValue = ""
}

/// What the Dashboard's sections need to lay tiles out and change them: the saved layout and a way to change it.
/// Absent outside the Dashboard: the default layout, no changes.
struct DashboardLayoutContext {
    var layout = DashboardLayout()
    var change: (@MainActor ((inout DashboardLayout) -> Void) -> Void)?
}

private struct DashboardLayoutContextKey: EnvironmentKey {
    static let defaultValue = DashboardLayoutContext()
}

/// The size of the tile a view is in (set by `DashTile`), so its content can adapt to it.
private struct TileSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 300, height: DashboardLayout.defaultHeight(for: ""))
}

extension EnvironmentValues {
    var dashboardLayoutContext: DashboardLayoutContext {
        get { self[DashboardLayoutContextKey.self] }
        set { self[DashboardLayoutContextKey.self] = newValue }
    }

    var tileSize: CGSize {
        get { self[TileSizeKey.self] }
        set { self[TileSizeKey.self] = newValue }
    }
}

extension View {
    /// Makes this view the tile `id` of its section: sized and placed by the saved layout.
    func dashSlot(_ section: DashboardLayout.Section, _ id: String) -> some View {
        layoutValue(key: TileIDKey.self, value: id)
    }
}

/// Places a section's tiles in the rows and fractions it is given, each at exactly its frame.
private struct FluidTiles: Layout {
    var rows: [DashboardLayout.ResolvedRow]

    private func frames(width: CGFloat) -> [String: DashboardLayout.TileFrame] {
        Dictionary(DashboardLayout.frames(rows, width: Double(width)).map { ($0.tile, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 700, height: DashboardLayout.totalHeight(rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(width: bounds.width)
        for subview in subviews {
            guard let frame = frames[subview[TileIDKey.self]] else { subview.place(at: bounds.origin, proposal: .zero); continue }
            subview.place(at: CGPoint(x: bounds.minX + frame.x, y: bounds.minY + frame.y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// A draggable divider: invisible until the pointer is over it, then a thin handle and a resize cursor. Dragging
/// reports the distance moved so far (in the window's space, so it stays steady while the divider moves under it).
private struct DividerHandle: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    let length: CGFloat
    let label: String
    let onDrag: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let isVertical = axis == .vertical
        ZStack {
            Capsule().fill(Color.accentColor.opacity(dragging ? 0.9 : 0.6))
                .frame(width: isVertical ? 4 : min(length, 48), height: isVertical ? min(length, 48) : 4)
                .opacity(hovering || dragging ? 1 : 0)
        }
        .frame(width: isVertical ? 14 : length, height: isVertical ? length : 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerStyle(isVertical ? .columnResize : .rowResize)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { dragging = true; onDrag(isVertical ? $0.translation.width : $0.translation.height) }
            .onEnded { dragging = false; onEnd(isVertical ? $0.translation.width : $0.translation.height) })
        .accessibilityElement()
        .accessibilityLabel(label)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A titled section: its name, a rule and a small menu to arrange its tiles, then its rows of tiles with dividers.
struct DashboardSection<Content: View>: View {
    let section: DashboardLayout.Section
    /// The ids of the tiles shown, in their natural order.
    let tiles: [String]
    @ViewBuilder let content: Content
    @Environment(\.dashboardLayoutContext) private var context
    @State private var width: CGFloat = 0
    /// A divider drag under way: the row, and the fractions or height it would have.
    @State private var drag: (row: Int, fractions: [Double]?, height: Double?)?

    private var savedRows: [DashboardLayout.ResolvedRow] { context.layout.rows(section, natural: tiles) }

    private var shownRows: [DashboardLayout.ResolvedRow] {
        var rows = savedRows
        if let drag, rows.indices.contains(drag.row) {
            if let fractions = drag.fractions, fractions.count == rows[drag.row].fractions.count { rows[drag.row].fractions = fractions }
            if let height = drag.height { rows[drag.row].height = height }
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(section.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                arrangeMenu
            }
            let rows = shownRows
            FluidTiles(rows: rows) { content }
                .overlay(alignment: .topLeading) { dividers(rows) }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    /// Move tiles between and within rows; reset this section.
    private var arrangeMenu: some View {
        Menu {
            ForEach(tiles, id: \.self) { tile in
                Menu(DashboardTile.title(tile)) {
                    ForEach([("Move left", DashboardLayout.Direction.left), ("Move right", .right), ("Move to the row above", .up), ("Move to the row below", .down)], id: \.0) { label, direction in
                        Button(label) { context.change?({ $0.move(tile, direction, in: section, natural: tiles) }) }
                            .disabled(!context.layout.canMove(tile, direction, in: section, natural: tiles))
                    }
                }
            }
            Divider()
            Button("Reset \(section.title) layout") { context.change?({ $0.reset(section) }) }
                .disabled(context.layout.layout(section).isEmpty)
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Arrange the \(section.title) tiles. Drag the gaps between tiles to resize them.")
        .accessibilityLabel("Arrange \(section.title) tiles")
    }

    private func dividers(_ rows: [DashboardLayout.ResolvedRow]) -> some View {
        let frames = DashboardLayout.frames(rows, width: Double(width))
        let spacing = DashboardLayout.spacing
        return ZStack(alignment: .topLeading) {
            // Between rows: the row's height.
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                let top = frames.first { $0.row == r }?.y ?? 0
                DividerHandle(axis: .horizontal, length: width, label: "Resize row \(r + 1) height") { delta in
                    drag = (r, nil, DashboardLayout.draggedHeight(savedRows[r].height, delta: Double(delta)))
                } onEnd: { delta in
                    let height = DashboardLayout.draggedHeight(savedRows[r].height, delta: Double(delta))
                    drag = nil
                    context.change?({ $0.setHeight(height, row: r, in: section, natural: tiles) })
                }
                .offset(y: top + row.height + spacing / 2 - 7)
            }
            // Between tiles of a row: the boundary.
            ForEach(frames.filter { $0.index < (rows[$0.row].tiles.count - 1) }, id: \.tile) { frame in
                let r = frame.row, i = frame.index
                DividerHandle(axis: .vertical, length: frame.height, label: "Resize \(DashboardTile.title(frame.tile))") { delta in
                    drag = (r, DashboardLayout.draggedFractions(savedRows[r].fractions, divider: i, delta: Double(delta), width: Double(width)), nil)
                } onEnd: { delta in
                    let fractions = DashboardLayout.draggedFractions(savedRows[r].fractions, divider: i, delta: Double(delta), width: Double(width))
                    drag = nil
                    context.change?({ $0.setFractions(fractions, row: r, in: section, natural: tiles) })
                }
                .offset(x: frame.x + frame.width + spacing / 2 - 7, y: frame.y)
            }
        }
        .frame(width: width, height: DashboardLayout.totalHeight(rows), alignment: .topLeading)
    }
}

/// One tile: a small title (with an optional "Name ›" link and accessory), then its content, which is given the tile's
/// size (and ChartBeside reads it from the environment) to decide how much to show. Clipped to the tile as a last resort.
struct DashTile<Accessory: View, Content: View>: View {
    let title: String
    var linkTitle: String? = nil
    var onLink: (() -> Void)? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder let content: (CGSize) -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius)
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    accessory
                    if let linkTitle, let onLink { PanelLink(title: linkTitle, action: onLink).lineLimit(1).fixedSize() }
                }
                content(CGSize(width: proxy.size.width, height: proxy.size.height))
            }
            .padding(12)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .environment(\.tileSize, proxy.size)
        }
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
        .clipShape(shape)
    }
}

extension DashTile where Accessory == EmptyView {
    init(_ title: String, linkTitle: String? = nil, onLink: (() -> Void)? = nil, @ViewBuilder content: @escaping (CGSize) -> Content) {
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

/// A tile's figures with its chart: beside them when the tile is wide, under them when it is tall and narrow, and
/// not at all when it is small (the figure always stays). The chart fills the room it is given; `figures` is told
/// how many secondary lines fit. `footer` is room kept for a line the tile adds under all of it.
struct ChartBeside<Figures: View, Chart: View>: View {
    var maximumLines = 0
    var footer: CGFloat = 0
    @ViewBuilder let figures: (Int) -> Figures
    @ViewBuilder let chart: (CGFloat) -> Chart
    @Environment(\.tileSize) private var size

    var body: some View {
        let plan = TileBudget.chartPlan(width: Double(size.width), height: Double(size.height), footer: Double(footer), maximumLines: maximumLines)
        Group {
            switch plan.placement {
            case .beside:
                HStack(alignment: .top, spacing: 12) {
                    figures(plan.lines).frame(width: CGFloat(TileBudget.besideFigureWidth), alignment: .leading)
                    chart(CGFloat(plan.chartHeight)).frame(maxWidth: .infinity)
                }
            case .below:
                VStack(alignment: .leading, spacing: 6) {
                    figures(plan.lines)
                    chart(CGFloat(plan.chartHeight)).frame(maxWidth: .infinity)
                }
            case .hidden:
                figures(plan.lines)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
