import Foundation

/// A mortgage instalment's receipt (`DocumentKind.mortgageReceipt`): the bank's "Recibo de
/// empréstimo" for the debit on its date, beside the notice issued before it. Reads which
/// instalment it is ("193/480") and names it.
public enum MortgageReceipt {
    /// Instalment `number` of `total`.
    public struct Instalment: Equatable, Sendable {
        public var number: Int
        public var total: Int

        public init(number: Int, total: Int) {
            self.number = number
            self.total = total
        }

        /// "193/480" (`label`) read back; nil for anything else.
        public init?(label: String) {
            let parts = label.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let number = parts[0], let total = parts[1], number >= 1, number <= total else { return nil }
            self.init(number: number, total: total)
        }

        /// "193/480".
        public var label: String { "\(number)/\(total)" }
    }

    /// The file name's "Recibo 193:480" (Finder's `/` is `:` on disk; `/` and `-` too).
    private static let fileNamePattern = try! NSRegularExpression(
        pattern: #"RECIBO\D{0,4}?(\d{1,3})\s*[/:\-]\s*(\d{1,3})(?!\d)"#, options: [.caseInsensitive])
    /// A "193/480" pair in the text, either way round: the bank prints the total first
    /// ("480/" and "193" on the next line, in the text's reading order). Never part of a date
    /// ("12/05/2024") or an amount.
    private static let textPattern = try! NSRegularExpression(pattern: #"(?<![\d.,/])(\d{1,3})\s*/\s*(\d{1,3})(?![\d.,/])"#)

    /// The instalment the receipt is for: from its text, else its file name's "Recibo n/total".
    public static func instalment(text: String?, fileName: String) -> Instalment? {
        if let text, let found = firstPair(textPattern, in: text, ordered: false) { return found }
        return firstPair(fileNamePattern, in: EvidenceText.fold((fileName as NSString).deletingPathExtension), ordered: true)
    }

    private static func firstPair(_ regex: NSRegularExpression, in text: String, ordered: Bool) -> Instalment? {
        let source = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let first = Int(source.substring(with: match.range(at: 1))), let second = Int(source.substring(with: match.range(at: 2))) else { continue }
            let (number, total) = ordered ? (first, second) : (min(first, second), max(first, second))
            guard number >= 1, total >= 2, number <= total else { continue }
            return Instalment(number: number, total: total)
        }
        return nil
    }

    /// `<date> - Property - Mortgage receipt - <n>/<total> - €<amount>` (`EvidenceNaming`): the
    /// instalment and amount when known.
    public static func canonicalName(date: Date, instalment: Instalment?, amountMinorUnits: Int?, currency: Currency?) -> String {
        EvidenceNaming.canonicalName(date: date, area: ImportNaming.area(of: .mortgageReceipt), type: DocumentKind.mortgageReceipt.displayName,
                                     detail: instalment?.label, amountMinorUnits: amountMinorUnits, currency: currency)
    }
}
