// App/Dashboard/SmallCards.swift
import SwiftUI
import BudgetCore

struct TopCategoriesCard: View {
    let categories: [CategorySpend]
    let hasActuals: Bool
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        DashboardCard(title: "Top categories this month", linkTitle: "Budget", onLink: { navigate(.budgetGrid) }) {
            if categories.isEmpty {
                Text("Nothing planned or spent yet this month.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(categories) { category in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(category.name).lineLimit(1)
                        Spacer()
                        // Amounts never wrap; the name truncates instead.
                        if category.isCoveredByReserve && category.expected == 0 && category.actual > 0 {
                            Text("\(DashboardFormat.pounds(category.actual)) · covered by reserve").foregroundStyle(.secondary).figureText()
                        } else if category.isUnplanned {
                            Text("\(DashboardFormat.pounds(category.actual)) · unplanned").foregroundStyle(.orange).figureText()
                        } else if hasActuals {
                            Text("\(DashboardFormat.pounds(category.actual)) of \(DashboardFormat.pounds(category.expected))")
                                .foregroundStyle(category.isOver ? theme.expense : Color.primary)
                                .figureText()
                            if category.isOver { Text("+\(DashboardFormat.pounds(category.actual - category.expected))").foregroundStyle(theme.expense).figureText() }
                        } else {
                            Text("expected \(DashboardFormat.pounds(category.expected))").foregroundStyle(.secondary).figureText()
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                    // Spent so far against what was planned for the month; PaceMeter caps the bar
                    // at full width, so an over-budget row reads as a full red bar.
                    if hasActuals && category.expected > 0 {
                        PaceMeter(fraction: max(Double(category.actual) / Double(category.expected), 0), pace: nil, tint: category.isOver ? theme.expense : theme.series(1))
                    }
                }
                if category.id != categories.last?.id { Divider() }
            }
        }
    }
}

struct AttentionCard: View {
    let items: AttentionItems
    /// The review's signals (tax deadline, late rent, evidence, waiting documents and imports,
    /// mortgage review), shown after the original rows.
    var extra: [DashboardReview.AttentionLine] = []
    let navigate: (AppScreen) -> Void

    private func destination(_ kind: DashboardReview.AttentionLine.Kind) -> (screen: AppScreen, link: String) {
        switch kind {
        case .taxDeadline: return (.taxYears, "Tax years")
        case .rentLate: return (.property, "Property")
        case .evidenceMissing: return (.missingEvidence, "Missing evidence")
        case .documentsWaiting: return (.documents, "Documents")
        case .importsWaiting: return (.imports, "Imports")
        case .mortgageReview: return (.property, "Property")
        }
    }

    var body: some View {
        DashboardCard(title: "Needs attention") {
            if items.uncategorizedCount > 0 {
                row(warning: true, "\(items.uncategorizedCount) transaction\(items.uncategorizedCount == 1 ? "" : "s") need a category", link: "Review") { navigate(.uncategorized) }
            } else {
                row(warning: false, "Nothing uncategorized", link: nil) {}
            }
            if items.staleBalanceCount > 0 {
                let since = items.oldestStaleSnapshotDate.map { " since \(DashboardFormat.day($0).unbroken)" } ?? ""
                row(warning: true, "\(items.staleBalanceCount) balance\(items.staleBalanceCount == 1 ? "" : "s") not updated\(since)", link: "Update balances") { navigate(.accounts) }
            } else {
                row(warning: false, "All balances up to date", link: nil) {}
            }
            if items.missingReserveAllowance {
                row(warning: true, "No reserve for unplanned spending in the budget", link: "Budget grid") { navigate(.budgetGrid) }
            }
            ForEach(extra) { line in
                let target = destination(line.kind)
                row(warning: true, line.text, link: target.link) { navigate(target.screen) }
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
        DashboardCard(title: "Upcoming bills · 30 days", linkTitle: "Budget", onLink: { navigate(.budgetGrid) }) {
            if bills.isEmpty {
                Text("None in the next 30 days.").font(.callout).foregroundStyle(.secondary)
            }
            // Offset identity: `UpcomingBill.id` collides for two identical bills (same
            // category, date and amount), which would make ForEach drop or misrender a row.
            let visible = Array(bills.prefix(shown).enumerated())
            ForEach(visible, id: \.offset) { index, bill in
                HStack {
                    // The day keeps its width; the category truncates.
                    HStack(spacing: 4) {
                        Text(DashboardFormat.day(bill.date)).figureText()
                        Text("· \(bill.categoryName)").lineLimit(1)
                    }
                    Spacer()
                    Text(DashboardFormat.pounds(abs(bill.amountMinorUnits))).monospacedDigit()
                        .figureText()
                }
                .font(.callout)
                if index < visible.count - 1 { Divider() }
            }
            if bills.count > shown {
                Button("+ \(bills.count - shown) more ›") { navigate(.budgetGrid) }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct AccountsCard: View {
    let accounts: [AccountSummary]
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme
    private let shown = 4

    var body: some View {
        DashboardCard(title: "Accounts", linkTitle: "Accounts", onLink: { navigate(.accounts) }) {
            if accounts.isEmpty {
                Text("No accounts yet.").font(.callout).foregroundStyle(.secondary)
            }
            let visible = Array(accounts.prefix(shown))
            ForEach(visible) { account in
                HStack {
                    Text(account.name).lineLimit(1)
                    Spacer()
                    balanceText(account)
                        .fixedSize()
                }
                .font(.callout)
                .monospacedDigit()
                if account.id != visible.last?.id { Divider() }
            }
            if accounts.count > shown {
                Button("+ \(accounts.count - shown) more ›") { navigate(.accounts) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    /// A credit account's balance is negative when money is owed (positive = in credit), so
    /// "owed" is only said for the negative case. A non-GBP account shows its native amount
    /// with the GBP equivalent secondary in parentheses (the Accounts screen instead lists the
    /// native amount and the GBP balance side by side, without parentheses).
    @ViewBuilder
    private func balanceText(_ account: AccountSummary) -> some View {
        let isOwed = account.kind == .credit && account.gbpBalanceMinorUnits < 0
        HStack(spacing: 4) {
            if account.currency == .gbp {
                if isOwed {
                    Text("\(DashboardFormat.pounds(abs(account.gbpBalanceMinorUnits))) owed").foregroundStyle(theme.expense).figureText()
                } else {
                    Text(DashboardFormat.pounds(account.gbpBalanceMinorUnits)).figureText()
                }
            } else {
                if isOwed {
                    Text("\(Money.format(abs(account.nativeBalanceMinorUnits), currency: account.currency)) owed").foregroundStyle(theme.expense).figureText()
                } else {
                    MoneyText(minorUnits: account.nativeBalanceMinorUnits, currency: account.currency, font: .callout.monospacedDigit(), tint: .primary)
                }
                Text("(\(DashboardFormat.pounds(isOwed ? abs(account.gbpBalanceMinorUnits) : account.gbpBalanceMinorUnits)))")
                    .foregroundStyle(.secondary)
                    .figureText()
            }
        }
    }
}
