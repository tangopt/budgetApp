import Foundation

public enum AccountDetailsError: Error, Equatable, LocalizedError {
    case invalidSortCode, invalidAccountNumber, invalidIBAN

    public var errorDescription: String? {
        switch self {
        case .invalidSortCode: return "Sort code must be 6 digits."
        case .invalidAccountNumber: return "Account number must be 6 to 8 digits."
        case .invalidIBAN: return "IBAN must be 15–34 letters and digits, starting with a country code and 2 check digits."
        }
    }
}

/// An account's optional alias and bank details as entered; `normalized()` gives what is
/// stored (or the first validation error).
public struct AccountDetails: Equatable, Sendable {
    public var alias: String?
    public var sortCode: String?
    public var accountNumber: String?
    public var iban: String?

    public init(alias: String? = nil, sortCode: String? = nil, accountNumber: String? = nil, iban: String? = nil) {
        self.alias = alias
        self.sortCode = sortCode
        self.accountNumber = accountNumber
        self.iban = iban
    }

    public init(_ account: Account) {
        self.init(alias: account.alias, sortCode: account.sortCode, accountNumber: account.accountNumber, iban: account.iban)
    }

    public func normalized() throws -> AccountDetails {
        AccountDetails(
            alias: AccountDetailsFormat.normalizedAlias(alias ?? ""),
            sortCode: try AccountDetailsFormat.normalizedSortCode(sortCode ?? ""),
            accountNumber: try AccountDetailsFormat.normalizedAccountNumber(accountNumber ?? ""),
            iban: try AccountDetailsFormat.normalizedIBAN(iban ?? "")
        )
    }
}

/// Normalisation (what is stored), light validation (no IBAN checksum) and display
/// formatting for account aliases and bank details. Blank input is always nil.
public enum AccountDetailsFormat {
    public static func normalizedAlias(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "30-00-00", "30 00 00" or "300000" → "300000".
    public static func normalizedSortCode(_ raw: String) throws -> String? {
        guard let stripped = stripped(raw, removing: " -") else { return nil }
        guard stripped.count == 6, stripped.allSatisfy(\.isASCIIDigit) else { throw AccountDetailsError.invalidSortCode }
        return stripped
    }

    /// Spaces and hyphens dropped; 6–8 digits.
    public static func normalizedAccountNumber(_ raw: String) throws -> String? {
        guard let stripped = stripped(raw, removing: " -") else { return nil }
        guard (6...8).contains(stripped.count), stripped.allSatisfy(\.isASCIIDigit) else { throw AccountDetailsError.invalidAccountNumber }
        return stripped
    }

    /// Spaces dropped, uppercased; 15–34 letters/digits, 2 letters then 2 digits first.
    public static func normalizedIBAN(_ raw: String) throws -> String? {
        guard let stripped = stripped(raw, removing: " ")?.uppercased() else { return nil }
        let chars = Array(stripped)
        guard (15...34).contains(chars.count),
              chars.allSatisfy({ $0.isASCIIDigit || $0.isASCIIUppercaseLetter }),
              chars[0].isASCIIUppercaseLetter, chars[1].isASCIIUppercaseLetter,
              chars[2].isASCIIDigit, chars[3].isASCIIDigit
        else { throw AccountDetailsError.invalidIBAN }
        return stripped
    }

    /// "300000" → "30-00-00"; anything not 6 characters is returned as-is.
    public static func formattedSortCode(_ stored: String) -> String {
        guard stored.count == 6 else { return stored }
        let c = Array(stored)
        return "\(String(c[0..<2]))-\(String(c[2..<4]))-\(String(c[4..<6]))"
    }

    /// "GB29NWBK60161331926819" → "GB29 NWBK 6016 1331 9268 19".
    public static func formattedIBAN(_ stored: String) -> String {
        let c = Array(stored)
        return stride(from: 0, to: c.count, by: 4).map { String(c[$0..<min($0 + 4, c.count)]) }.joined(separator: " ")
    }

    private static func stripped(_ raw: String, removing separators: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.filter { !separators.contains($0) })
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIIUppercaseLetter: Bool { isASCII && isUppercase }
}
