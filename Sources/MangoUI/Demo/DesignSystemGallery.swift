import SwiftUI
import BudgetCore

/// Every design-system piece with long figures (route `gallery`): what the wrap probe checks before the screens
/// arrive. Synthetic values only.
struct DesignSystemGallery: View {
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Design system")
                    .font(.largeTitle.bold())
                InlineBanner(tone: .amber, text: "Offline · showing data from 09:41. Your 3 changes will sync when you're back online.")
                InlineBanner(tone: .neutral, text: "Waiting for the household key from iCloud Keychain")
                Card(title: "Figures") {
                    // Side by side, top-aligned so the labels line up when one figure shrinks; stacked at
                    // accessibility sizes, where two figures can't share the width.
                    let tiles = AmountRowLayout.stacks(at: dynamicTypeSize)
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                    tiles {
                        tile("Net worth") {
                            MoneyText(minorUnits: 123_456_789, currency: .gbp, role: .balance, fit: .shrink())
                                .font(.title2.weight(.semibold))
                        }
                        tile("Held") {
                            Text("1,234 days").figureText(.shrink()).font(.title2.weight(.semibold))
                        }
                    }
                }
                Card(title: "Money by role") {
                    VStack(spacing: 0) {
                        AmountRow(label: "Salary", secondary: "Income", amount: MoneyText(minorUnits: 123_456_789, currency: .gbp, role: .income))
                        Divider()
                        AmountRow(label: "Builder's invoice for the kitchen", secondary: "Expense · 8 Jan 2026",
                                  amount: MoneyText(minorUnits: 1_234_567, currency: .eur, role: .expense))
                        Divider()
                        AmountRow(label: "To savings", secondary: "Transfer",
                                  amount: MoneyText(minorUnits: -50_000, currency: .gbp, role: .transfer))
                        Divider()
                        AmountRow(label: "Deposit held", amount: MoneyText(minorUnits: 240_000, currency: .gbp, role: .neutral))
                        Divider()
                        AmountRow(label: "Credit card", secondary: "Owed",
                                  amount: MoneyText(minorUnits: -8_147, currency: .gbp, role: .balance))
                    }
                }
                Card(title: "Days and counts") {
                    VStack(spacing: 0) {
                        FigureRow(label: "Tenancy started") {
                            DateText(MonthRange.calendar.date(from: DateComponents(year: 2026, month: 1, day: 8)))
                        }
                        Divider()
                        FigureRow(label: "Next statement") { DateText(nil) }
                        Divider()
                        FigureRow(label: "Evidence found") { Text("3 of 5").figureText() }
                    }
                }
                Card {
                    EmptyState(symbol: "magnifyingglass", title: "No results",
                               message: "Nothing matches \u{201C}kitchen\u{201D} between 1 Aug 2025 and 31 Aug 2025.")
                }
            }
            .padding(16)
        }
        .background(theme.background)
    }

    private func tile<Figure: View>(_ label: String, @ViewBuilder figure: () -> Figure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            figure()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Route `gallery-fold`: a long figure below the first screen (852 pt), which only the full-height render reaches; the
/// harness fails if it isn't measured.
struct DesignSystemGalleryFold: View {
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Above the fold") {
                    AmountRow(label: "Opening balance", amount: MoneyText(minorUnits: 100_000, currency: .gbp, role: .balance))
                }
                Color.clear.frame(height: 900)
                Card(title: "Below the fold") {
                    AmountRow(label: "Largest balance", secondary: "Held since 8 Jan 2026",
                              amount: MoneyText(minorUnits: 987_654_321, currency: .eur, role: .balance))
                }
            }
            .padding(16)
        }
        .background(theme.background)
    }
}
