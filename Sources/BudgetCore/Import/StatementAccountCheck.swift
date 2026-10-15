import Foundation
import GRDB

/// The distinct sort codes and account numbers a CSV statement's rows carry (normalised, in
/// file order).
public struct StatementAccountValues: Equatable, Sendable {
    public var sortCodes: [String]
    public var accountNumbers: [String]

    public init(sortCodes: [String] = [], accountNumbers: [String] = []) {
        self.sortCodes = sortCodes
        self.accountNumbers = accountNumbers
    }

    public var isEmpty: Bool { sortCodes.isEmpty && accountNumbers.isEmpty }
}

/// A sort code and/or account number: an account's (for the mismatch message) or the
/// empty account fields Finish import fills from the file.
public struct StatementAccountFill: Equatable, Sendable {
    public var sortCode: String?
    public var accountNumber: String?

    public init(sortCode: String?, accountNumber: String?) {
        self.sortCode = sortCode
        self.accountNumber = accountNumber
    }

    public var isEmpty: Bool { sortCode == nil && accountNumber == nil }
}

/// Spec 2026-10-15 §5: a CSV statement's sort code / account number columns checked against
/// the account before staging — a different account (or several in one file) blocks with an
/// alert; an account with empty fields gets them filled on Finish import.
public enum StatementAccountCheck {
    public enum Result: Equatable {
        /// Nothing contradicts the account. `fill` is what Finish import saves to its empty
        /// fields (nil when there's nothing to fill).
        case ok(fill: StatementAccountFill?)
        /// The file is for another account, or for several: `account` is what the account has.
        case mismatch(file: StatementAccountValues, account: StatementAccountFill)
    }

    /// Quotes, apostrophes (Lloyds exports `'30-94-57` so spreadsheets keep it as text),
    /// spaces and dashes dropped; 6 digits, else nil.
    public static func normalizedSortCode(_ raw: String) -> String? {
        let digits = stripped(raw)
        return digits.count == 6 && digits.allSatisfy(\.isASCIIDigitCharacter) ? digits : nil
    }

    /// The same stripping; digits only, else nil.
    public static func normalizedAccountNumber(_ raw: String) -> String? {
        let digits = stripped(raw)
        return !digits.isEmpty && digits.allSatisfy(\.isASCIIDigitCharacter) ? digits : nil
    }

    /// The file's distinct values from the profile's sort code / account number columns or,
    /// for a profile without them, the columns found by header name
    /// (`CSVColumnSuggester.sortCodeColumn`/`accountNumberColumn`).
    public static func fileValues(csvText: String, profile: ImportProfile) -> StatementAccountValues {
        let delimiter = Character(profile.csvDelimiter ?? ",")
        let lines = CSVStatementParser.splitLines(csvText)
        guard let headerLine = lines.first else { return StatementAccountValues() }
        let header = CSVRowSplitter.split(line: headerLine, delimiter: delimiter)
        let sortCodeIndex = profile.csvSortCodeColumnIndex ?? CSVColumnSuggester.sortCodeColumn(header: header)
        let accountNumberIndex = profile.csvAccountNumberColumnIndex ?? CSVColumnSuggester.accountNumberColumn(header: header)
        guard sortCodeIndex != nil || accountNumberIndex != nil else { return StatementAccountValues() }
        var values = StatementAccountValues()
        for line in lines.dropFirst() {
            let fields = CSVRowSplitter.split(line: line, delimiter: delimiter)
            if let i = sortCodeIndex, i < fields.count, let value = normalizedSortCode(fields[i]), !values.sortCodes.contains(value) {
                values.sortCodes.append(value)
            }
            if let i = accountNumberIndex, i < fields.count, let value = normalizedAccountNumber(fields[i]), !values.accountNumbers.contains(value) {
                values.accountNumbers.append(value)
            }
        }
        return values
    }

    /// Only what both the file and the account have is compared. An account with a sort code
    /// or account number is blocked by a different value or by a file with several; one with
    /// neither is never blocked. The fill takes the file's single value for each empty
    /// account field (an account number only when the UK rule accepts it, 6–8 digits).
    /// Sort codes are UK details: an account with a stored region other than UK is neither
    /// checked nor filled.
    public static func evaluate(file: StatementAccountValues, account: Account) -> Result {
        if let region = account.bankRegion, region != .uk { return .ok(fill: nil) }
        let stored = StatementAccountFill(sortCode: account.sortCode.flatMap(normalizedSortCode),
                                          accountNumber: account.accountNumber.flatMap(normalizedAccountNumber))
        guard !file.isEmpty else { return .ok(fill: nil) }
        let several = file.sortCodes.count > 1 || file.accountNumbers.count > 1
        if several {
            return stored.isEmpty ? .ok(fill: nil) : .mismatch(file: file, account: stored)
        }
        if let a = stored.sortCode, let f = file.sortCodes.first, a != f { return .mismatch(file: file, account: stored) }
        if let a = stored.accountNumber, let f = file.accountNumbers.first, a != f { return .mismatch(file: file, account: stored) }
        let fill = StatementAccountFill(
            sortCode: stored.sortCode == nil ? file.sortCodes.first : nil,
            accountNumber: stored.accountNumber == nil ? file.accountNumbers.first.flatMap { (try? AccountDetailsFormat.normalizedAccountNumber($0, region: .uk)) ?? nil } : nil
        )
        return .ok(fill: fill.isEmpty ? nil : fill)
    }

    /// "This file is for sort code 30-94-57, account 12345678 — Lloyds is 30-00-00, 87654321."
    public static func mismatchMessage(file: StatementAccountValues, account: StatementAccountFill, accountName: String) -> String {
        var fileParts: [String] = []
        if !file.sortCodes.isEmpty {
            fileParts.append("sort code\(file.sortCodes.count > 1 ? "s" : "") \(list(file.sortCodes.map(AccountDetailsFormat.formattedSortCode)))")
        }
        if !file.accountNumbers.isEmpty {
            fileParts.append("account\(file.accountNumbers.count > 1 ? "s" : "") \(list(file.accountNumbers))")
        }
        let accountParts = [account.sortCode.map(AccountDetailsFormat.formattedSortCode), account.accountNumber].compactMap { $0 }
        return "This file is for \(fileParts.joined(separator: ", ")) — \(accountName) is \(accountParts.joined(separator: ", "))."
    }

    /// The finish message's line for what was filled.
    public static func savedMessage(_ filled: StatementAccountFill, accountName: String) -> String {
        let what = [filled.sortCode.map { _ in "sort code" }, filled.accountNumber.map { _ in "account number" }].compactMap { $0 }
        return "Saved \(what.joined(separator: " and ")) to \(accountName)."
    }

    /// Finish import's fill, in its write: the account is fetched fresh and only its still-empty
    /// sort code / account number are set (plus `bankRegion = uk` when none is stored); no
    /// other column is written. Returns what was filled, nil when nothing was.
    @discardableResult
    public static func fill(db: Database, accountId: Int64, with fill: StatementAccountFill) throws -> StatementAccountFill? {
        guard var account = try Account.fetchOne(db, key: accountId) else { return nil }
        let original = account
        var filled = StatementAccountFill(sortCode: nil, accountNumber: nil)
        if isBlank(account.sortCode), let value = fill.sortCode {
            account.sortCode = value
            filled.sortCode = value
        }
        if isBlank(account.accountNumber), let value = fill.accountNumber {
            account.accountNumber = value
            filled.accountNumber = value
        }
        guard !filled.isEmpty else { return nil }
        if account.bankRegion == nil { account.bankRegion = .uk }
        try account.updateChanges(db, from: original)
        return filled
    }

    private static func isBlank(_ value: String?) -> Bool {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    private static func stripped(_ raw: String) -> String {
        let dropped: Set<Character> = ["'", "\"", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "`", "-", "\u{2013}"]
        return String(raw.filter { !$0.isWhitespace && !dropped.contains($0) })
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
