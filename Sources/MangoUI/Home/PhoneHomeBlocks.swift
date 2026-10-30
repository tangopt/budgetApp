import SwiftUI
import BudgetCore

/// The iPhone Home's lead block (design review §2.3): Left to spend as the hero figure, what it is of and the days to
/// payday under it, and the pay month's bar. Pablo opens the phone to check the month, so this is the first thing.
struct LeftToSpendCard: View {
    let summary: HomeSummary

    var body: some View {
        Card {
            Text("Left to spend")
                .mangoFont(.footnote)
                .foregroundStyle(.secondary)
            MoneyText(minorUnits: summary.leftToSpendMinorUnits, currency: .gbp, role: .neutral, fit: .shrink(),
                      font: .figureXL)
            Text(HomeCopy.leftToSpendCaption(summary).figuresUnbroken)
                .mangoFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PayMonthBarView(summary: summary)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The two tiles under the hero (shared `Tile`): Net worth with its change since last month, and what is spent so far
/// this pay month. Each is a button to its tab. Side by side up to Large; above that, one under the other.
struct HomeTiles: View {
    let summary: HomeSummary
    let open: (PhoneTab) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = HomeCopy.tilesSideBySide(at: dynamicTypeSize)
            ? AnyLayout(HStackLayout(alignment: .top, spacing: MangoSpacing.tile))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: MangoSpacing.tile))
        layout {
            Tile("Net worth", action: { open(.accounts) }) {
                if let current = summary.netWorth.currentNetWorthMinorUnits {
                    MoneyText(minorUnits: current, currency: .gbp, role: .balance, fit: .shrink(), font: .figureL)
                } else {
                    Text("No balances yet").foregroundStyle(.secondary)
                }
            } caption: {
                if let caption = HomeCopy.netWorthTileCaption(summary.netWorth) {
                    Text(caption.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                }
            }
            Tile("Spent this pay month", action: { open(.month) }) {
                MoneyText(minorUnits: summary.month.expenses.actual, currency: .gbp, role: .expense, fit: .shrink(),
                          font: .figureL)
            } caption: {
                Text("of \(MoneyPresentation(minorUnits: summary.plannedSpendingMinorUnits, currency: .gbp, role: .neutral).text) planned"
                    .figuresUnbroken)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
