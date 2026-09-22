import Foundation

public enum RuleMatcher {
    /// Returns the highest-priority rule whose pattern matches `description`, or nil.
    public static func match(description: String, rules: [Rule]) -> Rule? {
        let candidates = rules.filter { rule in
            switch rule.matchType {
            case .contains:
                return description.range(of: rule.matchPattern, options: .caseInsensitive) != nil
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
