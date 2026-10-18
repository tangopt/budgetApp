// App/DesignSystem/CopyValueButton.swift
import SwiftUI
import AppKit

/// A row's copy action (spec C8): one `doc.on.doc` icon that puts `text` on the clipboard and
/// turns into a tick for a moment, so the confirmation sits where the eye already is (no
/// banner pushing the page down while values are copied one after another). VoiceOver hears
/// "Copied …".
struct CopyValueButton: View {
    let text: String
    /// What's copied, for the tooltip and VoiceOver ("box 14, Total rents and other receipts").
    let name: String
    /// Copies; the clipboard by default.
    var copy: (String) -> Void = CopyValueButton.toPasteboard
    @State private var copied = false
    @State private var reset: Task<Void, Never>?
    @Environment(\.theme) private var theme

    static func toPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        Button {
            copy(text)
            AccessibilityNotification.Announcement("Copied \(text)").post()
            withAnimation(.snappy(duration: 0.15)) { copied = true }
            reset?.cancel()
            reset = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { copied = false }
            }
        } label: {
            // Both glyphs laid out, so the button keeps its size as it changes.
            ZStack {
                Image(systemName: "doc.on.doc").opacity(copied ? 0 : 1)
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(theme.income).opacity(copied ? 1 : 0)
            }
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied “\(text)”" : "Copy “\(text)”")
        .accessibilityLabel("Copy \(name)")
        .accessibilityValue(text)
        .onDisappear { reset?.cancel() }
    }
}
