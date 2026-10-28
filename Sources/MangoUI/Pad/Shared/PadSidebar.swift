import SwiftUI
import BudgetCore

enum PadSidebarMetrics {
    /// Every row's icon sits in a frame of this width, so the titles start at the same x whatever the symbol.
    static let iconWidth: CGFloat = 28
    static let iconToTitle: CGFloat = 10
}

/// The iPad's own sidebar (step 10, Task 3): the Mango glyph and a collapse button over the sections in their groups,
/// the footer pinned at the bottom. Collapsed it is a narrow rail, one 44 pt icon per section.
struct PadSidebar: View {
    let state: PadSidebarState
    @Binding var selection: PadSection
    let hasProperty: Bool
    let userName: String
    let avatar: Image?
    let sync: SyncSidebarStatus?
    let waitingChanges: Int
    let onToggle: () -> Void
    let onSettings: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: state.isCollapsed ? 4 : 2) {
                    ForEach(Array(PadSection.groups(hasProperty: hasProperty).enumerated()), id: \.offset) { index, group in
                        if let title = group.title, !state.isCollapsed {
                            Text(title.uppercased()).mangoFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                        } else if index > 0 {
                            Divider().padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        ForEach(group.sections, id: \.self) { row($0) }
                    }
                }
                .padding(.horizontal, state.isCollapsed ? 0 : 10).padding(.bottom, 8)
            }
            Divider()
            SidebarFooter(userName: userName, avatar: avatar, sync: sync, waitingChanges: waitingChanges,
                          collapsed: state.isCollapsed, onSettings: onSettings)
        }
        .frame(width: state.width)
        .background(theme.surface.opacity(0.6))
    }

    private var header: some View {
        Group {
            if state.isCollapsed {
                VStack(spacing: 6) {
                    MangoGlyph().frame(width: 36, height: 36)
                    toggle
                }
            } else {
                HStack {
                    MangoGlyph().frame(width: 34, height: 34)
                    Text("Mango").mangoFont(.title3, weight: .semibold)
                    Spacer()
                    toggle
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.top, 12).padding(.bottom, 8)
    }

    private var toggle: some View {
        Button(action: onToggle) {
            Image(systemName: "sidebar.left").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .help(state.isCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    @ViewBuilder
    private func row(_ section: PadSection) -> some View {
        let selected = selection == section
        Button { selection = section } label: {
            if state.isCollapsed {
                Image(systemName: section.systemImage).mangoFont(.title3)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.accent.opacity(0.18) : .clear))
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: PadSidebarMetrics.iconToTitle) {
                    Image(systemName: section.systemImage)
                        .mangoFont(.body)
                        .frame(width: PadSidebarMetrics.iconWidth)
                        .accessibilityHidden(true)
                    Text(section.title).mangoFont(.body).lineLimit(1).truncationMode(.middle)
                }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.accent.opacity(0.18) : .clear))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? theme.accent : Color.primary)
        .contentShape(Rectangle())
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(section.title)
    }
}
