// App/DesignSystem/WindowReader.swift
import SwiftUI
import AppKit

/// Reports the window a view is in (and again when it moves to another), for code outside
/// the view that must bring that window forward.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// A window held weakly (ContentView's own, from `WindowReader`).
@MainActor
final class WindowHolder {
    weak var window: NSWindow?
}
