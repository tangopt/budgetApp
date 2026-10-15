// App/DesignSystem/PendingStyle.swift
import SwiftUI
import AppKit

extension Color {
    /// Expected (not yet confirmed) money: a darker amber in light mode so it reads on
    /// white, the system yellow in dark mode. Used with italic amounts, the full-circle /
    /// half-circle icons, the Show forecast control, and "Unconfirmed" labels.
    static let pending = Color(nsColor: NSColor(name: "pendingAmount") { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]) {
        case .darkAqua?, .accessibilityHighContrastDarkAqua?:
            return .systemYellow
        default:
            return NSColor(srgbRed: 0.72, green: 0.48, blue: 0.0, alpha: 1)  // a brighter amber, still legible on plain and shaded rows
        }
    })
}
