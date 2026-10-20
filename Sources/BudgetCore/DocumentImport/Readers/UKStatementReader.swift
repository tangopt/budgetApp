import GRDB
import Foundation

/// UK bank CSV and PDF statements, read through the account's saved import profile
/// (`ImportProfile`): each statement only adds its transactions, categorised by saved rules
/// alone — everything else is left for the Uncategorized screen.
///
/// Staging is async, so it happens outside the readers' write transaction: `propose` only
/// resolves the account and profile (`resolve`) and returns the files it can't (Needs you);
/// the pipeline stages each resolved file (`stage`) and then builds its items (`items`).
public struct UKStatementReader: ImportReader {
    public static let groupKey = "Bank statements"

    /// The account and saved profile a statement is read with, or the Needs-you item saying
    /// why there are none.
    public enum Resolution: Equatable, Sendable {
        case resolved(accountId: Int64, profile: ImportProfile)
        case unresolved(ImportItem)
    }

    public enum StageError: Error, Equatable {
        /// The PDF profile has no layout saved (`resolve` already turns this into a Needs-you
        /// item, so a resolved statement never throws it).
        case noPDFLayout
    }

    public init() {}

    public func handles(_ kind: ImportKind) -> Bool { kind == .bankStatementCSV || kind == .bankStatementPDF }

    /// The Needs-you items of the statements that can't be read (no account, no saved
    /// profile); resolved statements give nothing here (the pipeline stages them and calls `items`).
    public func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        try files.compactMap { file, recognition in
            if case .unresolved(let item) = try Self.resolve(file: file, recognition: recognition, context: context, db: db) { return item }
            return nil
        }
    }

    static func format(of kind: ImportKind) -> ImportFormat { kind == .bankStatementPDF ? .pdf : .csv }

    /// The account: the intent's, else the one account with a saved profile of the file's
    /// format that fully matches the file's sort code / account number (CSV only,
    /// `fullMatch`), else unknown. Then that account's saved profile for the format, else no
    /// profile; a PDF profile must hold a readable layout.
    public static func resolve(file: ImportFile, recognition: ImportRecognition, context: ImportContext, db: Database) throws -> Resolution {
        let format = format(of: recognition.kind)
        let accounts = context.accounts.isEmpty ? try Account.fetchAll(db) : context.accounts
        let accountId: Int64
        if let id = context.intent.accountId {
            accountId = id
        } else if format == .csv, let text = file.text,
                  let found = try matchingAccount(csvText: text, accounts: accounts, db: db) {
            accountId = found
        } else {
            var item = ImportItem(file: file, recognition: recognition, title: file.fileName, effect: .none, groupKey: groupKey)
            item.issues.append(ImportIssue(id: "unknownAccount", kind: .statement(.unknownAccount),
                                           reason: "No account with a saved import profile matches this statement: leave it out of this import"))
            return .unresolved(item)
        }
        guard let profile = try savedProfile(db: db, accountId: accountId, format: format) else {
            let name = accounts.first { $0.id == accountId }?.displayName ?? "This account"
            var item = ImportItem(file: file, recognition: recognition, title: "\(name) statement", effect: .none, groupKey: groupKey)
            item.issues.append(ImportIssue(id: "noProfile", kind: .statement(.noProfile(format: format, accountId: accountId)),
                                           reason: "\(name) has no saved \(format.rawValue.uppercased()) import profile yet: leave it out of this import"))
            return .unresolved(item)
        }
        if format == .pdf, (try? profile.pdfLayoutConfig.map(PDFLayoutConfig.decode)) == nil {
            let name = accounts.first { $0.id == accountId }?.displayName ?? "This account"
            var item = ImportItem(file: file, recognition: recognition, title: "\(name) statement", effect: .none, groupKey: groupKey)
            let text = "\(name)'s saved PDF layout can't be read: leave it out of this import"
            item.issues.append(ImportIssue(id: "noPDFLayout", kind: .readerProblem(text), reason: text))
            return .unresolved(item)
        }
        return .resolved(accountId: accountId, profile: profile)
    }

    /// Stages a resolved statement for review: CSV through the profile's column mapping, PDF
    /// through its saved layout; saved rules only (`ImportCoordinator.Categorization.rulesOnly`).
    /// `alreadyStaged`: the rows of the account's earlier statements in this import (already
    /// imported for this one).
    public static func stage(file: ImportFile, recognition: ImportRecognition, accountId: Int64, profile: ImportProfile,
                             coordinator: ImportCoordinator, alreadyStaged: [StagedTransaction] = []) async throws -> StagedImport {
        switch format(of: recognition.kind) {
        case .csv:
            return try await coordinator.stageCSVImport(csvText: file.text ?? "", profile: profile, accountId: accountId,
                                                        categorization: .rulesOnly, alreadyStaged: alreadyStaged)
        case .pdf:
            guard let json = profile.pdfLayoutConfig else { throw StageError.noPDFLayout }
            let config = try PDFLayoutConfig.decode(json)
            // A scanned PDF has no text layer: its OCR text, when read, instead.
            var lines = (try? PDFTextExtractor.extractLines(from: file.url)) ?? []
            if lines.isEmpty { lines = (file.text ?? "").split(whereSeparator: \.isNewline).map(String.init) }
            return try await coordinator.stagePDFImport(lines: lines, config: config, accountId: accountId, categorization: .rulesOnly,
                                                        alreadyStaged: alreadyStaged)
        }
    }

    /// A staged statement's review items: the statement (its rows, closing balance check and
    /// account details to fill), plus one child holding the rows already imported (saved, or
    /// in an earlier statement of this import). `batchRows`: the account's rows those earlier
    /// statements add, counted in the closing balance check.
    public static func items(file: ImportFile, recognition: ImportRecognition, accountId: Int64, profile: ImportProfile,
                             staged: StagedImport, context: ImportContext, db: Database,
                             batchRows: [StagedTransaction] = []) throws -> [ImportItem] {
        let account = try Account.fetchOne(db, key: accountId)
        let name = account?.displayName ?? "Account #\(accountId)"
        let currency = account?.currency ?? .gbp
        let dates = (staged.staged.map(\.parsed) + staged.duplicates).map(\.date)
        let title: String
        if let first = dates.min(), let last = dates.max() {
            title = "\(name) statement \(dayText(first))–\(dayText(last))"
        } else {
            title = "\(name) statement"
        }

        var facts: [ImportFact] = []
        let chosen = context.intent.accountId == accountId
        let fileValues = profile.format == .csv ? file.text.map { StatementAccountCheck.fileValues(csvText: $0, profile: profile) } : nil
        let matchedBy = fileValues.map { $0.sortCodes.isEmpty ? "Account number matches" : "Sort code and account number match" }
        facts.append(ImportFact(field: .reference, value: .text(name), source: chosen ? .intent : .textLayer, confidence: .certain,
                                reason: chosen ? "You chose \(name)" : "\(matchedBy ?? "Matched to") \(name)"))
        if let first = dates.min(), let last = dates.max() {
            let source: ImportFactSource = file.usedOCR ? .ocr : .textLayer
            facts.append(ImportFact(field: .periodStart, value: .date(first), source: source, confidence: .certain,
                                    reason: "First transaction on the statement"))
            facts.append(ImportFact(field: .periodEnd, value: .date(last), source: source, confidence: .certain,
                                    reason: "Last transaction on the statement"))
        }
        let placement = ImportNaming.placement(kind: recognition.kind, facts: facts, file: file, persons: [])
        var item = ImportItem(file: file, recognition: recognition, title: title, facts: facts, placement: placement,
                              effect: .none, groupKey: groupKey)

        // The file's sort code / account number against the account's.
        // Only a statement imported into the account the user chose fills its details: one
        // matched without an intent matched in full, so it has nothing to fill.
        var accountFill: StatementAccountFill?
        if let fileValues, let account {
            switch StatementAccountCheck.evaluate(file: fileValues, account: account) {
            case .ok(let fill):
                accountFill = chosen ? fill : nil
            case .mismatch(let values, let stored):
                let message = StatementAccountCheck.mismatchMessage(file: values, account: stored, accountName: name)
                item.issues.append(ImportIssue(id: "accountMismatch", kind: .readerProblem(message), reason: message))
            }
        }

        if staged.staged.isEmpty, staged.duplicates.isEmpty, staged.unparsedLines.isEmpty {
            let text = "No transactions found in this statement"
            item.issues.append(ImportIssue(id: "noTransactions", kind: .readerProblem(text), reason: text))
        }
        if !staged.unparsedLines.isEmpty {
            let count = staged.unparsedLines.count
            item.issues.append(ImportIssue(id: "unparsedLines", kind: .statement(.unparsedLines(staged.unparsedLines)),
                                           reason: "\(count) line\(count == 1 ? "" : "s") of the statement couldn't be read: add \(count == 1 ? "it" : "them") by hand after the import",
                                           offers: [.acknowledge]))
        }

        // The closing balance against the account with these rows saved.
        var statement: StatementFinish?
        switch staged.statementBalances {
        case .available(let points):
            if let point = points.last(where: \.isClosing) ?? points.last {
                let closing = StatementClosing(date: point.date, balanceMinorUnits: point.balanceMinorUnits)
                statement = StatementFinish(closing: closing, addAdjustment: false)
                let rows = batchRows + staged.staged
                let check = try StatementCheck.compare(db: db, accountId: accountId, closing: closing,
                                                       stagedRows: rows.map { ($0.parsed.date, $0.parsed.amountMinorUnits) },
                                                       excludingTransactionIds: Set(rows.compactMap(\.replacesManual?.transactionId)))
                if let mismatch = check.mismatch {
                    item.issues.append(ImportIssue(
                        id: "balanceMismatch", kind: .statement(.balanceMismatch(mismatch)),
                        reason: "The statement closes at \(Money.format(mismatch.statementMinorUnits, currency: currency)) on \(dayText(mismatch.date)), "
                            + "but \(name) would be at \(Money.format(mismatch.computedMinorUnits, currency: currency)): leave it out of this import"))
                }
            }
        case .unverified(let why):
            item.notes.append(why)
        case .notProvided:
            break
        }
        if staged.skippedRowCount > 0 {
            item.notes.append("\(staged.skippedRowCount) row\(staged.skippedRowCount == 1 ? "" : "s") not completed (pending, reverted…) left out")
        }

        item.effect = .ukStatement(UKStatementEffect(accountId: accountId, sourceFileName: file.fileName, staged: staged.staged,
                                                     statement: statement, accountFill: accountFill, batchOverlap: staged.batchDuplicates))
        var items = [item]
        if !staged.duplicates.isEmpty {
            let count = staged.duplicates.count
            let of = "\(count) row\(count == 1 ? "" : "s") already imported"
            items.append(ImportItem(file: file, recognition: recognition, title: "\(title): \(of)", effect: .none,
                                    duplicate: ImportDuplicate(level: .transactions, of: of), parentId: item.id, groupKey: groupKey))
        }
        return items
    }

    /// The one account with a saved CSV profile that fully matches the file (`fullMatch`);
    /// nil when none or several.
    private static func matchingAccount(csvText: String, accounts: [Account], db: Database) throws -> Int64? {
        let profiles = try ImportProfile.filter(Column("format") == ImportFormat.csv.rawValue).fetchAll(db)
        var found: Set<Int64> = []
        for profile in profiles {
            guard let account = accounts.first(where: { $0.id == profile.accountId }) else { continue }
            if account.bankRegion.map({ $0 != .uk }) ?? false { continue }
            if fullMatch(StatementAccountCheck.fileValues(csvText: csvText, profile: profile), account: account) {
                found.insert(profile.accountId)
            }
        }
        return found.count == 1 ? found.first : nil
    }

    /// Without an intent, a file is an account's only when it shows one account number, equal
    /// to the account's stored one, and any sort code it shows is the account's stored one too.
    /// A sort code alone never matches (accounts at one branch share it).
    static func fullMatch(_ values: StatementAccountValues, account: Account) -> Bool {
        guard values.accountNumbers.count == 1, values.sortCodes.count <= 1,
              let stored = account.accountNumber.flatMap(StatementAccountCheck.normalizedAccountNumber),
              stored == values.accountNumbers[0] else { return false }
        guard let fileSortCode = values.sortCodes.first else { return true }
        return account.sortCode.flatMap(StatementAccountCheck.normalizedSortCode) == fileSortCode
    }

    /// `ImportProfileStore.find` in the caller's transaction.
    private static func savedProfile(db: Database, accountId: Int64, format: ImportFormat) throws -> ImportProfile? {
        try ImportProfile.filter(Column("accountId") == accountId && Column("format") == format.rawValue).fetchOne(db)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    /// "5 Mar 2023", the app's day style.
    private static func dayText(_ date: Date) -> String { dayFormatter.string(from: date) }
}
