import Foundation
import GRDB

/// Filed returns never change silently (plan Task 14, 2026-10-24): an edit made by hand — a
/// transaction's category, fields or deletion, a rule filing the uncategorised, a manual tax item,
/// the categories and properties the rental accounts read, receipt and recharge matching, the tax
/// settings — that would move a figure on a filed or paid Self Assessment return
/// (`FiledYearSyncCheck`'s protected years and people) is put to the person first, with each
/// return box it moves ("SA106 … box 17 £1,000.00 → £1,250.00"), and up to three answers:
/// - **Mark as not counted** (`Resolution.markNotCounted`): the edit is saved, and each source of
///   the edit whose figures moved (a transaction or manual item) is marked "deductible, not
///   claimed" in the years it moved them (`TaxNotClaimedSources.set`; the note names the edit and
///   the day, after any note the mark had), so the filed figures stay as filed. Offered only when
///   that keeps every filed figure (`Question.canMarkNotCounted`): never for a setting, a
///   structure change or a deletion.
/// - **Save anyway** (`.saveAnyway`): saved as it is; each (year, person) whose return moved gets
///   a line on its `TaxYear.notes` (the row is created when missing; `changedAfterFilingPrefix`),
///   which the year's return shows as differing from the filed one
///   (`TaxOverview.YearRow.changedAfterFiling`).
/// - **Cancel**: `save` was asked without a resolution and wrote nothing.
///
/// `save` runs the edit in savepoints that are rolled back to look at it, so `apply` may run up to
/// three times from the same state: it must only write to the database. A batch (a rule filing
/// every matching transaction) is one `apply`: one question for all it moves.
///
/// Cheap first: the caller declares what the edit reaches (`Scope`): the transactions it changes,
/// the dates and categories it gives, the manual items, the years of a setting, or every year.
/// The years to check are worked out from that with a few reads, before `apply` runs: a
/// transaction counts only in a property's category (before, or the one it is given) or when a
/// tax record points at it, and reaches the years from three before its tax year on (the rental
/// accounts' window, `RentalAccounts.compute`; later years carry its figures forward); a year
/// reaches itself and later ones. No protected year among them: `apply` runs once and no figures
/// are taken.
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

    /// What an edit reaches, declared by its caller (see the type's notes).
    public struct Scope: Equatable, Sendable {
        /// Existing transactions the edit changes or deletes (their date and category as stored count).
        public var transactionIds: [Int64]
        /// Dates the edit gives transactions (a new row's, a moved row's).
        public var dates: [Date]
        /// Categories the edit gives transactions (nil: uncategorised).
        public var categoryIds: [Int64?]
        /// Manual tax items the edit changes or deletes.
        public var manualItemIds: [Int64]
        /// UK tax years the edit reaches directly (a manual item's, a setting's): them and later ones.
        public var years: [Int]
        /// Every protected year (a setting of every year, the categories or a property).
        public var everyYear: Bool

        public init(transactionIds: [Int64] = [], dates: [Date] = [], categoryIds: [Int64?] = [], manualItemIds: [Int64] = [],
                    years: [Int] = [], everyYear: Bool = false) {
            self.transactionIds = transactionIds
            self.dates = dates
            self.categoryIds = categoryIds
            self.manualItemIds = manualItemIds
            self.years = years
            self.everyYear = everyYear
        }

        /// Every protected year.
        public static let everyYear = Scope(everyYear: true)

        /// `year` (a UK tax year's start) and later ones.
        public static func from(year: Int) -> Scope { Scope(years: [year]) }

        /// Transactions `ids` given `categoryId` (Set category…, an assignment, a rule's filing).
        public static func categorising(_ ids: [Int64], as categoryId: Int64?) -> Scope {
            Scope(transactionIds: ids, categoryIds: [categoryId])
        }

        /// A change to categories `ids` (renamed, moved, deleted) or to the categories of groups
        /// `groupIds` (a group deleted; a group they move into): every year when one of them is, or
        /// becomes, a property's category (the rental accounts read those, and a name suggests its
        /// tax line), else none.
        public static func categories(db: Database, ids: [Int64] = [], groupIds: [Int64] = []) throws -> Scope {
            let propertyGroups = Set(try Int64.fetchAll(db, sql: "SELECT categoryGroupId FROM propertyCategoryGroup"))
            if groupIds.contains(where: propertyGroups.contains) { return .everyYear }
            let groups = try Category.filter(keys: ids).fetchAll(db).compactMap(\.groupId)
            return groups.contains(where: propertyGroups.contains) ? .everyYear : Scope()
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// "Mark as not counted" chosen, but the marks don't keep these years ("2022/23") as filed.
        case notCountedStillChanges(years: [String])

        public var errorDescription: String? {
            switch self {
            case .notCountedStillChanges(let years):
                return "Not saved: marking it as not counted wouldn't keep the \(FiledYearEditCheck.list(years)) "
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

            /// "This changes your filed 2022/23 return:" ("paid" for a paid year); "the filed 2022/23
            /// returns of Person A and Person B" for several.
            public var title: String {
                let state = isPaid ? "paid" : "filed"
                guard people.count > 1 else { return "This changes your \(state) \(label) return:" }
                return "This changes the \(state) \(label) returns of \(FiledYearEditCheck.list(people)):"
            }
        }

        /// What the edit was ("Categorised as Repairs", "Owners of Property A changed"), for the notes.
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

        /// Marking the sources moved as not counted keeps every filed figure as filed.
        public var canMarkNotCounted: Bool { !markYears.isEmpty }

        public var id: String { edit + years.map(\.label).joined(separator: ",") }

        /// "2022/23", "2022/23, 2023/24 and 2024/25".
        public var yearsLabel: String { FiledYearEditCheck.list(years.map(\.label)) }

        /// "A filed return would change", "Paid returns would change", "Filed and paid returns would change".
        public var heading: String {
            let paid = years.filter(\.isPaid).count
            let state = paid == 0 ? "filed" : paid == years.count ? "paid" : "filed and paid"
            let plural = years.count > 1 || years.contains { $0.people.count > 1 }
            return plural ? "\(state.prefix(1).uppercased() + state.dropFirst()) returns would change" : "A \(state) return would change"
        }

        /// "Mark as not counted for 2022/23 and save", "… for 2022/23, 2023/24 and save".
        public var markTitle: String {
            "Mark as not counted for \(markYears.map { UKTaxYear(startYear: $0).label }.joined(separator: ", ")) and save"
        }
    }

    /// The start of each line `.saveAnyway` adds to a year's notes.
    public static let changedAfterFilingPrefix = "Changed after filing"

    /// Runs `apply` (in the caller's write) unless it would move a figure on a filed or paid return:
    /// then, without `resolution`, writes nothing and returns the question; with one, saves as
    /// it says. `edit` names the edit in the question and the notes; `scope` is what it reaches;
    /// `now` dates the notes.
    public static func save<T>(db: Database, edit: String, scope: Scope, resolution: Resolution? = nil, now: Date = Date(),
                               _ apply: () throws -> T) throws -> Outcome<T> {
        try save(db: db, edit: edit, scope: scope, resolution: resolution, now: now, onSnapshot: {}, apply)
    }

    /// `save`, calling `onSnapshot` for each set of figures taken (tests count them).
    static func save<T>(db: Database, edit: String, scope: Scope, resolution: Resolution?, now: Date, onSnapshot: () -> Void,
                        _ apply: () throws -> T) throws -> Outcome<T> {
        let years = try candidateYears(db: db, scope: scope)
        guard !years.isEmpty else { return .saved(try apply()) }
        let sources = Set(scope.transactionIds.map(RentalAccounts.SourceReference.transaction)
            + scope.manualItemIds.map(RentalAccounts.SourceReference.manualItem))
        onSnapshot()
        let beforeMemo = TaxComputationMemo()
        let before = try TaxFigures.snapshot(db: db, only: years, memo: beforeMemo)
        let newRowsFrom = try maxIds(db: db)

        /// Runs `apply` (in the caller's savepoint): its result, the impacts, and the sources it moved by year.
        func run() throws -> (T, [FiledYearImpact], [Int: Set<RentalAccounts.SourceReference>]) {
            let result = try apply()
            onSnapshot()
            let afterMemo = TaxComputationMemo()
            let after = try TaxFigures.snapshot(db: db, only: years, memo: afterMemo)
            let impacts = FiledYearSyncCheck.protectedImpacts(before: before, after: after)
            guard !impacts.isEmpty else { return (result, [], [:]) }
            let candidates = sources.union(try newSources(db: db, since: newRowsFrom))
            let moved = try movedSources(db: db, years: Set(impacts.map(\.startYear)), candidates: candidates,
                                         before: beforeMemo, after: afterMemo)
            return (result, impacts, moved)
        }

        var result: T?
        var impacts: [FiledYearImpact] = []
        var moved: [Int: Set<RentalAccounts.SourceReference>] = [:]
        var remaining: [FiledYearImpact] = []
        try db.inSavepoint {
            (result, impacts, moved) = try run()
            guard !impacts.isEmpty else { return .commit }
            switch resolution {
            case nil:
                return .rollback
            case .saveAnyway:
                try note(db: db, impacts: impacts, edit: edit, now: now)
                return .commit
            case .markNotCounted:
                remaining = try markNotCounted(db: db, moved: moved, before: before, years: years, edit: edit, now: now,
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
            if !moved.isEmpty {
                try db.inSavepoint {
                    _ = try apply()
                    let marked = try markNotCounted(db: db, moved: moved, before: before, years: years, edit: edit, now: now,
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

    /// Marks each moved source as not counted in the years it moved (a source that feeds no
    /// deductible line there is left alone; an existing mark keeps its note, the new one after it),
    /// and returns what still differs from `before` and the years a source was marked in.
    private static func markNotCounted(db: Database, moved: [Int: Set<RentalAccounts.SourceReference>], before: TaxFigures.Snapshot,
                                       years: [Int], edit: String, now: Date,
                                       onSnapshot: () -> Void) throws -> (remaining: [FiledYearImpact], years: [Int]) {
        var marked = Set<Int>()
        for (year, sources) in moved.sorted(by: { $0.key < $1.key }) {
            let note = "Not counted: \(edit) on \(day(now)), after the \(UKTaxYear(startYear: year).label) return was filed"
            for source in sources.sorted(by: { "\($0)" < "\($1)" }) {
                let existing = try TaxNotClaimedSources.marks(db: db, startYear: year)[source]?.notes
                do {
                    try TaxNotClaimedSources.set(db: db, startYear: year, reference: source, notClaimed: true,
                                                 notes: [existing, note].compactMap { $0 }.joined(separator: "; "))
                    marked.insert(year)
                } catch let error as TaxError where [.notASourceOfTheYear, .notClaimable, .transactionNotFound, .sourceNotFound].contains(error) {
                    continue
                }
            }
        }
        onSnapshot()
        let remaining = FiledYearSyncCheck.protectedImpacts(before: before, after: try TaxFigures.snapshot(db: db, only: years))
        return (remaining, marked.sorted())
    }

    /// `.saveAnyway`: a line on the notes of each (year, person) whose return moved (the year's
    /// row created when missing) — "Changed after filing on 2026-10-25 (Categorised as Repairs):
    /// SA106 … box 17 £1,000.00 → £1,250.00".
    private static func note(db: Database, impacts: [FiledYearImpact], edit: String, now: Date) throws {
        let people = try Person.fetchAll(db)
        for impact in impacts {
            guard let personId = people.first(where: { $0.name == impact.person })?.id else { continue }
            var year = try TaxYears.ensure(db: db, startYear: impact.startYear, personId: personId)
            let changes = boxLines(impact).map { "\($0.label) \($0.before) → \($0.after)" }.joined(separator: "; ")
            let line = "\(changedAfterFilingPrefix) on \(day(now)) (\(edit)): \(changes)"
            year.notes = [year.notes, line].compactMap { $0 }.joined(separator: "\n")
            try year.save(db)
        }
    }

    /// The lines `.saveAnyway` added to the notes, oldest first.
    public static func changesAfterFiling(_ notes: String?) -> [String] {
        (notes ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix(changedAfterFilingPrefix) }
    }

    // MARK: Which years

    /// The protected years (`FiledYearSyncCheck`: 2020/21–2024/25 and any year stored filed or paid).
    public static func protectedYears(db: Database) throws -> [Int] {
        Set(FiledYearSyncCheck.fixedYears).union(try FiledYearGuard.filedYears(db: db)).sorted()
    }

    /// The protected years `scope` can reach (empty: none, nothing to check). Reads only.
    public static func candidateYears(db: Database, scope: Scope) throws -> [Int] {
        let protected = try protectedYears(db: db)
        guard !protected.isEmpty else { return [] }
        if scope.everyYear { return protected }
        var earliest = scope.years.min()
        func reach(_ date: Date) {
            let year = UKTaxYear.containing(date).startYear - 3
            earliest = min(earliest ?? year, year)
        }
        let propertyCategories = try propertyCategoryIds(db: db)
        let givesPropertyCategory = scope.categoryIds.contains { $0.map(propertyCategories.contains) == true }
        let ids = Set(scope.transactionIds)
        if !ids.isEmpty {
            if try !referencedTransactionIds(db: db, among: ids).isEmpty { return protected }
            for transaction in try Transaction.filter(keys: ids).fetchAll(db)
            where givesPropertyCategory || transaction.categoryId.map(propertyCategories.contains) == true {
                reach(transaction.date)
                // Moved to new dates: those count too.
                scope.dates.forEach(reach)
            }
        }
        if givesPropertyCategory { scope.dates.forEach(reach) }
        if !scope.manualItemIds.isEmpty {
            for item in try TaxManualItem.filter(keys: scope.manualItemIds).fetchAll(db) {
                earliest = min(earliest ?? item.startYear, item.startYear)
            }
        }
        guard let earliest else { return [] }
        return protected.filter { $0 >= earliest }
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

    // MARK: Which sources moved

    /// The highest transaction and manual item ids now (rows above them are new).
    private static func maxIds(db: Database) throws -> (transaction: Int64, item: Int64) {
        (try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM transaction_") ?? 0,
         try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM taxManualItem") ?? 0)
    }

    /// Transactions and manual items added since `maxIds` was taken.
    private static func newSources(db: Database, since: (transaction: Int64, item: Int64)) throws -> Set<RentalAccounts.SourceReference> {
        Set(try Int64.fetchAll(db, sql: "SELECT id FROM transaction_ WHERE id > ?", arguments: [since.transaction]).map { .transaction($0) }
            + Int64.fetchAll(db, sql: "SELECT id FROM taxManualItem WHERE id > ?", arguments: [since.item]).map { .manualItem($0) })
    }

    /// Of `candidates`, those whose deductible amounts in `years`' rental accounts differ between
    /// the figures taken with `before` and `after` (each memo holds that state's accounts), by year:
    /// the sources a "not counted" mark could put back. A source moved from one deductible line to
    /// another for the same amount isn't one (marking it would take a filed cost off).
    private static func movedSources(db: Database, years: Set<Int>, candidates: Set<RentalAccounts.SourceReference>,
                                     before: TaxComputationMemo, after: TaxComputationMemo) throws -> [Int: Set<RentalAccounts.SourceReference>] {
        guard !candidates.isEmpty else { return [:] }
        var moved: [Int: Set<RentalAccounts.SourceReference>] = [:]
        for year in years {
            let old = try sourceFigures(db: db, year: year, memo: before)
            let new = try sourceFigures(db: db, year: year, memo: after)
            let changed = candidates.filter { old[$0] != new[$0] }
            if !changed.isEmpty { moved[year] = changed }
        }
        return moved
    }

    /// Each source's amount on the year's deductible lines (`TaxNotClaimedSources.isClaimable`), per
    /// owner and property, from `memo` (worked out and kept there when missing); keyed as a mark
    /// names it (an item receipt by its payment).
    private static func sourceFigures(db: Database, year: Int, memo: TaxComputationMemo) throws -> [RentalAccounts.SourceReference: [String: Int]] {
        var figures: [RentalAccounts.SourceReference: [String: Int]] = [:]
        for property in try Property.fetchAll(db) {
            guard let propertyId = property.id else { continue }
            for personId in Set(try Properties.owners(db: db, propertyId: propertyId).map(\.personId)).sorted() {
                let accounts = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: year), personId: personId,
                                                          propertyId: propertyId, memo: memo)
                for line in accounts.allLines where TaxNotClaimedSources.isClaimable(line.expenseType) {
                    for source in line.sources {
                        let key = source.transactionId.map(RentalAccounts.SourceReference.transaction) ?? source.reference
                        figures[key, default: [:]]["\(personId) \(propertyId)", default: 0] += source.attributedMinorUnits
                    }
                }
            }
        }
        return figures
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

extension FiledYearEditCheck.Outcome: Sendable where T: Sendable {}
