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
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.surface))
    }
}
