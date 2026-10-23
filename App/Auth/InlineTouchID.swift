// App/Auth/InlineTouchID.swift
import SwiftUI
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import BudgetCore

/// One Touch ID try in Mango's own window: an `LAContext` paired with an `LAAuthenticationView`
/// (LocalAuthenticationEmbeddedUI). Once the view is made with this context, `evaluatePolicy` and
/// `evaluateAccessControl` on it show their UI in that view instead of the system's panel (the framework's
/// header). A context is used for one try: "Use password" invalidates it (`LAError.appCancel`).
@MainActor
final class InlineTouchIDPrompt: BiometricPromptContext {
    let context = LAContext()
    private var isPaired = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init() {
        // No "Use Password…" from the system: Mango has its own.
        context.localizedFallbackTitle = ""
    }

    /// The embedded view exists and is in a window: only then may the context be evaluated, or the system's
    /// panel would show instead.
    fileprivate func paired() {
        isPaired = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: true) }
    }

    /// Waits for the lock screen to put the view on screen. False if it never does (the screen went):
    /// the try doesn't start at all.
    func waitUntilPaired(timeout: Duration = .seconds(2)) async -> Bool {
        if isPaired { return true }
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.expire()
        }
        defer { expiry.cancel() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func expire() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: isPaired) }
    }

    /// "Use password", another person picked, the lock screen gone: the try ends as a cancel.
    func cancel() {
        context.invalidate()
        expire()
    }
}

/// The Touch ID glyph that listens for a finger, in the lock screen. The snapshot build draws a stand-in
/// (the embedded view can render blank off screen, and the snapshots never ask this Mac for Touch ID).
struct InlineTouchIDView: View {
    let prompt: InlineTouchIDPrompt
    @Environment(\.theme) private var theme

    var body: some View {
        #if SNAPSHOTS
        Image(systemName: "touchid")
            .font(.system(size: 30))
            .foregroundStyle(theme.accent)
            .frame(width: 44, height: 44)
            .accessibilityLabel(TouchIDInlineText.listening)
        #else
        EmbeddedTouchID(prompt: prompt)
            .frame(width: 44, height: 44)
            .accessibilityLabel(TouchIDInlineText.listening)
        #endif
    }
}

/// `LAAuthenticationView` in a container that says when it reaches a window (`InlineTouchIDPrompt.paired`).
private struct EmbeddedTouchID: NSViewRepresentable {
    let prompt: InlineTouchIDPrompt

    func makeNSView(context: Context) -> PairingContainer {
        PairingContainer(prompt: prompt)
    }

    func updateNSView(_ nsView: PairingContainer, context: Context) {}
}

private final class PairingContainer: NSView {
    private let prompt: InlineTouchIDPrompt

    init(prompt: InlineTouchIDPrompt) {
        self.prompt = prompt
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        let touchID = LAAuthenticationView(context: prompt.context, controlSize: .large)
        touchID.translatesAutoresizingMaskIntoConstraints = false
        addSubview(touchID)
        NSLayoutConstraint.activate([
            touchID.centerXAnchor.constraint(equalTo: centerXAnchor),
            touchID.centerYAnchor.constraint(equalTo: centerYAnchor),
            touchID.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            touchID.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { prompt.paired() }
    }
}
