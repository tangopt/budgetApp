import SwiftUI
import BudgetCore

/// Needs attention (iPhone spec §3.2): uncategorised transactions, balances out of date and sync problems, one
/// line each. Read-only in this step: no "Sort ›", no actions.
struct AttentionCard: View {
    let lines: [AttentionLine]
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Card(title: "Needs you") {
            if lines.isEmpty {
                Text("Nothing needs attention.")
                    .foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                // At accessibility sizes the icon sits above its line: beside it, the enlarged glyph runs into the
                // label.
                if AmountRowLayout.stacks(at: dynamicTypeSize) {
                    VStack(alignment: .leading, spacing: 4) {
                        icon(line)
                        row(line)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        icon(line)
                            .frame(minWidth: 22)
                        row(line)
                    }
                }
            }
        }
    }

    private func icon(_ line: AttentionLine) -> some View {
        Image(systemName: line.symbol)
            .foregroundStyle(line.tone == .amber ? theme.pending : Color.secondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func row(_ line: AttentionLine) -> some View {
        if let count = line.count {
            FigureRow(label: line.label, secondary: line.detail) {
                Text(String(count)).figureText()
            }
        } else {
            Text(line.label.figuresUnbroken)
                .foregroundStyle(line.tone == .amber ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}
