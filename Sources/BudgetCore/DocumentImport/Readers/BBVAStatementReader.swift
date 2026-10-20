import CoreGraphics
import Foundation
import GRDB

/// BBVA Portugal monthly "extrato global" PDFs, read in the app (`BBVAStatementParser`): the
/// current account's rows only add what isn't saved yet (categorised by saved rules alone, the
/// mortgage instalments and fund subscriptions as transfer legs), each instalment paired with
/// the receipt the statement settled and each subscription with its fund movement, and every
/// gap between them a Needs-you issue — never a silent transfer without its interest.
///
/// Staging is async, so it happens outside the readers' write transaction, as for UK
/// statements (`UKStatementReader`): `propose` only resolves the current account (`resolve`)
/// and returns the files it can't (Needs you); the pipeline stages each resolved statement
/// (`stage`, several of one account in date order) and then builds its items (`items`).
public struct BBVAStatementReader: ImportReader {
    public static let groupKey = "BBVA statements"
    /// Why a statement read by text recognition (a scan) is never Ready.
    public static let scannedReason = "This statement is a scan read by text recognition: its rows and balances can't be relied on, "
        + "so it can't be imported as it is. Import the PDF downloaded from BBVA instead, or leave this one out of this import"
    /// Pages read from a statement (`PDFGlyphTextExtractor`).
    static let maxPages = 50
    /// The digits of a "Conta Nº" that a Portuguese IBAN holds (its account core).
    static let coreDigits = 9

    /// The statement read and the current account its rows go to.
    public struct Resolved: Equatable, Sendable {
        public var statement: BBVAStatementParser.Statement
        public var currentAccountId: Int64
        /// How the account was found: "You chose BBVA", "Account number matches BBVA" …
        public var accountReason: String
        public var accountSource: ImportFactSource
        /// The recognition's reason when a learnt rule named the account.
        public var rememberedReason: String?
        /// The accounts chosen in the review (learnt on Confirm import).
        public var learnAccounts: [StatementAccountRole: Int64]
        /// The learnt rule that named the current account (marked used on Confirm import).
        public var rememberedRuleId: Int64? = nil
        /// The account chosen or remembered isn't the one whose details hold the printed Conta Nº
        /// (`"accountMismatch"`, Needs you, the holding account offered first).
        public var accountIssue: ImportIssue? = nil
    }

    public enum Resolution: Equatable, Sendable {
        case resolved(Resolved)
        case unresolved(ImportItem)
    }

    public init() {}

    public func handles(_ kind: ImportKind) -> Bool { kind == .bbvaStatement }

    /// The statement's text as `PDFGlyphTextExtractor` reads BBVA's glyph-named fonts (up to 50
    /// pages), when that text reads as a statement; else the text the file was loaded with.
    public func prepare(_ file: ImportFile, recognition: ImportRecognition) -> ImportFile {
        guard let document = CGPDFDocument(file.url as CFURL) else { return file }
        let text = PDFGlyphTextExtractor.text(of: document, maxPages: Self.maxPages)
        guard !text.isEmpty, (try? BBVAStatementParser.parse(text)) != nil else { return file }
        var prepared = file
        prepared.text = text
        prepared.textStatus = .text
        prepared.usedOCR = false
        return prepared
    }

    /// The Needs-you items of the statements that can't be read or have no account; resolved
    /// statements give nothing here (the pipeline stages them and calls `items`).
    public func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        try files.compactMap { file, recognition in
            if case .unresolved(let item) = try Self.resolve(file: file, recognition: recognition, context: context, db: db) { return item }
            return nil
        }
    }

    // MARK: Resolving

    /// The statement parsed and its current account: the one chosen in the review, else the
    /// intent's, else the learnt `statementAccount` rule for `"bbva:<digits>"`, else the one
    /// account whose details hold the statement's account (`holds`), else the account named
    /// `BBVAHistoryImport.accountName` unless its recorded details are another account's, else
    /// unknown (the existing accounts offered). Checked as UK statements are: a chosen account
    /// (either way) another account's details hold the Conta Nº of is an `accountMismatch`; a
    /// learnt rule naming an account that doesn't hold it gives way to the one account that
    /// does, asked (`accountMismatch`, that account offered first).
    public static func resolve(file: ImportFile, recognition: ImportRecognition, context: ImportContext, db: Database) throws -> Resolution {
        func unreadable(_ text: String) -> Resolution {
            var item = ImportItem(file: file, recognition: recognition, title: file.fileName, effect: .none, groupKey: groupKey)
            let reason = "\(text): file it as a document, or leave it out of this import"
            item.issues.append(ImportIssue(id: "readerProblem", kind: .readerProblem(text), reason: reason, offers: [.chooseKind(.other)]))
            return .unresolved(item)
        }
        guard let text = file.text, !text.isEmpty else { return unreadable("No text could be read from the statement") }
        let statement: BBVAStatementParser.Statement
        do {
            statement = try BBVAStatementParser.parse(text)
        } catch {
            return unreadable("The statement could not be read: \(error.localizedDescription)")
        }
        let accounts = context.accounts.isEmpty ? try Account.fetchAll(db) : context.accounts
        let ids = Set(accounts.compactMap(\.id))
        func name(_ id: Int64) -> String { accounts.first { $0.id == id }?.displayName ?? "Account #\(id)" }
        let conta = statement.currentAccount ?? ""
        func resolved(_ id: Int64, _ reason: String, _ source: ImportFactSource, remembered: String? = nil,
                      learn: [StatementAccountRole: Int64] = [:], ruleId: Int64? = nil, issue: ImportIssue? = nil) -> Resolution {
            .resolved(Resolved(statement: statement, currentAccountId: id, accountReason: reason, accountSource: source,
                               rememberedReason: remembered, learnAccounts: learn, rememberedRuleId: ruleId, accountIssue: issue))
        }

        // The accounts whose details hold the printed Conta Nº.
        let matching = accounts.filter { holds($0, conta: conta) }
        let holding = matching.compactMap(\.id)
        /// A question about `id` when it doesn't hold the Conta Nº and another account does.
        func mismatch(_ id: Int64, _ reason: (String) -> String) -> ImportIssue? {
            guard let first = holding.first, !holding.contains(id) else { return nil }
            return ImportIssue(id: accountMismatchIssueId, kind: .statement(.unknownAccount), reason: reason(name(first)),
                               offers: StatementAccountOptions.ordered(accounts, currency: .eur, region: .europe, first: first))
        }
        func chosen(_ id: Int64, learn: [StatementAccountRole: Int64]) -> Resolution {
            resolved(id, "You chose \(name(id))", .intent, learn: learn, issue: mismatch(id) { holder in
                "This statement's Conta Nº is \(holder)'s, not \(name(id))'s: choose its account or leave it out of this import"
            })
        }

        if let id = context.intent.statementAccounts[.current], ids.contains(id) {
            return chosen(id, learn: [.current: id])
        }
        if let id = context.intent.accountId, ids.contains(id) {
            return chosen(id, learn: [:])
        }
        if let signature = StatementSignature.key(for: file, kind: .bbvaStatement),
           let (id, rule) = try learnt(db: db, key: signature.key, accounts: accounts) {
            let conflict = mismatch(id) { holder in
                "This statement's Conta Nº is \(holder)'s, but files like this were remembered for \(name(id)): confirm \(holder) or choose its account"
            }
            // The printed digits win over a rule naming another account (asked, never silent).
            if let conflict, holding.count == 1 {
                return resolved(holding[0], "Account number matches \(name(holding[0]))", .textLayer, issue: conflict)
            }
            return resolved(id, "Remembered for files like this: \(name(id))", .learntRule,
                            remembered: "Remembered: \(rule.matchLabel) → \(name(id))", ruleId: rule.id, issue: conflict)
        }
        if matching.count == 1, let id = matching[0].id {
            return resolved(id, "Account number matches \(name(id))", .textLayer)
        }
        if matching.isEmpty, let named = accounts.first(where: { $0.name == BBVAHistoryImport.accountName }), let id = named.id,
           !hasOtherDetails(named, conta: conta) {
            return resolved(id, "The account named \(BBVAHistoryImport.accountName)", .textLayer)
        }
        var item = ImportItem(file: file, recognition: recognition, title: title(statement), effect: .none, groupKey: groupKey)
        let digits = digitsOf(conta)
        let shown = digits.isEmpty ? "this statement's account" : "BBVA account …\(digits.suffix(4))"
        item.issues.append(ImportIssue(id: "unknownAccount", kind: .statement(.unknownAccount),
                                       reason: "No account matches \(shown): choose it or leave the statement out of this import",
                                       offers: StatementAccountOptions.ordered(accounts, currency: .eur, region: .europe)))
        return .unresolved(item)
    }

    /// The question of a chosen or remembered account that isn't the one holding the Conta Nº.
    public static let accountMismatchIssueId = "accountMismatch"

    /// Whether the account's details are this "Conta Nº": its stored account number has the
    /// same digits, or its IBAN's digits hold the Conta Nº's last 9 (the account core a PT IBAN
    /// carries between its bank/branch codes and check digits).
    static func holds(_ account: Account, conta: String) -> Bool {
        let digits = digitsOf(conta)
        guard !digits.isEmpty else { return false }
        if let number = account.accountNumber.map(digitsOf), number == digits { return true }
        let core = String(digits.suffix(coreDigits))
        guard core.count == coreDigits, let iban = account.iban.map(digitsOf) else { return false }
        return iban.contains(core)
    }

    /// The account records an IBAN or account number, and they aren't this Conta Nº's.
    static func hasOtherDetails(_ account: Account, conta: String) -> Bool {
        let recorded = [account.iban, account.accountNumber].contains { !($0.map(digitsOf) ?? "").isEmpty }
        return recorded && !holds(account, conta: conta)
    }

    /// The enabled learnt rule's account, when it still exists.
    private static func learnt(db: Database, key: String, accounts: [Account]) throws -> (Int64, ImportRule)? {
        guard let rule = try ImportRuleStore.rule(db: db, kind: .statementAccount, key: key),
              let action = try? JSONDecoder().decode(StatementAccountAction.self, from: Data(rule.actionJSON.utf8)),
              accounts.contains(where: { $0.id == action.accountId }) else { return nil }
        return (action.accountId, rule)
    }

    static func digitsOf(_ text: String) -> String { text.filter(\.isNumber) }

    // MARK: Staging

    /// The statement's movements staged on its current account with saved rules only
    /// (`ImportCoordinator.Categorization.rulesOnly`): rows already saved, or held by an
    /// earlier statement of the import (`alreadyStaged`), are duplicates.
    public static func stage(_ resolved: Resolved, coordinator: ImportCoordinator, alreadyStaged: [StagedTransaction] = []) async throws -> StagedImport {
        try await coordinator.stageParsedImport(parsed(resolved.statement), unparsedLines: resolved.statement.unreadLines,
                                                accountId: resolved.currentAccountId, categorization: .rulesOnly, alreadyStaged: alreadyStaged)
    }

    static func parsed(_ statement: BBVAStatementParser.Statement) -> [ParsedTransaction] {
        statement.movements.map { ParsedTransaction(date: $0.date, rawDescription: $0.description, amountMinorUnits: $0.amountMinorUnits,
                                                    balanceAfterMinorUnits: $0.balanceAfterMinorUnits) }
    }

    // MARK: Items

    /// A staged statement's review items: the statement (its new rows, legs, closing and
    /// accounts), plus one child counting the rows already imported — or, when every row is,
    /// its legs are there, no estimate is to replace, the fund is valued on the period end and
    /// nothing contradicts the saved data (`StatementChecks.keepsFromDuplicates`), the statement itself as a duplicate (a closing that disagrees with the
    /// saved data still asks: `StatementChecks.recheck`). `batchRows`: the current
    /// account's rows the earlier statements of the import add (a receipt whose debit one of
    /// them adds is theirs to pair). The closing is checked by `StatementChecks.recheck`.
    public static func items(file: ImportFile, recognition: ImportRecognition, resolved: Resolved, staged: StagedImport,
                             context: ImportContext, db: Database, batchRows: [StagedTransaction] = [],
                             skipped: [StagedTransaction] = []) throws -> [ImportItem] {
        let statement = resolved.statement
        let accounts = context.accounts.isEmpty ? try Account.fetchAll(db) : context.accounts
        let current = try accounts.first { $0.id == resolved.currentAccountId } ?? Account.fetchOne(db, key: resolved.currentAccountId)
        var reading = Reading(statement: statement, currentId: resolved.currentAccountId, currency: current?.currency ?? .eur,
                              accounts: accounts, db: db, rows: staged.staged, learn: resolved.learnAccounts, batchRows: batchRows,
                              skipped: skipped)

        var recognition = recognition
        if let remembered = resolved.rememberedReason { recognition.reason = remembered }
        if file.usedOCR {
            // A scan: never Ready, and the review says why.
            recognition.confidence = .needsReview
            recognition.reason = scannedReason
        } else if recognition.kind == .bbvaStatement {
            // Read again from its glyphs (`prepare`): no longer text recognition.
            recognition.confidence = .certain
        }
        let title = title(statement)
        var item = ImportItem(file: file, recognition: recognition, title: title, effect: .none, groupKey: groupKey)

        try reading.resolveLinkedAccounts(intent: context.intent)
        try reading.matchInstalments()
        try reading.pairFund()
        try reading.fileLegs()
        try reading.checkFundValue()
        reading.unreadLines()
        item.issues = (resolved.accountIssue.map { [$0] } ?? []) + reading.issues

        item.facts = reading.facts(accountName: current?.displayName ?? "Account #\(reading.currentId)", resolved: resolved, file: file)
        item.placement = ImportNaming.placement(kind: recognition.kind, facts: item.facts, file: file, persons: [])
        item.effect = .bbvaStatement(BBVAStatementEffect(statement: statement, currentAccountId: reading.currentId, loanAccountId: reading.loanId,
                                                         fundAccountId: reading.fundId, staged: reading.rows, instalments: reading.instalments,
                                                         fundPairs: reading.fundPairs, closing: reading.closing, sourceFileName: file.fileName,
                                                         learnAccounts: reading.learn, estimates: reading.estimates))
        if case .bbvaStatement(var effect) = item.effect {
            effect.certainDuplicates = staged.duplicateFingerprints
            effect.rememberedRuleIds = (resolved.rememberedRuleId.map { [$0] } ?? []) + reading.rememberedRuleIds
            effect.marketMovementMinorUnits = reading.marketMovement
            item.effect = .bbvaStatement(effect)
        }
        let duplicates = staged.duplicates.count
        let of = "Already imported: \(duplicates) row\(duplicates == 1 ? "" : "s")"
        if duplicates > 0, reading.rows.isEmpty, reading.estimates.isEmpty, !item.issues.contains(where: StatementChecks.keepsFromDuplicates) {
            // Every row imported and nothing contradicted (pure questions aside): a duplicate
            // unless the fund's valuation is still to add.
            guard let movement = reading.marketMovement else {
                item.duplicate = ImportDuplicate(level: .transactions, of: of)
                return [item]
            }
            item.notes.append("Every row is already imported: adds only the fund's market movement of "
                              + "\(signed(movement, reading.currency)) on \(dayText(statement.periodEnd))")
        }
        var items = [item]
        if duplicates > 0 {
            items.append(ImportItem(file: file, recognition: recognition, title: "\(title): \(of)", effect: .none,
                                    duplicate: ImportDuplicate(level: .transactions, of: of), parentId: item.id, groupKey: groupKey))
        }
        return items
    }

    /// One statement's reading in the write pass: its accounts, legs and issues, step by step.
    private struct Reading {
        let statement: BBVAStatementParser.Statement
        let currentId: Int64
        let currency: Currency
        let accounts: [Account]
        let db: Database
        /// The staged (new) rows; legs re-file theirs under the other account's transfer category.
        var rows: [StagedTransaction]
        var learn: [StatementAccountRole: Int64]
        var loanId: Int64?
        var fundId: Int64?
        var instalments: [BBVAStatementLegs.InstalmentMatch] = []
        var fundPairs: [BBVAStatementLegs.FundPair] = []
        var estimates: [BBVAStatementEffect.Estimate] = []
        /// The fund's Market movement on the period end confirming it adds (`BBVAStatementLegs.marketMovement`).
        var marketMovement: Int?
        /// Estimated interest rows already counted for a receipt.
        var claimedEstimates: Set<Int64> = []
        var issues: [ImportIssue] = []
        /// The learnt rules that named the mortgage or fund.
        var rememberedRuleIds: [Int64] = []
        /// The current account's rows the earlier statements of the import add (their legs are theirs).
        let batchRows: [StagedTransaction]
        /// The account's rows the user skipped (this statement's and the earlier ones'): never a
        /// receipt's or fund movement's debit — nothing writes them or their legs.
        let skipped: [StagedTransaction]

        init(statement: BBVAStatementParser.Statement, currentId: Int64, currency: Currency, accounts: [Account], db: Database,
             rows: [StagedTransaction], learn: [StatementAccountRole: Int64], batchRows: [StagedTransaction], skipped: [StagedTransaction]) {
            let skippedPrints = Set(skipped.map(\.fingerprint))
            self.batchRows = batchRows.filter { !skippedPrints.contains($0.fingerprint) }
            self.skipped = skipped
            self.statement = statement
            self.currentId = currentId
            self.currency = currency
            self.accounts = accounts
            self.db = db
            self.rows = rows
            self.learn = learn
        }

        var closing: StatementClosing { StatementClosing(date: statement.periodEnd, balanceMinorUnits: statement.closingMinorUnits) }

        func money(_ value: Int) -> String { BBVAStatementReader.signed(value, currency) }

        /// One movement per staged row, in its order (a row kept with a free fingerprint reads as itself).
        var newMovements: [BBVAStatementParser.Movement] {
            let fingerprints = TransactionFingerprint.computeAll(accountId: currentId, transactions: BBVAStatementReader.parsed(statement))
            var index: [String: Int] = [:]
            for (i, print) in fingerprints.enumerated() where index[print] == nil { index[print] = i }
            return rows.map { row in
                index[row.fingerprint].map { statement.movements[$0] }
                    ?? BBVAStatementParser.Movement(date: row.parsed.date, valueDate: row.parsed.date, description: row.parsed.rawDescription,
                                                    amountMinorUnits: row.parsed.amountMinorUnits, balanceAfterMinorUnits: nil)
            }
        }

        mutating func issue(_ id: String, _ kind: ImportIssueKind, _ reason: String, offers: [ImportResolution] = []) {
            issues.append(ImportIssue(id: id, kind: kind, reason: reason, offers: offers))
        }

        // MARK: Accounts

        /// The mortgage (asked only when the statement settled receipts) and the fund (only
        /// when it has one); each must differ from the statement's other accounts.
        mutating func resolveLinkedAccounts(intent: ImportIntent) throws {
            loanId = try linked(.mortgage, key: BBVAStatementReader.ruleKey(.mortgage, statement)?.key, name: BBVAFundMortgageImport.loanAccountName,
                                excluding: [currentId], intent: intent)
            if statement.fund != nil {
                fundId = try linked(.fund, key: BBVAStatementReader.ruleKey(.fund, statement)?.key, name: BBVAFundMortgageImport.fundAccountName,
                                    excluding: Set([currentId] + (loanId.map { [$0] } ?? [])), intent: intent)
            }
            func options(_ role: StatementAccountRole, excluding: Set<Int64>) -> [ImportResolution] {
                accounts.compactMap(\.id).filter { !excluding.contains($0) }.map { .chooseAccount(role, $0) }
            }
            if loanId == nil, !statement.loanReceipts.isEmpty {
                issue("unknownLinkedAccount.mortgage", .statement(.unknownLinkedAccount(.mortgage)),
                      "No mortgage account found for this statement's instalments: choose it or leave the statement out of this import",
                      offers: options(.mortgage, excluding: Set([currentId] + (fundId.map { [$0] } ?? []))))
            }
            if fundId == nil, statement.fund != nil {
                issue("unknownLinkedAccount.fund", .statement(.unknownLinkedAccount(.fund)),
                      "No fund account found for this statement's fund: choose it or leave the statement out of this import",
                      offers: options(.fund, excluding: Set([currentId] + (loanId.map { [$0] } ?? []))))
            }
        }

        /// A statement's mortgage or fund: the one chosen in the review, else the learnt
        /// `statementAccount` rule for `key`, else (mortgage) the `.mortgage` account of the one
        /// property whose `.current` account is the statement's, else the account named `name`;
        /// never an existing account of `excluding`.
        private mutating func linked(_ role: StatementAccountRole, key: String?, name: String, excluding: Set<Int64>,
                                     intent: ImportIntent) throws -> Int64? {
            let usable = Set(accounts.compactMap(\.id)).subtracting(excluding)
            if let id = intent.statementAccounts[role], usable.contains(id) {
                learn[role] = id
                return id
            }
            if let key, let (id, rule) = try BBVAStatementReader.learnt(db: db, key: key, accounts: accounts), usable.contains(id) {
                if let ruleId = rule.id { rememberedRuleIds.append(ruleId) }
                return id
            }
            if role == .mortgage {
                let properties = try Properties.properties(db: db, accountId: currentId).filter { $0.role == .current }.map(\.propertyId)
                let loans = Set(try properties.flatMap { try Properties.accounts(db: db, propertyId: $0, role: .mortgage).map(\.accountId) })
                if loans.count == 1, let id = loans.first, usable.contains(id) { return id }
            }
            return accounts.first { $0.name == name && $0.id.map(usable.contains) == true }?.id
        }

        // MARK: Mortgage

        /// The receipts that are the mortgage's: all of them when the statement has one loan
        /// contract; with several, only those of the contract the mortgage account's details
        /// hold — the others are issues, never paired.
        mutating func mortgageReceipts() -> [BBVAStatementParser.LoanReceipt] {
            let receipts = statement.loanReceipts
            guard Set(receipts.map { $0.contract ?? "" }).count > 1 else { return receipts }
            let loan = loanId.flatMap { id in accounts.first { $0.id == id } }
            var own: [BBVAStatementParser.LoanReceipt] = []
            for receipt in receipts {
                if let loan, let contract = receipt.contract, BBVAStatementReader.holds(loan, conta: contract) {
                    own.append(receipt)
                } else {
                    let text = "Receipt \(receipt.number) (\(dayText(receipt.operationDate))) is of loan contract \(receipt.contract ?? "unknown"), "
                        + "not attributable to the mortgage"
                    issue("instalmentMismatch.contract.\(receipt.number)", .statement(.instalmentMismatch(text)), text)
                }
            }
            return own
        }

        /// Instalments paired on the new rows. A receipt with no new debit is done only when its
        /// saved debit is already a transfer to the loan with its interest row; otherwise an issue.
        mutating func matchInstalments() throws {
            let movements = newMovements
            let result = BBVAStatementLegs.matchInstalments(movements: movements, receipts: mortgageReceipts())
            instalments = result.matches
            for index in result.movementsWithoutReceipt {
                let row = movements[index]
                let text = "Instalment of \(dayText(row.date)) \(money(row.amountMinorUnits)) has no settled receipt on the statement"
                issue("instalmentMismatch.row.\(index)", .statement(.instalmentMismatch(text)), text)
            }
            guard !result.receiptsWithoutMovement.isEmpty else { return }
            var saved = try savedRows { BBVAStatementLegs.isInstalment($0.rawDescription) }
            let loanCategory = try loanId.flatMap { try TransferCategories.category(db: db, forAccountId: $0)?.id }
            var batch = batchRows.filter { BBVAStatementLegs.isInstalment($0.parsed.rawDescription) }
            var skippedDebits = skipped.filter { BBVAStatementLegs.isInstalment($0.parsed.rawDescription) }
            for receipt in result.receiptsWithoutMovement {
                // Its debit skipped by the user: neither the debit nor its legs are written.
                if let held = skippedDebits.firstIndex(where: { $0.parsed.date == receipt.operationDate && $0.parsed.amountMinorUnits == -receipt.totalMinorUnits }) {
                    let row = skippedDebits.remove(at: held)
                    let text = "Instalment of \(dayText(row.parsed.date)) \(money(row.parsed.amountMinorUnits)) was skipped: its receipt has no debit"
                    issue("instalmentMismatch.skipped.\(receipt.number)", .statement(.instalmentMismatch(text)), text)
                    continue
                }
                // Its debit added by an earlier statement of the import, which pairs it.
                if let held = batch.firstIndex(where: { $0.parsed.date == receipt.operationDate && $0.parsed.amountMinorUnits == -receipt.totalMinorUnits }) {
                    batch.remove(at: held)
                    continue
                }
                guard let found = saved.firstIndex(where: { $0.date == receipt.operationDate && $0.amountMinorUnits == -receipt.totalMinorUnits }) else {
                    let text = "Receipt \(receipt.number) (\(dayText(receipt.operationDate))) has no instalment debit"
                    issue("instalmentMismatch.receipt.\(receipt.number)", .statement(.instalmentMismatch(text)), text)
                    continue
                }
                let debit = saved.remove(at: found)
                guard let loanId else { continue }  // asked for already (unknownLinkedAccount)
                let charges = BBVAStatementLegs.charges(receipt)
                let recordedCount = charges == 0 ? 0 : try Transaction
                    .filter(Column("accountId") == loanId && Column("rawDescription") == "\(BBVAFundMortgageImport.interestCategoryName) (instalment \(receipt.number))")
                    .fetchCount(db)
                let recorded = recordedCount > 0
                var interest = recorded || charges == 0
                let transfer = try isTransfer(debit, to: loanId, category: loanCategory)
                if !recorded, transfer, let derived = try derivedInterest(loanId: loanId, on: receipt.operationDate) {
                    // The fund/mortgage tool's estimate counts as the interest leg; a different
                    // split on the receipt asks to replace it.
                    interest = true
                    claimedEstimates.insert(derived.id!)
                    if derived.amountMinorUnits != -charges {
                        estimates.append(BBVAStatementEffect.Estimate(transactionId: derived.id!, receipt: receipt))
                        let text = "Instalment of \(dayText(receipt.operationDate)): the interest was estimated "
                            + "(\(Money.format(-derived.amountMinorUnits, currency: currency))); the statement's receipt says "
                            + "\(Money.format(charges, currency: currency)). Replace the estimate?"
                        issue("instalmentMismatch.estimate.\(receipt.number)", .statement(.instalmentMismatch(text)), text, offers: [.acknowledge])
                    }
                }
                if !transfer || !interest {
                    let text = "Instalment of \(dayText(debit.date)) \(money(debit.amountMinorUnits)) is already imported without its mortgage legs"
                    issue("instalmentMismatch.legs.\(receipt.number)", .statement(.instalmentMismatch(text)), text)
                }
            }
        }

        /// The loan's unclaimed "Mortgage interest (derived)" row on the instalment's day
        /// (`BBVAFundMortgageImport`'s estimate for an instalment it had no receipt for).
        private func derivedInterest(loanId: Int64, on date: Date) throws -> Transaction? {
            try Transaction.filter(Column("accountId") == loanId && Column("date") == date
                                   && Column("rawDescription") == BBVAStatementReader.derivedInterestDescription)
                .order(Column("id")).fetchAll(db).first { !claimedEstimates.contains($0.id!) }
        }

        // MARK: Fund

        /// Subscriptions paired on the new rows. A fund movement with no new debit is done only
        /// when its saved debit is already a transfer to the fund; otherwise an issue.
        mutating func pairFund() throws {
            let movements = newMovements
            let result = BBVAStatementLegs.pairFundMovements(movements: movements, fund: statement.fund)
            fundPairs = result.pairs
            for index in result.unpairedSubscriptions {
                let row = movements[index]
                let text = "Subscription of \(dayText(row.date)) \(money(row.amountMinorUnits)) has no fund movement on the statement"
                issue("fundMismatch.row.\(index)", .statement(.fundMismatch(text)), text)
            }
            guard !result.unpairedFundMovements.isEmpty else { return }
            var saved = try savedRows { BBVAFundMortgageImport.isSubscription($0.rawDescription) && $0.amountMinorUnits < 0 }
            let window = Double(BBVAEarlierHistoryImport.fundPairingDays) * 86_400
            let fundCategory = try fundId.flatMap { try TransferCategories.category(db: db, forAccountId: $0)?.id }
            var batch = batchRows.filter { BBVAFundMortgageImport.isSubscription($0.parsed.rawDescription) && $0.parsed.amountMinorUnits < 0 }
            var skippedDebits = skipped.filter { BBVAFundMortgageImport.isSubscription($0.parsed.rawDescription) && $0.parsed.amountMinorUnits < 0 }
            for (offset, movement) in result.unpairedFundMovements.enumerated() {
                // Its debit skipped by the user: neither the debit nor its fund leg is written.
                if let held = skippedDebits.firstIndex(where: {
                    $0.parsed.amountMinorUnits == -movement.amountMinorUnits && abs($0.parsed.date.timeIntervalSince(movement.date)) <= window
                }) {
                    let row = skippedDebits.remove(at: held)
                    let text = "Subscription of \(dayText(row.parsed.date)) \(money(row.parsed.amountMinorUnits)) was skipped: its fund movement has no debit"
                    issue("fundMismatch.skipped.\(offset)", .statement(.fundMismatch(text)), text)
                    continue
                }
                // Its debit added by an earlier statement of the import, which pairs it.
                if let held = batch.firstIndex(where: {
                    $0.parsed.amountMinorUnits == -movement.amountMinorUnits && abs($0.parsed.date.timeIntervalSince(movement.date)) <= window
                }) {
                    batch.remove(at: held)
                    continue
                }
                let options = saved.indices.filter {
                    saved[$0].amountMinorUnits == -movement.amountMinorUnits && abs(saved[$0].date.timeIntervalSince(movement.date)) <= window
                }
                guard let found = options.min(by: { abs(saved[$0].date.timeIntervalSince(movement.date)) < abs(saved[$1].date.timeIntervalSince(movement.date)) }) else {
                    let text = "Fund movement of \(dayText(movement.date)) \(money(movement.amountMinorUnits)) has no subscription debit on the statement"
                    issue("fundMismatch.fund.\(offset)", .statement(.fundMismatch(text)), text)
                    continue
                }
                let debit = saved.remove(at: found)
                guard let fundId else { continue }  // asked for already (unknownLinkedAccount)
                if try !isTransfer(debit, to: fundId, category: fundCategory) {
                    let text = "Subscription of \(dayText(debit.date)) \(money(debit.amountMinorUnits)) is already imported without its fund leg"
                    issue("fundMismatch.legs.\(offset)", .statement(.fundMismatch(text)), text)
                }
            }
        }

        /// A fund already valued on the period end must already be at the statement's value;
        /// one not valued yet gets the Market movement that brings it there (`marketMovement`,
        /// as `BBVAStatementLegs.marketMovement` will compute it after the fund legs).
        mutating func checkFundValue() throws {
            guard let fundId, let value = statement.fund else { return }
            let market = try BuiltInCategories.category(db: db, role: .marketMovement)
            let valued = try Transaction.filter(Column("accountId") == fundId && Column("date") == statement.periodEnd && Column("categoryId") == market.id).fetchCount(db)
            guard valued > 0 else {
                let saved = NetWorthCalculator.balance(accountId: fundId, at: statement.periodEnd,
                                                       snapshots: try BalanceSnapshot.filter(Column("accountId") == fundId).fetchAll(db),
                                                       transactions: try Transaction.filter(Column("accountId") == fundId).fetchAll(db))?.native ?? 0
                let movement = value.closingMinorUnits - saved - fundPairs.reduce(0) { $0 + $1.fundMovement.amountMinorUnits }
                marketMovement = movement == 0 ? nil : movement
                return
            }
            let held = (NetWorthCalculator.balance(accountId: fundId, at: BalanceUpdates.endOfDay(statement.periodEnd),
                                                   snapshots: try BalanceSnapshot.filter(Column("accountId") == fundId).fetchAll(db),
                                                   transactions: try Transaction.filter(Column("accountId") == fundId).fetchAll(db))?.native ?? 0)
                + fundPairs.reduce(0) { $0 + $1.fundMovement.amountMinorUnits }
            guard held != value.closingMinorUnits else { return }
            let text = "The fund already has a market movement on \(dayText(statement.periodEnd)), but would be at \(money(held)), "
                + "not the statement's \(money(value.closingMinorUnits))"
            issue("fundMismatch.value", .statement(.fundMismatch(text)), text)
        }

        // MARK: Legs, lines and closing

        /// The paired rows filed under the loan's or fund's transfer category; an account
        /// without one is an issue (its legs couldn't be linked).
        mutating func fileLegs() throws {
            func file(_ indices: [Int], to accountId: Int64?, role: StatementAccountRole) throws {
                guard let accountId, !indices.isEmpty else { return }
                guard let category = try TransferCategories.category(db: db, forAccountId: accountId)?.id else {
                    let name = accounts.first { $0.id == accountId }?.displayName ?? "Account #\(accountId)"
                    let text = "\(name) has no transfer category: give it one on the Categories screen, or leave the statement out of this import"
                    issue("noTransferCategory.\(role.rawValue)", .readerProblem(text), text)
                    return
                }
                for index in indices {
                    let row = rows[index]
                    // The leg is the loan's or fund's: never another account's transfer match.
                    rows[index] = StagedTransaction(id: row.id, parsed: row.parsed, suggestedCategoryId: category, source: .transfer, confidence: 1,
                                                    fingerprint: row.fingerprint, transfer: nil, replacesManual: row.replacesManual)
                }
            }
            try file(instalments.map(\.movementIndex), to: loanId, role: .mortgage)
            try file(fundPairs.map(\.movementIndex), to: fundId, role: .fund)
            let charged = instalments.contains { BBVAStatementLegs.charges($0.receipt) != 0 } || !estimates.isEmpty
            if charged, try BBVAStatementLegs.interestCategoryId(db: db) == nil {
                let name = BBVAFundMortgageImport.interestCategoryName
                let text = "There is no “\(name)” category for the instalments' interest: add it on the Categories screen, or leave the statement out of this import"
                issue("noInterestCategory", .readerProblem(text), text)
            }
        }

        /// Lines inside the movements that read as none.
        mutating func unreadLines() {
            guard !statement.unreadLines.isEmpty else { return }
            let count = statement.unreadLines.count
            issue("unparsedLines", .statement(.unparsedLines(statement.unreadLines)),
                  "\(count) line\(count == 1 ? "" : "s") of the statement couldn't be read: add \(count == 1 ? "it" : "them") by hand after the import",
                  offers: [.acknowledge])
        }

        // MARK: Facts

        /// What it says, as read (text recognition: each to check).
        func facts(accountName: String, resolved: Resolved, file: ImportFile) -> [ImportFact] {
            var facts = [ImportFact(field: .reference, value: .text(accountName), source: resolved.accountSource, confidence: .certain,
                                    reason: resolved.accountReason)]
            let source: ImportFactSource = file.usedOCR ? .ocr : .textLayer
            func read(_ field: ImportFigureField, _ value: ImportFactValue, _ reason: String) {
                facts.append(ImportFact(field: field, value: value, source: source, confidence: .certain, reason: reason))
            }
            read(.periodStart, .date(statement.periodStart), "PERÍODO DE on the statement")
            read(.periodEnd, .date(statement.periodEnd), "PERÍODO DE on the statement")
            read(.openingBalance, .money(statement.openingMinorUnits, currency), "Saldo inicial of the current account")
            read(.closingBalance, .money(statement.closingMinorUnits, currency), "Saldo final of the current account")
            read(.rows, .text(String(statement.movements.count)), "Movements of the current account")
            if !instalments.isEmpty {
                let k = instalments.count
                let charges = instalments.reduce(0) { $0 + BBVAStatementLegs.charges($1.receipt) }
                let capital = instalments.reduce(0) { $0 + $1.receipt.capitalMinorUnits }
                read(.instalments, .text("\(k) instalment\(k == 1 ? "" : "s"): interest \(Money.format(charges, currency: currency)), capital \(Money.format(capital, currency: currency))"),
                     "COBRANÇAS EFECTUADAS on the statement")
            }
            if let value = statement.fund {
                let subscribed = fundPairs.reduce(0) { $0 + $1.fundMovement.amountMinorUnits }
                read(.fund, .text("Fund: +\(Money.format(subscribed, currency: currency)), value \(Money.format(value.closingMinorUnits, currency: currency))"),
                     "The savings account on the statement")
            }
            return facts
        }

        // MARK: Saved rows

        /// The current account's saved rows in the statement's period that `include` takes.
        private func savedRows(_ include: (Transaction) -> Bool) throws -> [Transaction] {
            try Transaction.filter(Column("accountId") == currentId && Column("date") >= statement.periodStart.addingTimeInterval(-7 * 86_400)
                                   && Column("date") <= statement.periodEnd.addingTimeInterval(7 * 86_400))
                .order(Column("date"), Column("id")).fetchAll(db).filter(include)
        }

        /// Whether a saved debit already moves money to `accountId`: filed under its transfer
        /// category, or linked to a leg on it.
        private func isTransfer(_ debit: Transaction, to accountId: Int64, category: Int64?) throws -> Bool {
            if let category, debit.categoryId == category { return true }
            guard let id = debit.id else { return false }
            let links = try TransferLink.active.filter(Column("outTransactionId") == id || Column("inTransactionId") == id).fetchAll(db)
            let others = links.map { $0.outTransactionId == id ? $0.inTransactionId : $0.outTransactionId }
            guard !others.isEmpty else { return false }
            return try Transaction.filter(others.contains(Column("id")) && Column("accountId") == accountId).fetchCount(db) > 0
        }
    }

    static func title(_ statement: BBVAStatementParser.Statement) -> String { "BBVA statement \(statement.label)" }

    // MARK: Mortgage balance

    static let mortgageBalanceIssueId = "instalmentMismatch.balance"

    /// A statement whose loan wouldn't owe what its last receipt leaves: the receipt, the loan
    /// and the balance it would have.
    struct MortgageMismatch {
        var receipt: BBVAStatementParser.LoanReceipt
        var loan: Account?
        var mismatch: StatementMismatch
    }

    /// The loan's balance at the end of the last receipt's day (of this statement's
    /// instalments and estimates) against `-outstandingAfter`: the saved rows, the earlier
    /// statements' moves not saved yet (`batchLoan`), and, unless already written (`ownWritten`),
    /// this statement's own (+total and −charges per instalment, the estimates replaced). Nil
    /// when it matches, can't be checked, or the statement writes no receipt.
    static func mortgageMismatch(db: Database, _ effect: BBVAStatementEffect, ownWritten: Bool) throws -> MortgageMismatch? {
        guard let loanId = effect.loanAccountId else { return nil }
        let receipts = effect.instalments.map(\.receipt) + effect.estimates.map(\.receipt)
        guard let last = receipts.max(by: { ($0.operationDate, $0.number) < ($1.operationDate, $1.number) }) else { return nil }
        var moves = try unsavedBatchLoan(db: db, effect.batchLoan).map { ($0.date, $0.amountMinorUnits) }
        if !ownWritten { moves += try ownLoanRows(db: db, effect).map { ($0.date, $0.amountMinorUnits) } }
        let closing = StatementClosing(date: last.operationDate, balanceMinorUnits: -last.outstandingAfterMinorUnits)
        guard let mismatch = try StatementCheck.compare(db: db, accountId: loanId, closing: closing, stagedRows: moves).mismatch else { return nil }
        return MortgageMismatch(receipt: last, loan: try Account.fetchOne(db, key: loanId), mismatch: mismatch)
    }

    /// What applying the statement moves its loan by, per receipt: an instalment's +capital
    /// (leg +total, interest −charges), an estimate's replacement (−charges less the estimate).
    static func ownLoanRows(db: Database, _ effect: BBVAStatementEffect) throws -> [BBVAStatementEffect.BatchLoanRow] {
        var rows = effect.instalments.map { match in
            BBVAStatementEffect.BatchLoanRow(date: match.receipt.operationDate,
                                             amountMinorUnits: match.receipt.totalMinorUnits - BBVAStatementLegs.charges(match.receipt),
                                             accountId: effect.currentAccountId,
                                             fingerprint: effect.staged.indices.contains(match.movementIndex) ? effect.staged[match.movementIndex].fingerprint : nil)
        }
        for estimate in effect.estimates {
            guard let derived = try Transaction.fetchOne(db, key: estimate.transactionId) else { continue }
            rows.append(BBVAStatementEffect.BatchLoanRow(date: estimate.receipt.operationDate,
                                                         amountMinorUnits: -BBVAStatementLegs.charges(estimate.receipt) - derived.amountMinorUnits,
                                                         accountId: effect.currentAccountId, estimateId: estimate.transactionId))
        }
        return rows
    }

    /// The earlier statements' loan moves not written yet: an instalment whose debit isn't
    /// saved, an estimate still the derived row.
    static func unsavedBatchLoan(db: Database, _ rows: [BBVAStatementEffect.BatchLoanRow]) throws -> [BBVAStatementEffect.BatchLoanRow] {
        try rows.filter { row in
            if let id = row.estimateId {
                return try Transaction.fetchOne(db, key: id)?.rawDescription == derivedInterestDescription
            }
            guard let fingerprint = row.fingerprint else { return false }
            return try Transaction.filter(Column("accountId") == row.accountId && Column("fingerprint") == fingerprint).fetchCount(db) == 0
        }
    }

    /// What `BBVAFundMortgageImport` calls an interest row it estimated from the instalment's amount.
    static let derivedInterestDescription = "\(BBVAFundMortgageImport.interestCategoryName) (derived)"

    /// The learnt `statementAccount` rule's key and label for a role of the statement: the
    /// current account by its digits (`StatementSignature`'s `"bbva:<digits>"`), the mortgage by
    /// the current account's (`"bbva-mortgage:<digits>"`), the fund by its own account
    /// (`"bbva-fund:<account>"`). Nil when the statement has no digits for it.
    static func ruleKey(_ role: StatementAccountRole, _ statement: BBVAStatementParser.Statement) -> (key: String, label: String)? {
        let digits = digitsOf(statement.currentAccount ?? "")
        switch role {
        case .current:
            return digits.isEmpty ? nil : ("bbva:\(digits)", "BBVA statement of account …\(digits.suffix(4))")
        case .mortgage:
            return digits.isEmpty ? nil : ("bbva-mortgage:\(digits)", "Mortgage on BBVA statements of account …\(digits.suffix(4))")
        case .fund:
            guard let fund = statement.fund, !digitsOf(fund.account).isEmpty else { return nil }
            return ("bbva-fund:\(fund.account)", "Fund account …\(digitsOf(fund.account).suffix(4)) on BBVA statements")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

    /// "05/02/2026", as the statement prints days.
    static func dayText(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// "−€812.53": a minus sign, not a hyphen.
    static func signed(_ minorUnits: Int, _ currency: Currency) -> String {
        let text = Money.format(abs(minorUnits), currency: currency)
        return minorUnits < 0 ? "−" + text : text
    }
}

/// "05/02/2026" (`BBVAStatementReader.dayText`).
private func dayText(_ date: Date) -> String { BBVAStatementReader.dayText(date) }
