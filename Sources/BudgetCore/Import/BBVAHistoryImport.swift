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
    /// The tenant's deposit the user holds: a liability (credit, EUR). Its tied transfer
    /// category is named after it ("Transfer: Tenant deposit held" — `TransferCategories.ensure`
    /// keeps tied categories named so) and sits in the Lisbon group.
    public static let depositAccountName = "Tenant deposit held"

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
        /// To or from the tenant-deposit liability (its tied transfer category); the other leg
        /// is added there (`ManualTransactions.addOtherSide`).
        case depositTransfer
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
        case "tenant_deposit_return": return .depositTransfer
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

    /// A tenant credit to split: of the rent_received row booked on `date`, `depositMinorUnits`
    /// (> 0, less than the row) is the deposit received (a transfer from the deposit liability).
    public struct DepositSplit: Equatable, Sendable {
        public let date: Date
        public let depositMinorUnits: Int

        public init(date: Date, depositMinorUnits: Int) {
            self.date = date
            self.depositMinorUnits = depositMinorUnits
        }
    }

    public struct Input: Equatable, Sendable {
        /// In statement order.
        public let rows: [Row]
        /// Contiguous, oldest first; the first one's opening is the account's opening balance.
        public let months: [Month]
        /// The deposit liability's opening balance, signed (negative = owed), and its day;
        /// nil starts it from zero.
        public let depositOpening: (minorUnits: Int, date: Date)?
        public let depositSplits: [DepositSplit]

        public init(rows: [Row], months: [Month], depositOpening: (minorUnits: Int, date: Date)? = nil, depositSplits: [DepositSplit] = []) {
            self.rows = rows
            self.months = months
            self.depositOpening = depositOpening
            self.depositSplits = depositSplits
        }

        public static func == (lhs: Input, rhs: Input) -> Bool {
            lhs.rows == rhs.rows && lhs.months == rhs.months && lhs.depositSplits == rhs.depositSplits
                && lhs.depositOpening?.minorUnits == rhs.depositOpening?.minorUnits && lhs.depositOpening?.date == rhs.depositOpening?.date
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

    public static func parseDay(_ text: String) -> Date? {
        let parts = text.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return MonthRange.calendar.date(from: DateComponents(year: parts[2], month: parts[1], day: parts[0]))
    }

    /// "-1234.56" → -123456 (at most 2 decimals).
    public static func minorUnits(_ text: String) -> Int? {
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
        /// Nil when no account is ordered yet (BBVA then sorts alphabetically, like them).
        public let sortOrder: Int?
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
        public let deposit: DepositReport
        public let verification: [String]

        public var text: String {
            func money(_ value: Int) -> String { Money.format(value, currency: .eur) }
            let day = DateFormatter()
            day.calendar = MonthRange.calendar
            day.timeZone = MonthRange.calendar.timeZone
            day.dateFormat = "yyyy-MM-dd"
            var lines: [String] = []
            lines.append("Account “\(accountName)” (alias “\(accountAlias)”, EUR, cash, Europe) id \(accountId), sortOrder \(sortOrder.map(String.init) ?? "none (sorted alphabetically)")")
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
            lines.append("Account “\(depositAccountName)” (credit, EUR) id \(deposit.accountId); transfer category \(deposit.transferCategory ?? "none") in group \(deposit.transferCategoryGroup ?? "none")")
            if let opening = deposit.openingMinorUnits, let date = deposit.openingDate {
                lines.append("  Opening balance \(money(opening)) (signed; negative = owed) on \(day.string(from: date))")
            } else {
                lines.append("  No opening balance given (--deposit-opening): starts from zero")
            }
            for split in deposit.splits { lines.append("  Split \(day.string(from: split.date)) \(split.description) \(money(split.totalMinorUnits)) → rent \(money(split.totalMinorUnits - split.depositMinorUnits)) + deposit \(money(split.depositMinorUnits))") }
            for leg in deposit.legs { lines.append("  Leg \(day.string(from: leg.date)) \(leg.description) \(money(leg.amountMinorUnits)) (other side of BBVA “\(leg.bbvaDescription)”)") }
            lines.append("  Balance now \(deposit.balanceMinorUnits.map(money) ?? "—") (signed)")
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
        let account = try AccountEditing.add(db: db, name: accountName, currency: .eur, kind: .cash, openingBalanceEntered: first.openingMinorUnits,
                                             asOf: openingDate, details: AccountDetails(alias: accountAlias, region: .europe))
        let accountId = account.id!
        try db.execute(sql: "UPDATE balanceSnapshot SET note = ? WHERE accountId = ?", arguments: ["Opening balance (statement \(first.label))", accountId])
        // After the ordered accounts (`AccountEditing.add`); none ordered leaves it nil.
        let sortOrder = account.sortOrder
        let tied = try TransferCategories.category(db: db, forAccountId: accountId)
        let tiedGroup = try tied?.groupId.flatMap { try CategoryGroup.fetchOne(db, key: $0)?.name }

        // 2. The group and its categories.
        let group = try CategoryGroups.create(db: db, name: groupName, type: .expense)
        var categoryIds: [String: Int64] = [:]
        for (name, type) in categories {
            categoryIds[name] = try Categories.create(db: db, name: name, type: type, groupId: group.id).id
        }

        // The tenant-deposit liability, its tied transfer category moved into the group.
        let depositAccount = try AccountEditing.add(db: db, name: depositAccountName, currency: .eur, kind: .credit,
                                                    openingBalanceEntered: input.depositOpening.map { NetWorthCalculator.enteredBalance(signedMinorUnits: $0.minorUnits, accountKind: .credit) },
                                                    asOf: input.depositOpening?.date ?? openingDate, details: AccountDetails(region: .europe))
        let depositAccountId = depositAccount.id!
        if input.depositOpening != nil {
            try db.execute(sql: "UPDATE balanceSnapshot SET note = ? WHERE accountId = ?", arguments: ["Tenant deposit held (opening)", depositAccountId])
        }
        guard let depositCategory = try TransferCategories.category(db: db, forAccountId: depositAccountId), let depositCategoryId = depositCategory.id else {
            throw ImportError.badInput("no transfer category for \(depositAccountName)")
        }
        try Categories.move(db: db, ids: [depositCategoryId], toGroupId: group.id)

        // 3. The rows (deposit splits as two), through the import commit.
        let rows = try importRows(input)
        let parsed = rows.map { ParsedTransaction(date: $0.row.date, rawDescription: $0.row.description, amountMinorUnits: $0.amountMinorUnits) }
        let fingerprints = TransactionFingerprint.computeAll(accountId: accountId, transactions: parsed)
        let transferIds = try TransferCategories.categoryIdsByAccount(db: db)
        let otherAccounts = try Account.fetchAll(db).filter { $0.id != accountId && $0.id != depositAccountId }
        var unresolved: [String] = []
        var finalCategories: [Int64?] = []
        var staged: [StagedTransaction] = []
        var decisions: [ImportDecision] = []
        var depositStagedIds: [UUID] = []
        for (index, item) in rows.enumerated() {
            let row = item.row
            let categoryId: Int64?
            switch item.isDepositPart ? .depositTransfer : mapping(forKind: row.kind)! {
            case .category(let name): categoryId = categoryIds[name]
            case .uncategorised: categoryId = nil
            case .depositTransfer: categoryId = depositCategoryId
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
            let stagedRow = StagedTransaction(parsed: parsed[index], suggestedCategoryId: categoryId, source: categoryId == nil ? .none : .manual,
                                              confidence: 1, fingerprint: fingerprints[index])
            staged.append(stagedRow)
            if categoryId == depositCategoryId { depositStagedIds.append(stagedRow.id) }
            decisions.append(ImportDecision(stagedId: stagedRow.id, finalCategoryId: categoryId, learnRule: false, note: item.note))
        }
        try ImportCoordinator.commit(db: db, accountId: accountId, sourceFileName: sourceFileName, staged: staged, decisions: decisions)

        // The deposit legs: the other side of each deposit transfer, linked (Add the other side…).
        var depositLegs: [DepositLeg] = []
        for stagedId in depositStagedIds {
            let index = staged.firstIndex { $0.id == stagedId }!
            guard let bbvaRow = try Transaction.filter(Column("accountId") == accountId && Column("fingerprint") == fingerprints[index]).fetchOne(db) else { continue }
            let leg = try ManualTransactions.addOtherSide(db: db, transactionId: bbvaRow.id!, accountId: depositAccountId)
            depositLegs.append(DepositLeg(date: leg.date, description: leg.rawDescription, amountMinorUnits: leg.amountMinorUnits, bbvaDescription: bbvaRow.rawDescription))
        }

        // 4. Rules for the repeatable kinds.
        let names = Dictionary(try Category.fetchAll(db).compactMap { c in c.id.map { ($0, c.name) } }, uniquingKeysWith: { a, _ in a })
        // A split's deposit part shares the rent's description: left out, so it can't block the rent rule.
        let candidates = ruleCandidates(rows: rows.indices.filter { !rows[$0].isDepositPart }.map { (rows[$0].row.description, rows[$0].row.matchedText, finalCategories[$0].flatMap { names[$0] }) },
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
        check(transactions.count == rows.count, "rows saved: \(transactions.count) of \(rows.count) (\(input.rows.count) statement rows, \(input.depositSplits.count) split)")
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

        let depositTransactions = try Transaction.filter(Column("accountId") == depositAccountId).fetchAll(db)
        let depositSnapshots = try BalanceSnapshot.filter(Column("accountId") == depositAccountId).fetchAll(db)
        let depositBalance = NetWorthCalculator.balance(accountId: depositAccountId, at: nil, snapshots: depositSnapshots, transactions: depositTransactions)?.native
        let expectedDeposit = (input.depositOpening?.minorUnits ?? 0) + depositLegs.reduce(0) { $0 + $1.amountMinorUnits }
        check(depositLegs.count == depositStagedIds.count && (depositBalance ?? 0) == expectedDeposit,
              "\(depositAccountName): \(depositLegs.count) leg(s) for \(depositStagedIds.count) deposit transfer(s), balance \(Money.format(depositBalance ?? 0, currency: .eur))")
        let depositLegIds = Set(depositTransactions.compactMap(\.id))
        let linkedDepositLegs = try TransferLink.active.fetchAll(db).filter { depositLegIds.contains($0.outTransactionId) || depositLegIds.contains($0.inTransactionId) }.count
        check(linkedDepositLegs == depositLegs.count, "every deposit leg is linked to its BBVA row: \(linkedDepositLegs) of \(depositLegs.count)")
        let splits = rows.filter(\.isDepositPart).map { part in
            DepositSplitDone(date: part.row.date, description: part.row.description, totalMinorUnits: part.row.amountMinorUnits, depositMinorUnits: part.amountMinorUnits)
        }

        guard failures.isEmpty else { throw ImportError.verificationFailed(verification) }
        let deposit = DepositReport(accountId: depositAccountId, transferCategory: try Category.fetchOne(db, key: depositCategoryId)?.name, transferCategoryGroup: groupName,
                                    openingMinorUnits: input.depositOpening?.minorUnits, openingDate: input.depositOpening?.date,
                                    splits: splits, legs: depositLegs, balanceMinorUnits: depositBalance)
        return Report(accountId: accountId, openingMinorUnits: first.openingMinorUnits, openingDate: openingDate, sortOrder: sortOrder,
                      transferCategory: tied?.name, transferCategoryGroup: tiedGroup,
                      createdCategories: categories.map(\.name), rowCount: transactions.count, byCategoryYear: byCategoryYear,
                      uncategorisedPending: pending, unresolvedTransfers: unresolved, rulesLearned: learned, rulesSkipped: skipped,
                      links: links, refiledByLinks: refiled, deposit: deposit, verification: verification)
    }

    public struct DepositLeg: Equatable, Sendable {
        public let date: Date
        public let description: String
        public let amountMinorUnits: Int
        public let bbvaDescription: String
    }

    public struct DepositSplitDone: Equatable, Sendable {
        public let date: Date
        public let description: String
        public let totalMinorUnits: Int
        public let depositMinorUnits: Int
    }

    public struct DepositReport: Equatable, Sendable {
        public let accountId: Int64
        public let transferCategory: String?
        public let transferCategoryGroup: String?
        public let openingMinorUnits: Int?
        public let openingDate: Date?
        public let splits: [DepositSplitDone]
        public let legs: [DepositLeg]
        /// Signed (negative = owed), now.
        public let balanceMinorUnits: Int?
    }

    /// One row to save: a statement row, or one part of a split one.
    struct ImportRow {
        let row: Row
        let amountMinorUnits: Int
        let isDepositPart: Bool
        let note: String?
    }

    /// The statement rows in order, each split row (`depositSplits`) as its rent part then its
    /// deposit part. Each split must name exactly one rent_received row, for less than it.
    static func importRows(_ input: Input) throws -> [ImportRow] {
        var splitByIndex: [Int: Int] = [:]
        for split in input.depositSplits {
            let matches = input.rows.indices.filter { input.rows[$0].kind == "rent_received" && input.rows[$0].date == split.date }
            guard matches.count == 1, let index = matches.first else {
                throw ImportError.badInput("--split-deposit: \(matches.count) rent_received rows on that day (need exactly 1)")
            }
            guard split.depositMinorUnits > 0, split.depositMinorUnits < input.rows[index].amountMinorUnits, splitByIndex[index] == nil else {
                throw ImportError.badInput("--split-deposit: the deposit must be positive, less than the credit, and split once")
            }
            splitByIndex[index] = split.depositMinorUnits
        }
        var result: [ImportRow] = []
        for (index, row) in input.rows.enumerated() {
            guard let deposit = splitByIndex[index] else {
                result.append(ImportRow(row: row, amountMinorUnits: row.amountMinorUnits, isDepositPart: false, note: nil))
                continue
            }
            let total = Money.format(row.amountMinorUnits, currency: .eur)
            result.append(ImportRow(row: row, amountMinorUnits: row.amountMinorUnits - deposit, isDepositPart: false, note: "Rent part of a \(total) credit (rest: deposit)"))
            result.append(ImportRow(row: row, amountMinorUnits: deposit, isDepositPart: true, note: "Deposit part of a \(total) credit"))
        }
        return result
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
        // A snapshot is the balance at the end of its day: every deposit transfer must come after it.
        if let opening = input.depositOpening {
            let depositDates = input.rows.filter { mapping(forKind: $0.kind) == .depositTransfer }.map(\.date) + input.depositSplits.map(\.date)
            if let earliest = depositDates.min(), earliest <= opening.date {
                throw ImportError.badInput("--deposit-date must be before the first deposit movement")
            }
        }
    }

    static func checkNotApplied(db: Database) throws {
        if try ImportBatch.filter(Column("sourceFileName") == sourceFileName).fetchCount(db) > 0 { throw ImportError.alreadyApplied }
        if let existing = try Account.fetchAll(db).first(where: { account in [accountName, depositAccountName].contains { account.name.caseInsensitiveCompare($0) == .orderedSame } }) {
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
        for transferName in ["Transfer: \(accountAlias)", "Transfer: \(depositAccountName)"] {
            if let existing = categoryNames.first(where: { $0.caseInsensitiveCompare(transferName) == .orderedSame }) { clashes.append("category “\(existing)”") }
        }
        guard clashes.isEmpty else { throw ImportError.nameClash(clashes) }
    }
}
