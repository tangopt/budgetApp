import SwiftUI
import BudgetCore

/// A widget's tile as the home screen draws it: the family's size, WidgetKit's 16-pt content margins, the tertiary
/// fill (the extension's `containerBackground`). Used by the snapshot harness only.
struct WidgetTile<Content: View>: View {
    let size: MangoWidgetSize
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(width: size.tileSize.width, height: size.tileSize.height, alignment: .topLeading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22))
    }
}

/// Month spend in every family (the snapshot harness's `widgets-month-spend` route): `figures` (the demo's own) in the
/// small, medium and large tiles, and the same month ahead of its pace beside the small one.
public struct MonthSpendFamiliesPreview: View {
    let figures: MonthSpendFigures

    public init(figures: MonthSpendFigures) {
        self.figures = figures
    }

    /// The same month with spending ahead of the pace and two categories over budget.
    static func ahead(of figures: MonthSpendFigures) -> MonthSpendFigures {
        var ahead = figures
        let budget = max(figures.budgetMinorUnits, 100_000)
        ahead.budgetMinorUnits = budget
        let target = MonthSpendFigures.expected(budget: budget, day: figures.dayOfMonth, daysInMonth: figures.daysInMonth) * 13 / 10
        let days = max(figures.dayOfMonth, 1)
        ahead.cumulativeSpent = (1...days).map { target * $0 / days }
        ahead.spentMinorUnits = ahead.cumulativeSpent.last ?? 0
        ahead.overBudget = [
            .init(name: "Eating out", spentMinorUnits: 61_850, budgetMinorUnits: 40_000),
            .init(name: "Shopping", spentMinorUnits: 128_400, budgetMinorUnits: 110_000),
            .init(name: "Subscriptions and memberships", spentMinorUnits: 9_999, budgetMinorUnits: 8_000),
        ]
        return ahead
    }

    public var body: some View {
        let ahead = Self.ahead(of: figures)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                WidgetTile(size: .small) { MonthSpendWidgetView(figures: figures, size: .small, redacted: false) }
                WidgetTile(size: .small) { MonthSpendWidgetView(figures: ahead, size: .small, redacted: false) }
            }
            WidgetTile(size: .medium) { MonthSpendWidgetView(figures: figures, size: .medium, redacted: false) }
            WidgetTile(size: .large) { MonthSpendWidgetView(figures: ahead, size: .large, redacted: false) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Property month in its families (the `widgets-property-month` route): a month part way through, and one done.
public struct PropertyMonthFamiliesPreview: View {
    let figures: RechargePipelineFigures

    public init(figures: RechargePipelineFigures) {
        self.figures = figures
    }

    /// The pipeline finished: every bill in, the statement sent, the tenant paid.
    static func finished(_ figures: RechargePipelineFigures) -> RechargePipelineFigures {
        RechargePipelineFigures(tenancyName: figures.tenancyName, month: figures.month,
                                utilities: figures.utilities.map { .init(name: $0.name, kind: $0.kind, isIn: true) },
                                statementSent: true, paidByTenant: true, outstandingMinorUnits: 0, currencyCode: figures.currencyCode)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                WidgetTile(size: .small) { PropertyMonthWidgetView(figures: figures, size: .small, redacted: false) }
                WidgetTile(size: .small) { PropertyMonthWidgetView(figures: Self.finished(figures), size: .small, redacted: false) }
            }
            WidgetTile(size: .medium) { PropertyMonthWidgetView(figures: figures, size: .medium, redacted: false) }
            WidgetTile(size: .medium) { PropertyMonthWidgetView(figures: Self.finished(figures), size: .medium, redacted: false) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
