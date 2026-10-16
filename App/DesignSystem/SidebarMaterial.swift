// App/DesignSystem/SidebarMaterial.swift
import SwiftUI
import AppKit

/// The system sidebar material (behind-window vibrancy), drawn behind the sidebar List.
///
/// Since macOS 26 the split view's sidebar column is a Liquid Glass pane laid over the
/// window's content-background material, the same material the detail column sits on. In
/// dark mode the glass takes on that dark grey, so the sidebar came out the same colour as
/// the rest of the window. This material blends with what's behind the window instead, so the
/// sidebar stays distinct in both modes. It follows the effective appearance, which includes
/// the `NSApp.appearance` chosen in Settings ▸ Appearance (`AppAppearance`, applied by
/// `ThemedRoot`), and dims with the window's active state like a standard sidebar.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
