// App/DesignSystem/ScreenTabs.swift
import SwiftUI

/// A screen's sections as a segmented control that never forces the window wider (spec C6):
/// every section when they fit; otherwise the first ones that fit and a "More" menu with the
/// rest, which shows the chosen section's name while it's one of them.
struct ScreenTabs<Tab: Hashable>: View {
    let title: String
    @Binding var selection: Tab
    let tabs: [Tab]
    let label: (Tab) -> String

    init(_ title: String, selection: Binding<Tab>, tabs: [Tab], label: @escaping (Tab) -> String) {
        self.title = title
        self._selection = selection
        self.tabs = tabs
        self.label = label
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: tabs.count, through: min(2, tabs.count), by: -1)), id: \.self) { shown in
                strip(shown: shown)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func strip(shown: Int) -> some View {
        let visible = Array(tabs.prefix(shown))
        let overflow = Array(tabs.dropFirst(shown))
        HStack(spacing: 6) {
            Picker(title, selection: $selection) {
                ForEach(visible, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented).prominentTint()
            .labelsHidden()
            .fixedSize()
            if !overflow.isEmpty {
                let chosen = overflow.contains(selection)
                Menu {
                    ForEach(overflow, id: \.self) { tab in
                        Button(label(tab)) { selection = tab }
                    }
                } label: {
                    // As wide as its widest title, so picking a section from it doesn't
                    // reshuffle the bar.
                    ZStack(alignment: .center) {
                        ForEach(["More"] + overflow.map(label), id: \.self) { title in
                            FilterChipLabel(title: title, isActive: false).hidden()
                        }
                        FilterChipLabel(title: chosen ? label(selection) : "More", isActive: chosen)
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(chosen ? label(selection) : "More sections")
            }
        }
        .fixedSize()
    }
}
