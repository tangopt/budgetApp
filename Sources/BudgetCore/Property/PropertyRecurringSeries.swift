import Foundation

/// The payee series of a category's payments (2026-10-24): a cost recurs per payee, not per
/// category. A category's insurer can change (twice a year with one, quarterly with the next,
/// yearly with the latest); reading the category as one series mixed their cadences.
public enum PropertyRecurringSeries {
    /// One key per description, in the same order: the SEPA creditor identifier when the
    /// description carries one ("sepa:PT12ZZZ100200"), else the payee's words as `ReviewKey`
    /// groups them, without references (tokens with digits) and month names ("CONDOMINIO JAN"
    /// is the same payee as "CONDOMINIO ABRIL").
    public static func keys(_ descriptions: [String]) -> [String] {
        let words = ReviewKey.groupKeys(descriptions: descriptions.map(withoutMonths))
        return zip(descriptions, words).map { description, key in creditorIdentifier(description).map { "sepa:" + $0 } ?? key }
    }

    /// A readable name for a key: the payee's words in title case, or the creditor identifier.
    public static func label(_ key: String) -> String {
        if key.hasPrefix("sepa:") { return String(key.dropFirst(5)) }
        return key.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// The SEPA creditor identifier in a description: country code, two check digits, the
    /// usual "ZZZ" business code, then the national identifier ("PT12ZZZ100200").
    static func creditorIdentifier(_ description: String) -> String? {
        for token in description.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let chars = Array(token)
            guard chars.count >= 8, chars.count <= 35, chars[0].isASCII, chars[0].isLetter, chars[1].isASCII, chars[1].isLetter,
                  chars[2].isNumber, chars[3].isNumber, String(chars[4..<7]) == "ZZZ",
                  chars[7...].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
            return String(token)
        }
        return nil
    }

    /// Month names and abbreviations (English, Portuguese, Spanish) bank descriptions carry.
    static let monthTokens: Set<String> = [
        "JAN", "JANUARY", "JANEIRO", "ENE", "ENERO", "FEB", "FEBRUARY", "FEV", "FEVEREIRO", "FEBRERO", "MAR", "MARCH", "MARCO", "MARZO",
        "APR", "APRIL", "ABR", "ABRIL", "MAY", "MAI", "MAIO", "MAYO", "JUN", "JUNE", "JUNHO", "JUNIO", "JUL", "JULY", "JULHO", "JULIO",
        "AUG", "AUGUST", "AGO", "AGOSTO", "SEP", "SEPT", "SEPTEMBER", "SET", "SETEMBRO", "SEPTIEMBRE", "OCT", "OCTOBER", "OUT", "OUTUBRO",
        "OCTUBRE", "NOV", "NOVEMBER", "NOVEMBRO", "NOVIEMBRE", "DEC", "DECEMBER", "DEZ", "DEZEMBRO", "DIC", "DICIEMBRE",
    ]

    static func withoutMonths(_ description: String) -> String {
        let folded = description.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let kept = folded.uppercased().split(whereSeparator: \.isWhitespace).filter {
            !monthTokens.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "*-/.,#")))
        }
        return kept.isEmpty ? folded.uppercased() : kept.joined(separator: " ")
    }
}
