// App/DesignSystem/CellSelection.swift
import SwiftUI

/// The grid cell whose side panel is open (spec §2): its key (row id + column) for the
/// outline, and what the panel shows.
///
/// Like `HorizontalScrollOffset`: held by the grid in a plain `@State`, observed only by each
/// cell's `SelectedCellOutline` and by `SidePanelHost`, so clicking another cell redraws the
/// outlines and the panel without re-running the whole grid `body`.
@MainActor
final class CellSelection<Target>: ObservableObject {
    @Published private(set) var key: String?
    @Published private(set) var target: Target?

    func select(key: String, target: Target) {
        self.key = key
        self.target = target
    }

    func clear() {
        key = nil
        target = nil
    }
}

/// A cell's selected state: a 2pt outline over a light fill (the theme's selection colours),
/// drawn only while `key` is the selected cell. Goes in an `.overlay`, so it never changes
/// the cell's size.
struct SelectedCellOutline<Target>: View {
    @ObservedObject var selection: CellSelection<Target>
    let key: String
    @Environment(\.theme) private var theme

    var body: some View {
        if selection.key == key {
            Rectangle()
                .fill(theme.selectionFill)
                .overlay(Rectangle().strokeBorder(theme.selectionOutline, lineWidth: 2))
                .allowsHitTesting(false)
        }
    }
}

/// Already-built `content` with the side panel beside it while something is selected: the
/// content narrows, the panel slides in from the trailing edge.
struct SidePanelHost<Target, Content: View, Panel: View>: View {
    @ObservedObject var selection: CellSelection<Target>
    /// The remembered width's name (the panel is resizable, `ResizableDock`).
    let kind: String
    let content: Content
    let panel: (Target) -> Panel

    init(selection: CellSelection<Target>, kind: String, @ViewBuilder content: () -> Content, @ViewBuilder panel: @escaping (Target) -> Panel) {
        self.selection = selection
        self.kind = kind
        self.content = content()
        self.panel = panel
    }

    var body: some View {
        ResizableDock(kind: kind, isOpen: selection.target != nil) {
            content
        } panel: {
            if let target = selection.target {
                panel(target)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: selection.target == nil)
    }
}

/// A cell's "has a note" marker (spec §3): a small accent triangle in its top-right corner.
struct NoteCornerMarker: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 6, y: 0))
            path.addLine(to: CGPoint(x: 6, y: 6))
            path.closeSubpath()
        }
        .fill(theme.noteMarker)
        .frame(width: 6, height: 6)
        .allowsHitTesting(false)
    }
}

extension View {
    /// `NoteCornerMarker` in the top-right corner when `hasNote`.
    func noteMarker(_ hasNote: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if hasNote { NoteCornerMarker() }
        }
    }
}

extension View {
    /// A selectable grid cell: `SelectedCellOutline` while `key` is selected, and the whole
    /// cell clickable (`action` decides whether to select it, add, or do nothing).
    func selectable<Target>(_ selection: CellSelection<Target>, key: String, action: @escaping () -> Void) -> some View {
        overlay(SelectedCellOutline(selection: selection, key: key))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
