// App/DesignSystem/CategoryBadge.swift
import SwiftUI
import AppKit
import BudgetCore
import struct BudgetCore.Category

/// A small colored circle keyed by category type (expense red, income green, transfer
/// blue), sized small/medium/large, with an optional white SF Symbol inside. Categories use
/// `init(category:size:)`, which shows the category's own icon or its type's generic one.
struct CategoryBadge: View {
    enum Size {
        case small, medium, large

        var diameter: CGFloat {
            switch self {
            case .small: return 14
            case .medium: return 18
            case .large: return 28
            }
        }
    }

    let type: CategoryType
    var size: Size = .medium
    var systemImage: String? = nil

    private var color: Color {
        switch type {
        case .expense: return .red
        case .income: return .green
        case .transfer: return .blue
        case .adjustment: return .gray
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.85))
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size.diameter * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .accessibilityHidden(true)
    }
}

extension CategoryBadge {
    /// The category's badge: its chosen icon, else its type's generic symbol.
    init(category: Category, size: Size = .medium) {
        self.init(type: category.type, size: size, systemImage: category.badgeSymbol)
    }
}

extension CategoryType {
    /// The generic icon for a category of this type — every category's default icon.
    var symbolName: String {
        switch self {
        case .expense: return "arrow.up.right"
        case .income: return "arrow.down.left"
        case .transfer: return "arrow.left.arrow.right"
        case .adjustment: return "plusminus"
        }
    }
}

extension Category {
    /// The symbol its badge shows: the chosen icon when this macOS has it, else the type's.
    @MainActor var badgeSymbol: String {
        if let iconName, CategorySymbolAvailability.exists(iconName) { return iconName }
        return isReserved ? "tray" : type.symbolName
    }
}

/// Remembers which SF Symbol names this macOS can draw, so a stored icon missing from the
/// system falls back to the type's symbol instead of an empty circle.
@MainActor
enum CategorySymbolAvailability {
    private static var cache: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        if let known = cache[name] { return known }
        let found = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        cache[name] = found
        return found
    }

    /// The curated themes, minus any symbol this macOS lacks (and themes left empty).
    static func availableThemes(_ themes: [CategoryIconTheme]) -> [CategoryIconTheme] {
        themes.compactMap { theme in
            let icons = theme.icons.filter { exists($0.symbol) }
            return icons.isEmpty ? nil : CategoryIconTheme(title: theme.title, icons: icons)
        }
    }
}
