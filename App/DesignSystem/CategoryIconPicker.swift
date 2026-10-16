// App/DesignSystem/CategoryIconPicker.swift
import SwiftUI
import BudgetCore

/// The icon picker popover (spec: category icons): a search field, "Use default" (back to
/// the type's generic icon), then the curated symbols in a grid grouped by theme, each drawn
/// as the category's badge would show it. `onPick(nil)` clears the icon.
struct CategoryIconPicker: View {
    let type: CategoryType
    /// The category's chosen icon (nil = the type's default).
    let current: String?
    let onPick: (String?) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.theme) private var theme

    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8)

    var body: some View {
        let themes = CategorySymbolAvailability.availableThemes(CategoryIcons.search(query))
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search icons", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Button { onPick(nil) } label: {
                        HStack(spacing: 8) {
                            CategoryBadge(type: type, size: .medium, systemImage: type.symbolName)
                            Text("Use default")
                            Spacer()
                            if current == nil {
                                Image(systemName: "checkmark").foregroundStyle(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show the generic \(type.rawValue) icon")
                    if themes.isEmpty {
                        Text("No matching icons").foregroundStyle(.secondary)
                    }
                    ForEach(themes) { theme in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(theme.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                                ForEach(theme.icons) { icon in
                                    iconButton(icon)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 330, height: 400)
        .onAppear { searchFocused = true }
    }

    private func iconButton(_ icon: CategoryIcon) -> some View {
        let isCurrent = icon.symbol == current
        return Button { onPick(icon.symbol) } label: {
            CategoryBadge(type: type, size: .large, systemImage: icon.symbol)
                .padding(2)
                .overlay(
                    Circle().strokeBorder(theme.accent, lineWidth: isCurrent ? 2 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon.keywords.capitalizedFirst)
        .accessibilityLabel(icon.keywords)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
