import SwiftUI
import Charts
import BudgetCore
import struct BudgetCore.Category
import GRDB

/// What an account's detail shows: its balance history (`AccountHistory.make`, as the Mac's Accounts screen makes it)
/// and its newest transactions (`TransactionSearch`, the account's only).
public struct AccountDetail: Equatable, Sendable {
    public let account: Account
    public let history: AccountHistory
    /// Newest first, at most `AccountDetailModel.recentLimit`.
    public let recent: [TransactionSearch.Row]
}

/// An account's detail (iPhone spec §3.6, "shows its recent transactions and its balance chart"). Reads only the
/// account's own snapshots and transactions (filtered in SQL); both calculators filter by account themselves, so
/// the result is the same as over everything. Read-only: updating a balance from the phone comes in step 6.
@MainActor
public final class AccountDetailModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case loaded(AccountDetail)
        case failed(String)
    }

    public static let loadFailureMessage = "Mango couldn't read this account. Go back and try again."
    /// How many of the newest transactions the detail lists.
    public static let recentLimit = 20

    @Published public private(set) var state: State
    /// The row as Accounts last showed it (a sync can change its balance); nil if Accounts doesn't have it.
    @Published public private(set) var row: AccountRowPresentation?
    public let accountId: Int64
    private let dbQueue: any DatabaseReader
    private let today: () -> Date

    public init(dbQueue: any DatabaseReader, accountId: Int64, row: AccountRowPresentation?, today: @escaping () -> Date,
                preloaded: State = .idle) {
        self.dbQueue = dbQueue
        self.accountId = accountId
        self.row = row
        self.today = today
        self.state = preloaded
    }

    /// Reads off the main actor; a failed read keeps a detail already shown.
    public func load() async {
        let reader = dbQueue
        let id = accountId
        let day = today()
        do {
            state = .loaded(try await reader.read { db in try Self.read(db, accountId: id, today: day) })
        } catch {
            if case .loaded = state { return }
            state = .failed(Self.loadFailureMessage)
        }
    }

    /// After a sync: the row's new figures (if Accounts still has it) and the detail read again, in place.
    public func refresh(row updated: AccountRowPresentation?) async {
        if let updated, updated.id == accountId { row = updated }
        await load()
    }

    /// The same read, now (the snapshot routes).
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, accountId: Int64, today: Date) -> State {
        do {
            return .loaded(try dbQueue.read { db in try read(db, accountId: accountId, today: today) })
        } catch {
            return .failed(loadFailureMessage)
        }
    }

    nonisolated static func read(_ db: Database, accountId: Int64, today: Date) throws -> AccountDetail {
        guard let account = try Account.fetchOne(db, key: accountId) else { throw DatabaseError(resultCode: .SQLITE_NOTFOUND) }
        let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
        let transactions = try Transaction.filter(Column("accountId") == accountId).fetchAll(db)
        let categories = try Category.fetchAll(db)
        let adjustmentNames = Dictionary(categories.filter(\.isBuiltIn).compactMap { category in category.id.map { ($0, category.name) } },
                                         uniquingKeysWith: { first, _ in first })
        let history = AccountHistory.make(accountId: accountId, snapshots: snapshots, transactions: transactions,
                                          adjustmentCategoryNames: adjustmentNames, today: today)
        let input = TransactionSearch.Input(transactions: transactions, categories: categories, accounts: [account],
                                            links: try TransferLink.fetchAll(db),
                                            eurToGbpRate: try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate)
        let recent = TransactionSearch.rows(input, criteria: .init(accountIds: [accountId]), now: today)
        return AccountDetail(account: account, history: history, recent: Array(recent.prefix(recentLimit)))
    }

    /// A transaction's amount as `MoneyText` takes it, by its category's role (Month's rule): a spend as a cost, so
    /// a refund reads as a gain; uncategorised, as given (in or out by its sign).
    nonisolated static func amount(_ minorUnits: Int, category: Category?) -> (minorUnits: Int, role: MoneyRole) {
        guard let category else { return (minorUnits, .income) }
        return MonthTransactionsModel.amount(minorUnits, type: category.type)
    }

    /// Under a transaction's description: its day, and its category when it has one.
    nonisolated static func secondary(_ row: TransactionSearch.Row) -> String {
        ([PhoneDateFormat.day(row.date)] + (row.categoryName.isEmpty ? [] : [row.categoryName])).joined(separator: " · ")
    }
}

/// An account's detail: its balance (pounds beneath a non-GBP one), the balance chart (the opening day, each month
/// end, then today) and the newest transactions.
public struct AccountDetailView: View {
    @ObservedObject var model: AccountDetailModel
    @Environment(\.phoneTheme) private var theme

    public init(model: AccountDetailModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            // Not lazy: twenty rows at most, and the snapshot probe measures every one.
            VStack(alignment: .leading, spacing: 16) {
                if let row = model.row {
                    BalanceCard(row: row)
                }
                content
            }
            .padding(16)
        }
        .background(theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayModeInline()
        .task {
            if case .idle = model.state { await model.load() }
        }
    }

    private var title: String {
        if let row = model.row { return row.name }
        if case let .loaded(detail) = model.state { return detail.account.displayName }
        return "Account"
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "This account couldn't load", message: message)
        case .loaded(let detail):
            BalanceChartCard(history: detail.history, currency: detail.account.currency)
            Card(title: "Recent transactions") {
                if detail.recent.isEmpty {
                    Text("No transactions in this account yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else {
                    ForEach(Array(detail.recent.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        let amount = AccountDetailModel.amount(row.amountMinorUnits, category: row.category)
                        AmountRow(label: row.description, secondary: AccountDetailModel.secondary(row),
                                  amount: MoneyText(minorUnits: amount.minorUnits, currency: row.currency, role: amount.role))
                    }
                }
            }
        }
    }
}

/// The account's balance, large, with pounds beneath a non-GBP one and its caption.
private struct BalanceCard: View {
    let row: AccountRowPresentation
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                MoneyText(minorUnits: row.nativeMinorUnits, currency: row.currency, role: .balance, fit: .shrink(),
                          font: .largeTitle.weight(.semibold))
                if let gbp = row.gbpMinorUnits {
                    Text(MoneyPresentation.format(gbp, currency: .gbp))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .figureText(.shrink())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Balance")
            .accessibilityValue(row.spoken)
            Text(row.caption.figuresUnbroken)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            if row.needsUpdate {
                InlineBanner(tone: .amber, text: AccountsCopy.needsUpdate)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The balance over time in the account's currency (`AccountHistory.points`): needs two points to draw a line.
private struct BalanceChartCard: View {
    let history: AccountHistory
    let currency: Currency
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Card(title: "Balance") {
            let points = history.points
            if points.count >= 2 {
                Chart(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Date", point.date), y: .value("Balance", Double(point.balanceMinorUnits) / 100))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(theme.accent)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 180)
                .accessibilityLabel("Balance over time")
                .accessibilityValue(AccountDetailCopy.chartValue(points, currency: currency))
            } else {
                Text("Not enough history for a chart yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
    }
}

/// The detail's words.
enum AccountDetailCopy {
    /// "From £1,000.00 on 30 Sep 2023 to £2,400.00 on 15 Oct 2026".
    static func chartValue(_ points: [AccountHistory.Point], currency: Currency) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        func money(_ minorUnits: Int) -> String { MoneyPresentation.format(minorUnits, currency: currency) }
        return "From \(money(first.balanceMinorUnits)) on \(PhoneDateFormat.day(first.date)) "
            + "to \(money(last.balanceMinorUnits)) on \(PhoneDateFormat.day(last.date))"
    }
}
