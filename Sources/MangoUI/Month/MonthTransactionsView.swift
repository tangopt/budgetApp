import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import GRDB

/// A day's transactions in a row's list.
public struct MonthTransactionDay: Equatable, Sendable, Identifiable {
    /// The day (UTC start of day, as transactions are stored).
    public let day: Date
    public let rows: [TransactionSearch.Row]
    public var id: Date { day }
}

/// A category row's transactions in its pay month (iPhone spec §3.3, "tapping a row opens its transactions"):
/// `TransactionSearch` with the category and the month's dates, newest first, grouped by day. Read-only.
@MainActor
public final class MonthTransactionsModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case loaded([MonthTransactionDay])
        case failed(String)
    }

    public static let loadFailureMessage = "Mango couldn't read these transactions. Go back and try again."

    @Published public private(set) var state: State
    public let row: PayMonthReview.Row
    public let range: PayMonthReview.DayRange
    private let dbQueue: any DatabaseReader

    public init(dbQueue: any DatabaseReader, row: PayMonthReview.Row, range: PayMonthReview.DayRange, preloaded: State = .idle) {
        self.dbQueue = dbQueue
        self.row = row
        self.range = range
        self.state = preloaded
    }

    public func load() async {
        let reader = dbQueue
        let categoryId = row.id
        let range = range
        do {
            state = .loaded(try await reader.read { db in try Self.read(db, categoryId: categoryId, range: range) })
        } catch {
            if case .loaded = state { return }
            state = .failed(Self.loadFailureMessage)
        }
    }

    /// The same read, now (the snapshot routes).
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, row: PayMonthReview.Row, range: PayMonthReview.DayRange) -> State {
        do {
            return .loaded(try dbQueue.read { db in try read(db, categoryId: row.id, range: range) })
        } catch {
            return .failed(loadFailureMessage)
        }
    }

    nonisolated static func read(_ db: Database, categoryId: Int64, range: PayMonthReview.DayRange) throws -> [MonthTransactionDay] {
        let input = TransactionSearch.Input(transactions: try Transaction.fetchAll(db), categories: try Category.fetchAll(db),
                                            accounts: try Account.fetchAll(db), links: try TransferLink.fetchAll(db),
                                            eurToGbpRate: try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate)
        let criteria = TransactionSearch.Criteria(date: .custom(from: range.start, to: range.end), categoryIds: [categoryId])
        let rows = TransactionSearch.rows(input, criteria: criteria, now: range.end, timeZone: MonthRange.calendar.timeZone)
        return days(rows)
    }

    /// Rows (newest first) grouped by their day, newest day first.
    nonisolated static func days(_ rows: [TransactionSearch.Row]) -> [MonthTransactionDay] {
        var result: [MonthTransactionDay] = []
        for row in rows {
            let day = MonthRange.calendar.startOfDay(for: row.date)
            if let last = result.last, last.day == day {
                result[result.count - 1] = MonthTransactionDay(day: day, rows: last.rows + [row])
            } else {
                result.append(MonthTransactionDay(day: day, rows: [row]))
            }
        }
        return result
    }

    /// A transaction's amount as `MoneyText` takes it, by its category's role: a spend as a cost (so a refund reads
    /// as a gain), income as given, a transfer with its sign.
    nonisolated static func amount(_ minorUnits: Int, type: CategoryType) -> (minorUnits: Int, role: MoneyRole) {
        switch type {
        case .expense: (-minorUnits, .expense)
        case .income: (minorUnits, .income)
        case .transfer: (minorUnits, .transfer)
        case .adjustment: (minorUnits, .neutral)
        }
    }
}

/// The list a category row opens: its transactions in the pay month, by day, newest first. Read-only: a row
/// shows the description, the account and the amount, and opens nothing.
public struct MonthTransactionsView: View {
    @ObservedObject var model: MonthTransactionsModel
    @Environment(\.phoneTheme) private var theme

    public init(model: MonthTransactionsModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            // Not lazy: few rows, and the snapshot probe measures every one.
            VStack(alignment: .leading, spacing: 16) {
                Text(MonthCopy.range(model.range).figuresUnbroken)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                content
            }
            .padding(16)
        }
        .background(theme.background)
        .navigationTitle(model.row.category.name)
        .navigationBarTitleDisplayModeInline()
        .task {
            if case .idle = model.state { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Transactions couldn't load", message: message)
        case .loaded(let days) where days.isEmpty:
            // A row with a plan and no spending yet.
            EmptyState(symbol: "tray", title: "No transactions yet",
                       message: "Nothing in \(model.row.category.name) in this pay month so far.")
        case .loaded(let days):
            ForEach(days) { day in
                Card {
                    DateText(day.day, font: .subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.rows) { row in
                        let amount = MonthTransactionsModel.amount(row.amountMinorUnits, type: model.row.category.type)
                        AmountRow(label: row.description, secondary: row.accountName.isEmpty ? nil : row.accountName,
                                  amount: MoneyText(minorUnits: amount.minorUnits, currency: row.currency, role: amount.role))
                    }
                }
            }
        }
    }
}

extension View {
    /// The inline title of a pushed screen (iOS); nothing on the Mac, where MangoUI also builds for tests.
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
