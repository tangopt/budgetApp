import Foundation

/// The key rows are grouped by in Review and Uncategorized (spec §2). Coarser than
/// `MerchantKey`, which learning and rule matching keep using: it also joins the
/// variants a bank's 18-character truncation produces, and puts every processor-only
/// purchase ("AMAZON* NQ7KP7EB5") under the processor's name.
public enum ReviewKey {
    /// A key at least this long joins a longer key that starts with it.
    static let minimumMergePrefixLength = 5

    /// The bank's description length limit (Lloyds): a description this long may have been
    /// cut off mid-word.
    static let truncationLength = 18

    /// One key per description, in the same order. Keys are computed over the whole set:
    /// a key that is a prefix of a longer key in the set becomes that longer key, resolving
    /// chains to the longest. A word-boundary prefix ("OMNICOM" of "OMNICOM MANAGEMENT")
    /// always joins; a mid-word prefix joins when it has two or more words ("AMERICAN EXP" of
    /// "AMERICAN EXPRESS": real truncations are 15-17 characters) or when a description behind
    /// it is at the truncation length, so one-word "SHELL" stays apart from "SHELLEYS CAFE". When it prefixes several, it joins the one with the most rows (the
    /// first seen on a tie). Processor keys never join a longer key: "AMAZON" purchases
    /// aren't "AMAZON PRIME".
    public static func groupKeys(descriptions: [String]) -> [String] {
        let baseKeys = descriptions.map(baseKey)
        var rowCounts: [String: Int] = [:]
        var truncated: Set<String> = []
        var uniqueKeys: [String] = []
        for (description, key) in zip(descriptions, baseKeys) {
            if rowCounts[key] == nil { uniqueKeys.append(key) }
            rowCounts[key, default: 0] += 1
            if description.trimmingCharacters(in: .whitespaces).count >= truncationLength { truncated.insert(key) }
        }
        func canJoin(_ key: String, _ longer: String) -> Bool {
            guard key.count >= minimumMergePrefixLength, !isProcessorGroup(key),
                  longer != key, longer.hasPrefix(key) else { return false }
            return longer.hasPrefix(key + " ") || key.contains(" ") || truncated.contains(key)
        }
        // Keys that join nothing — where every chain ends. A key that can join an
        // intermediate key can also join whatever that one joins, so targets are always ends.
        let ends = uniqueKeys.filter { key in !uniqueKeys.contains { canJoin(key, $0) } }
        var merged: [String: String] = [:]
        for key in uniqueKeys {
            var target: String?
            for candidate in ends where canJoin(key, candidate) {
                if target == nil || rowCounts[candidate, default: 0] > rowCounts[target!, default: 0] { target = candidate }
            }
            if let target { merged[key] = target }
        }
        return baseKeys.map { merged[$0] ?? $0 }
    }

    /// Whether a group key is a payment processor's name ("AMAZON", "PAYPAL"): its rows are
    /// unrelated purchases, so its Remember checkbox defaults off.
    public static func isProcessorGroup(_ key: String) -> Bool {
        MerchantKey.processorTokens.contains(key)
    }

    /// The key of one description on its own: the processor name for a processor-only
    /// description, else `MerchantKey.make` (with "*" read as a separator) without trailing
    /// corporate suffixes ("POD POINT LTD" → "POD POINT"), as long as something remains.
    static func baseKey(_ description: String) -> String {
        let normalized = description.replacingOccurrences(of: "*", with: " ")
        let kept = MerchantKey.keptTokens(normalized)
        if let processor = kept.first, MerchantKey.processorTokens.contains(processor), MerchantKey.isUninformative(kept) {
            return processor
        }
        var tokens = MerchantKey.make(normalized).split(separator: " ")
        while tokens.count > 1, let last = tokens.last, MerchantKey.corporateSuffixTokens.contains(String(last)) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }
}
