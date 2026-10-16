// App/DesignSystem/GroupNameCell.swift
import SwiftUI

/// A group row's name cell (Budget grid and scenario grid): the whole cell, full category-column
/// width by row height, toggles the group, with a subtle fill while the pointer is over it (and
/// a highlight behind the chevron). ⌥-click toggles every group of the section to the clicked
/// group's new state (Finder's convention): `toggle` gets `true` then.
struct GroupNameCell: View {
    let name: String
    let isExpanded: Bool
    let toggle: (_ allInSection: Bool) -> Void
    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            DisclosureChevron(isExpanded: isExpanded, highlighted: hovering)
            Text(name).bold()
        }
        .frame(width: 220, height: 28, alignment: .leading)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(hovering ? 0.06 : 0))
        .background(theme.groupRowTint)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { toggle(NSEvent.modifierFlags.contains(.option)) }
        .accessibilityAction { toggle(false) }
        .help("⌥-click to expand or collapse every group in this section")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// The grids' disclosure chevron (group rows and section headers), with a small rounded
/// highlight while its row is hovered.
struct DisclosureChevron: View {
    let isExpanded: Bool
    let highlighted: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(highlighted ? 0.12 : 0)))
    }
}

/// A section header's name cell (Income, Expenses, …, Accounts, Reserved): the chevron and
/// title toggle the section; `accessory` (e.g. "+ Add planned item") sits on the right, and
/// while the pointer is over the cell two small buttons expand or collapse all the section's
/// groups (only when it has groups and is expanded).
struct SectionHeaderCell<Accessory: View>: View {
    let title: String
    let isCollapsed: Bool
    let toggle: () -> Void
    /// Expand all (`true`) / Collapse all (`false`) groups; nil when the section has none.
    let setAllGroups: ((Bool) -> Void)?
    @ViewBuilder let accessory: () -> Accessory
    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                DisclosureChevron(isExpanded: !isCollapsed, highlighted: hovering)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption).bold()
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityAction { toggle() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            accessory()
            if let setAllGroups, !isCollapsed {
                HStack(spacing: 2) {
                    groupsButton("rectangle.expand.vertical", label: "Expand all groups") { setAllGroups(true) }
                    groupsButton("rectangle.compress.vertical", label: "Collapse all groups") { setAllGroups(false) }
                }
                // Kept in the layout (just invisible) so the accessory doesn't shift on hover.
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
        }
        .frame(width: 220, height: 24, alignment: .leading)
        .padding(.horizontal, 8)
        .background(theme.sectionHeaderTint)
        .onHover { hovering = $0 }
    }

    private func groupsButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption2)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
