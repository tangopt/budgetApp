import Foundation

/// A PAYE tax code, simply parsed: the allowance (or K addition) and the flat-rate codes.
public struct TaxCode: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        /// Digits followed by L, M, N or T: an allowance of digits × £10 (pence).
        case standard(allowance: Int)
        /// K followed by digits: digits × £10 (pence) added to taxable pay.
        case k(addition: Int)
        /// All pay at the basic rate.
        case br
        /// All pay at the higher rate (Scotland: intermediate).
        case d0
        /// All pay at the additional rate (Scotland: higher).
        case d1
        /// No tax.
        case nt
        /// No allowance; normal bands.
        case zeroT
    }

    public static let defaultCode = "1257L"
    public static let unreadableNotice = "Using 1257L: couldn't read that code"

    public var kind: Kind
    /// The code as read: trimmed, upper-cased, without an S/C prefix or W1/M1/X suffix.
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// True for the default 1257L, whose allowance comes from the year's table.
    public var isDefault: Bool { text == Self.defaultCode }

    /// Reads `text`. Anything it can't read becomes 1257L with a notice to show.
    public static func parse(_ text: String) -> (code: TaxCode, notice: String?) {
        var code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // Emergency suffixes: "1257L W1", "1257LM1", "1257L X".
        for suffix in ["W1", "M1", "X"] where code.hasSuffix(suffix) {
            code = String(code.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        code = code.replacingOccurrences(of: " ", with: "")
        // Scottish and Welsh prefixes: the region the person picked decides the bands.
        if code.count > 1, code.hasPrefix("S") || code.hasPrefix("C") {
            code = String(code.dropFirst())
        }
        if let kind = kind(of: code) {
            return (TaxCode(kind: kind, text: code), nil)
        }
        return (TaxCode(kind: .standard(allowance: 1_257_000), text: defaultCode), unreadableNotice)
    }

    private static func kind(of code: String) -> Kind? {
        switch code {
        case "BR": return .br
        case "D0": return .d0
        case "D1": return .d1
        case "NT": return .nt
        case "0T": return .zeroT
        default: break
        }
        if code.hasPrefix("K") {
            let digits = code.dropFirst()
            guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy(\.isASCIIDigit), let n = Int(digits) else { return nil }
            return .k(addition: n * 1_000)
        }
        guard let last = code.last, "LMNT".contains(last) else { return nil }
        let digits = code.dropLast()
        guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy(\.isASCIIDigit), let n = Int(digits) else { return nil }
        return n == 0 ? .zeroT : .standard(allowance: n * 1_000)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
