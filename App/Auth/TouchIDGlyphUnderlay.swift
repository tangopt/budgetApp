// App/Auth/TouchIDGlyphUnderlay.swift
import AppKit

/// Hides the inline Touch ID glyph's once-a-second dip. While it listens, `LAAuthenticationView` re-checks
/// that it's visible about every second; for 20–40 ms of each check its glyph's `alphaValue` drops (to 0.5),
/// and the glyph flickers. Nothing covers it: it's the framework's own check (seen in the `TouchIDGlyph` log).
///
/// This puts a still copy of the glyph *behind* the live view, shown only during a dip. The copy is a
/// snapshot of the live view itself (`cacheDisplay`), taken only while it's steady (everything at full
/// opacity, nothing animating) and kept only once two snapshots in a row agree, so it's always the glyph's
/// current look, in the current appearance. During a dip its alpha is set so the two together draw exactly
/// what the live glyph draws at full opacity: for a live glyph at opacity k over a copy, a pixel of coverage a
/// needs the copy at a·(1−k)/(1−k·a).
///
/// It never shows when there's no fresh steady snapshot, while anything in the live view animates (a scan
/// answered, a finger not matched), when the dip ends, for a fade that lasts longer than a dip (the glyph
/// greyed out on purpose), or once the try is over. It only reads the live view through public AppKit
/// calls; the evaluation, the context and the framework's check are untouched. It takes no clicks and isn't an
/// accessibility element.
@MainActor
final class TouchIDGlyphUnderlay {
    /// The copy, behind the live view, the same frame.
    let view = UnderlayImageView()
    private weak var live: NSView?
    private let onChange: (Bool, String) -> Void
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var timer: Timer?
    /// The live view's look, confirmed by two snapshots in a row that agree; nil when it isn't steady.
    private var steady: NSBitmapImageRep?
    private var lastSnapshot: NSBitmapImageRep?
    /// The copy drawn for one dip opacity, so a dip doesn't redraw it.
    private var compensated: (opacity: CGFloat, image: NSImage)?

    /// The dip being covered (counted, so a late check knows it's still the same one) and whether it has
    /// lasted too long to be one.
    private var dip = 0
    private var inDip = false
    private var dimHeld = false
    /// The try is over: the framework fades the glyph on purpose then, and the copy never comes back.
    private var ended = false

    /// How often the snapshot is refreshed while the view is in a window.
    static let refreshInterval: TimeInterval = 0.1
    /// The framework's dip lasts 20–50 ms. A fade that lasts longer is meant (the glyph greyed out, the try
    /// over), so the copy goes and lets it show.
    static let longestDip: TimeInterval = 0.12

    /// `onChange(shown, why)`: the copy came up or went (for the diagnostic log).
    init(live: NSView, onChange: @escaping (Bool, String) -> Void = { _, _ in }) {
        self.live = live
        self.onChange = onChange
        view.isHidden = true
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    func movedToWindow(_ window: NSWindow?) {
        timer?.invalidate()
        timer = nil
        forget("left the window")
        guard window != nil, !ended else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.live != nil else { timer.invalidate(); return }
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// The try ended (answered or cancelled): the copy goes for good.
    func end() {
        ended = true
        timer?.invalidate()
        timer = nil
        forget("the try ended")
    }

    /// Light/dark changed: the old snapshot is the wrong colour until a new one is confirmed.
    func appearanceChanged() { forget("appearance changed") }

    // MARK: - Snapshots

    private func refresh() {
        watchTree()
        guard let live else { return }
        if Self.isAnimating(live) {
            forget("the glyph is animating")
            return
        }
        // During a dip the live view draws faded: no snapshot then, the last steady one stands.
        guard Self.opacity(of: live) >= 1 else { return }
        guard let snapshot = Self.snapshot(live), Self.hasInk(snapshot) else {
            forget("no snapshot")
            return
        }
        if let last = lastSnapshot, Self.same(last, snapshot) {
            if steady.map({ !Self.same($0, snapshot) }) ?? true {
                steady = snapshot
                compensated = nil
            }
        } else if steady != nil {
            forget("the glyph changed")
        }
        lastSnapshot = snapshot
    }

    private func forget(_ why: String) {
        steady = nil
        lastSnapshot = nil
        compensated = nil
        hide(why)
    }

    private static func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func same(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
              a.bitsPerPixel == b.bitsPerPixel, let da = a.bitmapData, let db = b.bitmapData else { return false }
        return memcmp(da, db, a.bytesPerRow * a.pixelsHigh) == 0
    }

    /// Something drawn (before Touch ID starts the view is empty).
    private static func hasInk(_ rep: NSBitmapImageRep) -> Bool {
        guard let cg = rep.cgImage, let pixels = premultipliedRGBA(cg) else { return false }
        defer { pixels.data.deallocate() }
        for i in 0..<(pixels.width * pixels.height) where pixels.data[i * 4 + 3] > 0 { return true }
        return false
    }

    // MARK: - The dip

    /// KVO on `isHidden` and `alphaValue` of the live view and everything in it (the framework adds its glyph
    /// once a try starts, so this runs again on every refresh).
    private func watchTree() {
        guard let live else { return }
        var seen: Set<ObjectIdentifier> = []
        var queue = [live]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let id = ObjectIdentifier(current)
            seen.insert(id)
            queue += current.subviews
            guard observations[id] == nil else { continue }
            observations[id] = [
                current.observe(\.alphaValue) { [weak self] _, _ in Self.onMain { self?.liveChanged() } },
                current.observe(\.isHidden) { [weak self] _, _ in Self.onMain { self?.liveChanged() } },
            ]
        }
        for gone in Set(observations.keys).subtracting(seen) { observations[gone] = nil }
    }

    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    /// The live glyph faded or came back: the copy follows in the same pass, so no frame shows the dip.
    private func liveChanged() {
        guard let live else { return }
        let opacity = Self.opacity(of: live)
        guard opacity < 1 else {
            inDip = false
            dimHeld = false
            hide("dip over")
            return
        }
        if !inDip {
            inDip = true
            dip += 1
            let thisDip = dip
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.longestDip) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.inDip, self.dip == thisDip else { return }
                    self.dimHeld = true
                    self.hide("faded longer than a dip")
                }
            }
        }
        guard !ended, !dimHeld else { return }
        guard let steady else {
            hide("dip, but no steady snapshot")
            return
        }
        guard !Self.isAnimating(live) else {
            forget("dip while the glyph animates")
            return
        }
        if compensated?.opacity != opacity {
            guard let image = Self.compensate(steady, liveOpacity: opacity, size: live.bounds.size) else {
                hide("couldn't draw the copy")
                return
            }
            compensated = (opacity, image)
        }
        view.image = compensated?.image
        if view.isHidden {
            view.isHidden = false
            onChange(true, String(format: "dip to %.2f", opacity))
        }
    }

    private func hide(_ why: String) {
        guard !view.isHidden else { return }
        view.isHidden = true
        onChange(false, why)
    }

    /// The live glyph's lowest effective opacity: each view's `alphaValue` (0 when hidden) times its
    /// ancestors' within the live view.
    private static func opacity(of live: NSView) -> CGFloat {
        func walk(_ view: NSView, _ above: CGFloat) -> CGFloat {
            let mine = above * (view.isHidden ? 0 : view.alphaValue)
            return view.subviews.map { walk($0, mine) }.min() ?? mine
        }
        return walk(live, 1)
    }

    private static func isAnimating(_ live: NSView) -> Bool {
        func animating(_ layer: CALayer) -> Bool {
            !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains(where: animating)
        }
        return live.layer.map(animating) ?? false
    }

    /// The steady snapshot with each pixel's coverage a (and its premultiplied colour) scaled to
    /// a·(1−k)/(1−k·a), so the live glyph at opacity k over it adds up to the glyph at full opacity.
    private static func compensate(_ rep: NSBitmapImageRep, liveOpacity k: CGFloat, size: NSSize) -> NSImage? {
        guard let cg = rep.cgImage, let pixels = premultipliedRGBA(cg) else { return nil }
        defer { pixels.data.deallocate() }
        let data = pixels.data
        for i in 0..<(pixels.width * pixels.height) {
            let a = CGFloat(data[i * 4 + 3]) / 255
            guard a > 0 else { continue }
            let factor = k <= 0 ? 1 : (1 - k) / (1 - k * a)
            for j in 0..<4 { data[i * 4 + j] = UInt8(min(255, (CGFloat(data[i * 4 + j]) * factor).rounded())) }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: data, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                                      bytesPerRow: pixels.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    /// The image's pixels as premultiplied sRGB RGBA bytes (the caller deallocates `data`).
    private static func premultipliedRGBA(_ image: CGImage) -> (data: UnsafeMutablePointer<UInt8>, width: Int, height: Int)? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        data.initialize(repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            data.deallocate()
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height)
    }
}

/// The copy: drawn only, never clicked, never read out.
final class UnderlayImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
