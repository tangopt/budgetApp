// App/Accounts/AccountsView.swift
import SwiftUI
import Charts
import BudgetCore

/// Net worth and accounts on one screen: header total, banners, accounts grouped by kind
/// on the left, the selected account's detail and balance history on the right.
struct AccountsView: View {
    @ObservedObject var viewModel: AccountsViewModel
    @ObservedObject var environment: AppEnvironment
    @State private var activeSheet: AccountsSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let overview = viewModel.overview, !viewModel.accounts.isEmpty {
                header(overview)
                banners(overview)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        AccountsListView(groups: overview.groups, selection: $viewModel.selectedAccountId)
                        footer
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    AccountDetailView(
                        row: viewModel.selectedRow,
                        history: viewModel.selectedHistory,
                        onUpdateBalance: { activeSheet = .updateOne($0) },
                        onEdit: { activeSheet = .edit($0.account) }
                    )
                        .frame(width: 320)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            } else {
                commonBanners
                // Only claim "no accounts" once a load has succeeded; a failed first load
                // shows just its error banner.
                if viewModel.overview != nil {
                    emptyState
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                AddAccountSheet(viewModel: viewModel)
            case .edit(let account):
                EditAccountSheet(viewModel: viewModel, account: account)
            case .updateOne(let row):
                UpdateBalanceSheet(viewModel: viewModel, row: row)
            case .updateAll(let groups):
                UpdateBalancesSheet(viewModel: viewModel, groups: groups)
            }
        }
    }

    // MARK: Header

    private func header(_ overview: AccountsOverview) -> some View {
        HStack(alignment: .top) {
            headerTotals(overview)
            Spacer()
            Button("Update balances…") { activeSheet = .updateAll(overview.groups) }
            Button("+ Add account") { activeSheet = .add }
                .buttonStyle(.borderedProminent)
        }
    }

    private func headerTotals(_ overview: AccountsOverview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(overview.asOf.map { "Net worth · as of \(DashboardFormat.day($0))" } ?? "Net worth")
                .font(.callout)
                .foregroundStyle(.secondary)
            MoneyText(minorUnits: overview.netWorthGBP, font: .largeTitle.bold().monospacedDigit(), tint: .primary)
            if let change = overview.changeVsPreviousMonthGBP {
                HStack(spacing: 4) {
                    if change == 0 {
                        Text("No change vs previous month")
                    } else {
                        Text(change > 0 ? "↑" : "↓")
                        Text("\(Money.format(abs(change), currency: .gbp)) vs previous month")
                    }
                }
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(change > 0 ? Color.green : (change < 0 ? Color.red : Color.secondary))
            }
        }
    }

    // MARK: Banners

    @ViewBuilder
    private func banners(_ overview: AccountsOverview) -> some View {
        if overview.staleCount > 0 {
            let since = overview.oldestStaleDate.map { " since \(DashboardFormat.day($0))" } ?? ""
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                Text("\(overview.staleCount) balance\(overview.staleCount == 1 ? "" : "s") not updated\(since) — import a statement or update them.")
            }
        }
        if !viewModel.warnings.isEmpty {
            Banner(systemImage: "exclamationmark.circle.fill", tint: .orange, onDismiss: { viewModel.warnings = [] }) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.warnings, id: \.self) { Text($0) }
                }
            }
        }
        commonBanners
    }

    @ViewBuilder
    private var commonBanners: some View {
        if let error = viewModel.errorMessage {
            Banner(systemImage: "xmark.octagon.fill", tint: .red, onDismiss: { viewModel.errorMessage = nil }) {
                Text(error)
            }
        }
        if let banner = environment.exchangeRateBanner {
            Banner(systemImage: "eurosign.circle", tint: .blue, onDismiss: { environment.exchangeRateBanner = nil }) {
                Text(banner)
            }
        }
    }

    // MARK: Footer / empty

    private var footer: some View {
        let rate = viewModel.rate
        let formattedRate = rate.eurToGbpRate.formatted(.number.precision(.fractionLength(2...4)))
        return Text("EUR rate \(formattedRate) · updated \(DashboardFormat.day(rate.updatedAt))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "building.columns")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Add your first account").font(.title3)
            Text("Accounts and their balances make up your net worth.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("+ Add account") { activeSheet = .add }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sheets

private enum AccountsSheet: Identifiable {
    case add
    case edit(Account)
    case updateOne(AccountRow)
    case updateAll([AccountGroup])

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let account): return "edit-\(account.id ?? 0)"
        case .updateOne(let row): return "update-\(row.id)"
        case .updateAll: return "update-all"
        }
    }
}

// MARK: - Banner

private struct Banner<Content: View>: View {
    let systemImage: String
    let tint: Color
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: systemImage).foregroundStyle(tint)
            content.font(.callout)
            Spacer()
            if let onDismiss {
                Button("Dismiss", action: onDismiss).font(.caption)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }
}

// MARK: - List

private struct AccountsListView: View {
    let groups: [AccountGroup]
    @Binding var selection: Int64?

    var body: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        AccountListRow(row: row).tag(row.id)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("\(AccountsFormat.kind(group.kind)) ·")
                        MoneyText(minorUnits: group.subtotalGBP, font: .headline.monospacedDigit(), tint: group.subtotalGBP < 0 ? .red : .primary)
                    }
                    .font(.headline)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }
}

private struct AccountListRow: View {
    let row: AccountRow

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.account.name)
            if row.isStale {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("Not updated in over \(BalanceStaleness.thresholdDays) days")
            }
            Spacer()
            if row.account.currency != .gbp {
                AccountsFormat.balanceText(row.nativeBalanceMinorUnits, kind: row.account.kind, currency: row.account.currency)
                    .foregroundStyle(.secondary)
            }
            AccountsFormat.balanceText(row.gbpBalanceMinorUnits, kind: row.account.kind, currency: .gbp)
        }
        .font(.body.monospacedDigit())
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

private struct AccountDetailView: View {
    let row: AccountRow?
    let history: [BalanceSnapshot]
    let onUpdateBalance: (AccountRow) -> Void
    let onEdit: (AccountRow) -> Void
    @State private var showAllHistory = false
    private let historyLimit = 12

    var body: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.account.name).font(.title2.bold())
                        Text("\(row.account.currency.rawValue.uppercased()) · \(AccountsFormat.kind(row.account.kind)) · \(row.account.trackingMode == .manual ? "Manual balance" : "Imported")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        AccountsFormat.balanceText(row.nativeBalanceMinorUnits, kind: row.account.kind, currency: row.account.currency, font: .title.bold().monospacedDigit())
                        if row.account.currency != .gbp {
                            AccountsFormat.balanceText(row.gbpBalanceMinorUnits, kind: row.account.kind, currency: .gbp)
                                .foregroundStyle(.secondary)
                        }
                    }
                    updatedLine(row)
                    HStack {
                        Button("Update balance…") { onUpdateBalance(row) }
                        Button("Edit…") { onEdit(row) }
                    }
                    chart(row)
                    historyList(row)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .onChange(of: row.id) { _ in showAllHistory = false }
        } else {
            Text("Select an account.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func updatedLine(_ row: AccountRow) -> some View {
        Group {
            if let date = row.lastUpdated {
                Text("Updated \(DashboardFormat.day(date)) · \(AccountsFormat.age(of: date))")
            } else {
                Text("No balance recorded yet")
            }
        }
        .font(.callout)
        .foregroundStyle(row.isStale ? Color.orange : Color.secondary)
    }

    @ViewBuilder
    private func chart(_ row: AccountRow) -> some View {
        // Indexed: same-day snapshots share a date, so the date can't be the identity.
        let points = history.reversed().enumerated().map { (index: $0.offset, date: $0.element.date, value: Double($0.element.balanceMinorUnits) / 100) }
        if points.count >= 2 {
            Chart(points, id: \.index) { point in
                LineMark(x: .value("Date", point.date), y: .value("Balance", point.value))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 60)
        }
    }

    @ViewBuilder
    private func historyList(_ row: AccountRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Balance history").font(.headline)
            if history.isEmpty {
                Text("No balances recorded.").font(.callout).foregroundStyle(.secondary)
            }
            let visible = showAllHistory ? history : Array(history.prefix(historyLimit))
            ForEach(visible, id: \.id) { snapshot in
                HStack(alignment: .firstTextBaseline) {
                    Text(DashboardFormat.day(snapshot.date))
                    if let note = snapshot.note, !note.isEmpty {
                        Text(note).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                    AccountsFormat.balanceText(snapshot.balanceMinorUnits, kind: row.account.kind, currency: row.account.currency)
                }
                .font(.callout.monospacedDigit())
                Divider()
            }
            if history.count > historyLimit {
                Button(showAllHistory ? "Show fewer" : "Show all \(history.count)") { showAllHistory.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Formatting

enum AccountsFormat {
    static func kind(_ kind: AccountKind) -> String {
        switch kind {
        case .cash: return "Cash"
        case .investment: return "Investment"
        case .credit: return "Credit"
        }
    }

    /// Credit balances are stored signed (negative = owed) and shown as the amount owed,
    /// coloured by the stored sign so debt reads red — as the Net Worth screen did.
    @ViewBuilder
    static func balanceText(_ signedMinorUnits: Int, kind: AccountKind, currency: Currency, font: Font = .body.monospacedDigit()) -> some View {
        if kind == .credit && signedMinorUnits < 0 {
            HStack(spacing: 4) {
                MoneyText(minorUnits: NetWorthCalculator.enteredBalance(signedMinorUnits: signedMinorUnits, accountKind: .credit), currency: currency, font: font, colorOverride: signedMinorUnits)
                Text("owed").font(font).foregroundStyle(.red)
            }
        } else {
            MoneyText(minorUnits: signedMinorUnits, currency: currency, font: font, tint: signedMinorUnits < 0 ? .red : .primary)
        }
    }

    /// A picked local calendar day as the stored snapshot date (that day, 00:00 UTC).
    static func snapshotDay(_ picked: Date) -> Date {
        PayCalendar.utcDay(sameDayAs: picked, in: .current)
    }

    /// The row's current balance as the user would enter it (amount owed for credit),
    /// as a `Money.formatInput` string for prefilling a text field: "1,234.56", "-12.00".
    static func enteredAmountText(_ row: AccountRow) -> String {
        Money.formatInput(NetWorthCalculator.enteredBalance(signedMinorUnits: row.nativeBalanceMinorUnits, accountKind: row.account.kind))
    }

    static func invalidAmountMessage(_ text: String) -> String {
        "“\(text.trimmingCharacters(in: .whitespacesAndNewlines))” isn't a valid amount. Use digits with an optional decimal point, e.g. 1,234.56."
    }

    /// "today", "3 days ago", "2 months ago" — whole UTC days / calendar months.
    static func age(of date: Date, today: Date = Date()) -> String {
        let calendar = MonthRange.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: today)).day ?? 0
        if days <= 0 { return "today" }
        if days < 60 { return days == 1 ? "1 day ago" : "\(days) days ago" }
        let months = calendar.dateComponents([.month], from: date, to: today).month ?? 0
        return months == 1 ? "1 month ago" : "\(months) months ago"
    }
}
