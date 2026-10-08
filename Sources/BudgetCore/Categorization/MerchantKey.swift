import Foundation

public enum MerchantKey {
    private static let edgePunctuation = CharacterSet(charactersIn: "*-/.,#")

    /// Stable merchant identity for a statement description: uppercase, tokens containing
    /// digits dropped (store numbers, references), edge punctuation stripped. Falls back to
    /// the whole uppercased description when the result would be shorter than 3 characters.
    public static func make(_ description: String) -> String {
        let tokens = description.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let collapsed = tokens.joined(separator: " ")
        let kept = tokens
            .filter { token in !token.contains(where: \.isNumber) }
            .map { $0.trimmingCharacters(in: edgePunctuation) }
            .filter { !$0.isEmpty }
        let key = kept.joined(separator: " ")
        return key.count < 3 ? collapsed : key
    }
}
