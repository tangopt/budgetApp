import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// The top of a category's detail: spent / planned / left in the Month list's own figures.
struct MonthCategorySummary: View {
    let row: PayMonthReview.Row
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static func transactionsTitle(_ type: CategoryType) -> String {
        switch type {
        case .income: "Received"
        case .transfer, .adjustment: "Moved"
        case .expense: "Spent"
        }
    }

    var body: some View {
        let figures = CategorySummaryPresentation(row).figures
        Card {
            // Side by side when they fit; stacked at accessibility sizes or in a narrow panel.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: MangoSpacing.m) {
                    ForEach(figures) { figure in cell(figure); if figure.id != figures.last?.id { Spacer(minLength: 0) } }
                }
                VStack(alignment: .leading, spacing: MangoSpacing.s) {
                    ForEach(figures) { figure in cell(figure) }
                }
            }
        }
    }

    private func cell(_ figure: CategorySummaryPresentation.Figure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(figure.label).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Text(figure.text.figuresUnbroken)
                .foregroundStyle(figure.isOver ? theme.expense : Color.primary)
                .figureText()
                .mangoFont(.headline, figures: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the plan holds for the category in the month, by date: still planned, or done (a transaction covers it).
struct MonthPlannedList: View {
    let items: [PlannedCategoryItems.Item]
    let row: PayMonthReview.Row

    var body: some View {
        VStack(alignment: .leading, spacing: MangoSpacing.xs) {
            Text("Planned").mangoFont(.headline).accessibilityAddTraits(.isHeader)
            Card {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { MangoDivider() }
                    let amount = MonthTransactionsModel.amount(item.amountMinorUnits, type: row.category.type)
                    ListRow(item.note?.isEmpty == false ? item.note! : row.category.name, detail: PhoneDateFormat.day(item.date),
                            pill: item.isDone ? ("Done", .done) : ("Planned", .waiting),
                            trailing: { MoneyText(minorUnits: amount.minorUnits, currency: .gbp, role: amount.role) })
                        .opacity(item.isDone ? 0.7 : 1)
                }
            }
        }
    }
}
