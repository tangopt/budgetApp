// App/DesignSystem/Panel.swift
import SwiftUI
import BudgetCore

/// The shared measurements of the screens (UI polish spec §1): screen padding, block spacing
/// and the card recipe.
enum ScreenMetrics {
    /// Around a screen's content (`.padding()` on the polished screens).
    static let padding: CGFloat = 16
    /// Between a screen's blocks.
    static let spacing: CGFloat = 12
}

/// A card: the app's one panel recipe (`DashboardCard`'s look, spec §1.2). An optional
/// `.headline` title with an optional `.caption` secondary subtitle and a trailing accessory
/// (buttons, a "Name ›" link, a status), then the content; 14 pt padding, 10 pt spacing,
/// a 12 pt rounded `theme.surface` fill **stroked with the separator colour** — the stroke is
/// what keeps a card visible where the surface matches the window (Classic light).
struct Panel<Content: View, Accessory: View>: View {
    static var cornerRadius: CGFloat { 12 }

    let title: String?
    var subtitle: String?
    var padding: CGFloat
    /// Stretches to the height it's offered (cards side by side in a `TwoUpRow`).
    var fillsHeight: Bool
    let accessory: Accessory
    let content: Content
    @Environment(\.theme) private var theme

    init(_ title: String? = nil, subtitle: String? = nil, padding: CGFloat = 14, fillsHeight: Bool = false,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.padding = padding
        self.fillsHeight = fillsHeight
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let title {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                            if let subtitle {
                                // Wraps as prose; the figures in it stay whole (spec §6.3).
                                Text(subtitle.figuresUnbroken).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

extension Panel where Accessory == PanelLink {
    /// A card whose accessory is a "Name ›" link to another screen (the Dashboard's cards).
    init(_ title: String, link: String, fillsHeight: Bool = false, onLink: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title, fillsHeight: fillsHeight, accessory: { PanelLink(title: link, action: onLink) }, content: content)
    }
}

/// A panel's "Name ›" navigation link.
struct PanelLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button("\(title) ›", action: action)
            .buttonStyle(.link)
            .font(.caption)
            .help("Open \(title)")
    }
}
