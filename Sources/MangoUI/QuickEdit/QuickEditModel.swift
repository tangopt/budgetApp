import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import GRDB
import struct BudgetCore.Transaction

extension EnvironmentValues {
    /// The phone's quick edits (step 7b). Nil where nothing is editable (the iPad's screens, previews); the model
    /// itself offers nothing with no writer (demo data).
    @Entry public var quickEdit: QuickEditModel?
}

/// What the category choices are made from: every assignable category and its group, and the ids of the categories
/// the household files most into, most used first.
// `CategoryGroup` isn't marked Sendable, but is a plain value read once and never changed.
public struct QuickEditLists: Equatable, @unchecked Sendable {
    public var categories: [Category] = []
    public var groups: [CategoryGroup] = []
    public var mostUsed: [Int64] = []

    public init(categories: [Category] = [], groups: [CategoryGroup] = [], mostUsed: [Int64] = []) {
        self.categories = categories
        self.groups = groups
        self.mostUsed = mostUsed
    }

    public func name(of id: Int64) -> String? { categories.first { $0.id == id }?.name }
}

/// One card's category buttons: the suggestion first, then the most-used categories that fit the amount's sign (money
/// out files to expense and transfer, money in to income and transfer), up to `topCount`; `more` is the rest, by group.
public struct QuickSortChoices: Equatable {
    public static let topCount = 6

    /// A group's categories under "More…".
    public struct Group: Equatable, Identifiable {
        public let id: String
        public let title: String?
        public let categories: [Category]
    }

    public let top: [Category]
    public let more: [Group]

    public init(card: PhoneQuickEdits.QuickSortCard, lists: QuickEditLists) {
        let sections = CategoryPickerSections.build(categories: lists.categories, groups: lists.groups, suggestedId: card.suggestedCategoryId,
                                                    recentIds: [], amountMinorUnits: card.amountMinorUnits, query: "", showAll: false)
        var allowed: Set<Int64> = []
        for entry in sections.flatMap(\.entries) {
            if case .pick(let id?) = entry.action { allowed.insert(id) }
        }
        let byId = Dictionary(lists.categories.compactMap { category in category.id.map { ($0, category) } }, uniquingKeysWith: { first, _ in first })
        var ids: [Int64] = []
        if let suggested = card.suggestedCategoryId, allowed.contains(suggested) { ids.append(suggested) }
        for id in lists.mostUsed where allowed.contains(id) && !ids.contains(id) && ids.count < Self.topCount { ids.append(id) }
        top = ids.compactMap { byId[$0] }
        let shown = Set(ids)
        more = sections.compactMap { section in
            guard section.id != "none", section.id != "suggested", section.id != "show-all" else { return nil }
            let categories = section.entries.compactMap { entry -> Category? in
                if case .pick(let id?) = entry.action, !shown.contains(id) { return byId[id] }
                return nil
            }
            return categories.isEmpty ? nil : Group(id: section.id, title: section.title, categories: categories)
        }
    }
}

/// A toast at the foot of Quick sort: what was done, with Undo while `token` holds the way back.
public struct UndoToast: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let message: String
    /// Nil when there is nothing to undo (the toast after Undo).
    public let token: PhoneQuickEdits.UndoToken?

    public var canUndo: Bool { token != nil }
}

/// The iPhone's quick edits (step 7b spec §2.2): the transaction sheet's Save, Quick sort and its Undo, and Update
/// balance, all through the device writer (`PhoneQuickEdits`). A refusal (`DeviceWriteRefusal`, `AccessDenied`,
/// `QuickEditError`) is kept as its own text for the sheet's banner. With no writer (demo data) nothing is offered.
/// Owned by `PhoneTabsModel`, above the lock cover.
@MainActor
public final class QuickEditModel: ObservableObject {
    public static let toastSeconds: Double = 6

    public let writer: DeviceWriter?
    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    /// Whose accounts are seen in full (the quick-sort queue reads through it); set by the tabs.
    public var viewer: PhoneViewer = .everyone
    /// How long the Undo toast stays.
    public var toastDuration: Duration = .seconds(QuickEditModel.toastSeconds)
    /// After a write: the screens read again (set by the tabs).
    public var onChange: (@MainActor () async -> Void)?

    @Published public var refusal: String?
    @Published public private(set) var queue: [PhoneQuickEdits.QuickSortCard] = []
    @Published public private(set) var lists = QuickEditLists()
    @Published public private(set) var toast: UndoToast?
    // Sheet state, cleared on a lock (`dismissSheets`).
    @Published public var showsQuickSort = false
    @Published public var balanceAccountId: Int64?
    /// The transaction a Month row opened.
    @Published public var monthDetail: TransactionSearch.Row?
    private var toastTask: Task<Void, Never>?

    public init(writer: DeviceWriter?, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.writer = writer
        self.dbQueue = dbQueue
        self.today = today
    }

    /// The day Update balance starts from.
    public var currentDay: Date { today() }

    /// Editing exists at all (not on demo data).
    public var isAvailable: Bool { writer != nil }

    /// Shows an already known state (the snapshot routes' first frame).
    public func preload(lists: QuickEditLists? = nil, queue: [PhoneQuickEdits.QuickSortCard]? = nil, refusal: String? = nil, toast: UndoToast? = nil) {
        if let lists { self.lists = lists }
        if let queue { self.queue = queue }
        self.refusal = refusal
        self.toast = toast
    }

    /// On a lock: closes the sheets' state and drops what they showed.
    public func dismissSheets() {
        showsQuickSort = false
        balanceAccountId = nil
        monthDetail = nil
        refusal = nil
        clearToast()
    }

    // MARK: Reads

    /// Whether the user may categorise or note the transaction.
    public func canEdit(transactionId: Int64) async -> Bool {
        guard let writer else { return false }
        return await PhoneQuickEdits.canEditTransaction(transactionId, writer: writer, dbReader: dbQueue)
    }

    /// Whether the account shows "Update balance".
    public func canUpdateBalance(accountId: Int64) async -> Bool {
        guard let writer else { return false }
        return await PhoneQuickEdits.canUpdateBalance(accountId: accountId, writer: writer, dbReader: dbQueue)
    }

    /// Reads the category choices and the quick-sort queue (this pay month's uncategorised rows the user can edit).
    public func load() async {
        guard let writer else {
            queue = []
            return
        }
        let property = await writer.canEdit(.property)
        let budget = await writer.canEdit(.budgetAndAccounts)
        let day = today()
        let viewer = viewer
        do {
            let (cards, lists) = try await dbQueue.read { db in
                try Self.readQueue(db, today: day, viewer: viewer, canEditProperty: property, canEditBudget: budget)
            }
            queue = cards
            self.lists = lists
        } catch {
            // A failed read keeps what was shown.
        }
    }

    nonisolated static func readQueue(_ db: Database, today: Date, viewer: PhoneViewer, canEditProperty: Bool,
                                      canEditBudget: Bool) throws -> ([PhoneQuickEdits.QuickSortCard], QuickEditLists) {
        let input = try DashboardInput.load(db: db, today: today)
        let range = PayMonthReview.make(month: input.payCalendar.current, input: input).range
        let cards = try PhoneQuickEdits.quickSortQueue(db: db, viewer: viewer, payMonth: range) { area in
            switch area {
            case .property: canEditProperty
            case .budgetAndAccounts: canEditBudget
            default: false
            }
        }
        return (cards, try readLists(db))
    }

    /// The queue and the category choices, now, as an editor of both areas (the snapshot routes).
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, today: Date, viewer: PhoneViewer) -> ([PhoneQuickEdits.QuickSortCard], QuickEditLists) {
        (try? dbQueue.read { db in
            try readQueue(db, today: today, viewer: viewer, canEditProperty: true, canEditBudget: true)
        }) ?? ([], QuickEditLists())
    }

    /// The category choices, now (the snapshot routes).
    public nonisolated static func readListsNow(_ dbQueue: any DatabaseReader) -> QuickEditLists {
        (try? dbQueue.read { db in try readLists(db) }) ?? QuickEditLists()
    }

    nonisolated static func readLists(_ db: Database) throws -> QuickEditLists {
        let used = try Int64.fetchAll(db, sql: """
            SELECT categoryId FROM transaction_ WHERE categoryId IS NOT NULL GROUP BY categoryId ORDER BY COUNT(*) DESC, categoryId
            """)
        return QuickEditLists(categories: try Category.fetchAll(db).filter(\.isAssignable), groups: try CategoryGroup.fetchAll(db), mostUsed: used)
    }

    /// A transaction as the search lists it (what the detail sheet shows), or nil if it is gone.
    public func row(transactionId: Int64) async -> TransactionSearch.Row? {
        let reader = dbQueue
        return try? await reader.read { db -> TransactionSearch.Row? in
            guard let transaction = try Transaction.fetchOne(db, key: transactionId) else { return nil }
            let input = TransactionSearch.Input(transactions: [transaction], categories: try Category.fetchAll(db),
                                                accounts: try Account.fetchAll(db), links: try TransferLink.fetchAll(db),
                                                eurToGbpRate: try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate)
            return TransactionSearch.Index(input).allRows.first
        }
    }

    // MARK: Writes

    /// The sheet's Save: category and note together, only now. True when it saved; else `refusal` says why.
    public func save(transactionId: Int64, categoryId: Int64?, note: String?) async -> Bool {
        guard let writer else { return false }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await PhoneQuickEdits.categorise(writer: writer, transactionId: transactionId, categoryId: categoryId,
                                                 note: trimmed?.isEmpty == false ? trimmed : nil)
        } catch {
            refusal = Self.text(for: error)
            return false
        }
        refusal = nil
        if monthDetail?.id == transactionId { monthDetail = await row(transactionId: transactionId) }
        await onChange?()
        return true
    }

    /// A quick-sort category button: saves at once, drops the card and offers Undo.
    public func pick(card: PhoneQuickEdits.QuickSortCard, categoryId: Int64) async {
        guard let writer else { return }
        do {
            let token = try await PhoneQuickEdits.pick(writer: writer, card: card, categoryId: categoryId)
            refusal = nil
            queue.removeAll { $0.id == card.id }
            show(UndoToast(message: DeviceWriteCopy.categorisedToast(lists.name(of: categoryId) ?? "category"), token: token))
        } catch {
            refusal = Self.text(for: error)
            return
        }
        await onChange?()
    }

    /// The toast's Undo: the card goes back where it was.
    public func undo() async {
        guard let writer, let token = toast?.token else { return }
        do {
            try await PhoneQuickEdits.undo(writer: writer, token: token)
        } catch {
            clearToast()
            refusal = Self.text(for: error)
            return
        }
        refusal = nil
        show(UndoToast(message: DeviceWriteCopy.undoneToast, token: nil))
        await load()
        await onChange?()
    }

    /// Update balance's Save. True when it saved; else `refusal` says why.
    public func updateBalance(accountId: Int64, enteredMinorUnits: Int, asOf: Date, note: String?) async -> Bool {
        guard let writer else { return false }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await PhoneQuickEdits.updateManualBalance(writer: writer, accountId: accountId, enteredMinorUnits: enteredMinorUnits, asOf: asOf,
                                                              note: trimmed?.isEmpty == false ? trimmed : nil)
        } catch {
            refusal = Self.text(for: error)
            return false
        }
        refusal = nil
        await onChange?()
        return true
    }

    // MARK: Toast

    private func show(_ new: UndoToast) {
        toastTask?.cancel()
        toast = new
        let id = new.id
        let duration = toastDuration
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismissToast(id)
        }
    }

    private func dismissToast(_ id: UUID) {
        if toast?.id == id { toast = nil }
    }

    private func clearToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// A day the user picked, as balance snapshots store it: the same calendar day at UTC midnight.
    nonisolated static func snapshotDay(_ date: Date) -> Date {
        MonthRange.calendar.date(from: Calendar.current.dateComponents([.year, .month, .day], from: date)) ?? date
    }

    nonisolated static func text(for error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return DeviceWriteCopy.notSaved
    }
}
