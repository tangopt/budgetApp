import Foundation
import GRDB

/// One-off import of the BBVA Portugal current account's history (statements 2023-01 to
/// 2026-09, already parsed and classified into a CSV outside the app): creates the account
/// with its opening balance, the "Lisbon" category group and its categories, commits every row
/// through the normal import commit (`ImportCoordinator.commit(db:)`: fingerprints, transfer
/// matching, forecast refresh), learns conservative rules for the repeatable kinds, then
/// verifies the month-end balances against the statements' — all in the caller's transaction.
public enum BBVAHistoryImport {
    public static let accountName = "BBVA"
    public static let accountAlias = "BBVA PT"
    public static let groupName = "Lisbon"
    public static let sourceFileName = "BBVA extratos 2023-01 to 2026-09"

    /// The Lisbon group's categories, created in this order.
    public static let categories: [(name: String, type: CategoryType)] = [
        ("Rental income", .income),
        ("Mortgage", .expense), ("Life insurance", .expense), ("Building insurance", .expense),
        ("Contents insurance", .expense), ("Condomínio", .expense), ("IMI", .expense), ("PT tax", .expense),
        ("PT accountant", .expense), ("Utilities", .expense), ("Repairs", .expense), ("BBVA fees", .expense),
        ("Legal fees", .expense), ("Other", .expense),
        // Card statements settled from the account (a transfer, like the AMEX one; not tied).
        ("BBVA credit card", .transfer)
    ]

    /// Categories rules are learned for: the clearly repeatable kinds.
    public static let ruleCategories: Set<String> = [
        "Rental income", "Mortgage", "Life insurance", "Condomínio", "Utilities", "BBVA fees", "PT accountant"
    ]

    /// Where a classified row goes.
    public enum Mapping: Equatable, Sendable {
        case category(String)
        /// Between the user's own accounts: the other account's tied transfer category, when
        /// the description names exactly one account; else uncategorised.
        case ownAccountTransfer
        /// No category, pending review (the Uncategorized screen).
        case uncategorised
    }

    /// Nil for a kind this import doesn't know (refused).
    public static func mapping(forKind kind: String) -> Mapping? {
        if kind.hasPrefix("utilities_") { return .category("Utilities") }
        switch kind {
        case "rent_received": return .category("Rental income")
        case "mortgage_instalment": return .category("Mortgage")
        case "life_insurance", "insurance_refund": return .category("Life insurance")
        case "building_insurance_mr", "insurance_mapfre": return .category("Building insurance")
        case "condominio": return .category("Condomínio")
        case "imi": return .category("IMI")
        case "pt_irs": return .category("PT tax")
        case "accountant": return .category("PT accountant")
        case "bank_fees": return .category("BBVA fees")
        case "legal_fees": return .category("Legal fees")
        case "tenant_deposit_return": return .category("Other")
        case "card_payment": return .category("BBVA credit card")
        case "transfer_own_accounts": return .ownAccountTransfer
        case "investment_subscription", "state_payment_other", "other": return .uncategorised
        default: return nil
        }
    }

    // MARK: Input

    public struct Row: Equatable, Sendable {
        /// The booking date (UTC midnight).
        public let date: Date
        public let description: String
        public let amountMinorUnits: Int
        public let balanceAfterMinorUnits: Int
        public let kind: String
        /// The classifier's matched text (a rule pattern candidate).
        public let matchedText: String

        public init(date: Date, description: String, amountMinorUnits: Int, balanceAfterMinorUnits: Int, kind: String, matchedText: String = "") {
            self.date = date
            self.description = description
            self.amountMinorUnits = amountMinorUnits
            self.balanceAfterMinorUnits = balanceAfterMinorUnits
            self.kind = kind
            self.matchedText = matchedText
        }
    }

    /// One statement month: its opening and closing balances.
    public struct Month: Equatable, Sendable {
        public let year: Int
        public let month: Int
        public let openingMinorUnits: Int
        public let closingMinorUnits: Int

        public init(year: Int, month: Int, openingMinorUnits: Int, closingMinorUnits: Int) {
            self.year = year
            self.month = month
            self.openingMinorUnits = openingMinorUnits
            self.closingMinorUnits = closingMinorUnits
        }

        public var label: String { String(format: "%04d-%02d", year, month) }
        public var range: (start: Date, end: Date) { MonthRange.of(year: year, month: month) }
    }

    public struct Input: Equatable, Sendable {
        /// In statement order.
        public let rows: [Row]
        /// Contiguous, oldest first; the first one's opening is the account's opening balance.
        public let months: [Month]

        public init(rows: [Row], months: [Month]) {
            self.rows = rows
            self.months = months
        }
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case alreadyApplied
        case accountNameTaken(String)
        /// Names already used by a category or group (ignoring case); nothing is renamed.
        case nameClash([String])
        case unknownKinds([String])
        case badInput(String)
        case verificationFailed([String])

        public var errorDescription: String? {
            switch self {
            case .alreadyApplied: return "Already applied: account “\(accountName)” has the batch “\(sourceFileName)”."
            case .accountNameTaken(let name): return "An account named “\(name)” already exists (without this import's batch)."
            case .nameClash(let names): return "Names already in use: \(names.joined(separator: ", ")) — nothing renamed."
            case .unknownKinds(let kinds): return "Unknown kinds: \(kinds.joined(separator: ", "))."
            case .badInput(let reason): return "Bad input: \(reason)"
            case .verificationFailed(let lines): return "Verification failed:\n" + lines.joined(separator: "\n")
            }
        }
    }

    // MARK: Parsing

    /// The classified CSV: Date (dd/MM/yyyy booking), ValueDate, Description, Amount, Balance,
    /// kind, matched_text, … (header row first; quoted fields may hold commas).
    public static func parseClassifiedCSV(_ text: String) throws -> [Row] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { throw ImportError.badInput("empty CSV") }
        let columns = CSVRowSplitter.split(line: header, delimiter: ",")
        func index(_ name: String) throws -> Int {
            guard let i = columns.firstIndex(of: name) else { throw ImportError.badInput("no “\(name)” column") }
            return i
        }
        let (date, description, amount, balance, kind) = (try index("Date"), try index("Description"), try index("Amount"), try index("Balance"), try index("kind"))
        let matched = columns.firstIndex(of: "matched_text")
        return try lines.dropFirst().enumerated().map { offset, line in
            let fields = CSVRowSplitter.split(line: line, delimiter: ",")
            let needed = [date, description, amount, balance, kind].max()!
            guard fields.count > needed, let day = parseDay(fields[date]), let minor = minorUnits(fields[amount]),
                  let after = minorUnits(fields[balance]) else {
                throw ImportError.badInput("row \(offset + 2) unreadable")
            }
            return Row(date: day, description: fields[description], amountMinorUnits: minor, balanceAfterMinorUnits: after,
                       kind: fields[kind], matchedText: matched.flatMap { $0 < fields.count ? fields[$0] : nil } ?? "")
        }
    }

    /// monthly_summary.csv: period (yyyy-MM), opening, …, closing.
    public static func parseMonthlySummary(_ text: String) throws -> [Month] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { throw ImportError.badInput("empty summary") }
        let columns = CSVRowSplitter.split(line: header, delimiter: ",")
        guard let period = columns.firstIndex(of: "period"), let opening = columns.firstIndex(of: "opening"),
              let closing = columns.firstIndex(of: "closing") else { throw ImportError.badInput("summary needs period, opening, closing") }
        return try lines.dropFirst().map { line in
            let fields = CSVRowSplitter.split(line: line, delimiter: ",")
            let parts = fields[period].split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2, let open = minorUnits(fields[opening]), let close = minorUnits(fields[closing]) else {
                throw ImportError.badInput("summary line “\(line)” unreadable")
            }
            return Month(year: parts[0], month: parts[1], openingMinorUnits: open, closingMinorUnits: close)
        }
    }

    static func parseDay(_ text: String) -> Date? {
        let parts = text.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return MonthRange.calendar.date(from: DateComponents(year: parts[2], month: parts[1], day: parts[0]))
    }

    /// "-927.85" → -92785 (at most 2 decimals).
    static func minorUnits(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespaces)
        var sign = 1
        if s.hasPrefix("-") { sign = -1; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let whole = Int(parts[0]) else { return nil }
        var cents = 0
        if parts.count == 2 {
            let fraction = String(parts[1])
            guard (1...2).contains(fraction.count), let value = Int(fraction) else { return nil }
            cents = fraction.count == 1 ? value * 10 : value
        }
        return sign * (whole * 100 + cents)
    }

    // MARK: Rules

    public struct RuleCandidate: Equatable, Sendable {
        public let pattern: String
        public let categoryName: String
        /// Rows of the import it matches (all in `categoryName`).
        public let matchCount: Int
    }

    /// Contains-patterns to learn: for each row of a `learnFor` category not yet covered, the
    /// one of its merchant key, the classifier's matched text and its whole description
    /// (uppercased) matching the most rows (the first on a tie) among those at least 4
    /// characters long that match (as a contains rule would,
    /// `RuleMatcher`) at least 2 rows of that category and none filed anywhere else
    /// (uncategorised included). Rows with no such pattern get no rule. Pure.
    public static func ruleCandidates(rows: [(description: String, matchedText: String, categoryName: String?)], learnFor: Set<String>) -> [RuleCandidate] {
        var result: [RuleCandidate] = []
        var covered = Set<Int>()
        func matching(_ pattern: String) -> [Int] {
            let rule = Rule(matchPattern: pattern, matchType: .contains, categoryId: 0, priority: 0)
            return rows.indices.filter { RuleMatcher.matches(rule, description: rows[$0].description) }
        }
        for (index, row) in rows.enumerated() {
            guard let category = row.categoryName, learnFor.contains(category), !covered.contains(index) else { continue }
            let whole = row.description.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let matchedText = row.matchedText.uppercased().trimmingCharacters(in: .whitespaces)
            var options = [MerchantKey.make(row.description)]
            if !matchedText.isEmpty, row.description.range(of: matchedText, options: .caseInsensitive) != nil { options.append(matchedText) }
            options.append(whole)
            var best: (pattern: String, hits: [Int])?
            for pattern in options where pattern.count >= 4 && !result.contains(where: { $0.pattern == pattern }) {
                let hits = matching(pattern)
                guard hits.count >= 2, hits.allSatisfy({ rows[$0].categoryName == category }) else { continue }
                if hits.count > best?.hits.count ?? 0 { best = (pattern, hits) }
            }
            if let best {
                result.append(RuleCandidate(pattern: best.pattern, categoryName: category, matchCount: best.hits.count))
                covered.formUnion(best.hits)
            }
        }
        return result
    }

    // MARK: Report

    public struct CategoryYear: Equatable, Sendable {
        /// Nil = uncategorised.
        public let categoryName: String?
        public let year: Int
        public let count: Int
        public let totalMinorUnits: Int
    }

    public struct LinkFound: Equatable, Sendable {
        public let bbvaDescription: String
        public let bbvaDate: Date
        public let bbvaAmountMinorUnits: Int
        public let otherAccountName: String
        public let otherDescription: String
        public let otherDate: Date
        public let otherAmountMinorUnits: Int
        public let otherCurrency: Currency
    }

    public struct Report: Equatable, Sendable {
        public let accountId: Int64
        public let openingMinorUnits: Int
        public let openingDate: Date
        public let sortOrder: Int?
        /// Other accounts given a sortOrder (in their displayed order) so BBVA could go last.
        public let renumberedAccounts: Int
        public let transferCategory: String?
        public let transferCategoryGroup: String?
        public let createdCategories: [String]
        public let rowCount: Int
        public let byCategoryYear: [CategoryYear]
        public let uncategorisedPending: Int
        /// Own-account transfers whose description names no single account (left uncategorised).
        public let unresolvedTransfers: [String]
        public let rulesLearned: [RuleCandidate]
        public let rulesSkipped: [String]
        public let links: [LinkFound]
        /// Rows whose category changed after the commit (linked transfer legs re-filed).
        public let refiledByLinks: Int
        public let verification: [String]

        public var text: String {
            func money(_ value: Int) -> String { Money.format(value, currency: .eur) }
            let day = DateFormatter()
            day.calendar = MonthRange.calendar
            day.timeZone = MonthRange.calendar.timeZone
            day.dateFormat = "yyyy-MM-dd"
            var lines: [String] = []
            lines.append("Account “\(accountName)” (alias “\(accountAlias)”, EUR, cash, Europe) id \(accountId), sortOrder \(sortOrder.map(String.init) ?? "—")"
                         + (renumberedAccounts > 0 ? " (\(renumberedAccounts) other accounts numbered in their displayed order first)" : ""))
            lines.append("  Opening balance \(money(openingMinorUnits)) on \(day.string(from: openingDate))")
            lines.append("  Transfer category: \(transferCategory ?? "none") in group \(transferCategoryGroup ?? "none")")
            lines.append("Group “\(groupName)”: created \(createdCategories.joined(separator: ", "))")
            lines.append("Imported \(rowCount) rows in batch “\(sourceFileName)”")
            let years = Array(Set(byCategoryYear.map(\.year))).sorted()
            lines.append("Per category (count / total) by year:")
            let names = byCategoryYear.map { $0.categoryName ?? "(uncategorised)" }
            var seen = Set<String>()
            for name in names where seen.insert(name).inserted {
                let entries = byCategoryYear.filter { ($0.categoryName ?? "(uncategorised)") == name }
                let cells = years.map { year -> String in
                    guard let e = entries.first(where: { $0.year == year }) else { return "\(year): —" }
                    return "\(year): \(e.count) / \(money(e.totalMinorUnits))"
                }
                let count = entries.reduce(0) { $0 + $1.count }, total = entries.reduce(0) { $0 + $1.totalMinorUnits }
                lines.append("  \(name) — \(count) / \(money(total)) — " + cells.joined(separator: "; "))
            }
            lines.append("Uncategorised (pending review): \(uncategorisedPending)")
            if !unresolvedTransfers.isEmpty {
                lines.append("Own-account transfers naming no single account (left uncategorised): " + unresolvedTransfers.joined(separator: " | "))
            }
            lines.append("Rules learned: \(rulesLearned.count)")
            for rule in rulesLearned { lines.append("  contains “\(rule.pattern)” → \(rule.categoryName) (\(rule.matchCount) rows)") }
            for skipped in rulesSkipped { lines.append("  skipped: \(skipped)") }
            lines.append("Transfer links created with BBVA rows: \(links.count)")
            for link in links {
                lines.append("  \(day.string(from: link.bbvaDate)) \(link.bbvaDescription) \(money(link.bbvaAmountMinorUnits)) ↔ \(link.otherAccountName) "
                             + "\(day.string(from: link.otherDate)) \(link.otherDescription) \(Money.format(link.otherAmountMinorUnits, currency: link.otherCurrency))")
            }
            if refiledByLinks > 0 { lines.append("  \(refiledByLinks) BBVA row(s) re-filed by linking") }
            lines.append("Verification:")
            lines.append(contentsOf: verification.map { "  " + $0 })
            return lines.joined(separator: "\n")
        }
    }

    // MARK: Apply

    /// Everything, in the caller's write transaction; throws (nothing to keep) on any refusal
    /// or failed verification.
    public static func apply(db: Database, input: Input, today: Date = Date()) throws -> Report {
        try validate(input)
        try checkNotApplied(db: db)
        try checkNames(db: db)

        // 1. The account and its opening balance.
        let first = input.months[0]
        let openingDate = first.range.start
        let others = AccountOrdering.sorted(try Account.fetchAll(db))
        let account = try AccountEditing.add(db: db, name: accountName, currency: .eur, kind: .cash, openingBalanceEntered: first.openingMinorUnits,
                                             asOf: openingDate, details: AccountDetails(alias: accountAlias, region: .europe))
        let accountId = account.id!
        try db.execute(sql: "UPDATE balanceSnapshot SET note = ? WHERE accountId = ?", arguments: ["Opening balance (statement \(first.label))", accountId])
        var renumbered = 0
        if others.contains(where: { $0.sortOrder == nil }) {
            for (position, other) in others.enumerated() {
                try db.execute(sql: "UPDATE account SET sortOrder = ? WHERE id = ?", arguments: [position, other.id])
            }
            renumbered = others.count
        }
        let sortOrder = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM account WHERE id <> ?", arguments: [accountId])).map { $0 + 1 } ?? 0
        try db.execute(sql: "UPDATE account SET sortOrder = ? WHERE id = ?", arguments: [sortOrder, accountId])
        let tied = try TransferCategories.category(db: db, forAccountId: accountId)
        let tiedGroup = try tied?.groupId.flatMap { try CategoryGroup.fetchOne(db, key: $0)?.name }

        // 2. The group and its categories.
        let group = try CategoryGroups.create(db: db, name: groupName, type: .expense)
        var categoryIds: [String: Int64] = [:]
        for (name, type) in categories {
            categoryIds[name] = try Categories.create(db: db, name: name, type: type, groupId: group.id).id
        }

        // 3. The rows, through the import commit.
        let parsed = input.rows.map { ParsedTransaction(date: $0.date, rawDescription: $0.description, amountMinorUnits: $0.amountMinorUnits, balanceAfterMinorUnits: $0.balanceAfterMinorUnits) }
        let fingerprints = TransactionFingerprint.computeAll(accountId: accountId, transactions: parsed)
        let transferIds = try TransferCategories.categoryIdsByAccount(db: db)
        let otherAccounts = try Account.fetchAll(db).filter { $0.id != accountId }
        var unresolved: [String] = []
        var finalCategories: [Int64?] = []
        var staged: [StagedTransaction] = []
        var decisions: [ImportDecision] = []
        for (index, row) in input.rows.enumerated() {
            let categoryId: Int64?
            switch mapping(forKind: row.kind)! {
            case .category(let name): categoryId = categoryIds[name]
            case .uncategorised: categoryId = nil
            case .ownAccountTransfer:
                let named = otherAccounts.filter { other in
                    [other.name, other.alias].compactMap { $0 }.contains { !$0.isEmpty && row.description.range(of: $0, options: .caseInsensitive) != nil }
                }
                if named.count == 1, let id = named[0].id, let tiedId = transferIds[id] {
                    categoryId = tiedId
                } else {
                    categoryId = nil
                    unresolved.append(row.description)
                }
            }
            finalCategories.append(categoryId)
            let item = StagedTransaction(parsed: parsed[index], suggestedCategoryId: categoryId, source: categoryId == nil ? .none : .manual,
                                         confidence: 1, fingerprint: fingerprints[index])
            staged.append(item)
            decisions.append(ImportDecision(stagedId: item.id, finalCategoryId: categoryId, learnRule: false))
        }
        try ImportCoordinator.commit(db: db, accountId: accountId, sourceFileName: sourceFileName, staged: staged, decisions: decisions)

        // 4. Rules for the repeatable kinds.
        let names = Dictionary(try Category.fetchAll(db).compactMap { c in c.id.map { ($0, c.name) } }, uniquingKeysWith: { a, _ in a })
        let candidates = ruleCandidates(rows: input.rows.enumerated().map { ($1.description, $1.matchedText, finalCategories[$0].flatMap { names[$0] }) },
                                        learnFor: ruleCategories)
        var learned: [RuleCandidate] = []
        var skipped: [String] = []
        let existingRules = try Rule.filter(Column("matchType") == RuleMatchType.contains.rawValue).fetchAll(db)
        for candidate in candidates {
            let categoryId = categoryIds[candidate.categoryName]!
            if let existing = existingRules.first(where: { $0.matchPattern.caseInsensitiveCompare(candidate.pattern) == .orderedSame }) {
                skipped.append("“\(candidate.pattern)” — a rule with this pattern already files into \(names[existing.categoryId] ?? "#\(existing.categoryId)")")
                continue
            }
            try Rules.add(db: db, pattern: candidate.pattern, matchType: .contains, categoryId: categoryId, applyToUncategorised: false)
            learned.append(candidate)
        }

        // 5. What was saved, and the verification.
        let transactions = try Transaction.filter(Column("accountId") == accountId).order(Column("date"), Column("id")).fetchAll(db)
        let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
        var verification: [String] = []
        var failures: [String] = []
        func check(_ ok: Bool, _ line: String) {
            verification.append((ok ? "OK   " : "FAIL ") + line)
            if !ok { failures.append(line) }
        }
        check(transactions.count == input.rows.count, "rows saved: \(transactions.count) of \(input.rows.count)")
        var monthFailures = 0
        for month in input.months {
            let balance = NetWorthCalculator.balance(accountId: accountId, at: month.range.end, snapshots: snapshots, transactions: transactions)?.native
            if balance != month.closingMinorUnits {
                monthFailures += 1
                check(false, "\(month.label) closing: computed \(balance.map { Money.format($0, currency: .eur) } ?? "—"), statement \(Money.format(month.closingMinorUnits, currency: .eur))")
            }
        }
        check(monthFailures == 0, "month-end balances match all \(input.months.count) statement closings" + (monthFailures > 0 ? " (\(monthFailures) differ)" : ""))
        let last = input.months[input.months.count - 1]
        let closing = NetWorthCalculator.balance(accountId: accountId, at: last.range.end, snapshots: snapshots, transactions: transactions)?.native
        check(closing == last.closingMinorUnits,
              "balance at \(last.label) end: \(closing.map { Money.format($0, currency: .eur) } ?? "—") (expected \(Money.format(last.closingMinorUnits, currency: .eur)))")
        let refiled = zip(transactions, finalCategories).filter { $0.0.categoryId != $0.1 }.count
        let pending = transactions.filter { $0.categoryId == nil && $0.status == .pendingReview }.count
        let uncategorised = transactions.filter { $0.categoryId == nil }.count
        check(pending == uncategorised, "every uncategorised row is pending review: \(pending) of \(uncategorised) (mapped uncategorised \(finalCategories.filter { $0 == nil }.count))")
        check(transactions.filter { $0.categoryId != nil }.allSatisfy { $0.status == .confirmed }, "every categorised row is confirmed")

        var byCategoryYear: [CategoryYear] = []
        let grouped = Dictionary(grouping: transactions) { t in
            Pair(category: t.categoryId.flatMap { names[$0] }, year: MonthRange.calendar.component(.year, from: t.date))
        }
        for (key, rows) in grouped {
            byCategoryYear.append(CategoryYear(categoryName: key.category, year: key.year, count: rows.count, totalMinorUnits: rows.reduce(0) { $0 + $1.amountMinorUnits }))
        }
        byCategoryYear.sort { ($0.categoryName ?? "~", $0.year) < ($1.categoryName ?? "~", $1.year) }

        let ids = Set(transactions.compactMap(\.id))
        let accountsById = Dictionary(try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        var links: [LinkFound] = []
        for link in try TransferLink.active.fetchAll(db) where ids.contains(link.outTransactionId) || ids.contains(link.inTransactionId) {
            let bbvaId = ids.contains(link.outTransactionId) ? link.outTransactionId : link.inTransactionId
            let otherId = bbvaId == link.outTransactionId ? link.inTransactionId : link.outTransactionId
            guard let bbva = try Transaction.fetchOne(db, key: bbvaId), let other = try Transaction.fetchOne(db, key: otherId) else { continue }
            let otherAccount = accountsById[other.accountId]
            links.append(LinkFound(bbvaDescription: bbva.rawDescription, bbvaDate: bbva.date, bbvaAmountMinorUnits: bbva.amountMinorUnits,
                                   otherAccountName: otherAccount?.displayName ?? "#\(other.accountId)", otherDescription: other.rawDescription,
                                   otherDate: other.date, otherAmountMinorUnits: other.amountMinorUnits, otherCurrency: otherAccount?.currency ?? .gbp))
        }
        links.sort { $0.bbvaDate < $1.bbvaDate }

        guard failures.isEmpty else { throw ImportError.verificationFailed(verification) }
        return Report(accountId: accountId, openingMinorUnits: first.openingMinorUnits, openingDate: openingDate, sortOrder: sortOrder,
                      renumberedAccounts: renumbered, transferCategory: tied?.name, transferCategoryGroup: tiedGroup,
                      createdCategories: categories.map(\.name), rowCount: transactions.count, byCategoryYear: byCategoryYear,
                      uncategorisedPending: pending, unresolvedTransfers: unresolved, rulesLearned: learned, rulesSkipped: skipped,
                      links: links, refiledByLinks: refiled, verification: verification)
    }

    private struct Pair: Hashable {
        let category: String?
        let year: Int
    }

    /// Rows and months agree: known kinds, months contiguous, each month's opening is the
    /// previous closing, the running balance holds row by row, and every row falls after the
    /// opening day within the months covered.
    static func validate(_ input: Input) throws {
        guard !input.rows.isEmpty, let first = input.months.first, let last = input.months.last else { throw ImportError.badInput("no rows or no months") }
        let unknown = Array(Set(input.rows.map(\.kind).filter { mapping(forKind: $0) == nil })).sorted()
        guard unknown.isEmpty else { throw ImportError.unknownKinds(unknown) }
        for (previous, next) in zip(input.months, input.months.dropFirst()) {
            let expected = MonthRange.components(of: MonthRange.calendar.date(byAdding: .month, value: 1, to: previous.range.start)!)
            guard expected.year == next.year, expected.month == next.month else { throw ImportError.badInput("months not contiguous after \(previous.label)") }
            guard next.openingMinorUnits == previous.closingMinorUnits else { throw ImportError.badInput("\(next.label) opening ≠ \(previous.label) closing") }
        }
        var balance = first.openingMinorUnits
        for (index, row) in input.rows.enumerated() {
            balance += row.amountMinorUnits
            guard balance == row.balanceAfterMinorUnits else { throw ImportError.badInput("running balance breaks at row \(index + 1) (\(row.description))") }
            // The opening snapshot is dated at the start of the first day; a row that day wouldn't count after it.
            guard row.date >= MonthRange.calendar.date(byAdding: .day, value: 1, to: first.range.start)!, row.date <= last.range.end else {
                throw ImportError.badInput("row \(index + 1) dated outside \(first.label)…\(last.label) (or on the opening day)")
            }
        }
        guard balance == last.closingMinorUnits else { throw ImportError.badInput("rows end at \(balance), statements close at \(last.closingMinorUnits)") }
    }

    static func checkNotApplied(db: Database) throws {
        if try ImportBatch.filter(Column("sourceFileName") == sourceFileName).fetchCount(db) > 0 { throw ImportError.alreadyApplied }
        if let existing = try Account.fetchAll(db).first(where: { $0.name.caseInsensitiveCompare(accountName) == .orderedSame }) {
            throw ImportError.accountNameTaken(existing.name)
        }
    }

    static func checkNames(db: Database) throws {
        let categoryNames = try Category.fetchAll(db).map(\.name)
        var clashes: [String] = []
        if let group = try CategoryGroup.fetchAll(db).first(where: { $0.name.caseInsensitiveCompare(groupName) == .orderedSame }) {
            clashes.append("group “\(group.name)”")
        }
        for (name, _) in categories {
            if let existing = categoryNames.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { clashes.append("category “\(existing)”") }
        }
        let transferName = "Transfer: \(accountAlias)"
        if let existing = categoryNames.first(where: { $0.caseInsensitiveCompare(transferName) == .orderedSame }) { clashes.append("category “\(existing)”") }
        guard clashes.isEmpty else { throw ImportError.nameClash(clashes) }
    }
}
