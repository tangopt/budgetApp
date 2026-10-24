import SwiftUI
import BudgetCore

/// Every design-system piece with long figures (route `gallery`): what the wrap probe checks before the screens
/// arrive. Synthetic values only.
struct DesignSystemGallery: View {
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Design system")
                    .font(.largeTitle.bold())
                InlineBanner(tone: .amber, text: "Offline · showing data from 09:41. Your 3 changes will sync when you're back online.")
                InlineBanner(tone: .neutral, text: "Waiting for the household key from iCloud Keychain")
                Card(title: "Figures") {
                    HStack(spacing: 12) {
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Tenancy started")
                            Spacer()
                            DateText(MonthRange.calendar.date(from: DateComponents(year: 2026, month: 1, day: 8)))
                        }
                        HStack {
                            Text("Next statement")
                            Spacer()
                            DateText(nil)
                        }
                        HStack {
                            Text("Evidence found")
                            Spacer()
                            Text("3 of 5").figureText()
                        }
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
