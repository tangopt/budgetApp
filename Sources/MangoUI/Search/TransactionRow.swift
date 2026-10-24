import SwiftUI
import BudgetCore

/// How a search result reads (iPhone spec §3.4): the description, "account · category" ("Uncategorised" when it has
/// none) and its amount, in the account's currency, with the sign it was stored with. A transfer is drawn in the
/// transfer colour, an adjustment neutral, everything else by its sign (money in green, money out in the expense
/// colour).
public struct TransactionRowPresentation {
    public let description: String
    public let secondary: String
    public let isUncategorised: Bool
    public let amount: (minorUnits: Int, role: MoneyRole)
    public let currency: Currency

    public init(_ row: TransactionSearch.Row) {
        description = row.description
        isUncategorised = row.category == nil
        let category = row.categoryName.isEmpty ? "Uncategorised" : row.categoryName
        secondary = row.accountName.isEmpty ? category : "\(row.accountName) · \(category)"
        amount = (row.amountMinorUnits, Self.role(row.category?.type))
        currency = row.currency
    }

    static func role(_ type: CategoryType?) -> MoneyRole {
        switch type {
        case .transfer: .transfer
        case .adjustment: .neutral
        case .expense, .income, nil: .income
        }
    }
}

/// The amber "?" an uncategorised row carries in place of a category badge, the size of `CategoryBadge`.
struct UncategorisedBadge: View {
    @Environment(\.phoneTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var scaled: CGFloat = 32
    private var diameter: CGFloat { min(scaled, 44) }

    var body: some View {
        ZStack {
            Circle().fill(theme.pending)
            Image(systemName: "questionmark")
                .font(.system(size: diameter * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// One search result: badge, description, "account · category", amount. Side by side the amount trails; at
/// accessibility sizes it goes under the description (`FigureRow`).
public struct TransactionRow: View {
    let row: TransactionSearch.Row

    public init(row: TransactionSearch.Row) {
        self.row = row
    }

    public var body: some View {
        let shown = TransactionRowPresentation(row)
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let category = row.category {
                    CategoryBadge(category: category)
                } else {
                    UncategorisedBadge()
                }
            }
            .padding(.top, 6)
            FigureRow(label: shown.description, secondary: shown.secondary) {
                MoneyText(minorUnits: shown.amount.minorUnits, currency: shown.currency, role: shown.amount.role)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the transaction")
    }
}
