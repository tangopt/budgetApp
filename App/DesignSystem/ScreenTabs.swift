// App/DesignSystem/ScreenTabs.swift
import SwiftUI

/// A screen's sections as a segmented control that never forces the window wider (spec C6):
/// every section when they fit; otherwise the first ones that fit and a "More" menu with the
/// rest, which shows the chosen section's name while it's one of them.
///
/// Each form (all sections, all but one, …) is measured once, hidden, and the one that fits
/// is the only one shown and laid out: unlike `ViewThatFits`, the page's layout passes (the
/// window's minimum size is worked out again after every change) don't measure every form's
/// controls again. Equal when it shows the same sections with the same one chosen
/// (`.equatable()`), so a page redrawing for something else leaves it be.
struct ScreenTabs<Tab: Hashable>: View, Equatable {
    let title: String
    @Binding var selection: Tab
    let tabs: [Tab]
    let label: (Tab) -> String
    /// Each form's size, by how many sections it shows.
    @State private var sizes: [Int: CGSize] = [:]
    /// How many sections show (nil: all, until the forms are measured).
    @State private var shown: Int?

    init(_ title: String, selection: Binding<Tab>, tabs: [Tab], label: @escaping (Tab) -> String) {
        self.title = title
        self._selection = selection
        self.tabs = tabs
        self.label = label
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.selection == rhs.selection && lhs.tabs == rhs.tabs && lhs.tabs.map(lhs.label) == rhs.tabs.map(rhs.label)
    }

    /// The forms, widest first: every section, then one fewer, down to two.
    private var forms: [Int] {
        Array(stride(from: tabs.count, through: min(2, tabs.count), by: -1))
    }

    var body: some View {
        let forms = forms
        ScreenTabsLayout(sizes: forms.map { sizes[$0] }) {
            strip(shown: shown ?? tabs.count)
        }
        // The layout took the first form that fits: show that one.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard forms.allSatisfy({ sizes[$0] != nil }) else { return }
            let fitting = forms.first { sizes[$0]!.width <= width + 0.5 } ?? forms.last
            if fitting != shown { shown = fitting }
        }
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(forms, id: \.self) { form in
                    strip(shown: form)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                            if sizes[form] != size { sizes[form] = size }
                        }
                }
            }
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .wrapProbeIgnored()
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

/// The tabs' bar: as wide as the first of its forms (`sizes`, widest first) that fits the width
/// proposed, the narrowest when none does, without measuring the bar shown (until the forms
/// are measured: then the bar's own size). No alignment guides of its own: a stack aligns it by
/// its frame, without asking its controls.
private struct ScreenTabsLayout: Layout {
    let sizes: [CGSize?]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let known = sizes.compactMap { $0 }
        guard known.count == sizes.count, let narrowest = known.last else { return subviews.first?.sizeThatFits(.unspecified) ?? .zero }
        let width = proposal.width ?? .infinity
        return known.first { $0.width <= width + 0.5 } ?? narrowest
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
