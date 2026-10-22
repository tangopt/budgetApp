import Foundation

/// The words the setup, lock screen and Settings ▸ Sign-in show about people and sign-in (auth spec §6).
public enum AuthText {
    /// The avatar's letters: the first letters of the first and last words ("Person A" → "PA").
    public static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// After too many wrong attempts: "Try again in N s", N rounded up and never 0, the figure kept whole.
    public static func tryAgain(after seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded(.up)))
        return "Try again in \("\(whole) s".unbroken)"
    }
}

/// How hard a password would be to guess, for the hint under "Choose a password". Only `tooShort` is
/// refused (`AppUserStore.minimumPasswordLength`); the rest is advice.
public enum PasswordStrength: Int, Comparable, Sendable {
    case tooShort, weak, fair, strong

    public static func assess(_ password: String) -> PasswordStrength {
        guard password.count >= AppUserStore.minimumPasswordLength else { return .tooShort }
        if Set(password).count <= 3 { return .weak }
        var kinds = 0
        if password.contains(where: \.isLowercase) { kinds += 1 }
        if password.contains(where: \.isUppercase) { kinds += 1 }
        if password.contains(where: \.isNumber) { kinds += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { kinds += 1 }
        let score = kinds + (password.count >= 14 ? 1 : 0) + (password.count >= 20 ? 1 : 0)
        switch score {
        case ...1: return .weak
        case 2...3: return .fair
        default: return .strong
        }
    }

    public var isAcceptable: Bool { self != .tooShort }

    public var hint: String {
        switch self {
        case .tooShort: "At least 10 characters"
        case .weak: "Weak: make it longer, or add numbers and symbols"
        case .fair: "Fair: a few more words would make it stronger"
        case .strong: "Strong"
        }
    }

    public static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool { lhs.rawValue < rhs.rawValue }
}
