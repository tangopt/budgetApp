// App/DesignSystem/Charts/ProgressBar.swift
import SwiftUI

/// How much of something is done, as a line (`ProgressRing`'s colours): the accent — the
/// income colour once complete — over a faint track, full width, `height` tall. For a
/// footer under a chart (a loan repaid); the figures go in their own text beside or below.
struct ProgressBar: View {
    /// 0…1.
    let fraction: Double
    var height: CGFloat = 6
    var accessibilityLabel = "Progress"
    @Environment(\.theme) private var theme

    private var clamped: Double { min(1, max(0, fraction)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(clamped >= 1 ? theme.income : theme.accent)
                    .frame(width: max(height, geometry.size.width * clamped))
                    .opacity(clamped > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int((clamped * 100).rounded(.down))) percent")
    }
}
