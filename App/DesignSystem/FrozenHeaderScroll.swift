// App/DesignSystem/FrozenHeaderScroll.swift
import SwiftUI

/// The horizontal scroll offset a frozen header row mirrors (content minX in the body's
/// horizontal scroll view: 0 at rest, negative once scrolled right).
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
