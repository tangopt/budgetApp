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

    /// A page marker just before a pair ("Pág. 1/2", "Page 1/2", "Folha 1/2"): never an instalment.
    private static let pageMarker = try! NSRegularExpression(pattern: #"\b(?:PAG(?:INA)?|PAGE|FOLHA|FL)\.?\s*(?:N\.?\s*[O\u00BA]\.?\s*)?$"#,
                                                             options: [.caseInsensitive])
    /// How close to "RECIBO" (characters, either side) a pair counts as the receipt's own.
    private static let nearReceipt = 40

    /// The instalment the receipt is for: from its text — a pair near "RECIBO" or of a loan's
    /// length (total ≥ 100), never a page marker — else its file name's "Recibo n/total", else
    /// any other pair in the text.
    public static func instalment(text: String?, fileName: String) -> Instalment? {
        let candidates = text.map { textPairs(in: EvidenceText.fold($0)) } ?? []
        if let preferred = candidates.first(where: { $0.nearReceipt || $0.instalment.total >= 100 }) { return preferred.instalment }
        let name = EvidenceText.fold((fileName as NSString).deletingPathExtension)
        if let fromName = pairs(fileNamePattern, in: name, ordered: true).first { return fromName.instalment }
        return candidates.first?.instalment
    }

    private struct Candidate {
        var instalment: Instalment
        var range: NSRange
        var nearReceipt = false
    }

    /// The text's pairs, page markers left out, each marked when "RECIBO" is near it.
    private static func textPairs(in text: String) -> [Candidate] {
        let source = text as NSString
        let receipts = EvidenceAnalyzer.occurrences(of: "RECIBO", in: source)
        return pairs(textPattern, in: text, ordered: false).compactMap { candidate in
            let start = max(0, candidate.range.location - 12)
            let before = source.substring(with: NSRange(location: start, length: candidate.range.location - start))
            if pageMarker.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil { return nil }
            var candidate = candidate
            candidate.nearReceipt = receipts.contains { receipt in
                let gap = receipt.location >= candidate.range.location + candidate.range.length
                    ? receipt.location - (candidate.range.location + candidate.range.length)
                    : candidate.range.location - (receipt.location + receipt.length)
                return gap <= nearReceipt
            }
            return candidate
        }
    }

    private static func pairs(_ regex: NSRegularExpression, in text: String, ordered: Bool) -> [Candidate] {
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let first = Int(source.substring(with: match.range(at: 1))), let second = Int(source.substring(with: match.range(at: 2))) else { return nil }
            let (number, total) = ordered ? (first, second) : (min(first, second), max(first, second))
            guard number >= 1, total >= 2, number <= total else { return nil }
            return Candidate(instalment: Instalment(number: number, total: total), range: match.range)
        }
    }

    /// `<date> - Property - Mortgage receipt - <n>/<total> - €<amount>` (`EvidenceNaming`): the
    /// instalment and amount when known.
    public static func canonicalName(date: Date, instalment: Instalment?, amountMinorUnits: Int?, currency: Currency?) -> String {
        EvidenceNaming.canonicalName(date: date, area: ImportNaming.area(of: .mortgageReceipt), type: DocumentKind.mortgageReceipt.displayName,
                                     detail: instalment?.label, amountMinorUnits: amountMinorUnits, currency: currency)
    }
}
