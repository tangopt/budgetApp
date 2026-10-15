// App/DesignSystem/AppearanceToggle.swift
import SwiftUI
import AppKit

/// The app's light/dark choice, remembered across launches. `system` follows macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    static let storageKey = "appAppearance"

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Applied app-wide (windows, sheets, popovers and menus alike); nil follows macOS.
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// System / Light / Dark, pinned at the bottom of the sidebar.
struct AppearanceToggle: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { option in
                Image(systemName: option.systemImage)
                    .help(option.title)
                    .accessibilityLabel(option.title)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .help("Appearance: System, Light or Dark")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { appearance.apply() }
        .onChange(of: appearance) { _, new in new.apply() }
    }
}
