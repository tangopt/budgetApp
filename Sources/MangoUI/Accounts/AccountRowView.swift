import SwiftUI
import BudgetCore

/// An account row's words (iPhone spec §3.6): the name over "Imported · through <day>" or "Checked <n> days ago",
/// the amber "Needs an update" when the Mac's rule says it's stale (`AccountRow.isStale`, `BalanceStaleness`), and
/// the balance in the account's currency with pounds beneath for a non-GBP account. Wording only: the figures are
/// `AccountsOverview`'s.
public struct AccountRowPresentation: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let name: String
    public let caption: String
    public let needsUpdate: Bool
    public let nativeMinorUnits: Int
    public let currency: Currency
    /// The pounds equivalent under a non-GBP balance; nil for a GBP account.
    public let gbpMinorUnits: Int?
    /// Counts toward net worth (and the section's subtotal).
    public let isInNetWorth: Bool
    /// What VoiceOver reads after the name: "balance £1,200.00, Imported · through 12 Oct 2026".
    public let spoken: String

    public init(_ row: AccountRow, importedThrough: Date?, today: Date) {
        id = row.id
        name = row.account.displayName
        if let importedThrough {
            caption = "Imported · through \(PhoneDateFormat.day(importedThrough))"
        } else if let last = row.lastUpdated {
            caption = "Checked \(Self.age(of: last, today: today))"
        } else {
            caption = "No balance recorded yet"
        }
        needsUpdate = row.isStale
        nativeMinorUnits = row.nativeBalanceMinorUnits
        currency = row.account.currency
        gbpMinorUnits = row.account.currency == .gbp ? nil : row.gbpBalanceMinorUnits
        isInNetWorth = row.account.includeInNetWorth

        var parts = [MoneyPresentation(minorUnits: nativeMinorUnits, currency: currency, role: .balance).spoken]
        if let gbpMinorUnits {
            parts.append("about \(MoneyPresentation.format(abs(gbpMinorUnits), currency: .gbp))")
        }
        parts.append(caption)
        if needsUpdate { parts.append(AccountsCopy.needsUpdate) }
        if !isInNetWorth { parts.append(AccountsCopy.notInNetWorth) }
        spoken = parts.joined(separator: ", ")
    }

    /// "today", "3 days ago", "2 months ago": whole UTC days, then calendar months from 60 days (the Mac's
    /// `AccountsFormat.age`).
    static func age(of date: Date, today: Date) -> String {
        let calendar = MonthRange.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: today)).day ?? 0
        if days <= 0 { return "today" }
        if days < 60 { return days == 1 ? "1 day ago" : "\(days) days ago" }
        let months = calendar.dateComponents([.month], from: date, to: today).month ?? 0
        return months == 1 ? "1 month ago" : "\(months) months ago"
    }
}

/// One account (iPhone spec §3.6): two lines, the name over its caption, with the balance trailing; pounds beneath a
/// non-GBP balance; the amber "Needs an update" under them when stale. At accessibility sizes the balance goes under
/// the name.
struct AccountRowView: View {
    let row: AccountRowPresentation
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if AmountRowLayout.stacks(at: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 4) {
                    labels
                    balances(alignment: .leading)
                        .environment(\.stackedFigureRowSize, dynamicTypeSize)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    labels
                        .frame(maxWidth: .infinity, alignment: .leading)
                    balances(alignment: .trailing)
                }
            }
            if row.needsUpdate {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .accessibilityHidden(true)
                    Text(AccountsCopy.needsUpdate)
                }
                .font(.subheadline)
                .foregroundStyle(theme.pending)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.spoken)
        // Always inside Accounts' NavigationLink: say it opens the account.
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the balance history and recent transactions")
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.caption.figuresUnbroken)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !row.isInNetWorth {
                Text(AccountsCopy.notInNetWorth)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func balances(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            MoneyText(minorUnits: row.nativeMinorUnits, currency: row.currency, role: .balance)
            if let gbp = row.gbpMinorUnits {
                Text(MoneyPresentation.format(gbp, currency: .gbp))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .figureText()
            }
        }
    }
}
