// App/DesignSystem/GridRowLabels.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// The month grids' (Budget grid, Forecast scenario grid) shared row pieces: the label
/// column's cells, the type stripe colours, the Totals block's styling and the panel titles.

extension CategoryType {
    /// A grid row's leading stripe: income green, expenses red, transfers blue, adjustments grey.
    var gridStripeColor: Color {
        switch self {
        case .income: return .green
        case .expense: return .red
        case .transfer: return .blue
        case .adjustment: return .gray
        }
    }

    /// A section's name in a side panel title ("Expenses — Oct 2026").
    var gridSectionName: String {
        switch self {
        case .income: return "Income"
        case .expense: return "Expenses"
        case .transfer: return "Transfers"
        case .adjustment: return "Adjustments"
        }
    }
}

extension View {
    /// A label column cell's footprint and chrome: 220pt by 28pt with 8pt padding either side,
    /// the row's background, a bottom separator and a 3pt leading stripe.
    func gridRowLabel(background: Color, stripe: Color) -> some View {
        frame(width: 220, height: 28, alignment: .leading)
            .padding(.horizontal, 8)
            .background(background)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            .overlay(Rectangle().frame(width: 3).foregroundStyle(stripe), alignment: .leading)
    }
}

/// The alternating-shade background of a body row (category, account, reserve).
enum GridRowShade {
    static func background(_ shaded: Bool) -> Color { shaded ? Color.primary.opacity(0.07) : Color.clear }
}

/// A category row's label: its icon (`CategoryBadge`) and name, stripe in its type's colour.
/// A group's member is indented, its name secondary.
struct CategoryRowLabel: View {
    let category: Category
    let shaded: Bool
    var isGroupChild = false

    var body: some View {
        HStack(spacing: 6) {
            CategoryBadge(category: category, size: .medium)
            Text(category.name).foregroundStyle(isGroupChild ? Color.secondary : Color.primary).lineLimit(1)
        }
        .frame(width: isGroupChild ? 200 : 220, height: 28, alignment: .leading)
        .padding(.leading, isGroupChild ? 28 : 8).padding(.trailing, 8)
        .background(GridRowShade.background(shaded))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        .overlay(Rectangle().frame(width: 3).foregroundStyle(category.type.gridStripeColor), alignment: .leading)
    }
}

/// A Totals block row's label (Total in, Total out, Net), teal-striped, with its help.
struct TotalsRowLabel: View {
    let row: BudgetTotals.Row

    var body: some View {
        Text(row.title).fontWeight(row == .net ? .bold : .semibold)
            .gridRowLabel(background: row.gridBackground, stripe: .teal)
            .help(row.gridHelp)
    }
}

extension BudgetTotals.Row {
    /// The row's background, across the label, month, Year Total and multi-year cells: a teal
    /// tint that sets the block apart from the category rows' grey banding in light and dark
    /// mode (the system teal adapts to both); Net a shade stronger.
    var gridBackground: Color {
        Color.teal.opacity(self == .net ? 0.28 : 0.17)
    }

    var gridHelp: String {
        switch self {
        case .totalIn: return "Income, plus transfers in from outside the shown accounts"
        case .totalOut: return "Expenses and reserves, plus transfers out of the shown accounts"
        case .net: return "Total in plus Total out"
        }
    }
}

/// The grids' month labels, in UTC like the pay months' names.
enum GridMonthLabel {
    /// "October 2026" (or `format`).
    static func monthYear(year: Int, month: Int, format: String = "MMMM yyyy") -> String {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return "\(month)/\(year)" }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// "Oct 2026", for side panel titles.
    static func shortMonthYear(year: Int, month: Int) -> String {
        monthYear(year: year, month: month, format: "MMM yyyy")
    }
}
