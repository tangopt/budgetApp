// App/DesignSystem/CategoryBadge.swift
import SwiftUI
import BudgetCore

/// A small colored circle keyed by category type, sized small/medium/large, with an
/// optional SF Symbol icon slot for a future per-category icon set (currently unused —
/// every call site passes `systemImage: nil`, so this is a data change later, not a
/// component rewrite).
struct CategoryBadge: View {
    enum Size {
        case small, medium, large

        var diameter: CGFloat {
            switch self {
            case .small: return 10
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
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.85))
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size.diameter * 0.5))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size.diameter, height: size.diameter)
    }
}
