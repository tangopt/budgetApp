import Foundation

public enum RuleMatcher {
    /// Returns the highest-priority rule whose pattern matches `description`, or nil.
    /// A `.contains` rule matches when its pattern appears in the raw description or in its
    /// `MerchantKey` (so key rules learned from "SQ *DONUTELIER CAR" still match it).
    public static func match(description: String, rules: [Rule]) -> Rule? {
        let key = MerchantKey.make(description)
        let candidates = rules.filter { rule in
            switch rule.matchType {
            case .contains:
                return description.range(of: rule.matchPattern, options: .caseInsensitive) != nil
                    || key.range(of: rule.matchPattern, options: .caseInsensitive) != nil
            case .regex:
                return (try? NSRegularExpression(pattern: rule.matchPattern, options: .caseInsensitive))
                    .map { regex in
                        regex.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)) != nil
                    } ?? false
            }
        }
        return candidates.max(by: { $0.priority < $1.priority })
    }
}
