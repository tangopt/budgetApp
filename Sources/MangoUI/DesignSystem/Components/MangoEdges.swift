import SwiftUI
import BudgetCore

/// How a set's edge style (`ThemeSet.Edges`) shows on the shared components: Clear draws a 1 pt `separator` border on
/// surfaces, Flat draws no line anywhere (rows and cards are told apart by surface steps and space), Standard draws
/// hairlines between rows and no card border.
enum MangoEdgeRules {
    /// Hairlines between the rows of a list: every set but Flat.
    static func drawsDividers(_ edges: ThemeSet.Edges) -> Bool { edges != .flat }
    /// A border around cards, tiles and panels: Clear only.
    static func drawsBorders(_ edges: ThemeSet.Edges) -> Bool { edges == .bordered }
}

/// The hairline between two rows of a card; nothing (and no height) in Flat.
struct MangoDivider: View {
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        if MangoEdgeRules.drawsDividers(theme.edges) {
            Rectangle().fill(theme.separator).frame(height: 1).accessibilityHidden(true)
        }
    }
}

extension View {
    /// A tile or card surface: the fill, `MangoRadius.card` continuous corners, and Clear's border.
    func mangoSurface(radius: CGFloat = MangoRadius.card, fill: KeyPath<PhoneTheme, Color> = \.surface) -> some View {
        modifier(MangoSurface(radius: radius, fill: fill))
    }

    /// The one selected-row style (design review I6): an `accentTint` fill and a 3 pt accent bar on the leading edge,
    /// with VoiceOver's selected trait.
    func mangoRowSelection(_ isSelected: Bool, radius: CGFloat = MangoRadius.control) -> some View {
        modifier(MangoRowSelection(isSelected: isSelected, radius: radius))
    }
}

private struct MangoSurface: ViewModifier {
    let radius: CGFloat
    let fill: KeyPath<PhoneTheme, Color>
    @Environment(\.phoneTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme[keyPath: fill]))
            .overlay {
                if MangoEdgeRules.drawsBorders(theme.edges) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.separator, lineWidth: 1)
                }
            }
    }
}

private struct MangoRowSelection: ViewModifier {
    let isSelected: Bool
    let radius: CGFloat
    @Environment(\.phoneTheme) private var theme
    @Environment(\.mangoRowBleed) private var bleed

    /// In a card the tint runs square to the card's edges (the card clips its corners); on its own it keeps `radius`.
    private var shape: UnevenRoundedRectangle {
        let r = bleed > 0 ? 0 : radius
        return UnevenRoundedRectangle(cornerRadii: .init(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r), style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if isSelected { shape.fill(theme.accentTint).padding(.horizontal, -bleed) }
            }
            .overlay(alignment: .leading) {
                // The bar sits at the row's own leading edge (the card's edge in a card), outside the text.
                if isSelected {
                    Capsule().fill(theme.accent).frame(width: MangoRowMetrics.selectionBar)
                        .padding(.vertical, MangoSpacing.xs).offset(x: -bleed)
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MangoRowBleedKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// How far a selected row's tint reaches past the row on each side: the padding of the card the row sits in, so the
    /// whole row, edge to edge of the card, is painted. Set by `Card`; zero elsewhere.
    var mangoRowBleed: CGFloat {
        get { self[MangoRowBleedKey.self] }
        set { self[MangoRowBleedKey.self] = newValue }
    }
}

enum MangoRowMetrics {
    /// The selected row's accent bar.
    static let selectionBar: CGFloat = 3
}
