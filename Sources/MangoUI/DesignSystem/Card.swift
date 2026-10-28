import SwiftUI

/// A titled group on a screen (Home's cards, a month's sections): an optional headline title over its content on
/// the theme's surface, 16 pt padding, continuous corners.
public struct Card<Content: View>: View {
    public let title: String?
    public let content: Content
    @Environment(\.phoneTheme) private var theme

    public init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        // The card keeps the width it is offered: a figure too wide for it runs past its edge (which the probe
        // reports as cut off) instead of silently widening the card past its neighbours.
        ProposedWidth {
            stack
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.surface))
        // A figure must stay on the card, not just in the window.
        .wrapProbeClips()
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .mangoFont(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays its one child out at the offered width and reports that width, whatever the child would rather be (the
/// child's own width only when no finite width is offered).
struct ProposedWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(proposal)
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return CGSize(width: offered ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
