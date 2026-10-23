// App/Auth/LockCoveredToolbar.swift
import SwiftUI

// The main window keeps its toolbar while the lock screen covers it (hiding a window's toolbar changes the
// window's frame), so what's in the toolbar has to hide itself. Every screen's toolbar items and search
// field go through these; `LockCoverToolbarTests` fails on a `.toolbar {` or `.searchable(` in App/ that
// doesn't.

extension View {
    /// A toolbar item under the lock screen: keeps its place (so the toolbar, and the window, keep their
    /// size) but can't be seen, clicked, focused or read out. For the window's own items (ContentView),
    /// which keep the toolbar from emptying.
    func lockCoverHidden(_ covered: Bool) -> some View {
        opacity(covered ? 0 : 1)
            .disabled(covered)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
    }

    /// A screen's window toolbar items. While the lock screen covers the window they're gone: nothing to
    /// see, click, tab to or trigger by shortcut. The window's own items stay, so the toolbar keeps its size.
    func screenToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(ScreenToolbar(items: items()))
    }

    /// A screen's search field. While covered it shows nothing typed and takes no clicks, focus or typing;
    /// `text` itself isn't touched, so the search is back on unlock. The field isn't removed: that would
    /// rebuild the screen under it and lose its open sheets and scroll position.
    func screenSearchable(text: Binding<String>, prompt: String) -> some View {
        modifier(ScreenSearchable(text: text, prompt: prompt))
    }
}

private struct ScreenToolbar<Items: ToolbarContent>: ViewModifier {
    @Environment(\.isLockCovered) private var covered
    let items: Items

    func body(content: Content) -> some View {
        content.toolbar { // lock-cover: the screens' items, gone while covered
            if !covered { items }
        }
    }
}

private struct ScreenSearchable: ViewModifier {
    @Environment(\.isLockCovered) private var covered
    let text: Binding<String>
    let prompt: String

    func body(content: Content) -> some View {
        content
            .searchable(text: covered ? .constant("") : text, prompt: Text(covered ? "" : prompt)) // lock-cover: cleared and disabled while covered
            .disabled(covered)
    }
}
