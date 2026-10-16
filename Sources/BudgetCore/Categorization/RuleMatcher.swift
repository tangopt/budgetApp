import Foundation

public enum RuleMatcher {
    /// Returns the highest-priority rule whose pattern matches `description`, or nil.
    /// A `.contains` rule matches when its pattern appears in the raw description or in its
    /// `MerchantKey` (so key rules learned from "SQ *DONUTELIER CAR" still match it).
    public static func match(description: String, rules: [Rule]) -> Rule? {
        let key = MerchantKey.make(description)
        let candidates = rules.filter { rule in matches(rule, description: description, key: key) }
        return candidates.max(by: { $0.priority < $1.priority })
    }

    /// Whether one rule matches `description`, with the same semantics as `match` (imports).
    public static func matches(_ rule: Rule, description: String) -> Bool {
        matches(rule, description: description, key: MerchantKey.make(description))
    }

    /// `matches` for many descriptions: the rule's regex is compiled once. An invalid regex
    /// matches nothing.
    static func predicate(for rule: Rule) -> (String) -> Bool {
        switch rule.matchType {
        case .contains:
            let pattern = rule.matchPattern
            return { description in
                description.range(of: pattern, options: .caseInsensitive) != nil
                    || MerchantKey.make(description).range(of: pattern, options: .caseInsensitive) != nil
            }
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: rule.matchPattern, options: .caseInsensitive) else { return { _ in false } }
            return { description in
                regex.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)) != nil
            }
        }
    }

    private static func matches(_ rule: Rule, description: String, key: String) -> Bool {
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
}
