// App/Auth/RecoveryKeySheet.swift
import SwiftUI
import AppKit
import BudgetCore

/// "Your recovery key", shown once (auth spec §7): after setup, after adding someone, and after Regenerate
/// recovery key…. Only its hash is kept, so closing this is the last time it can be read.
struct RecoveryKeyContent: View {
    let key: String
    /// Whose key it is, when it isn't the person signed in ("Person B's recovery key").
    var ownerName: String? = nil
    let onSaved: () -> Void
    @State private var copied = false
    @Environment(\.theme) private var theme

    private var groups: [String] { RecoveryKey.formatted(key).split(separator: "-").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
            Text(ownerName.map { "\($0)'s recovery key" } ?? "Your recovery key")
                .font(.title3.weight(.semibold))
            Text("If you forget your password, this key lets you set a new one. Save it in your password manager: it's shown only once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Text(group)
                        .font(.system(.title3, design: .monospaced).weight(.medium))
                        .figureText()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent.opacity(0.10)))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recovery key \(RecoveryKey.formatted(key))")
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(RecoveryKey.formatted(key), forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer(minLength: 0)
                Button("I've saved it", action: onSaved)
                    .buttonStyle(.borderedProminent).prominentTint()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }
}

/// The recovery key as a sheet (Settings ▸ Sign-in): no Cancel, only "I've saved it".
struct RecoveryKeySheet: View {
    let key: String
    var ownerName: String? = nil
    let onSaved: () -> Void

    var body: some View {
        RecoveryKeyContent(key: key, ownerName: ownerName, onSaved: onSaved)
            .padding(SheetMetrics.padding)
            .frame(width: SheetMetrics.formWidth, alignment: .topLeading)
            .interactiveDismissDisabled()
    }
}
