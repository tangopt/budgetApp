// App/Dashboard/SmallCards.swift
import SwiftUI
import BudgetCore

struct TopCategoriesCard: View {
    let categories: [CategorySpend]
    let hasActuals: Bool
    let navigate: (AppScreen) -> Void

    var body: some View {
        DashboardCard(title: "Top categories this month", linkTitle: "Forecast", onLink: { navigate(.forecast) }) {
            if categories.isEmpty {
                Text("Nothing planned or spent yet this month.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(categories) { category in
                HStack {
                    Text(category.name)
                    Spacer()
                    if category.isUnplanned {
                        Text("\(DashboardFormat.pounds(category.actual)) · unplanned").foregroundStyle(.orange)
                    } else if hasActuals {
                        Text("\(DashboardFormat.pounds(category.actual)) of \(DashboardFormat.pounds(category.expected))")
                            .foregroundStyle(category.isOver ? Color.red : Color.primary)
                        if category.isOver { Text("+\(DashboardFormat.pounds(category.actual - category.expected))").foregroundStyle(.red) }
                    } else {
                        Text("expected \(DashboardFormat.pounds(category.expected))").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .monospacedDigit()
                if category.id != categories.last?.id { Divider() }
            }
        }
    }
}

struct AttentionCard: View {
    let items: AttentionItems
    let navigate: (AppScreen) -> Void

    var body: some View {
        DashboardCard(title: "Needs attention") {
            if items.uncategorizedCount > 0 {
                row(warning: true, "\(items.uncategorizedCount) transaction\(items.uncategorizedCount == 1 ? "" : "s") need a category", link: "Review") { navigate(.uncategorized) }
            } else {
                row(warning: false, "Nothing uncategorized", link: nil) {}
            }
            if items.staleBalanceCount > 0 {
                let since = items.oldestStaleSnapshotDate.map { " since \(DashboardFormat.day($0))" } ?? ""
                row(warning: true, "\(items.staleBalanceCount) balance\(items.staleBalanceCount == 1 ? "" : "s") not updated\(since)", link: "Update balances") { navigate(.netWorth) }
            } else {
                row(warning: false, "All balances up to date", link: nil) {}
            }
            switch items.catchAllIssue {
            case .notDesignated:
                row(warning: true, "No catch-all allowance in the forecast — unplanned spending isn't being projected", link: "Categories") { navigate(.categories) }
            case .noAllowance:
                row(warning: true, "The catch-all category has no monthly allowance in the forecast", link: "Forecast") { navigate(.forecast) }
            case nil:
                EmptyView()
            }
        }
    }

    private func row(warning: Bool, _ text: String, link: String?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: warning ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(warning ? Color.orange : Color.green)
            Text(text).font(.callout)
            Spacer()
            if let link { Button("\(link) ›", action: action).buttonStyle(.link).font(.caption) }
        }
    }
}

struct UpcomingBillsCard: View {
    let bills: [UpcomingBill]
    let navigate: (AppScreen) -> Void
    private let shown = 5

    var body: some View {
        DashboardCard(title: "Upcoming bills · 30 days", linkTitle: "Forecast", onLink: { navigate(.forecast) }) {
            if bills.isEmpty {
                Text("None in the next 30 days.").font(.callout).foregroundStyle(.secondary)
            }
            // Offset identity: `UpcomingBill.id` collides for two identical bills (same
            // category, date and amount), which would make ForEach drop or misrender a row.
            let visible = Array(bills.prefix(shown).enumerated())
            ForEach(visible, id: \.offset) { index, bill in
                HStack {
                    Text("\(DashboardFormat.day(bill.date)) · \(bill.categoryName)")
                    Spacer()
                    Text(DashboardFormat.pounds(abs(bill.amountMinorUnits))).monospacedDigit()
                }
                .font(.callout)
                if index < visible.count - 1 { Divider() }
            }
            if bills.count > shown {
                Button("+ \(bills.count - shown) more ›") { navigate(.forecast) }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct AccountsCard: View {
    let accounts: [AccountSummary]
    let navigate: (AppScreen) -> Void
    private let shown = 4

    var body: some View {
        DashboardCard(title: "Accounts", linkTitle: "Net Worth", onLink: { navigate(.netWorth) }) {
            if accounts.isEmpty {
                Text("No accounts yet.").font(.callout).foregroundStyle(.secondary)
            }
            let visible = Array(accounts.prefix(shown))
            ForEach(visible) { account in
                HStack {
                    Text(account.name)
                    Spacer()
                    balanceText(account)
                }
                .font(.callout)
                .monospacedDigit()
                if account.id != visible.last?.id { Divider() }
            }
            if accounts.count > shown {
                Button("+ \(accounts.count - shown) more ›") { navigate(.netWorth) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    /// A credit account's balance is negative when money is owed (positive = in credit), so
    /// "owed" is only said for the negative case.
    @ViewBuilder
    private func balanceText(_ account: AccountSummary) -> some View {
        if account.kind == .credit && account.gbpBalanceMinorUnits < 0 {
            Text("\(DashboardFormat.pounds(abs(account.gbpBalanceMinorUnits))) owed").foregroundStyle(.red)
        } else {
            Text(DashboardFormat.pounds(account.gbpBalanceMinorUnits))
        }
    }
}
