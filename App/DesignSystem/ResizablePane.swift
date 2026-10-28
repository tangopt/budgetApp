// App/DesignSystem/ResizablePane.swift
import SwiftUI
import AppKit
import BudgetCore

/// The draggable edge between two panes: a hairline with a wider invisible grab area, the
/// left-right resize cursor over it. `onDrag` gets the translation since the drag began (points,
/// right is positive) and `onEnd` the drag finishing.
private struct PaneDivider: View {
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { onDrag($0.translation.width) }
                        .onEnded { _ in onEnd() })
                    .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
                    .accessibilityHidden(true)
            }
            .help("Drag to resize")
    }
}

/// A page with a detail panel docked at its trailing edge, resizable by dragging the leading edge.
/// The one component behind every Mac right-hand panel (the Budget and Forecast grids' cell panel,
/// Categories, Documents, Property's statements, receipts and months, Missing documents).
/// The width is remembered per `kind` on this Mac (`@AppStorage`, so the snapshot harness's own
/// defaults apply there), held between `minimumWidth` and `maximumWidth`, and never so wide the
/// page loses `pageMinimum`. The page narrows at once; only the panel fades.
struct ResizableDock<Page: View, Panel: View>: View {
    let kind: String
    var isOpen = true
    var defaultWidth: CGFloat = 320
    var minimumWidth: CGFloat = 280
    var maximumWidth: CGFloat = 4000
    var pageMinimum: CGFloat = 360
    @ViewBuilder let page: Page
    @ViewBuilder let panel: Panel

    @AppStorage private var stored: Double
    @State private var dragStart: CGFloat?
    @State private var live: CGFloat?

    init(kind: String, isOpen: Bool = true, defaultWidth: CGFloat = 320, minimumWidth: CGFloat = 280,
         maximumWidth: CGFloat = 4000, pageMinimum: CGFloat = 360,
         @ViewBuilder page: () -> Page, @ViewBuilder panel: () -> Panel) {
        self.kind = kind
        self.isOpen = isOpen
        self.defaultWidth = defaultWidth
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
        self.pageMinimum = pageMinimum
        self.page = page()
        self.panel = panel()
        _stored = AppStorage(wrappedValue: 0, PaneSizing.widthKey(kind))
    }

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = isOpen ? width(in: proxy.size.width) : 0
            let pageWidth = max(pageMinimum, proxy.size.width - (isOpen ? panelWidth + 1 : 0))
            HStack(spacing: 0) {
                // The page keeps its minimum width and scrolls sideways inside its own box when the
                // panel leaves it less (it never pushes the panel out of the window).
                ScrollView(.horizontal) {
                    page.frame(width: pageWidth, height: proxy.size.height, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if isOpen {
                    let width = panelWidth
                    PaneDivider(onDrag: { translation in
                        let start = dragStart ?? width
                        dragStart = start
                        live = clamped(PaneSizing.draggedPanelWidth(start: Double(start), translation: Double(translation)), in: proxy.size.width)
                    }, onEnd: {
                        if let live { stored = Double(live) }
                        dragStart = nil
                        live = nil
                    })
                    panel
                        .frame(width: width)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
        }
        // The window grows to what the page and panel need at least.
        .frame(minWidth: pageMinimum + (isOpen ? minimumWidth + 1 : 0))
    }

    private func width(in available: CGFloat) -> CGFloat {
        if let live { return live }
        return clamped(stored, in: available)
    }

    private func clamped(_ wanted: Double, in available: CGFloat) -> CGFloat {
        // At most 55% of the area (the page keeps the other 45% and lays out narrower).
        CGFloat(PaneSizing.panelWidth(stored: wanted, defaultWidth: Double(defaultWidth), minimum: Double(minimumWidth),
                                      maximum: Double(maximumWidth), available: Double(available), pageMinimum: Double(available) * 0.45))
    }
}

/// Two columns side by side with a draggable divider between them; the leading column's share is
/// remembered per `kind` on this Mac. Each column keeps its minimum width.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    let kind: String
    var defaultFraction: Double = 0.42
    var leadingMinimum: CGFloat = 380
    var trailingMinimum: CGFloat = 400
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @AppStorage private var stored: Double
    @State private var dragStart: CGFloat?
    @State private var live: CGFloat?

    init(kind: String, defaultFraction: Double = 0.42, leadingMinimum: CGFloat = 380, trailingMinimum: CGFloat = 400,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.kind = kind
        self.defaultFraction = defaultFraction
        self.leadingMinimum = leadingMinimum
        self.trailingMinimum = trailingMinimum
        self.leading = leading()
        self.trailing = trailing()
        _stored = AppStorage(wrappedValue: 0, PaneSizing.splitKey(kind))
    }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let leadingWidth = live ?? held(CGFloat(stored > 0 ? stored : defaultFraction) * total, total)
            HStack(spacing: 0) {
                leading.frame(width: leadingWidth).frame(maxHeight: .infinity, alignment: .topLeading)
                PaneDivider(onDrag: { translation in
                    let start = dragStart ?? leadingWidth
                    dragStart = start
                    live = held(start + translation, total)
                }, onEnd: {
                    if let live { stored = PaneSizing.splitFraction(leadingWidth: Double(live), total: Double(total)) }
                    dragStart = nil
                    live = nil
                })
                trailing.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func held(_ wanted: CGFloat, _ total: CGFloat) -> CGFloat {
        CGFloat(PaneSizing.splitLeadingWidth(fraction: total > 0 ? Double(wanted / total) : 0, total: Double(total),
                                             leadingMinimum: Double(leadingMinimum), trailingMinimum: Double(trailingMinimum)))
    }
}
