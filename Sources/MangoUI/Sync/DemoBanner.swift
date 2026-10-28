import SwiftUI
import BudgetCore

/// The banner over every screen while the phone shows demo data ("Try with demo data"): white on a solid purple no
/// theme uses, in light and dark alike, so it can't be mistaken for the household's figures or a sync message.
public struct DemoBanner: View {
    public static let text = "Demo data — not yours"
    static let fill = Color(red: 0.42, green: 0.20, blue: 0.72)

    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "theatermasks.fill")
                .accessibilityHidden(true)
            Text(Self.text)
                .mangoFont(.callout, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.fill))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension EnvironmentValues {
    /// The screens below show demo data (`PhoneTabs(isDemo:)`).
    @Entry public var showsDemoData = false
}

private struct DemoBannerSlot: ViewModifier {
    @Environment(\.showsDemoData) private var showsDemoData

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if showsDemoData { DemoBanner() }
        }
    }
}

extension View {
    /// Shows `DemoBanner` at the top of this view, under its navigation bar, when a view above set
    /// `showsDemoData` (`PhoneTabs(isDemo:)`): pushed screens and sheets (Settings, a transaction's detail). The
    /// tabs' root screens show it through `offlineBannerSlot()`.
    public func demoBannerSlot() -> some View {
        modifier(DemoBannerSlot())
    }
}
