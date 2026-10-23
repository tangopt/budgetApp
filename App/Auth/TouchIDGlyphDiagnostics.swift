// App/Auth/TouchIDGlyphDiagnostics.swift
import AppKit
import OSLog

/// Opt-in logging of what the inline Touch ID glyph (`LAAuthenticationView`) does while it listens, to find
/// out why it disappears for a moment. Off unless turned on:
///
///     defaults write ubberninja.mango auth.diagnoseTouchIDGlyph -bool YES
///     log stream --predicate 'subsystem == "com.personal.budget" && category == "TouchIDGlyph"' --level info
///
/// It only reads view state (never changes it, never touches the context, the Keychain or anything typed):
/// every change of `isHidden` and `alphaValue` of the view and of every view inside it, its subviews each
/// second, the framework's own occlusion verdict (read-only, when the private view answers), what the window
/// hit-tests at the glyph's centre, the layout passes per second, the window's occlusion state and key
/// state, and when the view moves to or from a window.
@MainActor
final class TouchIDGlyphDiagnostics {
    nonisolated static let defaultsKey = "auth.diagnoseTouchIDGlyph"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    nonisolated private static let log = Logger(subsystem: "com.personal.budget", category: "TouchIDGlyph")

    private weak var view: NSView?
    private let started = Date()
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var windowObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var layoutPasses = 0
    private var changesThisSecond = 0
    private var lastAncestors = ""

    init(watching view: NSView) {
        self.view = view
        Self.log.info("[\(self.stamp, privacy: .public)] watching \(String(describing: type(of: view)), privacy: .public)")
        watchTree()
    }

    private var stamp: String { String(format: "%.3f", Date().timeIntervalSince(started)) }

    func layoutPassed() { layoutPasses += 1 }

    func movedToWindow(_ window: NSWindow?) {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        timer?.invalidate()
        timer = nil
        guard let window else {
            Self.log.info("[\(self.stamp, privacy: .public)] viewDidMoveToWindow: none")
            return
        }
        Self.log.info("[\(self.stamp, privacy: .public)] viewDidMoveToWindow: \(Self.describe(window), privacy: .public)")
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                                          NSWindow.didResignKeyNotification]
        for name in names {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow else { return }
                    Self.log.info("[\(self.stamp, privacy: .public)] \(note.name.rawValue, privacy: .public): \(Self.describe(window), privacy: .public)")
                }
            })
        }
        watchTree()
        report()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.view != nil else { timer.invalidate(); return }
                self.watchTree()
                self.report()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// KVO on `isHidden` and `alphaValue` of the view and every view inside it (the framework adds its glyph
    /// views once a try starts, so this runs again each second).
    private func watchTree() {
        guard let view else { return }
        var seen: Set<ObjectIdentifier> = []
        var queue = [view]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let id = ObjectIdentifier(current)
            seen.insert(id)
            queue += current.subviews
            guard observations[id] == nil else { continue }
            let name = String(describing: type(of: current))
            let depth = Self.depth(of: current, under: view)
            Self.log.info("[\(self.stamp, privacy: .public)] now watching \(name, privacy: .public) (depth \(depth, privacy: .public)) hidden=\(current.isHidden, privacy: .public) alpha=\(current.alphaValue, privacy: .public) frame=\(NSStringFromRect(current.frame), privacy: .public)")
            observations[id] = [
                current.observe(\.isHidden, options: [.old, .new]) { [weak self] _, change in
                    let text = "\(name) isHidden \(change.oldValue.map(String.init(describing:)) ?? "?") → \(change.newValue.map(String.init(describing:)) ?? "?")"
                    Self.changed(text, self)
                },
                current.observe(\.alphaValue, options: [.old, .new]) { [weak self] _, change in
                    let text = "\(name) alphaValue \(change.oldValue.map { String(format: "%.2f", $0) } ?? "?") → \(change.newValue.map { String(format: "%.2f", $0) } ?? "?")"
                    Self.changed(text, self)
                },
            ]
        }
        for gone in Set(observations.keys).subtracting(seen) { observations[gone] = nil }
    }

    /// A KVO change: logged at once (from whatever thread made it), with the occlusion verdict when on main.
    nonisolated private static func changed(_ text: String, _ diagnostics: TouchIDGlyphDiagnostics?) {
        guard Thread.isMainThread else {
            log.info("[off-main] \(text, privacy: .public)")
            return
        }
        MainActor.assumeIsolated {
            guard let diagnostics else { return }
            diagnostics.changesThisSecond += 1
            log.info("[\(diagnostics.stamp, privacy: .public)] \(text, privacy: .public) | \(diagnostics.occlusion(), privacy: .public)")
        }
    }

    private func report() {
        guard let view else { return }
        let window = view.window
        let tree = Self.tree(view)
        let occlusion = occlusion()
        var hit = "no window"
        if let window, let content = window.contentView {
            let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let inContent = content.superview?.convert(centre, from: nil) ?? centre
            hit = content.hitTest(inContent).map { hitView in
                let mine = hitView === view || hitView.isDescendant(of: view) || view.isDescendant(of: hitView)
                return "\(String(describing: type(of: hitView)))\(mine ? "" : " (NOT the glyph or its container)")"
            } ?? "nothing"
        }
        let ancestors = Self.ancestors(of: view)
        if ancestors != lastAncestors {
            Self.log.info("[\(self.stamp, privacy: .public)] ancestors: \(ancestors, privacy: .public)")
            lastAncestors = ancestors
        }
        Self.log.info("[\(self.stamp, privacy: .public)] tick: layouts/s=\(self.layoutPasses, privacy: .public) kvoChanges/s=\(self.changesThisSecond, privacy: .public) window=\(window.map(Self.describe) ?? "none", privacy: .public) appActive=\(NSApp.isActive, privacy: .public) hitAtCentre=\(hit, privacy: .public) \(occlusion, privacy: .public) subviews=\(view.subviews.count, privacy: .public) tree=\(tree, privacy: .public)")
        layoutPasses = 0
        changesThisSecond = 0
    }

    /// The framework's occlusion-detection view, read-only and only through selectors it answers to.
    private func occlusion() -> String {
        guard let view else { return "occlusion=?" }
        let getter = NSSelectorFromString("occlusionDetectionView")
        guard view.responds(to: getter), let detector = view.value(forKey: "occlusionDetectionView") as? NSObject else {
            return "occlusion=none"
        }
        var parts: [String] = []
        for key in ["isOccluded", "occlusionReason"] where detector.responds(to: NSSelectorFromString(key)) {
            parts.append("\(key)=\(detector.value(forKey: key).map { String(describing: $0) } ?? "nil")")
        }
        return "occlusion[\(parts.joined(separator: " "))]"
    }

    private static func describe(_ window: NSWindow) -> String {
        let visible = window.occlusionState.contains(.visible)
        return "\(String(describing: type(of: window))) occlusionState=\(visible ? "visible" : "occluded") key=\(window.isKeyWindow) main=\(window.isMainWindow) alpha=\(String(format: "%.2f", window.alphaValue)) level=\(window.level.rawValue)"
    }

    private static func tree(_ view: NSView) -> String {
        func walk(_ v: NSView) -> String {
            var text = "\(String(describing: type(of: v)))(h=\(v.isHidden ? 1 : 0) a=\(String(format: "%.2f", v.alphaValue)) \(Int(v.frame.width))x\(Int(v.frame.height))"
            if let layer = v.layer, layer.opacity < 1 || layer.isHidden || layer.masksToBounds {
                text += " layer[op=\(String(format: "%.2f", layer.opacity)) h=\(layer.isHidden ? 1 : 0) mask=\(layer.masksToBounds ? 1 : 0)]"
            }
            if !v.subviews.isEmpty { text += " {" + v.subviews.map(walk).joined(separator: ", ") + "}" }
            return text + ")"
        }
        return walk(view)
    }

    /// Every ancestor that hides, fades or clips: the things the glyph's visibility check reacts to.
    private static func ancestors(of view: NSView) -> String {
        var notes: [String] = []
        var current = view.superview
        var depth = 1
        while let v = current {
            var flags: [String] = []
            if v.isHidden { flags.append("hidden") }
            if v.alphaValue < 1 { flags.append("alpha=\(String(format: "%.2f", v.alphaValue))") }
            if v.clipsToBounds { flags.append("clips") }
            if let layer = v.layer {
                if layer.masksToBounds { flags.append("masksToBounds") }
                if layer.opacity < 1 { flags.append("layerOpacity=\(String(format: "%.2f", layer.opacity))") }
                if layer.mask != nil { flags.append("layerMask") }
                if !(layer.filters ?? []).isEmpty || !(layer.backgroundFilters ?? []).isEmpty { flags.append("filters") }
            }
            if v is NSVisualEffectView { flags.append("visualEffect") }
            if !flags.isEmpty { notes.append("\(depth):\(String(describing: type(of: v)))[\(flags.joined(separator: ","))]") }
            current = v.superview
            depth += 1
        }
        return notes.isEmpty ? "none hide, fade or clip (\(depth - 1) levels)" : notes.joined(separator: " ")
    }

    private static func depth(of view: NSView, under root: NSView) -> Int {
        var depth = 0
        var current: NSView? = view
        while let v = current, v !== root { depth += 1; current = v.superview }
        return depth
    }
}
