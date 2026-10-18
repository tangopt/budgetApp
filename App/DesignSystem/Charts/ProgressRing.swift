// App/DesignSystem/Charts/ProgressRing.swift
import SwiftUI

/// How much of something is done (spec §4.1; evidence collected): a ring in the accent — the
/// income colour once complete — on a faint track, the percentage inside (rings of 30 pt and
/// up; a smaller ring is a glyph beside its own text), an optional caption beneath.
struct ProgressRing: View {
    let done: Int
    let total: Int
    var size: CGFloat = 56
    var lineWidth: CGFloat? = nil
    var caption: String? = nil
    @Environment(\.theme) private var theme

    private var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 1 }
    /// Rounded down, so 100% means everything is done.
    private var percent: Int { Int((fraction * 100).rounded(.down)) }
    private var stroke: CGFloat { lineWidth ?? max(2.5, (size / 9).rounded()) }

    private var percentFont: Font {
        switch size {
        case 64...: return .title3.weight(.semibold)
        case 44...: return .callout.weight(.semibold)
        default: return .caption2.weight(.semibold)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: stroke)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(fraction >= 1 ? theme.income : theme.accent, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if size >= 30 {
                    Text("\(percent)%")
                        .font(percentFont)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, stroke)
                }
            }
            .frame(width: size, height: size)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? "Progress")
        .accessibilityValue("\(percent) percent, \(done) of \(total)")
    }
}
