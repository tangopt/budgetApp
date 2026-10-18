// App/DesignSystem/SearchField.swift
import SwiftUI

/// The screens' search field (the Search screen's, spec C9): a magnifier, a plain field and a
/// clear button on the text background, corner 6, stroked with the separator colour.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    /// Focus to drive from outside (the Search screen's ⌘F).
    var focus: FocusState<Bool>.Binding?

    init(_ prompt: String, text: Binding<String>, focus: FocusState<Bool>.Binding? = nil) {
        self.prompt = prompt
        self._text = text
        self.focus = focus
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            if let focus {
                field.focused(focus)
            } else {
                field
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var field: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .accessibilityLabel(prompt)
    }
}

/// A filter's button (the Search screen's chips): its current value with a chevron, in the
/// accent while the filter is on; opens `content` in a popover.
struct FilterChip<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let isActive: Bool
    @ViewBuilder let content: Content
    @State private var isPresented = false

    init(_ title: String, isActive: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        Button { isPresented = true } label: {
            FilterChipLabel(title: title, isActive: isActive)
        }
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityHint("Opens the filter")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content
                .padding(SheetMetrics.popoverPadding)
                .controlSize(.regular)
        }
    }
}

/// A filter chip that picks one of a few values from a menu ("All kinds", "Rent receipt"…);
/// on (accented) when anything but `allValue` is picked.
struct FilterPickerChip<Value: Hashable>: View {
    let allTitle: String
    let allValue: Value
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// What the chip filters ("Kind"), for VoiceOver: "Kind: All kinds".
    let name: String?

    init(_ allTitle: String, name: String? = nil, all allValue: Value, selection: Binding<Value>, options: [(value: Value, title: String)]) {
        self.allTitle = allTitle
        self.name = name
        self.allValue = allValue
        self._selection = selection
        self.options = options
    }

    private var title: String {
        selection == allValue ? allTitle : (options.first { $0.value == selection }?.title ?? allTitle)
    }

    var body: some View {
        Menu {
            Button(allTitle) { selection = allValue }
            if !options.isEmpty { Divider() }
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.title) { selection = option.value }
            }
        } label: {
            FilterChipLabel(title: title, isActive: selection != allValue)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        // Read as "Kind, All kinds": what it filters, then what it shows.
        .accessibilityLabel(name ?? allTitle)
        .accessibilityValue(title)
    }
}

/// A chip's face: the value and a small chevron.
struct FilterChipLabel: View {
    let title: String
    let isActive: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
        }
        .foregroundStyle(isActive ? theme.accent : Color.primary)
    }
}
