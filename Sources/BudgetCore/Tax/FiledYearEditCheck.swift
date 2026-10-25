import Foundation
import GRDB
import SQLite3

/// Filed returns never change silently (plan Task 14, 2026-10-24): an edit made by hand — Edit
/// transaction, a category set in the grid, Search or Uncategorized, a rule applied to the
/// uncategorised, a manual tax item — that would move a figure on a filed or paid Self Assessment
/// return (`FiledYearSyncCheck`'s protected years and people) is put to the person first, with
/// each return box it moves ("SA106 … box 17 £1,000.00 → £1,250.00"), and three answers:
/// - **Mark as not counted** (`Resolution.markNotCounted`): the edit is saved and each source it
///   touched is marked "deductible, not claimed" in those years (`TaxNotClaimedSources.set`, with
///   a note naming the edit and the day), so the filed figures stay as filed. Offered only when
///   that keeps every filed figure (`Question.canMarkNotCounted`).
/// - **Save anyway** (`.saveAnyway`): saved as it is; the year's `TaxYear.notes` records what changed
///   after filing (`changedAfterFilingPrefix`).
/// - **Cancel**: `save` was asked without a resolution and wrote nothing.
///
/// `save` runs the edit in savepoints that are rolled back to look at it, so `apply` may run up to
/// three times from the same state: it must only write to the database. A batch (a rule applied
/// to every matching transaction) is one `apply`: one question for all it moves.
///
/// Cheap first: a trial run (rolled back) records the rows `apply` writes. When it writes only
/// transactions and manual tax items — besides tables no tax figure reads (`unreadTables`) — the
/// years are narrowed: a transaction counts only when it is in a property's category before or
/// after (or a tax record points at it), and it can reach the years from three before its tax year
/// on (the rental accounts' window, `RentalAccounts.compute`; later years carry its figures
/// forward); a manual tax item, its year on. No protected year among them: saved, no figures
/// taken. Anything else written checks every protected year.
public enum FiledYearEditCheck {
    /// The answer to a `Question`.
    public enum Resolution: Equatable, Sendable {
        case markNotCounted
        case saveAnyway
    }

    /// What `save` did: saved (with `apply`'s result), or nothing written and a question to ask.
    public enum Outcome<T> {
        case saved(T)
        case asks(Question)
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// "Mark as not counted" chosen, but the marks don't keep these years ("2022/23") as filed.
        case notCountedStillChanges(years: [String])

        public var errorDescription: String? {
            switch self {
            case .notCountedStillChanges(let years):
                return "Not saved: marking it as not counted wouldn't keep the filed \(FiledYearEditCheck.list(years)) "
                    + (years.count == 1 ? "return" : "returns") + " as filed."
            }
        }
    }

    /// What an edit would change on filed or paid returns.
    public struct Question: Equatable, Sendable, Identifiable {
        /// One return box that moves.
        public struct Line: Equatable, Sendable {
            /// Whose return, when the year's question covers more than one person's.
            public var person: String?
            /// "SA106 Land and property abroad box 17 Property expenses".
            public var box: String
            public var before: String
            public var after: String

            public init(person: String?, box: String, before: String, after: String) {
                self.person = person
                self.box = box
                self.before = before
                self.after = after
            }

            /// "SA106 … box 17 Property expenses £1,000.00 → £1,250.00", after "Person A · " when named.
            public var text: String { (person.map { "\($0) · " } ?? "") + "\(box) \(before) → \(after)" }
        }

        /// A year whose filed (or paid) return moves.
        public struct Year: Equatable, Sendable, Identifiable {
            public var startYear: Int
            /// Paid, not only filed (for everyone it names).
            public var isPaid: Bool
            /// The people whose return moves.
            public var people: [String]
            public var lines: [Line]
            public var id: Int { startYear }

            public init(startYear: Int, isPaid: Bool, people: [String], lines: [Line]) {
                self.startYear = startYear
                self.isPaid = isPaid
                self.people = people
                self.lines = lines
            }

            /// "2022/23".
            public var label: String { UKTaxYear(startYear: startYear).label }

            /// "This changes your filed 2022/23 return:" — "the filed 2022/23 returns of Person A and Person B" for several.
            public var title: String {
                let state = isPaid ? "paid" : "filed"
                guard people.count > 1 else { return "This changes your \(state) \(label) return:" }
                return "This changes the \(state) \(label) returns of \(FiledYearEditCheck.list(people)):"
            }
        }

        /// What the edit was ("Edit transaction", "Set category to Repairs"), for the marks' notes.
        public var edit: String
        public var years: [Year]
        /// The years "Mark as not counted" marks a source in (empty: it can't keep every filed
        /// figure as filed, and isn't offered). A later year that only carries a figure forward
        /// isn't marked: it is kept by the earlier year's mark.
        public var markYears: [Int]

        public init(edit: String, years: [Year], markYears: [Int]) {
            self.edit = edit
            self.years = years
            self.markYears = markYears
        }

        /// Marking the sources touched as not counted keeps every filed figure as filed.
        public var canMarkNotCounted: Bool { !markYears.isEmpty }

        public var id: String { edit + years.map(\.label).joined(separator: ",") }

        /// "2022/23", "2022/23 and 2023/24".
        public var yearsLabel: String { FiledYearEditCheck.list(years.map(\.label)) }

        /// "Mark as not counted for 2022/23 and save".
        public var markTitle: String {
            "Mark as not counted for \(FiledYearEditCheck.list(markYears.map { UKTaxYear(startYear: $0).label })) and save"
        }
    }

    /// The start of each line `.saveAnyway` adds to a year's notes.
    public static let changedAfterFilingPrefix = "Changed after filing"

    /// Tables no tax figure reads (asserted against what `TaxFigures.snapshot` reads, in the tests):
    /// writing them alone never asks. Rules, sync bookkeeping, files kept for later.
    static let unreadTables: Set<String> = [
        "rule", "importWaitingFile", "syncPending", "syncFieldClock", "syncRecord", "syncTombstone", "syncState",
        "syncWriter", "syncConflict", "syncStaging"
    ]

    /// Runs `apply` (in the caller's write) unless it would move a figure on a filed or paid return:
    /// then, without `resolution`, writes nothing and returns the question; with one, saves as
    /// it says. `edit` names the edit in the question and the notes; `now` dates the notes.
    public static func save<T>(db: Database, edit: String, resolution: Resolution? = nil, now: Date = Date(),
                               _ apply: () throws -> T) throws -> Outcome<T> {
        try save(db: db, edit: edit, resolution: resolution, now: now, onSnapshot: {}, apply)
    }

    /// `save`, calling `onSnapshot` for each set of figures taken (tests count them).
    static func save<T>(db: Database, edit: String, resolution: Resolution?, now: Date, onSnapshot: () -> Void,
                        _ apply: () throws -> T) throws -> Outcome<T> {
        let scope = try self.scope(db: db, apply)
        guard !scope.years.isEmpty else { return .saved(try apply()) }
        onSnapshot()
        let before = try TaxFigures.snapshot(db: db, only: scope.years)
        var result: T?
        var impacts: [FiledYearImpact] = []
        var remaining: [FiledYearImpact] = []
        try db.inSavepoint {
            result = try apply()
            onSnapshot()
            impacts = FiledYearSyncCheck.protectedImpacts(before: before, after: try TaxFigures.snapshot(db: db, only: scope.years))
            guard !impacts.isEmpty else { return .commit }
            switch resolution {
            case nil:
                return .rollback
            case .saveAnyway:
                try note(db: db, impacts: impacts, edit: edit, now: now)
                return .commit
            case .markNotCounted:
                remaining = try markNotCounted(db: db, scope: scope, impacts: impacts, before: before, edit: edit, now: now,
                                               onSnapshot: onSnapshot).remaining
                return remaining.isEmpty ? .commit : .rollback
            }
        }
        guard !impacts.isEmpty else { return .saved(result!) }
        switch resolution {
        case .saveAnyway:
            return .saved(result!)
        case .markNotCounted:
            guard remaining.isEmpty else { throw Failure.notCountedStillChanges(years: labels(remaining)) }
            return .saved(result!)
        case nil:
            // Would the marks keep the filed figures? Tried, and rolled back.
            var markYears: [Int] = []
            if !scope.sources.isEmpty {
                try db.inSavepoint {
                    _ = try apply()
                    let marked = try markNotCounted(db: db, scope: scope, impacts: impacts, before: before, edit: edit, now: now,
                                                    onSnapshot: onSnapshot)
                    if marked.remaining.isEmpty { markYears = marked.years }
                    return .rollback
                }
            }
            return .asks(question(edit: edit, impacts: impacts, markYears: markYears))
        }
    }

    // MARK: The question

    static func question(edit: String, impacts: [FiledYearImpact], markYears: [Int]) -> Question {
        let years = Dictionary(grouping: impacts, by: \.startYear).sorted { $0.key < $1.key }.map { startYear, impacts in
            let people = impacts.map(\.person).sorted()
            let named = people.count > 1
            let lines = impacts.sorted { $0.person < $1.person }.flatMap { impact in
                boxLines(impact).map { Question.Line(person: named ? impact.person : nil, box: $0.label, before: $0.before, after: $0.after) }
            }
            return Question.Year(startYear: startYear, isPaid: impacts.allSatisfy(\.isPaid), people: people, lines: lines)
        }
        return Question(edit: edit, years: years, markYears: markYears)
    }

    /// The impact's return boxes; the calculation's lines ("calculation · income tax due") only
    /// when no box moves (a figure the boxes don't show).
    static func boxLines(_ impact: FiledYearImpact) -> [FiledYearImpact.Line] {
        let calculation = "calculation · "
        let boxes = impact.returnChanges.filter { !$0.label.hasPrefix(calculation) }
        guard boxes.isEmpty else { return boxes }
        return impact.returnChanges.map { line in
            var line = line
            if line.label.hasPrefix(calculation) { line.label = "SA calculation: " + line.label.dropFirst(calculation.count) }
            return line
        }
    }

    // MARK: Resolutions

    /// Marks each source the edit touched as not counted in the years of `impacts` (a source that
    /// feeds no deductible line there is left alone), and returns what still differs from `before`
    /// and the years a source was marked in.
    private static func markNotCounted(db: Database, scope: Scope, impacts: [FiledYearImpact], before: TaxFigures.Snapshot,
                                       edit: String, now: Date, onSnapshot: () -> Void) throws -> (remaining: [FiledYearImpact], years: [Int]) {
        var marked = Set<Int>()
        for year in Set(impacts.map(\.startYear)).sorted() {
            let notes = "Not counted: \(edit) on \(day(now)), after the \(UKTaxYear(startYear: year).label) return was filed"
            for source in scope.sources {
                do {
                    try TaxNotClaimedSources.set(db: db, startYear: year, reference: source, notClaimed: true, notes: notes)
                    marked.insert(year)
                } catch let error as TaxError where [.notASourceOfTheYear, .notClaimable, .transactionNotFound, .sourceNotFound].contains(error) {
                    continue
                }
            }
        }
        onSnapshot()
        let remaining = FiledYearSyncCheck.protectedImpacts(before: before, after: try TaxFigures.snapshot(db: db, only: scope.years))
        return (remaining, marked.sorted())
    }

    /// `.saveAnyway`: a line per (year, person) on that year's notes — "Changed after filing on
    /// 2026-10-25 (Set category to Repairs): SA106 … box 17 £1,000.00 → £1,250.00".
    private static func note(db: Database, impacts: [FiledYearImpact], edit: String, now: Date) throws {
        let people = try Person.fetchAll(db)
        for impact in impacts {
            guard let personId = people.first(where: { $0.name == impact.person })?.id,
                  var year = try TaxYear.filter(Column("startYear") == impact.startYear && Column("personId") == personId).fetchOne(db)
            else { continue }
            let changes = boxLines(impact).map { "\($0.label) \($0.before) → \($0.after)" }.joined(separator: "; ")
            let line = "\(changedAfterFilingPrefix) on \(day(now)) (\(edit)): \(changes)"
            year.notes = [year.notes, line].compactMap { $0 }.joined(separator: "\n")
            try year.update(db)
        }
    }

    /// The lines `.saveAnyway` added to the notes, oldest first.
    public static func changesAfterFiling(_ notes: String?) -> [String] {
        (notes ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix(changedAfterFilingPrefix) }
    }

    // MARK: Scope

    /// The protected years an edit can move, and the sources it touches (what "not counted" marks).
    struct Scope {
        var years: [Int]
        var sources: [RentalAccounts.SourceReference]
    }

    /// What a transaction is, as far as the tax figures read it.
    private struct TransactionFacts: Equatable {
        var date: Date
        var accountId: Int64
        var amount: Int
        var categoryId: Int64?
        var description: String
        var note: String?

        init(_ transaction: Transaction) {
            date = transaction.date
            accountId = transaction.accountId
            amount = transaction.amountMinorUnits
            categoryId = transaction.categoryId
            description = transaction.rawDescription
            note = transaction.note
        }
    }

    /// Runs `apply` once in a savepoint (rolled back) to see what it writes, and works out the
    /// years to check from it.
    static func scope(db: Database, _ apply: () throws -> some Any) throws -> Scope {
        let protected = Set(FiledYearSyncCheck.fixedYears).union(try FiledYearGuard.filedYears(db: db)).sorted()
        guard !protected.isEmpty else { return Scope(years: [], sources: []) }
        var written: [String: Set<Int64>]?
        var transactionsAfter: [Int64: TransactionFacts] = [:]
        var itemYearsAfter: [Int64: Int] = [:]
        try db.inSavepoint {
            written = try writtenRows(db: db) { _ = try apply() }
            if let written {
                transactionsAfter = try transactionFacts(db: db, ids: written["transaction_"] ?? [])
                itemYearsAfter = try itemYears(db: db, ids: written["taxManualItem"] ?? [])
            }
            return .rollback
        }
        guard let written else { return Scope(years: protected, sources: []) }
        let transactionIds = written["transaction_"] ?? []
        let itemIds = written["taxManualItem"] ?? []
        let transactionsBefore = try transactionFacts(db: db, ids: transactionIds)
        let itemYearsBefore = try itemYears(db: db, ids: itemIds)

        // The transactions whose change the tax figures can see.
        let propertyCategories = try propertyCategoryIds(db: db)
        let referenced = try referencedTransactionIds(db: db, among: transactionIds)
        var earliest: Int?
        var everyYear = false
        var sources: [RentalAccounts.SourceReference] = []
        for id in transactionIds.sorted() {
            let old = transactionsBefore[id], new = transactionsAfter[id]
            guard old != new else { continue }
            let facts = [old, new].compactMap { $0 }
            if referenced.contains(id) {
                everyYear = true
            } else if !facts.contains(where: { $0.categoryId.map(propertyCategories.contains) == true }) {
                continue
            }
            for fact in facts {
                let year = UKTaxYear.containing(fact.date).startYear - 3
                earliest = min(earliest ?? year, year)
            }
            if new != nil { sources.append(.transaction(id)) }
        }
        for id in itemIds.sorted() {
            let years = [itemYearsBefore[id], itemYearsAfter[id]].compactMap { $0 }
            guard let first = years.min() else { continue }
            earliest = min(earliest ?? first, first)
            if itemYearsAfter[id] != nil { sources.append(.manualItem(id)) }
        }
        let other = Set(written.keys).subtracting(["transaction_", "taxManualItem"]).subtracting(unreadTables)
        if everyYear || !other.isEmpty { return Scope(years: protected, sources: sources) }
        guard let earliest else { return Scope(years: [], sources: []) }
        return Scope(years: protected.filter { $0 >= earliest }, sources: sources)
    }

    private static func transactionFacts(db: Database, ids: Set<Int64>) throws -> [Int64: TransactionFacts] {
        guard !ids.isEmpty else { return [:] }
        var facts: [Int64: TransactionFacts] = [:]
        for transaction in try Transaction.filter(keys: ids).fetchAll(db) {
            if let id = transaction.id { facts[id] = TransactionFacts(transaction) }
        }
        return facts
    }

    private static func itemYears(db: Database, ids: Set<Int64>) throws -> [Int64: Int] {
        guard !ids.isEmpty else { return [:] }
        var years: [Int64: Int] = [:]
        for item in try TaxManualItem.filter(keys: ids).fetchAll(db) {
            if let id = item.id { years[id] = item.startYear }
        }
        return years
    }

    /// Every property's categories (the rental accounts read transactions in them only).
    private static func propertyCategoryIds(db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: """
            SELECT category.id FROM category JOIN propertyCategoryGroup ON propertyCategoryGroup.categoryGroupId = category.groupId
            """))
    }

    /// Those of `ids` a tax record points at (an insurer's receipt, a rent receipt or recharge link,
    /// an owner assignment, a "not claimed" mark): their year isn't their date's.
    private static func referencedTransactionIds(db: Database, among ids: Set<Int64>) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        var found = Set<Int64>()
        for table in ["taxPolicyReceipt", "rentReceiptPayment", "rechargePayment", "taxTransactionOwner", "taxNotClaimed"] {
            guard try db.tableExists(table), try db.columns(in: table).contains(where: { $0.name == "transactionId" }) else { continue }
            found.formUnion(try Int64.fetchAll(db, sql: "SELECT transactionId FROM \(table) WHERE transactionId IN (\(list))"))
        }
        return found
    }

    /// `body` run, and the rows it wrote by table (SQLite's update hook: inserted, updated or
    /// deleted rowids). Nil when that can't be told (as `TaxFiguresReads.writtenTables`: a write
    /// not reported — a nested check took the hook, a table emptied at once — or the schema changed).
    static func writtenRows(db: Database, _ body: () throws -> Void) throws -> [String: Set<Int64>]? {
        final class Written {
            var rows: [String: Set<Int64>] = [:]
            var count = 0
        }
        let written = Written()
        let schema = try db.schemaVersion()
        let changes = db.totalChangesCount
        let context = Unmanaged.passUnretained(written).toOpaque()
        let previous = sqlite3_update_hook(db.sqliteConnection, { context, _, _, table, rowid in
            let written = Unmanaged<Written>.fromOpaque(context!).takeUnretainedValue()
            written.count += 1
            if let table { written.rows[String(cString: table), default: []].insert(rowid) }
        }, context)
        do {
            defer { sqlite3_update_hook(db.sqliteConnection, nil, nil) }
            try withExtendedLifetime(written) { try body() }
        }
        guard previous == nil, try db.schemaVersion() == schema, written.count == db.totalChangesCount - changes else { return nil }
        return written.rows
    }

    // MARK: Formatting

    private static func labels(_ impacts: [FiledYearImpact]) -> [String] {
        Set(impacts.map(\.startYear)).sorted().map { UKTaxYear(startYear: $0).label }
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    private static func day(_ date: Date) -> String {
        let components = MonthRange.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
