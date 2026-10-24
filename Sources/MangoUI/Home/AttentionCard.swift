import SwiftUI
import BudgetCore

/// Needs attention (iPhone spec §3.2): uncategorised transactions, balances out of date and sync problems, one
/// line each. Read-only in this step: no "Sort ›", no actions.
struct AttentionCard: View {
    let lines: [AttentionLine]
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Card(title: "Needs attention") {
            if lines.isEmpty {
                Text("Nothing needs attention.")
                    .foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: line.symbol)
                        .foregroundStyle(line.tone == .amber ? theme.pending : Color.secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
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
        }
    }
}
