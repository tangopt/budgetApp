// App/Auth/IdleMonitor.swift
import AppKit

/// Calls `onIdle` once after `timeout` seconds without keyboard, mouse or scroll input, in this app or
/// anywhere on the Mac. Input only stamps a time; a slow timer compares it, so mouse moves cost nothing.
@MainActor
final class IdleMonitor {
    private let onIdle: @MainActor () -> Void
    private var timeout: TimeInterval?
    private var lastInput = Date()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var timer: Timer?

    private static let events: NSEvent.EventTypeMask = [
        .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .scrollWheel,
    ]

    init(onIdle: @escaping @MainActor () -> Void) {
        self.onIdle = onIdle
    }

    /// Starts watching with `timeout` seconds; nil (Never) stops watching.
    func start(timeout: TimeInterval?) {
        stop()
        guard let timeout else { return }
        self.timeout = timeout
        lastInput = Date()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.events) { [weak self] event in
            MainActor.assumeIsolated { self?.lastInput = Date() }
            return event
        }
        // Mouse events from other apps need no permission; key events from them aren't delivered without
        // Accessibility access, which is fine: the mouse moves too.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.events) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastInput = Date() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: min(15, timeout), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        timer?.invalidate()
        timer = nil
        timeout = nil
    }

    private func check() {
        guard let timeout, Date().timeIntervalSince(lastInput) >= timeout else { return }
        stop()
        onIdle()
    }
}
