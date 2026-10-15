import Foundation

public enum AccountDetailsError: Error, Equatable, LocalizedError {
    case invalidSortCode, invalidAccountNumber, invalidIBAN, invalidIBANChecksum
    case invalidRoutingNumber, invalidUSAccountNumber, accountNumberTooLong, invalidBIC

    public var errorDescription: String? {
        switch self {
        case .invalidSortCode: return "Sort code must be 6 digits."
        case .invalidAccountNumber: return "Account number must be 6 to 8 digits."
        case .invalidIBAN: return "IBAN must be 15–34 letters and digits, starting with a country code and 2 check digits."
        case .invalidIBANChecksum: return "IBAN check digits don't match — check it for a typo."
        case .invalidRoutingNumber: return "Routing number must be 9 digits with a valid check digit."
        case .invalidUSAccountNumber: return "Account number must be 4 to 17 digits."
        case .accountNumberTooLong: return "Account number must be at most 34 characters."
        case .invalidBIC: return "BIC must be 8 or 11 letters and digits, e.g. LOYDGB2L."
        }
    }
}

/// An account's optional alias and bank details as entered; `normalized()` gives what is
/// stored (or the first validation error).
///
/// With a `region` (spec 2026-10-15 §2) only that region's fields plus bank name and BIC are
/// validated and saved (`activeFields`); the others are left as stored. Without one (legacy
/// callers) every field is, with the UK account-number rule.
public struct AccountDetails: Equatable, Sendable {
    public var alias: String?
    public var sortCode: String?
    public var accountNumber: String?
    public var iban: String?
    public var region: BankRegion?
    public var bankName: String?
    public var routingNumber: String?
    public var bic: String?

    public init(alias: String? = nil, sortCode: String? = nil, accountNumber: String? = nil, iban: String? = nil,
                region: BankRegion? = nil, bankName: String? = nil, routingNumber: String? = nil, bic: String? = nil) {
        self.alias = alias
        self.sortCode = sortCode
        self.accountNumber = accountNumber
        self.iban = iban
        self.region = region
        self.bankName = bankName
        self.routingNumber = routingNumber
        self.bic = bic
    }

    /// The account's stored details, with its effective region.
    public init(_ account: Account) {
        self.init(alias: account.alias, sortCode: account.sortCode, accountNumber: account.accountNumber, iban: account.iban,
                  region: account.effectiveBankRegion, bankName: account.bankName, routingNumber: account.routingNumber, bic: account.bic)
    }

    /// The fields validated and saved.
    public var activeFields: [BankDetailField] {
        guard let region else { return BankDetailField.allCases }
        return [.bankName] + region.fields + [.bic]
    }

    public subscript(field: BankDetailField) -> String? {
        get {
            switch field {
            case .bankName: return bankName
            case .sortCode: return sortCode
            case .routingNumber: return routingNumber
            case .accountNumber: return accountNumber
            case .iban: return iban
            case .bic: return bic
            }
        }
        set {
            switch field {
            case .bankName: bankName = newValue
            case .sortCode: sortCode = newValue
            case .routingNumber: routingNumber = newValue
            case .accountNumber: accountNumber = newValue
            case .iban: iban = newValue
            case .bic: bic = newValue
            }
        }
    }

    /// Each active field's validation error. A value that fails but is the one `existing`
    /// already stores (ignoring spaces, hyphens and case) passes: stored values that predate
    /// a rule keep loading and saving; the error shows once the field is edited.
    public func errors(existing: Account? = nil) -> [BankDetailField: AccountDetailsError] {
        var errors: [BankDetailField: AccountDetailsError] = [:]
        for field in activeFields {
            do { _ = try normalizedValue(field, existing: existing) } catch let error as AccountDetailsError { errors[field] = error } catch {}
        }
        return errors
    }

    /// The alias and active fields normalised (inactive ones nil); throws the first error.
    public func normalized(existing: Account? = nil) throws -> AccountDetails {
        var result = AccountDetails(alias: AccountDetailsFormat.normalizedAlias(alias ?? ""), region: region)
        for field in activeFields {
            result[field] = try normalizedValue(field, existing: existing)
        }
        return result
    }

    private func normalizedValue(_ field: BankDetailField, existing: Account?) throws -> String? {
        let raw = self[field] ?? ""
        do {
            return try AccountDetailsFormat.normalized(field, raw, region: region ?? .uk)
        } catch {
            if let stored = existing?.bankDetail(field), Self.squashed(raw) == Self.squashed(stored) { return stored }
            throw error
        }
    }

    private static func squashed(_ value: String) -> String {
        String(value.filter { !$0.isWhitespace && $0 != "-" }).uppercased()
    }
}

extension Account {
    public func bankDetail(_ field: BankDetailField) -> String? {
        switch field {
        case .bankName: return bankName
        case .sortCode: return sortCode
        case .routingNumber: return routingNumber
        case .accountNumber: return accountNumber
        case .iban: return iban
        case .bic: return bic
        }
    }

    /// Saves normalised `details`: the alias, the active fields (inactive ones keep their
    /// stored values) and the region when there is one.
    mutating func apply(_ details: AccountDetails) {
        alias = details.alias
        if let region = details.region { bankRegion = region }
        for field in details.activeFields {
            let value = details[field]
            switch field {
            case .bankName: bankName = value
            case .sortCode: sortCode = value
            case .routingNumber: routingNumber = value
            case .accountNumber: accountNumber = value
            case .iban: iban = value
            case .bic: bic = value
            }
        }
    }
}

/// Normalisation (what is stored), validation and display formatting for account aliases
/// and bank details. Blank input is always nil.
public enum AccountDetailsFormat {
    /// `field`'s normaliser; `region` picks the account-number rule.
    public static func normalized(_ field: BankDetailField, _ raw: String, region: BankRegion) throws -> String? {
        switch field {
        case .bankName: return normalizedBankName(raw)
        case .sortCode: return try normalizedSortCode(raw)
        case .routingNumber: return try normalizedRoutingNumber(raw)
        case .accountNumber: return try normalizedAccountNumber(raw, region: region)
        case .iban: return try normalizedIBAN(raw)
        case .bic: return try normalizedBIC(raw)
        }
    }

    public static func normalizedBankName(_ raw: String) -> String? {
        normalizedAlias(raw)
    }

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

    /// UK: spaces and hyphens dropped, 6–8 digits. US: the same, 4–17 digits. Europe/Other:
    /// free text, trimmed, at most 34 characters.
    public static func normalizedAccountNumber(_ raw: String, region: BankRegion = .uk) throws -> String? {
        switch region {
        case .uk:
            guard let stripped = stripped(raw, removing: " -") else { return nil }
            guard (6...8).contains(stripped.count), stripped.allSatisfy(\.isASCIIDigit) else { throw AccountDetailsError.invalidAccountNumber }
            return stripped
        case .us:
            guard let stripped = stripped(raw, removing: " -") else { return nil }
            guard (4...17).contains(stripped.count), stripped.allSatisfy(\.isASCIIDigit) else { throw AccountDetailsError.invalidUSAccountNumber }
            return stripped
        case .europe, .other:
            guard let trimmed = normalizedAlias(raw) else { return nil }
            guard trimmed.count <= 34 else { throw AccountDetailsError.accountNumberTooLong }
            return trimmed
        }
    }

    /// Spaces and hyphens dropped; 9 digits passing the ABA checksum
    /// 3·(d1+d4+d7) + 7·(d2+d5+d8) + (d3+d6+d9) ≡ 0 (mod 10).
    public static func normalizedRoutingNumber(_ raw: String) throws -> String? {
        guard let stripped = stripped(raw, removing: " -") else { return nil }
        guard stripped.count == 9, stripped.allSatisfy(\.isASCIIDigit) else { throw AccountDetailsError.invalidRoutingNumber }
        let d = stripped.compactMap(\.wholeNumberValue)
        let sum = 3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])
        guard sum % 10 == 0 else { throw AccountDetailsError.invalidRoutingNumber }
        return stripped
    }

    /// Spaces dropped, uppercased; 8 or 11 characters: 4 letters (bank), 2 letters (country),
    /// 2 letters/digits (location), optionally 3 letters/digits (branch).
    public static func normalizedBIC(_ raw: String) throws -> String? {
        guard let stripped = stripped(raw, removing: " ")?.uppercased() else { return nil }
        let c = Array(stripped)
        guard c.count == 8 || c.count == 11,
              c[0..<6].allSatisfy(\.isASCIIUppercaseLetter),
              c[6...].allSatisfy({ $0.isASCIIDigit || $0.isASCIIUppercaseLetter })
        else { throw AccountDetailsError.invalidBIC }
        return stripped
    }

    /// Spaces dropped, uppercased; 15–34 letters/digits, 2 letters then 2 digits first, and
    /// the ISO 13616 mod-97 checksum (`invalidIBANChecksum` when only that fails).
    public static func normalizedIBAN(_ raw: String) throws -> String? {
        guard let stripped = stripped(raw, removing: " ")?.uppercased() else { return nil }
        let chars = Array(stripped)
        guard (15...34).contains(chars.count),
              chars.allSatisfy({ $0.isASCIIDigit || $0.isASCIIUppercaseLetter }),
              chars[0].isASCIIUppercaseLetter, chars[1].isASCIIUppercaseLetter,
              chars[2].isASCIIDigit, chars[3].isASCIIDigit
        else { throw AccountDetailsError.invalidIBAN }
        guard ibanChecksumIsValid(chars) else { throw AccountDetailsError.invalidIBANChecksum }
        return stripped
    }

    /// The first 4 characters moved to the end, letters as 10–35: the number mod 97 is 1.
    private static func ibanChecksumIsValid(_ chars: [Character]) -> Bool {
        var remainder = 0
        for char in chars[4...] + chars[..<4] {
            let value: Int
            if let digit = char.wholeNumberValue { value = digit } else { value = Int(char.asciiValue! - Character("A").asciiValue!) + 10 }
            remainder = (value < 10 ? remainder * 10 + value : remainder * 100 + value) % 97
        }
        return remainder == 1
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

/// One line of an account's bank details as the detail panel shows it: `copied` is the
/// unformatted value its copy button puts on the clipboard.
public struct BankDetailLine: Equatable, Sendable {
    public let label: String
    public let shown: String
    public let copied: String

    public init(label: String, shown: String, copied: String) {
        self.label = label
        self.shown = shown
        self.copied = copied
    }
}

/// The detail panel's "Bank details" section (spec 2026-10-15 §3).
public enum BankDetailsFormat {
    public static func label(_ field: BankDetailField) -> String {
        switch field {
        case .bankName: return "Bank"
        case .sortCode: return "Sort code"
        case .routingNumber: return "Routing number"
        case .accountNumber: return "Account number"
        case .iban: return "IBAN"
        case .bic: return "BIC"
        }
    }

    /// Bank name, the effective region's fields, then BIC — only those set.
    public static func lines(for account: Account) -> [BankDetailLine] {
        let fields = [BankDetailField.bankName] + account.effectiveBankRegion.fields + [.bic]
        return fields.compactMap { field in
            guard let value = account.bankDetail(field)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            let shown: String
            switch field {
            case .sortCode: shown = AccountDetailsFormat.formattedSortCode(value)
            case .iban: shown = AccountDetailsFormat.formattedIBAN(value)
            default: shown = value
            }
            return BankDetailLine(label: label(field), shown: shown, copied: value)
        }
    }

    /// A plain-text block: the bank name, "Name: <account name>", then "Label: value" for each
    /// other line. Nil when no details are set.
    public static func copyAllText(for account: Account) -> String? {
        let lines = lines(for: account)
        guard !lines.isEmpty else { return nil }
        var text: [String] = []
        var rest = lines[...]
        if let first = rest.first, first.label == label(.bankName) {
            text.append(first.shown)
            rest = rest.dropFirst()
        }
        text.append("Name: \(account.name)")
        text += rest.map { "\($0.label): \($0.shown)" }
        return text.joined(separator: "\n")
    }
}
