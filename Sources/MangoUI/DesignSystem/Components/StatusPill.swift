import SwiftUI
import BudgetCore

/// A status as a word on a tint (design review §3.4): done, waiting, problem, to do, neutral. The word is always there
/// (status is never colour alone), and the colours are the set's status roles, so every set keeps the contrast its
/// palette was tested for.
struct StatusPill: View {
    enum Status: CaseIterable, Sendable {
        case done, waiting, problem, todo, neutral

        /// The role the word is drawn in and the role it sits on.
        var roles: (text: KeyPath<ThemeRoles, ThemeColor>, fill: KeyPath<ThemeRoles, ThemeColor>) {
            switch self {
            case .done: (\.income, \.incomeTint)
            case .waiting: (\.pending, \.pendingTint)
            case .problem: (\.expense, \.expenseTint)
            case .todo: (\.accentTintText, \.accentTint)
            case .neutral: (\.textSecondary, \.surface2)
            }
        }

        /// The word used when a caller has nothing more specific ("Done", "Waiting", "Problem", "To do", "Not needed").
        var defaultWord: String {
            switch self {
            case .done: "Done"
            case .waiting: "Waiting"
            case .problem: "Problem"
            case .todo: "To do"
            case .neutral: "Not needed"
            }
        }
    }

    let text: String
    let status: Status
    @Environment(\.phoneTheme) private var theme

    /// An empty `text` falls back to the status's own word: a pill never shows colour alone.
    init(_ text: String, _ status: Status) {
        self.text = text.isEmpty ? status.defaultWord : text
        self.status = status
    }

    var body: some View {
        let roles = status.roles
        Text(text)
            .mangoFont(.caption, weight: .semibold)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, MangoSpacing.xs + 2).padding(.vertical, MangoSpacing.xxs)
            .foregroundStyle(theme.color(roles.text))
            .background(Capsule().fill(theme.color(roles.fill)))
    }
}

extension PhoneTheme {
    /// A role's colour in this set (the same dynamic light/dark colour the set's other properties use).
    func color(_ role: KeyPath<ThemeRoles, ThemeColor>) -> Color {
        Self.color(light: lightRoles[keyPath: role], dark: darkRoles[keyPath: role])
    }
}
