// App/DesignSystem/StatusPill.swift
import SwiftUI

/// A record's state as a small capsule (the Accounts badges' recipe, spec §1.2):
/// `.caption.weight(.medium)`, the tone's colour on 15% of it. Statement draft/sent/paid,
/// receipt issued/cancelled, tax year preparing/filed, a check's issues.
struct StatusPill: View {
    enum Tone {
        /// Not started or not applicable (draft, cancelled, preparing).
        case neutral
        /// Under way (sent, ready).
        case accent
        /// Done (paid, filed, complete).
        case positive
        /// Needs doing (missing, overdue, unmatched).
        case warning
        /// Wrong (a mismatch, an error).
        case negative
    }

    let title: String
    var tone: Tone = .neutral
    var systemImage: String? = nil
    /// A longer explanation, as the pill's tooltip and VoiceOver hint.
    var help: String? = nil
    @Environment(\.theme) private var theme

    init(_ title: String, tone: Tone = .neutral, systemImage: String? = nil, help: String? = nil) {
        self.title = title
        self.tone = tone
        self.systemImage = systemImage
        self.help = help
    }

    private var color: Color {
        switch tone {
        case .neutral: return theme.neutralMoney
        case .accent: return theme.accent
        case .positive: return theme.income
        case .warning: return theme.pending
        case .negative: return theme.expense
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(tone == .neutral ? Color.secondary : color)
        .accessibilityElement(children: .combine)
        .modifier(PillHelp(text: help))
    }
}

/// A pill's tooltip and hint, only when it has one.
private struct PillHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text).accessibilityHint(text)
        } else {
            content
        }
    }
}
