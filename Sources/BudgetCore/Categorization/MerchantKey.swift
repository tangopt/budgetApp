import Foundation

public enum MerchantKey {
    private static let edgePunctuation = CharacterSet(charactersIn: "*-/.,#")

    /// Payment-processor prefixes: a key made only of these ("PAYPAL") would capture every
    /// merchant behind the processor.
    static let processorTokens: Set<String> = ["PAYPAL", "SQ", "SUMUP", "ZETTLE", "IZ", "STRIPE", "CRV", "CKO", "AMZN", "AMZNMKTPLACE", "MKTP", "AMAZON", "GOOGLE"]

    /// Corporate suffixes and country codes ("POD POINT LTD"); `ReviewKey` drops them from
    /// the end of a key.
    static let corporateSuffixTokens: Set<String> = ["LTD", "LIMITED", "PLC", "CO", "INC", "LLC", "UK", "GB"]

    /// Corporate suffixes and generic words: a key made only of these ("LIMITED" left over from
    /// "AB1 LIMITED") would group unrelated merchants.
    static let genericTokens: Set<String> = corporateSuffixTokens.union(["LONDON", "STORE", "STORES", "SHOP", "CARD", "PAYMENT", "MOBILE", "SERVICES", "GROUP"])

    /// Stable merchant identity for a statement description: uppercase, tokens containing
    /// digits dropped (store numbers, references), edge punctuation stripped. Falls back to
    /// the whole uppercased description when the result would be shorter than 3 characters or
    /// made only of processor or generic tokens.
    public static func make(_ description: String) -> String {
        let collapsed = description.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let kept = keptTokens(description)
        let key = kept.joined(separator: " ")
        if key.count < 3 { return collapsed }
        return isUninformative(kept) ? collapsed : key
    }

    /// The description's uppercased tokens without those containing digits, edge
    /// punctuation stripped.
    static func keptTokens(_ description: String) -> [String] {
        description.uppercased().split(whereSeparator: \.isWhitespace)
            .filter { token in !token.contains(where: \.isNumber) }
            .map { $0.trimmingCharacters(in: edgePunctuation) }
            .filter { !$0.isEmpty }
    }

    /// Whether the tokens are only processor or generic tokens.
    static func isUninformative(_ tokens: [String]) -> Bool {
        tokens.allSatisfy { processorTokens.contains($0) || genericTokens.contains($0) }
    }
}
