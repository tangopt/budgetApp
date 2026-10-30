import SwiftUI

/// One icon-button action on a row, from the fixed vocabulary (`RowAction`: globe = open site, paperclip = link
/// document, magnifier = check, ...). A row that doesn't offer an action keeps its slot (invisible, not tappable) so the
/// icons line up in columns down the list.
struct ListRowAction {
    let action: RowAction
    /// The item the action acts on, for VoiceOver ("Link document, Gas bill").
    let item: String?
    let isOffered: Bool
    let perform: () -> Void

    init(_ action: RowAction, item: String? = nil, isOffered: Bool = true, perform: @escaping () -> Void) {
        self.action = action
        self.item = item
        self.isOffered = isOffered
        self.perform = perform
    }
}

/// The numbers and rules behind `ListRow`, kept out of the view so they can be tested.
enum ListRowLayout {
    /// The least height of a row (design review §3.4).
    static let minHeight: CGFloat = 56
    /// The leading glyph disc.
    static let glyphSize: CGFloat = 32
    /// Icon buttons on one row: the most the layout has room for.
    static let maxActions = 2

    /// The actions a row draws: the first `maxActions`, in the order given.
    static func visibleActions(_ actions: [ListRowAction]) -> [ListRowAction] { Array(actions.prefix(maxActions)) }

    /// At accessibility Dynamic Type sizes the figure goes under the text instead of beside it, so the text keeps a
    /// readable width; otherwise it sits trailing at its natural width.
    static func stacksFigure(at size: DynamicTypeSize) -> Bool { AmountRowLayout.stacks(at: size) }

    /// Layout priority of the title block and of the figure: the figure is placed first, at its natural width, so it
    /// never wraps or truncates, and the text gives way (truncating in the middle).
    static let figurePriority: Double = 2
    static let textPriority: Double = 1
    static let titleLineLimit = 1
}

/// A neutral glyph in a 32 pt disc (the row's leading icon slot).
struct RowGlyph: View {
    let systemName: String
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Image(systemName: systemName)
            .mangoFont(.subheadline, weight: .semibold)
            .foregroundStyle(theme.textSecondary)
            .frame(width: ListRowLayout.glyphSize, height: ListRowLayout.glyphSize)
            .background(Circle().fill(theme.surface2))
            .accessibilityHidden(true)
    }
}

/// A list row (design review §3.4): at least 56 pt; an optional leading icon; a title over a secondary line, both
/// truncating in the middle; a trailing status pill, figure and up to two icon buttons. A figure never wraps or
/// truncates (the text gives way). Tapping the row runs `select`; the selected row has one style everywhere
/// (`mangoRowSelection`: accent tint and a 3 pt accent bar).
struct ListRow<Leading: View, Trailing: View>: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let pill: (text: String, status: StatusPill.Status)?
    let actions: [ListRowAction]
    let select: (() -> Void)?
    let leading: Leading
    let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, detail: String? = nil, isSelected: Bool = false, pill: (text: String, status: StatusPill.Status)? = nil,
         actions: [ListRowAction] = [], select: (() -> Void)? = nil,
         @ViewBuilder leading: () -> Leading = { EmptyView() }, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.pill = pill
        self.actions = actions
        self.select = select
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: MangoSpacing.xs) {
            main
            ForEach(Array(ListRowLayout.visibleActions(actions).enumerated()), id: \.offset) { _, row in
                RowIconButton(row.action, item: row.item, size: .small, perform: row.perform)
                    .opacity(row.isOffered ? 1 : 0)
                    .disabled(!row.isOffered)
                    .accessibilityHidden(!row.isOffered)
            }
        }
        .padding(.horizontal, MangoSpacing.xs)
        .frame(minHeight: ListRowLayout.minHeight)
        .mangoRowSelection(isSelected)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var main: some View {
        if let select {
            Button(action: select) { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: MangoSpacing.s) {
            leading
            if ListRowLayout.stacksFigure(at: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: MangoSpacing.xxs) {
                    texts
                    trailingGroup
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                texts.frame(maxWidth: .infinity, alignment: .leading)
                trailingGroup
            }
        }
        .frame(minHeight: ListRowLayout.minHeight)
        .contentShape(Rectangle())
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).mangoFont(.headline)
                .lineLimit(ListRowLayout.titleLineLimit).truncationMode(.middle)
            if let detail, !detail.isEmpty {
                Text(detail.figuresUnbroken).mangoFont(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .layoutPriority(ListRowLayout.textPriority)
    }

    private var trailingGroup: some View {
        HStack(spacing: MangoSpacing.xs) {
            if let pill { StatusPill(pill.text, pill.status) }
            trailing
        }
        .layoutPriority(ListRowLayout.figurePriority)
    }
}

extension ListRow where Leading == RowGlyph {
    /// A row with a glyph disc as its leading icon.
    init(_ title: String, icon: String, detail: String? = nil, isSelected: Bool = false,
         pill: (text: String, status: StatusPill.Status)? = nil, actions: [ListRowAction] = [], select: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.init(title, detail: detail, isSelected: isSelected, pill: pill, actions: actions, select: select,
                  leading: { RowGlyph(systemName: icon) }, trailing: trailing)
    }
}
