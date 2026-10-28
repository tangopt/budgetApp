import SwiftUI
import BudgetCore

/// A message at the top of a tab (iPhone spec §3.9): `.amber` for what limits the data (offline, showing data from
/// a time), `.neutral` for what is only information (waiting for the household key: waiting isn't failing, so
/// never red). An icon in the tone's colour and `.callout` prose on a 10% wash of it; figures in the text stay
/// whole.
public struct InlineBanner: View {
    public enum Tone: Sendable {
        case amber, neutral
    }

    public let tone: Tone
    public let text: String
    @Environment(\.phoneTheme) private var theme

    public init(tone: Tone, text: String) {
        self.tone = tone
        self.text = text
    }

    private var tint: Color {
        switch tone {
        case .amber: theme.pending
        case .neutral: .secondary
        }
    }

    private var symbol: String {
        switch tone {
        case .amber: "exclamationmark.triangle.fill"
        case .neutral: "info.circle.fill"
        }
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text.figuresUnbroken)
                .mangoFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}
