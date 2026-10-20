import CryptoKit
import Foundation
import GRDB

/// The checks of the review's bank statements (UK and BBVA) taken together, the one place they
/// chain across the batch: run over the whole plan on every pass (`ImportPipeline.annotate`),
/// so leaving a statement out, adding one or answering one re-checks every other statement of
/// its account. (Which rows each statement holds — the earlier ones' rows already imported for
/// the later ones — is decided when the pipeline stages them, again for the whole account
/// whenever one of its statements changes.)
///
/// - Closing balances: per account, its statements not left out in date order (`orderKey`:
///   first row's day, last row's day, then order), each closing compared
///   (`StatementCheck.compare`) with the rows of this and the earlier kept statements counted: a
///   mismatch is the issue `statement(.balanceMismatch)` `"balance-<account>-<yyyy-MM-dd>"`,
///   replaced on every pass, gone when it matches (and with it the reason it was imported anyway);
///   a statement whose rows were all imported (a BBVA reader's duplicate) is then asked too.
/// - Possible duplicate rows: a row not a certain duplicate nor a manual entry's replacement
///   whose account has a saved non-manual row of the same amount, dated within ±2 days, whose
///   description differs, that nothing else of the batch claims (a certain duplicate's saved row
///   is claimed first; then rows in order, each taking the nearest such row, the lower id on a
///   tie) — one child item per row, Needs you ("Keep" / "Skip"). A skipped row stays under its
///   statement as a row it doesn't add ("Skipped: not imported"), never Ready. A statement is
///   Needs you while one of its children is.
/// - Mortgages (BBVA): each loan's statements chained in period order, as `batchLoan`
///   (`BBVAStatementReader.mortgageMismatch`).
public enum StatementChecks {
    /// How far apart a possible duplicate may be dated from the saved row it looks like.
    static let duplicateDays = 2
    /// The issue a statement has while one of its rows needs the user.
    public static let rowsIssueId = "possibleDuplicateRows"
    public static let possibleDuplicateIssueId = "possibleDuplicateRow"
    public static let skippedNote = "Skipped: not imported"
    /// Every balance issue's id starts so (`"balance-<account>-<yyyy-MM-dd>"`).
    static let balanceIssuePrefix = "balance-"

    public static func recheck(_ items: [ImportItem], db: Database) throws -> [ImportItem] {
        let parents = Set(items.filter { $0.parentId == nil && statement($0) != nil }.map(\.id))
        // The row children are made again below.
        var result = items.filter { !isRowChild($0, parents: parents) }
        let leftOut = ImportApplier.leftOutIds(ImportPlan(items: result))
        var children: [UUID: [ImportItem]] = [:]

        let indices = result.indices.filter { parents.contains(result[$0].id) }
        let byAccount = Dictionary(grouping: indices) { statement(result[$0])!.accountId }
        for accountId in byAccount.keys.sorted() {
            let account = try Account.fetchOne(db, key: accountId)
            let ordered = byAccount[accountId]!.sorted { order(result[$0], $0) < order(result[$1], $1) }
            // The saved rows a staged one could look like (within the window of the account's rows).
            let dates = ordered.flatMap { i in statement(result[i]).map { ($0.staged + $0.skipped).map(\.parsed.date) } ?? [] }
            let window = Double(duplicateDays) * 86_400
            let saved = try dates.min().map { first in
                try Transaction.filter(Column("accountId") == accountId && Column("isManual") == false
                                       && Column("date") >= first.addingTimeInterval(-window) && Column("date") <= dates.max()!.addingTimeInterval(window))
                    .order(Column("date"), Column("id")).fetchAll(db)
            } ?? []
            var counted: [StagedTransaction] = []
            var fingerprints: Set<String> = []
            // A saved row a certain duplicate of the batch matches is that row's: never a lookalike.
            let certain = Set(ordered.flatMap { statement(result[$0])?.certainDuplicates ?? [] })
            var claimed = Set(saved.filter { certain.contains($0.fingerprint) }.compactMap(\.id))
            for i in ordered {
                var item = result[i]
                item.issues.removeAll { isBalanceIssue($0) || $0.id == rowsIssueId }
                guard !leftOut.contains(item.id), let held = statement(item) else {
                    result[i] = item
                    continue
                }
                // This statement's rows after the earlier ones' (the pipeline stages each after them).
                for row in held.staged where fingerprints.insert(row.fingerprint).inserted { counted.append(row) }
                if let closing = held.closing {
                    let check = try StatementCheck.compare(db: db, accountId: accountId, closing: closing,
                                                           stagedRows: counted.map { ($0.parsed.date, $0.parsed.amountMinorUnits) },
                                                           excludingTransactionIds: Set(counted.compactMap(\.replacesManual?.transactionId)))
                    if let mismatch = check.mismatch {
                        item.issues.append(balanceIssue(mismatch, accountId: accountId, account: account, style: held.style))
                        // Every row already imported, but the saved data closes elsewhere: asked,
                        // never skipped as a duplicate.
                        if item.duplicate?.level == .transactions { item.duplicate = nil }
                    } else {
                        item.resolutionNote = nil
                    }
                }
                children[item.id] = rowChildren(of: item, held, account: account, saved: saved, claimed: &claimed)
                result[i] = item
            }
        }
        result = try chainMortgages(result, db: db)
        return holdParents(inserting(children, into: result))
    }

    /// Each statement with the issue `rowsIssueId` exactly while one of its children is Needs you.
    public static func holdParents(_ items: [ImportItem]) -> [ImportItem] {
        let waiting = Set(items.filter { $0.parentId != nil && $0.section == .needsYou }.compactMap(\.parentId))
        return items.map { item in
            guard item.parentId == nil, statement(item) != nil else { return item }
            var item = item
            item.issues.removeAll { $0.id == rowsIssueId }
            if waiting.contains(item.id) && !item.isLeftOut {
                let text = "Some rows look already saved: keep or skip each"
                item.issues.append(ImportIssue(id: rowsIssueId, kind: .readerProblem(text), reason: text))
            }
            return item
        }
    }

    /// The statement and the fingerprint of the row a row child (a possible duplicate) stands for.
    static func row(of child: ImportItem, in items: [ImportItem]) -> (parent: ImportItem, fingerprint: String)? {
        guard let parentId = child.parentId, let parent = items.first(where: { $0.id == parentId }), let held = statement(parent) else { return nil }
        for row in held.staged + held.skipped where rowChildId(parent: parentId, fingerprint: row.fingerprint) == child.id {
            return (parent, row.fingerprint)
        }
        return nil
    }

    /// Whether `item` is one of `parent`'s rows these checks made (a possible duplicate, a kept
    /// or a skipped row): shown under its statement, never as a document of its own.
    public static func isRowChild(_ item: ImportItem, of parent: ImportItem) -> Bool {
        item.parentId == parent.id && parent.parentId == nil && statement(parent) != nil && isRowChild(item, parents: [parent.id])
    }

    /// Whether a row child is a row the user skipped (`skippedNote`).
    public static func isSkippedRow(_ item: ImportItem) -> Bool {
        item.parentId != nil && item.effect == .none && item.duplicate?.of == skippedNote
    }

    /// The account a statement item's rows go to (nil: not a staged statement).
    static func accountId(of item: ImportItem) -> Int64? { statement(item)?.accountId }

    /// Whether confirming the statement adds anything: rows (and with them the loan and fund
    /// legs), an estimated interest replaced, the fund's market movement. True for anything else.
    static func writesSomething(_ item: ImportItem) -> Bool {
        switch item.effect {
        case .ukStatement(let effect): return !effect.staged.isEmpty
        case .bbvaStatement(let effect): return !effect.staged.isEmpty || !effect.estimates.isEmpty || effect.marketMovementMinorUnits != nil
        default: return true
        }
    }

    /// Whether an issue keeps a statement that adds nothing out of Duplicates: what it says
    /// contradicts the saved data (a closing balance, an instalment, fund or legs mismatch, the
    /// printed account another account's) or its legs can't be checked (no mortgage or fund
    /// account, no transfer or interest category). Pure questions (a remembered account to
    /// confirm, unread lines…) and filed-year holds don't.
    static func keepsFromDuplicates(_ issue: ImportIssue) -> Bool {
        switch issue.kind {
        case .statement(.balanceMismatch), .statement(.instalmentMismatch), .statement(.fundMismatch): return true
        default:
            return [BBVAStatementReader.accountMismatchIssueId, "unknownLinkedAccount", "noTransferCategory", "noInterestCategory"]
                .contains { issue.id.hasPrefix($0) }
        }
    }

    /// Whether the statement adds rows of its own (the ones later statements of its account count).
    static func holdsRows(_ item: ImportItem) -> Bool { !(statement(item)?.staged.isEmpty ?? true) }

    // MARK: Statements

    enum DayStyle { case uk, bbva }

    /// What the checks read of a statement item's effect.
    struct Held {
        var accountId: Int64
        var staged: [StagedTransaction]
        var skipped: [StagedTransaction]
        var certainDuplicates: [String]
        var closing: StatementClosing?
        /// The days of its rows (all of them, already imported ones too), for the date order.
        var rowDays: [Date]
        var style: DayStyle
    }

    static func statement(_ item: ImportItem) -> Held? {
        switch item.effect {
        case .ukStatement(let effect):
            // Its first and last row's days (`UKStatementReader.items`).
            let days = item.facts.filter { $0.field == .periodStart || $0.field == .periodEnd }.compactMap { fact -> Date? in
                if case .date(let date) = fact.value { return date }
                return nil
            }
            return Held(accountId: effect.accountId, staged: effect.staged, skipped: effect.skipped, certainDuplicates: effect.certainDuplicates,
                        closing: effect.statement?.closing, rowDays: days, style: .uk)
        case .bbvaStatement(let effect):
            let days = effect.statement.movements.map(\.date)
            return Held(accountId: effect.currentAccountId, staged: effect.staged, skipped: effect.skipped, certainDuplicates: effect.certainDuplicates,
                        closing: effect.closing, rowDays: days.isEmpty ? [effect.statement.periodStart, effect.statement.periodEnd] : days, style: .bbva)
        default:
            return nil
        }
    }

    /// The one date order of an account's statements (staging, these checks, the mortgage chain
    /// and apply): the first row's day, then the last row's, then `index` (file or plan order).
    static func orderKey(_ rowDays: [Date], _ index: Int) -> (Date, Date, Int) {
        (rowDays.min() ?? .distantFuture, rowDays.max() ?? .distantFuture, index)
    }

    /// `orderKey` of a statement item.
    static func order(_ item: ImportItem, _ index: Int) -> (Date, Date, Int) {
        guard let held = statement(item) else { return orderKey([], index) }
        return orderKey(held.rowDays.isEmpty ? held.closing.map { [$0.date] } ?? [] : held.rowDays, index)
    }

    static func isBalanceIssue(_ issue: ImportIssue) -> Bool {
        if case .statement(.balanceMismatch) = issue.kind { return true }
        return false
    }

    private static func balanceIssue(_ mismatch: StatementMismatch, accountId: Int64, account: Account?, style: DayStyle) -> ImportIssue {
        let currency = account?.currency ?? .gbp
        let name = account?.displayName ?? "Account #\(accountId)"
        return ImportIssue(id: "balance-\(accountId)-\(isoDay.string(from: mismatch.date))", kind: .statement(.balanceMismatch(mismatch)),
                           reason: "The statement closes at \(Money.format(mismatch.statementMinorUnits, currency: currency)) on "
                            + "\(dayText(mismatch.date, style)), but \(name) would be at \(Money.format(mismatch.computedMinorUnits, currency: currency)): "
                            + "import it anyway with a reason, or leave it out of this import")
    }

    // MARK: Possible duplicates

    /// A child made by these checks (a possible duplicate, or a skipped row): a statement's child
    /// that isn't its already-imported rows.
    private static func isRowChild(_ item: ImportItem, parents: Set<UUID>) -> Bool {
        guard let parentId = item.parentId, parents.contains(parentId), item.effect == .none else { return false }
        return item.duplicate == nil || item.duplicate?.of == skippedNote
    }

    /// The statement's skipped rows (shown, settled) and its possible duplicates (Needs you),
    /// each claiming the saved row it looks like.
    private static func rowChildren(of parent: ImportItem, _ held: Held, account: Account?, saved: [Transaction],
                                    claimed: inout Set<Int64>) -> [ImportItem] {
        let currency = account?.currency ?? .gbp
        func lookalike(_ row: StagedTransaction) -> Transaction? {
            let window = Double(duplicateDays) * 86_400
            let description = normalized(row.parsed.rawDescription)
            return saved.filter { candidate in
                guard let id = candidate.id, !claimed.contains(id) else { return false }
                return candidate.amountMinorUnits == row.parsed.amountMinorUnits
                    && abs(candidate.date.timeIntervalSince(row.parsed.date)) <= window
                    && normalized(candidate.rawDescription) != description
            }.min { (abs($0.date.timeIntervalSince(row.parsed.date)), $0.id!) < (abs($1.date.timeIntervalSince(row.parsed.date)), $1.id!) }
        }
        func child(_ row: StagedTransaction) -> ImportItem {
            ImportItem(id: rowChildId(parent: parent.id, fingerprint: row.fingerprint), file: parent.file, recognition: parent.recognition,
                       title: "\(dayText(row.parsed.date, held.style)) \(row.parsed.rawDescription) \(Money.format(row.parsed.amountMinorUnits, currency: currency))",
                       effect: .none, parentId: parent.id, isLeftOut: parent.isLeftOut, groupKey: parent.groupKey)
        }
        var made: [ImportItem] = []
        for row in held.skipped {
            if let existing = lookalike(row) { claimed.insert(existing.id!) }
            // Shown under its statement with the rows it doesn't add, never as Ready.
            var item = child(row)
            item.duplicate = ImportDuplicate(level: .transactions, of: skippedNote)
            made.append(item)
        }
        for row in held.staged where row.replacesManual == nil {
            guard let existing = lookalike(row), let id = existing.id else { continue }
            claimed.insert(id)
            let day = dayText(existing.date, held.style)
            let label = "\(existing.rawDescription) (\(day), \(Money.format(existing.amountMinorUnits, currency: currency)))"
            var item = child(row)
            item.issues = [ImportIssue(id: possibleDuplicateIssueId, kind: .statement(.possibleDuplicate(existingTransactionId: id, existingLabel: label)),
                                       reason: "Looks like “\(existing.rawDescription)” of \(day) already saved", offers: [.keepRow, .skipRow])]
            made.append(item)
        }
        return made
    }

    private static func normalized(_ description: String) -> String {
        description.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The same id for the same row of the same statement on every pass (its answers stay).
    static func rowChildId(parent: UUID, fingerprint: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(parent.uuidString)|\(fingerprint)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The children placed after their statement and its other children.
    private static func inserting(_ children: [UUID: [ImportItem]], into items: [ImportItem]) -> [ImportItem] {
        guard children.values.contains(where: { !$0.isEmpty }) else { return items }
        var result: [ImportItem] = []
        var open: UUID?
        func close() {
            if let id = open { result += children[id] ?? [] }
            open = nil
        }
        for item in items {
            if let id = open, item.parentId != id { close() }
            result.append(item)
            if item.parentId == nil, children[item.id] != nil { open = item.id }
        }
        close()
        return result
    }

    // MARK: Mortgages

    /// The import's BBVA statements chained per mortgage, in date order (`order`): each carries
    /// the earlier ones' loan moves (`batchLoan`; left-out and duplicate statements add none)
    /// and is checked against its last receipt (`BBVAStatementReader.mortgageMismatch`): a mismatch is a Needs-you
    /// `instalmentMismatch` "Mortgage balance after <statement> would be <x>, the statement says <y>".
    static func chainMortgages(_ items: [ImportItem], db: Database) throws -> [ImportItem] {
        let leftOut = ImportApplier.leftOutIds(ImportPlan(items: items))
        func effect(_ i: Int) -> BBVAStatementEffect? {
            guard items[i].parentId == nil, case .bbvaStatement(let effect) = items[i].effect, effect.loanAccountId != nil else { return nil }
            return effect
        }
        var result = items
        let indices = items.indices.filter { effect($0) != nil }
        for (_, group) in Dictionary(grouping: indices, by: { effect($0)!.loanAccountId! }) {
            var earlier: [BBVAStatementEffect.BatchLoanRow] = []
            for i in group.sorted(by: { order(items[$0], $0) < order(items[$1], $1) }) {
                var statement = effect(i)!
                statement.batchLoan = earlier
                var item = result[i]
                item.effect = .bbvaStatement(statement)
                item.issues.removeAll { $0.id == BBVAStatementReader.mortgageBalanceIssueId }
                if let found = try BBVAStatementReader.mortgageMismatch(db: db, statement, ownWritten: false) {
                    let currency = found.loan?.currency ?? .eur
                    let text = "Mortgage balance after \(BBVAStatementReader.title(statement.statement)) would be "
                        + "\(BBVAStatementReader.signed(found.mismatch.computedMinorUnits, currency)), "
                        + "the statement says \(BBVAStatementReader.signed(found.mismatch.statementMinorUnits, currency))"
                    item.issues.append(ImportIssue(id: BBVAStatementReader.mortgageBalanceIssueId, kind: .statement(.instalmentMismatch(text)), reason: text))
                }
                result[i] = item
                if !leftOut.contains(item.id), item.duplicate == nil { earlier += try BBVAStatementReader.ownLoanRows(db: db, statement) }
            }
        }
        return result
    }

    // MARK: Days

    private static let isoDay: DateFormatter = formatter("yyyy-MM-dd")
    private static let ukDay: DateFormatter = formatter("d MMM yyyy")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = format
        return formatter
    }

    /// "5 Mar 2023" (UK statements), "05/03/2023" (BBVA, as the statement prints days).
    private static func dayText(_ date: Date, _ style: DayStyle) -> String {
        style == .uk ? ukDay.string(from: date) : BBVAStatementReader.dayText(date)
    }
}
