// App/Snapshots/SnapshotCapture.swift
#if SNAPSHOTS
import SwiftUI
import AppKit
import QuartzCore
import PDFKit

/// The harness's window: titled like the app's (title bar, toolbar, sidebar), placed far off
/// every screen, never key or main, so nothing shows and no focus moves. It reports key and
/// main appearance so controls draw as in the frontmost window.
final class SnapshotWindow: NSWindow {
    /// The window's size (`--size`; 1440×900 by default).
    static var size = NSSize(width: 1440, height: 900)

    static func make() -> SnapshotWindow {
        let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        window.hidesOnDeactivate = false
        window.titlebarAppearsTransparent = false
        window.setFrame(NSRect(origin: offscreenOrigin, size: size), display: false)
        // Ordered in (off-screen) so AppKit-backed controls lay out and draw as they do on screen.
        window.orderFrontRegardless()
        return window
    }

    /// Well beyond the left and bottom of every screen.
    static var offscreenOrigin: NSPoint {
        let frames = NSScreen.screens.map(\.frame)
        let minX = frames.map(\.minX).min() ?? 0
        let minY = frames.map(\.minY).min() ?? 0
        return NSPoint(x: minX - size.width - 6_000, y: minY - size.height - 6_000)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    // AppKit's own checks for drawing a window's controls as active.
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }
    @objc func hasMainAppearance() -> Bool { true }

    /// Shows `view` filling the window. Like the app's window (SwiftUI's `minSize` sizing),
    /// the window is never smaller than the view's minimum: on a screen that needs more than
    /// `--size`, it grows to the screen's minimum, as the app's window does on that screen.
    func mount<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.minSize]
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        contentView = hosting
        setFrame(NSRect(origin: Self.offscreenOrigin, size: Self.size), display: false)
    }

    /// The content's size now (the window may have grown to the content's minimum).
    var contentLayoutSize: CGSize {
        contentView?.bounds.size ?? Self.size
    }

    func unmount() {
        contentView = NSView(frame: NSRect(origin: .zero, size: Self.size))
        title = ""
    }

    func setAppearance(_ name: NSAppearance.Name) {
        let appearance = NSAppearance(named: name)
        NSApp.appearance = appearance
        self.appearance = appearance
    }
}

/// Draws the window into a PNG. `cacheDisplay` draws views, not the window server's
/// compositing, so it misses Liquid Glass and vibrancy: the sidebar's glass pane is drawn
/// separately on a sidebar-coloured fill, vibrancy filters (which would come out black or
/// blank) are dropped, and the scroll edges' blur is hidden.
@MainActor
enum SnapshotCapture {
    static func png(of window: NSWindow, scale: CGFloat) -> Data? {
        guard let frameView = window.contentView?.superview else { return nil }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        hidePockets(frameView)
        if let layer = frameView.layer { stripVibrancy(layer, isDark: isDark(window)) }
        replaceRowSelections(frameView, isDark: isDark(window))
        frameView.displayIfNeeded()

        let size = frameView.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        let dark = isDark(window)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (window.appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        frameView.cacheDisplay(in: frameView.bounds, to: rep)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The sidebar's glass pane.
        for glass in views(in: frameView, className: "NSGlassEffectView") where glass.bounds.width >= 120 && glass.bounds.height >= 200 {
            let rect = glass.convert(glass.bounds, to: frameView)
            sidebarFill(dark: dark).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
            let holder = glass.subviews.first { className($0) == "ContentHolderView" }
            if ProcessInfo.processInfo.environment["SNAPSHOT_DEBUG"] == "1", let layer = holder?.layer { debugDump(layer) }
            for view in holder?.subviews ?? [] {
                draw(view, into: frameView)
            }
        }
        // PDF pages draw in tiles that a view capture misses: draw the visible pages directly.
        for case let pdfView as PDFView in allViews(in: frameView) {
            drawPages(of: pdfView, into: frameView, context: context.cgContext)
        }
        // The traffic lights sit above the sidebar.
        for name in ["_NSThemeCloseWidget", "_NSThemeWidget", "_NSThemeZoomWidget"] {
            for view in views(in: frameView, className: name) { draw(view, into: frameView) }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func debugDump(_ layer: CALayer, depth: Int = 0) {
        guard depth < 16 else { return }
        let line = String(repeating: "  ", count: depth) + "\(type(of: layer)) \(layer.name ?? "-") \(NSStringFromRect(layer.frame)) bg=\(layer.backgroundColor.map { "\($0)" } ?? "nil") contents=\(layer.contents != nil) filters=\(layer.filters?.map { "\($0)" } ?? []) comp=\(layer.compositingFilter.map { "\($0)" } ?? "nil") mask=\(layer.mask != nil) hidden=\(layer.isHidden) op=\(layer.opacity)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        layer.sublayers?.forEach { debugDump($0, depth: depth + 1) }
    }

    private static func isDark(_ window: NSWindow) -> Bool {
        (window.appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The sidebar material's usual tone.
    private static func sidebarFill(dark: Bool) -> NSColor {
        dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    }

    private static func draw(_ view: NSView, into root: NSView) {
        guard !view.isHidden, view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let rect = view.convert(view.bounds, to: root)
        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func drawPages(of pdfView: PDFView, into root: NSView, context: CGContext) {
        let visible = pdfView.convert(pdfView.bounds, to: root)
        context.saveGState()
        context.clip(to: visible)
        for page in pdfView.visiblePages {
            let box = page.bounds(for: pdfView.displayBox)
            let rect = pdfView.convert(pdfView.convert(box, from: page), to: root)
            guard rect.width > 0, rect.height > 0 else { continue }
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: pdfView.displayBox, to: context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func className(_ view: NSView) -> String { String(describing: type(of: view)) }

    private static func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews)
    }

    private static func views(in root: NSView, className name: String) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if className(view) == name { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// A list row's selection is a vibrant material view, which draws black off screen: hide
    /// it and put a plain rounded fill in its place — neutral in the sidebar, the accent
    /// (selected-content) colour elsewhere.
    private static func replaceRowSelections(_ root: NSView, isDark: Bool) {
        let sidebars = views(in: root, className: "NSGlassEffectView").filter { $0.bounds.width >= 120 && $0.bounds.height >= 200 }
        for effect in views(in: root, className: "NSVisualEffectView") {
            guard let row = effect.superview, className(row).contains("RowView"), let rowLayer = row.layer else { continue }
            let inSidebar = sidebars.contains { effect.isDescendant(of: $0) }
            let name = "snapshotSelection"
            var fill = rowLayer.sublayers?.first { $0.name == name }
            if fill == nil {
                // Only a visible selection gets a fill (hidden ones are unselected rows).
                guard !effect.isHidden else { continue }
                let layer = CALayer()
                layer.name = name
                rowLayer.insertSublayer(layer, at: 0)
                fill = layer
            }
            guard let fill else { continue }
            if !effect.isHidden {
                fill.frame = effect.frame
                fill.cornerRadius = min(8, effect.frame.height / 3)
                effect.isHidden = true
            }
            let color: NSColor = inSidebar
                ? (isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.1))
                : NSColor.selectedContentBackgroundColor
            var cgColor = color.cgColor
            (root.window?.appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance { cgColor = color.cgColor }
            fill.backgroundColor = cgColor
        }
    }

    /// The blurred scroll edges (drawn as solid colour blocks off screen).
    private static func hidePockets(_ root: NSView) {
        for pocket in views(in: root, className: "NSScrollPocket") { pocket.isHidden = true }
    }

    /// Vibrancy draws through filters only the window server applies: drop them so text and
    /// icons draw in their own colours, and give vibrant fills (the sidebar's selection) a
    /// plain translucent tone instead of black.
    private static func stripVibrancy(_ layer: CALayer, isDark: Bool) {
        if let filters = layer.filters, filters.contains(where: { "\($0)".localizedCaseInsensitiveContains("vibrant") }) {
            layer.filters = filters.filter { !"\($0)".localizedCaseInsensitiveContains("vibrant") }
        }
        if let filter = layer.compositingFilter {
            let name = "\(filter)"
            if name.localizedCaseInsensitiveContains("vibrant") || name == "plusD" || name == "plusL" {
                layer.compositingFilter = nil
                if layer.backgroundColor != nil, layer.contents == nil {
                    layer.backgroundColor = (isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.09)).cgColor
                }
            }
        }
        layer.sublayers?.forEach { stripVibrancy($0, isDark: isDark) }
    }
}

/// `index.html`: every route, a row of its captures per appearance and theme.
enum SnapshotIndex {
    static func html(_ routes: [(name: String, title: String, files: [String])], appearances: [String], themes: [String]) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var rows = ""
        for route in routes {
            rows += "<section id=\"\(route.name)\"><h2>\(escape(route.title)) <code>\(route.name)</code></h2><div class=\"grid\">"
            for file in route.files {
                rows += "<figure><a href=\"\(file)\"><img loading=\"lazy\" src=\"\(file)\" alt=\"\(file)\"></a><figcaption>\(file)</figcaption></figure>"
            }
            rows += "</div></section>\n"
        }
        let toc = routes.map { "<a href=\"#\($0.name)\">\(escape($0.title))</a>" }.joined(separator: " · ")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Budget UI snapshots</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, system-ui, sans-serif; margin: 24px; background: Canvas; color: CanvasText; }
        h1 { font-size: 20px; } h2 { font-size: 15px; margin-top: 28px; } code { color: GrayText; font-weight: normal; }
        nav { line-height: 1.8; }
        .grid { display: grid; grid-template-columns: repeat(\(max(1, themes.count)), 1fr); gap: 12px; }
        figure { margin: 0; } img { width: 100%; border: 1px solid #8884; border-radius: 6px; }
        figcaption { color: GrayText; font-size: 11px; margin-top: 2px; }
        </style></head><body>
        <h1>Budget UI snapshots</h1>
        <p>Demo database only. Appearances: \(appearances.joined(separator: ", ")); themes: \(themes.joined(separator: ", ")).</p>
        <nav>\(toc)</nav>
        \(rows)
        </body></html>
        """
    }
}
#endif
