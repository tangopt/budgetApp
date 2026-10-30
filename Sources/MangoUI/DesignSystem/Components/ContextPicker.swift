import SwiftUI
import BudgetCore

/// The one picker for what a page is about (design review §3.4, I4): a tenancy, an account, a year. An accent-tint
/// capsule with the choice's label and a chevron, opening a menu of the options with a tick on the chosen one. It
/// sits first in a `PageHeader`'s context line, always on the left. The label truncates in the middle.
struct ContextPicker: View {
    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// What the capsule says: the chosen option's title.
    let label: String
    /// What VoiceOver names the control ("Tenancy", "Year").
    let accessibilityName: String
    let options: [Option]
    let selectedId: String?
    let choose: (String) -> Void
    @Environment(\.phoneTheme) private var theme

    init(label: String, accessibilityName: String, options: [Option], selectedId: String?, choose: @escaping (String) -> Void) {
        self.label = label
        self.accessibilityName = accessibilityName
        self.options = options
        self.selectedId = selectedId
        self.choose = choose
    }

    /// A picker over any items: `id` and `title` read each one; the label is the selected item's title (`fallback`
    /// when none is selected). The capsule says `shortTitle` when given, the menu the full `title`.
    init<Item>(_ accessibilityName: String, items: [Item], selected: String?, fallback: String = "",
               id: @escaping (Item) -> String, title: (Item) -> String, shortTitle: ((Item) -> String)? = nil,
               choose: @escaping (Item) -> Void) {
        let options = items.map { Option(id: id($0), title: title($0)) }
        let label = items.first { id($0) == selected }.map { shortTitle?($0) ?? title($0) } ?? fallback
        self.init(label: label, accessibilityName: accessibilityName,
                  options: options, selectedId: selected) { chosen in
            if let item = items.first(where: { id($0) == chosen }) { choose(item) }
        }
    }

    /// A single choice isn't a choice: the capsule is then a plain label (a year with one year, one tenancy).
    var isInteractive: Bool { Self.isInteractive(optionCount: options.count) }

    static func isInteractive(optionCount: Int) -> Bool { optionCount > 1 }

    var body: some View {
        if isInteractive {
            Menu {
                ForEach(options) { option in
                    Button { choose(option.id) } label: {
                        if option.id == selectedId { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                    }
                }
            } label: {
                capsule(showsChevron: true)
            }
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(label)
        } else {
            capsule(showsChevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func capsule(showsChevron: Bool) -> some View {
        HStack(spacing: MangoSpacing.xxs + 2) {
            Text(label).lineLimit(1).truncationMode(.middle)
            if showsChevron { Image(systemName: "chevron.up.chevron.down").mangoFont(.caption, weight: .semibold).accessibilityHidden(true) }
        }
        .mangoFont(.subheadline, weight: .semibold)
        .foregroundStyle(theme.accentTintText)
        .padding(.horizontal, MangoSpacing.s)
        .frame(minHeight: 36)
        .background(Capsule().fill(theme.accentTint))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
