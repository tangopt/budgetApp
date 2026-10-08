// App/DesignSystem/FrozenHeaderScroll.swift
import SwiftUI

/// The horizontal scroll offset a frozen header row mirrors (minus the body scroll view's
/// `contentOffset.x`: 0 at rest, negative once scrolled right).
///
/// It lives in its own object, held by the grid in a plain `@State` (which does *not*
/// subscribe to `objectWillChange`), and is observed only by `HorizontalOffsetFollower`.
/// So a scroll frame invalidates just that follower — a dozen header labels — instead of
/// the whole grid `body` (every row, every cell, the plan look-ups), which is what happened
/// while the offset was a `@State CGFloat` on the grid view itself.
@MainActor
final class HorizontalScrollOffset: ObservableObject {
    @Published private(set) var x: CGFloat = 0

    func update(_ newValue: CGFloat) {
        if x != newValue { x = newValue }
    }
}

/// Shifts already-built `content` by the observed offset. The parent builds `content` once
/// per its own render; per scroll frame only this view's `body` re-runs.
struct HorizontalOffsetFollower<Content: View>: View {
    @ObservedObject var offset: HorizontalScrollOffset
    let content: Content

    init(offset: HorizontalScrollOffset, @ViewBuilder content: () -> Content) {
        self.offset = offset
        self.content = content()
    }

    var body: some View {
        content.offset(x: offset.x)
    }
}

/// The width the body's rows actually get inside the vertical scroll view, which the frozen
/// header (outside that scroll view) adopts so its right-pinned cells line up with the body's:
/// a legacy (always-visible) vertical scroller takes ~15pt from the body but not the header.
///
/// Like `HorizontalScrollOffset`: held in plain `@State`, observed only by
/// `BodyWidthFollower`, so a live window resize doesn't re-run the whole grid `body`.
@MainActor
final class GridBodyWidth: ObservableObject {
    @Published private(set) var width: CGFloat?

    func update(_ newValue: CGFloat) {
        if width != newValue { width = newValue }
    }
}

/// Gives already-built `content` (the frozen header row) the body's measured width, leading
/// aligned; unconstrained until the first measurement.
struct BodyWidthFollower<Content: View>: View {
    @ObservedObject var width: GridBodyWidth
    let content: Content

    init(width: GridBodyWidth, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        content.frame(width: width.width, alignment: .leading)
    }
}

/// The month grids' column footprints (Budget grid, Forecast scenario grid), shared by the
/// frozen header, the scrolling month cells and the pinned Year Total column so they line up.
enum GridMetrics {
    /// A value cell's frame width.
    static let cellWidth: CGFloat = 120
    /// A value cell's horizontal padding, either side.
    static let cellPadding: CGFloat = 8
    /// A column's full footprint: the cell's frame plus its padding either side.
    static let columnWidth: CGFloat = cellWidth + 2 * cellPadding
    /// The twelve month columns' full width (the most the month scroller ever takes).
    static let monthsWidth: CGFloat = 12 * columnWidth
}

extension View {
    /// A month column's trailing 1pt separator. Omitted after December: the pinned Year
    /// Total column draws its own leading separator, so the line isn't doubled there.
    func monthSeparator(_ month: Int) -> some View {
        overlay(Rectangle().frame(width: 1).foregroundStyle(.separator).opacity(month < 12 ? 1 : 0), alignment: .trailing)
    }
}
