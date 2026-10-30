import SwiftUI

/// A titled group on a screen (Home's cards, a month's sections): an optional headline title over its content on
/// the theme's surface, `MangoSpacing.cardPadding`, `MangoRadius.card` continuous corners.
public struct Card<Content: View>: View {
    public let title: String?
    public let content: Content
    @Environment(\.phoneTheme) private var theme
    /// In a row of equal-height cards (the iPad's `PadTileGrid`), the card fills the height it is offered.
    @Environment(\.cardFillsHeight) private var fillsHeight

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
        .background(RoundedRectangle(cornerRadius: MangoRadius.card, style: .continuous).fill(theme.surface))
        // Clear draws a visible border on every card; the other sets tell cards from the ground by the surface step.
        .overlay {
            if theme.edges == .bordered {
                RoundedRectangle(cornerRadius: MangoRadius.card, style: .continuous).strokeBorder(theme.separator, lineWidth: 1)
            }
        }
        // A figure must stay on the card, not just in the window.
        .wrapProbeClips()
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: MangoSpacing.s) {
            if let title {
                Text(title)
                    .mangoFont(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            content
                .environment(\.cardFillsHeight, false)
        }
        .padding(MangoSpacing.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: fillsHeight ? .topLeading : .leading)
    }
}

private struct CardFillsHeightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set on a row of cards that share one height (`padEqualHeightCards()`): each `Card` fills the height offered.
    public var cardFillsHeight: Bool {
        get { self[CardFillsHeightKey.self] }
        set { self[CardFillsHeightKey.self] = newValue }
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
