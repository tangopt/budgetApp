// App/DesignSystem/PendingStyle.swift
import SwiftUI
import AppKit

extension Color {
    /// Expected (not yet confirmed) money: a darker amber in light mode so it reads on
    /// white, the system yellow in dark mode. Used with italic amounts, the clock /
    /// half-circle icons, the grid's caption, and "Unconfirmed" labels.
    static let pending = Color(nsColor: NSColor(name: "pendingAmount") { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]) {
        case .darkAqua?, .accessibilityHighContrastDarkAqua?:
            return .systemYellow
        default:
            return NSColor(srgbRed: 0.62, green: 0.40, blue: 0.0, alpha: 1)  // ~4.8:1 on white
        }
    })
}
