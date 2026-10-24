import SwiftUI
import BudgetCore
import struct BudgetCore.Category
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A category's round badge, as the Mac's `CategoryBadge`: the type's money colour with the category's icon
/// (`CategoryIcons`) in white, or the type's generic symbol when it has none (or this system can't draw it).
struct CategoryBadge: View {
    let category: Category
    @Environment(\.phoneTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var scaled: CGFloat = 32
    /// Grows with the text, up to 44 pt, so the name and figures keep the row's width at accessibility sizes.
    private var diameter: CGFloat { min(scaled, 44) }

    var body: some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: Self.symbol(category))
                .font(.system(size: diameter * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch category.type {
        case .expense: theme.expense
        case .income: theme.income
        case .transfer: theme.transfer
        case .adjustment: theme.neutralMoney
        }
    }

    /// The category's chosen icon when the system has it, else its type's (the Mac's `badgeSymbol`).
    static func symbol(_ category: Category) -> String {
        if let icon = category.iconName, exists(icon) { return icon }
        if category.isReserved { return "tray" }
        return switch category.type {
        case .expense: "arrow.up.right"
        case .income: "arrow.down.left"
        case .transfer: "arrow.left.arrow.right"
        case .adjustment: "plusminus"
        }
    }

    private static func exists(_ symbol: String) -> Bool {
        #if canImport(UIKit)
        UIImage(systemName: symbol) != nil
        #else
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        #endif
    }
}

/// One category in a pay month (iPhone spec §3.3): badge, name, "actual / plan", a progress bar and "£x left" or
/// "£x over plan", the over-plan status in the expense colour. Side by side, "actual / plan" trails the name; at
/// accessibility sizes it goes under it (`FigureRow`).
struct CategoryRow: View {
    let row: PayMonthReview.Row
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let shown = CategoryRowPresentation(row)
        HStack(alignment: .top, spacing: 12) {
            CategoryBadge(category: row.category)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                FigureRow(label: row.category.name) {
                    if AmountRowLayout.stacks(at: dynamicTypeSize) {
                        // "actual / plan" is too wide for one line here: the plan goes under the actual.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shown.actualText).figureText()
                            if let plan = shown.planText {
                                Text(plan).foregroundStyle(.secondary).figureText()
                            }
                        }
                    } else {
                        Text(shown.amounts).figureText()
                    }
                }
                if let fraction = shown.fraction {
                    ProgressBar(fraction: fraction, color: barColor(shown))
                }
                if let status = shown.status {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(shown.isOverPlan ? theme.expense : Color.secondary)
                        .figureText(.shrink())
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.category.name)
        .accessibilityValue(shown.spoken)
        // Always inside Month's NavigationLink: say it opens the list.
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the transactions")
    }

    private func barColor(_ shown: CategoryRowPresentation) -> Color {
        if shown.isOverPlan { return theme.expense }
        return switch row.category.type {
        case .income: theme.income
        case .transfer: theme.transfer
        case .expense, .adjustment: theme.accent
        }
    }
}

/// A thin bar filled to `fraction` (0...1).
struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.secondary.opacity(0.15))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * fraction)
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
