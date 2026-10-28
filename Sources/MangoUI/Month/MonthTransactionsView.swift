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
/// first, grouped by day, then one line per account of the other person's that the viewer reads only as category
/// totals (`SharedActuals.privateLines`, step 6). Read-only, except where quick edits are on (step 7b): a row then
/// opens its transaction.
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
    /// After the days: the other person's private accounts' lines for this row (step 6), read with the list.
    @Published public private(set) var privateLines: [SharedActuals.PrivateLine]
    public let range: PayMonthReview.DayRange
    /// Whose transactions the list shows (step 6): the next load reads with it.
    public var viewer: PhoneViewer
    private let dbQueue: any DatabaseReader
    private let today: () -> Date

    public init(dbQueue: any DatabaseReader, row: PayMonthReview.Row, range: PayMonthReview.DayRange, viewer: PhoneViewer = .everyone,
                today: @escaping () -> Date = { Date() }, preloaded: State = .idle, privateLines: [SharedActuals.PrivateLine] = []) {
        self.dbQueue = dbQueue
        self.row = row
        self.range = range
        self.viewer = viewer
        self.today = today
        self.state = preloaded
        self.privateLines = privateLines
    }

    /// Reads the list off the main actor; a failed read keeps a list already shown.
    public func load() async {
        let reader = dbQueue
        let categoryId = row.id
        let range = range
        let viewer = viewer
        let day = today()
        do {
            let (days, lines) = try await reader.read { db in
                (try Self.read(db, categoryId: categoryId, range: range, viewer: viewer, today: day),
                 try Self.privateLines(db, categoryId: categoryId, range: range, viewer: viewer, today: day))
            }
            state = .loaded(days)
            privateLines = lines
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
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, row: PayMonthReview.Row, range: PayMonthReview.DayRange,
                                           viewer: PhoneViewer = .everyone, today: Date = Date()) -> State {
        do {
            return .loaded(try dbQueue.read { db in try read(db, categoryId: row.id, range: range, viewer: viewer, today: today) })
        } catch {
            return .failed(loadFailureMessage)
        }
    }

    /// The row's private lines, now (the snapshot routes); none when the read fails.
    public nonisolated static func privateLinesNow(_ dbQueue: any DatabaseReader, row: PayMonthReview.Row, range: PayMonthReview.DayRange,
                                                   viewer: PhoneViewer, today: Date) -> [SharedActuals.PrivateLine] {
        (try? dbQueue.read { db in try privateLines(db, categoryId: row.id, range: range, viewer: viewer, today: today) }) ?? []
    }

    nonisolated static func read(_ db: Database, categoryId: Int64, range: PayMonthReview.DayRange, viewer: PhoneViewer = .everyone,
                                 today: Date = Date()) throws -> [MonthTransactionDay] {
        days(try PayMonthReview.transactions(db: db, categoryId: categoryId, range: range, viewer: try viewer.resolve(db: db), today: today))
    }

    nonisolated static func privateLines(_ db: Database, categoryId: Int64, range: PayMonthReview.DayRange, viewer: PhoneViewer,
                                         today: Date) throws -> [SharedActuals.PrivateLine] {
        try SharedActuals.privateLines(categoryIds: [categoryId], from: range.start, to: range.end, viewer: try viewer.resolve(db: db),
                                       today: today, db: db)
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

/// The list a category row opens: its transactions in the pay month, by day, newest first. A row shows the
/// description, the account and the amount; with quick edits on it opens its transaction.
public struct MonthTransactionsView: View {
    @ObservedObject var model: MonthTransactionsModel
    @Environment(\.phoneTheme) private var theme
    @Environment(\.quickEdit) private var quickEdit

    public init(model: MonthTransactionsModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            // Not lazy: few rows, and the snapshot probe measures every one.
            VStack(alignment: .leading, spacing: 16) {
                Text(MonthCopy.range(model.range).figuresUnbroken)
                    .mangoFont(.subheadline)
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
        .modifier(MonthDetailSheet(model: quickEdit))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Transactions couldn't load", message: message)
        case .loaded(let days) where days.isEmpty && model.privateLines.isEmpty:
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
                        let line = AmountRow(label: row.description, secondary: MonthTransactionsModel.secondary(row),
                                             amount: MoneyText(minorUnits: amount.minorUnits, currency: .gbp, role: amount.role))
                        if let quickEdit, quickEdit.isAvailable {
                            // Where editing is on, a row opens its transaction (and from there Edit).
                            Button {
                                Task { quickEdit.monthDetail = await quickEdit.row(transactionId: row.id) }
                            } label: {
                                line.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows the transaction")
                        } else {
                            line
                        }
                    }
                }
            }
            if !model.privateLines.isEmpty {
                // The other person's accounts read only as category totals: one line each, after the shared ones.
                Card {
                    ForEach(model.privateLines) { line in
                        let amount = MonthTransactionsModel.amount(line.amountMinorUnits, type: model.row.category.type)
                        AmountRow(label: line.text, secondary: nil,
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
