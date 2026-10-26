// App/DesignSystem/SharingBadge.swift
import SwiftUI
import BudgetCore

/// The lock beside one of your own accounts shared below Everything (sharing spec §3 goal 6): "Shared as
/// balance only", one line, in the secondary style. Nothing at Everything.
struct SharingBadge: View {
    let level: SharingLevel

    var body: some View {
        if let text = SharingCopy.badge(level) {
            Label(text, systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(SharingCopy.badgeHelp)
        }
    }
}
