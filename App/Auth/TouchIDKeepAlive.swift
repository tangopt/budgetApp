// App/Auth/TouchIDKeepAlive.swift
import AppKit

/// Keeps Mango's window compositing while the inline Touch ID listens, so Touch ID isn't paused every second.
///
/// The glyph's occlusion check (AppKit's occlusion-detection view inside `LAAuthenticationView`) asks the
/// WindowServer whether its region is covered. Once the window has composited no new frame for about a second,
/// the WindowServer reports the region occluded (reason 2) until the next frame; `LAAuthenticationView` then
/// pauses Touch ID (the Touch Bar prompt blinks) and dims its glyph, and that redraw clears it again — every
/// second while the lock screen sits still.
///
/// This 2×2 pt view, in a corner of the glyph's square and outside the glyph's own frame, runs a render-server
/// animation that steps its layer's opacity between 0 and 0.0001 every half second: a new frame each step,
/// nothing visible, no work in the app. The check itself is untouched: anything really covering the glyph is
/// still reported within a frame. It's on screen (not hidden) only while a try listens, takes no clicks and
/// isn't an accessibility element.
final class TouchIDKeepAlive: NSView {
    static let side: CGFloat = 2
    /// Under a second, so a frame always lands inside the WindowServer's one-second window.
    static let period: CFTimeInterval = 1.0
    private static let key = "touchIDKeepAlive"

    private(set) var isRunning = false
    private let onChange: (Bool, String) -> Void

    /// `onChange(running, why)`: started or stopped (for the diagnostic log).
    init(onChange: @escaping (Bool, String) -> Void = { _, _ in }) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.opacity = 0
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override var acceptsFirstResponder: Bool { false }

    /// The try is listening and the view is in a window.
    func start() {
        guard !isRunning, window != nil, let layer else { return }
        isRunning = true
        isHidden = false
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0.0001]
        animation.calculationMode = .discrete
        animation.duration = Self.period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.key)
        onChange(true, "listening")
    }

    func stop(_ why: String) {
        guard isRunning else { return }
        isRunning = false
        layer?.removeAnimation(forKey: Self.key)
        isHidden = true
        onChange(false, why)
    }
}
