import Foundation

/// The key rows are grouped by in Review and Uncategorized (spec §2). Coarser than
/// `MerchantKey`, which learning and rule matching keep using: it also joins the
/// variants a bank's 18-character truncation produces, and puts every processor-only
/// purchase ("AMAZON* NQ7KP7EB5") under the processor's name.
public enum ReviewKey {
    /// A key at least this long joins a longer key that starts with it.
    static let minimumMergePrefixLength = 5

    /// One key per description, in the same order. Keys are computed over the whole set:
    /// a key that is a plain string prefix of a longer key in the set ("OMNICOM" of
    /// "OMNICOM MANAGEMENT") becomes that longer key, resolving chains to the longest. When
    /// it prefixes several, it joins the one with the most rows (the first seen on a tie).
    /// Processor keys never join a longer key: "AMAZON" purchases aren't "AMAZON PRIME".
    public static func groupKeys(descriptions: [String]) -> [String] {
        let baseKeys = descriptions.map(baseKey)
        var rowCounts: [String: Int] = [:]
        var uniqueKeys: [String] = []
        for key in baseKeys {
            if rowCounts[key] == nil { uniqueKeys.append(key) }
            rowCounts[key, default: 0] += 1
        }
        // Keys no other key extends — where every chain ends.
        let longest = uniqueKeys.filter { key in !uniqueKeys.contains { $0 != key && $0.hasPrefix(key) } }
        var merged: [String: String] = [:]
        for key in uniqueKeys where key.count >= minimumMergePrefixLength && !isProcessorGroup(key) {
            var target: String?
            for candidate in longest where candidate != key && candidate.hasPrefix(key) {
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
