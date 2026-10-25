import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import GRDB

/// A day's transactions in a row's list.
public struct MonthTransactionDay: Equatable, Sendable, Identifiable {
    /// The day (UTC start of day, as transactions are stored).
    public let day: Date
    public let rows: [PayMonthReview.RowTransaction]
    public var id: Date { day }
}

/// A category row's transactions in its pay month (iPhone spec §3.3, "tapping a row opens its transactions"):
/// exactly the ones its figure sums (`PayMonthReview.transactions`: confirmed, budget-facing, in GBP), newest
/// first, grouped by day. Read-only.
@MainActor
public final class MonthTransactionsModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case loaded([MonthTransactionDay])
        case failed(String)
    }

    public static let loadFailureMessage = "Mango couldn't read these transactions. Go back and try again."

    @Published public private(set) var state: State
    /// The row as the month last showed it (a sync can change its figures).
    @Published public private(set) var row: PayMonthReview.Row
    public let range: PayMonthReview.DayRange
    private let dbQueue: any DatabaseReader

    public init(dbQueue: any DatabaseReader, row: PayMonthReview.Row, range: PayMonthReview.DayRange, preloaded: State = .idle) {
        self.dbQueue = dbQueue
        self.row = row
        self.range = range
        self.state = preloaded
    }

    /// Reads the list off the main actor; a failed read keeps a list already shown.
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

    /// After a sync: the row's new figures (if the month still has it) and the list read again, in place, so a
    /// pushed list neither flickers nor stays stale.
    public func refresh(row updated: PayMonthReview.Row?) async {
        if let updated, updated.id == row.id { row = updated }
        await load()
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
        days(try PayMonthReview.transactions(db: db, categoryId: categoryId, range: range))
    }

    /// Rows (newest first) grouped by their day, newest day first.
    nonisolated static func days(_ rows: [PayMonthReview.RowTransaction]) -> [MonthTransactionDay] {
        var result: [MonthTransactionDay] = []
        var day: Date?
        var current: [PayMonthReview.RowTransaction] = []
        for row in rows {
            let rowDay = MonthRange.calendar.startOfDay(for: row.date)
            if let open = day, open != rowDay {
                result.append(MonthTransactionDay(day: open, rows: current))
                current.removeAll(keepingCapacity: true)
            }
            day = rowDay
            current.append(row)
        }
        if let open = day { result.append(MonthTransactionDay(day: open, rows: current)) }
        return result
    }

    /// Under the description: the account, and the account's own amount when it was converted to pounds
    /// ("Euro Account · €100.00"). Nil with neither.
    nonisolated static func secondary(_ row: PayMonthReview.RowTransaction) -> String? {
        var parts: [String] = []
        if !row.accountName.isEmpty { parts.append(row.accountName) }
        if row.isConverted { parts.append(MoneyPresentation.format(row.originalMinorUnits, currency: row.originalCurrency)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                        let amount = MonthTransactionsModel.amount(row.gbpMinorUnits, type: model.row.category.type)
                        AmountRow(label: row.description, secondary: MonthTransactionsModel.secondary(row),
                                  amount: MoneyText(minorUnits: amount.minorUnits, currency: .gbp, role: amount.role))
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
