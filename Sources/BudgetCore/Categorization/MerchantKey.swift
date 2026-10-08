import Foundation

public enum MerchantKey {
    private static let edgePunctuation = CharacterSet(charactersIn: "*-/.,#")

    /// Payment-processor prefixes: a key made only of these ("PAYPAL") would capture every
    /// merchant behind the processor.
    private static let processorTokens: Set<String> = ["PAYPAL", "SQ", "SUMUP", "ZETTLE", "IZ", "STRIPE", "CRV", "CKO", "AMZN", "MKTP", "AMAZON", "GOOGLE"]

    /// Corporate suffixes and generic words: a key made only of these ("LIMITED" left over from
    /// "AB1 LIMITED") would group unrelated merchants.
    private static let genericTokens: Set<String> = ["LTD", "LIMITED", "PLC", "CO", "INC", "LLC", "UK", "GB", "LONDON", "STORE", "STORES", "SHOP", "CARD", "PAYMENT", "MOBILE", "SERVICES", "GROUP"]

    /// Stable merchant identity for a statement description: uppercase, tokens containing
    /// digits dropped (store numbers, references), edge punctuation stripped. Falls back to
    /// the whole uppercased description when the result would be shorter than 3 characters or
    /// made only of processor or generic tokens.
    public static func make(_ description: String) -> String {
        let tokens = description.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let collapsed = tokens.joined(separator: " ")
        let kept = tokens
            .filter { token in !token.contains(where: \.isNumber) }
            .map { $0.trimmingCharacters(in: edgePunctuation) }
            .filter { !$0.isEmpty }
        let key = kept.joined(separator: " ")
        if key.count < 3 { return collapsed }
        let uninformative = kept.allSatisfy { processorTokens.contains($0) || genericTokens.contains($0) }
        return uninformative ? collapsed : key
    }
}
