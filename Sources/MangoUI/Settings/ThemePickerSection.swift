import SwiftUI
import BudgetCore

/// Settings ▸ Theme (design review 2026-10-28 §3.5, step 8): the cards the picker shows. Pure, so a test can read
/// them.
public struct ThemePickerModel {
    public struct Card: Identifiable, Equatable {
        public let id: String
        public let name: String
        /// The set's faces, as the card's 12 pt line shows them ("SF Pro Rounded · SF Pro").
        public let fontNames: String
        public let isSelected: Bool
        /// What VoiceOver reads: "Editorial, serif headings, selected".
        public let spoken: String
    }

    /// The figure each card draws in its set's figure face, so the person sees how money will look.
    public static let sampleFigure = "£1,284"

    /// The eight sets in the catalogue's order; the stored id marks one (an unknown id marks Mango).
    public static func cards(selected id: String) -> [Card] {
        let selectedID = ThemeSet.named(id).id
        return ThemeSet.all.map { set in
            let selected = set.id == selectedID
            return Card(id: set.id, name: set.name, fontNames: set.fonts.names, isSelected: selected,
                        spoken: [set.name, set.summary, selected ? "selected" : nil].compactMap { $0 }.joined(separator: ", "))
        }
    }

    /// Columns: 2 x 4 on the iPhone, 4 x 2 on the iPad (a regular width); one column at the accessibility sizes,
    /// where a card's name and figure need the row.
    public static func columns(regularWidth: Bool, accessibilitySize: Bool) -> Int {
        accessibilitySize ? 1 : (regularWidth ? 4 : 2)
    }
}

/// The Theme section: eight preview cards, each drawn in its own set's palette and fonts in the current appearance
/// (its name in the display face, a figure in the figure face, an accent chip and the font names); the chosen card
/// has a 2 pt accent ring and a check. The cards are radio buttons.
struct ThemePickerSection: View {
    @Binding var themeSetId: String
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let count = ThemePickerModel.columns(regularWidth: sizeClass == .regular, accessibilitySize: typeSize.isAccessibilitySize)
        Section("Theme") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MangoSpacing.s), count: count), spacing: MangoSpacing.s) {
                ForEach(ThemePickerModel.cards(selected: themeSetId)) { card in
                    Button {
                        themeSetId = card.id
                    } label: {
                        ThemePreviewCard(card: card)
                            .environment(\.phoneTheme, PhoneTheme.named(card.id))
                            .environment(\.phoneFonts, ThemeSet.named(card.id).fonts)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(card.spoken)
                    .accessibilityAddTraits(card.isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, MangoSpacing.xs)
            .listRowInsets(EdgeInsets(top: MangoSpacing.s, leading: MangoSpacing.m, bottom: MangoSpacing.s, trailing: MangoSpacing.m))
            .listRowBackground(Color.clear)
        }
    }
}

/// One set's card, drawn with the set's theme and fonts in the environment.
private struct ThemePreviewCard: View {
    let card: ThemePickerModel.Card
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MangoRadius.control, style: .continuous)
        VStack(alignment: .leading, spacing: MangoSpacing.xs) {
            HStack(spacing: MangoSpacing.xs) {
                Text(card.name)
                    .mangoFont(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if card.isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: MangoSpacing.s) {
                Text(ThemePickerModel.sampleFigure)
                    .mangoFont(PhoneTextStyle.headline.figure())
                Spacer(minLength: 0)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 28, height: 14)
            }
            // Two lines, reserved so the cards in a row match: "SF Pro Rounded · SF Pro" doesn't fit one at half the
            // phone's width.
            Text(card.fontNames)
                .mangoFont(.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.text)
        .padding(MangoSpacing.s)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(shape.fill(theme.surface))
        .overlay {
            if card.isSelected {
                shape.strokeBorder(theme.accent, lineWidth: 2)
            } else {
                shape.strokeBorder(theme.separator, lineWidth: 1)
            }
        }
        .contentShape(shape)
    }
}
