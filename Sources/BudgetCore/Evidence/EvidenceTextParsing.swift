import Foundation

/// Dates found in a document's text: `dd/MM/yyyy`, `dd-MM-yyyy`, `dd.MM.yyyy`, `yyyy-MM-dd`, `yyyy.MM.dd`,
/// `yyyy/MM/dd`, Portuguese `5 de abril de 2025` (or `5 de abril 2025`, `5 abr 2025`) and
/// English `5 April 2025` / `5 Apr 2025` / `5Apr2025`. Days are UTC midnight, like every stored
/// day in the app; impossible dates (31/02) and years outside 1990–2100 are skipped.
public enum EvidenceDateParser {
    public struct Found: Equatable, Sendable {
        public var date: Date
        /// Where in the text it was found (UTF-16 offsets).
        public var range: NSRange
    }

    static let months: [String: Int] = [
        "janeiro": 1, "fevereiro": 2, "marco": 3, "abril": 4, "maio": 5, "junho": 6, "julho": 7, "agosto": 8,
        "setembro": 9, "outubro": 10, "novembro": 11, "dezembro": 12,
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "fev": 2, "feb": 2, "mar": 3, "abr": 4, "apr": 4, "mai": 5, "jun": 6, "jul": 7, "ago": 8,
        "aug": 8, "set": 9, "sep": 9, "sept": 9, "out": 10, "oct": 10, "nov": 11, "dez": 12, "dec": 12
    ]

    private static let numericPattern = try! NSRegularExpression(
        pattern: #"(?<!\d)(?:(\d{4})([-/.])(\d{1,2})\2(\d{1,2})|(\d{1,2})([-/.])(\d{1,2})\6(\d{4}))(?!\d)"#)
    private static let wordPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\d])(\d{1,2})(?:º|\.)?\s*(?:de\s+)?(\p{L}{3,9})\.?,?\s*(?:de\s+)?(\d{4})(?!\d)"#,
        options: [.caseInsensitive])

    /// Every date in `text`, in the order they appear.
    public static func dates(in text: String) -> [Found] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        let source = text as NSString
        var found: [Found] = []
        for match in numericPattern.matches(in: text, range: range) {
            func int(_ group: Int) -> Int? {
                let r = match.range(at: group)
                return r.location == NSNotFound ? nil : Int(source.substring(with: r))
            }
            let date: Date?
            if let year = int(1), let month = int(3), let day = int(4) {
                date = makeDate(year: year, month: month, day: day)
            } else if let day = int(5), let month = int(7), let year = int(8) {
                date = makeDate(year: year, month: month, day: day)
            } else {
                date = nil
            }
            if let date { found.append(Found(date: date, range: match.range)) }
        }
        for match in wordPattern.matches(in: text, range: range) {
            let monthWord = EvidenceText.fold(source.substring(with: match.range(at: 2))).lowercased()
            guard let month = months[monthWord],
                  let day = Int(source.substring(with: match.range(at: 1))),
                  let year = Int(source.substring(with: match.range(at: 3))),
                  let date = makeDate(year: year, month: month, day: day) else { continue }
            found.append(Found(date: date, range: match.range))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The first date in `text`, if any.
    public static func firstDate(in text: String) -> Date? {
        dates(in: text).first?.date
    }

    /// A date from a file name: `yyyyMMdd` on its own, else the `yyyyMMddhhmmss` timestamp that
    /// ends BBVA's exports (after the account number), else `yyyy-MM-dd`-style dates; nil when
    /// there is none.
    public static func fileNameDate(_ fileName: String) -> Date? {
        let name = (fileName as NSString).deletingPathExtension
        let source = name as NSString
        for regex in fileNamePatterns {
            for match in regex.matches(in: name, range: NSRange(location: 0, length: source.length)) {
                if let year = Int(source.substring(with: match.range(at: 1))), let month = Int(source.substring(with: match.range(at: 2))),
                   let day = Int(source.substring(with: match.range(at: 3))), let date = makeDate(year: year, month: month, day: day) {
                    return date
                }
            }
        }
        return dates(in: name).first?.date
    }

    private static let fileNamePatterns = [
        try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})(\d{2})(\d{2})(?!\d)"#),
        try! NSRegularExpression(pattern: #"(\d{4})(\d{2})(\d{2})([01]\d|2[0-3])[0-5]\d[0-5]\d$"#)
    ]

    static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        guard (1990...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = EvidenceText.utcCalendar.date(from: components),
              EvidenceText.utcCalendar.component(.day, from: date) == day else { return nil }
        return date
    }
}

/// Amounts found in a document's text: Portuguese `1.234,56 €` / `1.234,56 EUR`, UK
/// `£1,234.56` / `1,234.56 GBP`, and bare `1.234,56` (no currency). Only amounts with two
/// decimals count, so references and ids aren't read as money; thousands are grouped by `.`,
/// `,` or a no-break space, or by plain spaces next to a euro marker ("30 000,00 €").
public enum EvidenceAmountParser {
    public struct Found: Equatable, Sendable {
        /// Sign-free minor units.
        public var minorUnits: Int
        /// The currency written next to it, if any.
        public var currency: Currency?
        public var range: NSRange
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:(€|£|EUR|GBP)\s?)?(?<![\d.,])(\d{1,3}(?:([.,\u00A0\u202F])\d{3})*|\d+)([.,])(\d{2})(?!\d|[.,]\d)(?:\s?(€|£|EUR(?:OS)?|GBP|euros?))?"#,
        options: [.caseInsensitive])
    /// Thousands grouped by plain spaces ("30 000,00 €"): only next to a euro marker, since a
    /// plain space usually separates columns.
    private static let spacedPattern = try! NSRegularExpression(
        pattern: #"(?:(€|EUR)\s?)?(?<![\d.,])(\d{1,3}(?: \d{3})+),(\d{2})(?!\d|[.,]\d)(?:\s?(€|EUR(?:OS)?|euros?))?"#,
        options: [.caseInsensitive])

    /// Every amount in `text`, in the order they appear.
    public static func amounts(in text: String) -> [Found] {
        let source = text as NSString
        let all = NSRange(location: 0, length: source.length)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let r = match.range(at: index)
            return r.location == NSNotFound ? nil : source.substring(with: r)
        }
        var found: [Found] = []
        for match in spacedPattern.matches(in: text, range: all) {
            guard group(match, 1) != nil || group(match, 4) != nil, let whole = group(match, 2), let cents = group(match, 3).flatMap({ Int($0) }),
                  let wholeValue = Int(whole.filter(\.isNumber)) else { continue }
            found.append(Found(minorUnits: wholeValue * 100 + cents, currency: .eur, range: match.range))
        }
        let spaced = found.map(\.range)
        for match in pattern.matches(in: text, range: all) {
            if spaced.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            guard let whole = group(match, 2), let decimalSeparator = group(match, 4), let cents = group(match, 5), let centsValue = Int(cents) else { continue }
            // The grouping separator must differ from the decimal one ("1.234.56" is not money).
            if let grouping = group(match, 3), grouping == decimalSeparator { continue }
            let digits = whole.filter(\.isNumber)
            guard let wholeValue = Int(digits), digits.count <= 12 else { continue }
            let marker = (group(match, 1) ?? group(match, 6))?.uppercased()
            let currency: Currency? = switch marker {
            case "€", "EUR", "EUROS", "EURO": .eur
            case "£", "GBP": .gbp
            default: nil
            }
            found.append(Found(minorUnits: wholeValue * 100 + centsValue, currency: currency, range: match.range))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Parses one amount ("1.234,56", "£1,234.56", "240,00 €").
    public static func amount(_ string: String) -> Found? {
        amounts(in: string).first
    }
}

/// Text helpers shared by classification and field extraction.
public enum EvidenceText {
    /// Diacritics removed, case kept ("Prestação" → "Prestacao").
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// For rule matching: folded, uppercased, whitespace runs as single spaces.
    public static func normalized(_ text: String) -> String {
        fold(text).uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
