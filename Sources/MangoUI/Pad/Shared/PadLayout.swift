import SwiftUI

/// The iPad's layout system (the 2026-10-28 design pass): the shared spacing scale and radii (`MangoSpacing`,
/// `MangoRadius`), one page scaffold (`padPage`: the same large title, subtitle and trailing actions at the same inset
/// from the sidebar on every screen), one content frame (`padPageContent`), equal-height tile rows (`PadTileGrid`,
/// `PadTile`), and one section header (`PadSectionHeader`).
/// Every iPad screen uses these instead of its own paddings, so titles and content line up from page to page.
enum PadMetrics {
    /// The leading and trailing inset of every page's title and content: the same distance from the sidebar on every
    /// screen. Narrow pages (a document panel open beside them) use `compactPageInset`.
    static let pageInset: CGFloat = 32
    static let compactPageInset: CGFloat = 20
    /// Below this page width (iPad multitasking) the compact inset is used.
    static let compactWidth: CGFloat = 500
    /// The widest a page's content (and title row) grows: the whole detail column (round 2: a cap left an empty band
    /// on the right). A block of running text caps itself.
    static let contentMaxWidth: CGFloat = .infinity

    static func inset(forWidth width: CGFloat) -> CGFloat { width < compactWidth ? compactPageInset : pageInset }
}

// MARK: Page scaffold

private struct PadPageInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = PadMetrics.pageInset
}

extension EnvironmentValues {
    /// The current page's leading and trailing inset (`PadMetrics.inset(forWidth:)`), set by `padPage`.
    var padPageInset: CGFloat {
        get { self[PadPageInsetKey.self] }
        set { self[PadPageInsetKey.self] = newValue }
    }
}

/// Hands its content the current page inset, for a screen that lays out its own margins (a `List`'s).
struct PadPageInsetReading<Content: View>: View {
    @Environment(\.padPageInset) private var inset
    let content: (CGFloat) -> Content

    init(@ViewBuilder content: @escaping (CGFloat) -> Content) { self.content = content }

    var body: some View { content(inset) }
}

private struct PadPageScaffold<Trailing: View>: ViewModifier {
    let title: String
    let subtitle: String?
    let contexts: [ContextPicker]
    let primary: PageAction?
    let keepsSearchBar: Bool
    let trailing: Trailing
    /// The iPhone: the gutter is fixed, not read from the width.
    let isPhone: Bool

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                PageHeader(title: title, subtitle: subtitle, contexts: contexts, primary: primary,
                           topPadding: isPhone ? MangoSpacing.xs : MangoSpacing.l) { trailing }
            }
            .navigationTitle(title)
            #if os(iOS)
            .modifier(PadNavigationBar(keepsSearchBar: keepsSearchBar))
            #endif
            .modifier(PadPageInsetReader(fixed: isPhone ? MangoSpacing.phoneGutter : nil))
    }
}

#if os(iOS)
private struct PadNavigationBar: ViewModifier {
    let keepsSearchBar: Bool

    func body(content: Content) -> some View {
        if keepsSearchBar {
            content.toolbar(removing: .title).toolbarTitleDisplayMode(.inline)
        } else {
            content.toolbar(.hidden, for: .navigationBar)
        }
    }
}
#endif

/// Reads the page's width and sets `padPageInset` for the header and content under it.
private struct PadPageInsetReader: ViewModifier {
    /// A fixed inset (the iPhone's gutter) instead of the one read from the width.
    var fixed: CGFloat?
    @State private var width: CGFloat = 1000

    func body(content: Content) -> some View {
        content
            .environment(\.padPageInset, fixed ?? PadMetrics.inset(forWidth: width))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

extension View {
    /// The iPad page scaffold, applied to a screen's root inside its `NavigationStack`: `PadPageHeader` sits above the
    /// content, so every page's title has the same size, position and inset from the sidebar. The system navigation
    /// bar is hidden on this screen (a pushed screen keeps its own), unless `keepsSearchBar`: a screen with a system
    /// search field keeps the bar for it, without its title. The title stays the screen's navigation title for
    /// VoiceOver and the app switcher.
    func padPage<Actions: View>(_ title: String, subtitle: String? = nil, contexts: [ContextPicker] = [],
                                primary: PageAction? = nil, keepsSearchBar: Bool = false, isPhone: Bool = false,
                                @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        modifier(PadPageScaffold(title: title, subtitle: subtitle, contexts: contexts, primary: primary,
                                 keepsSearchBar: keepsSearchBar, trailing: actions(), isPhone: isPhone))
    }

    /// A page's content frame: the page inset on both sides, the standard top and bottom space, at most
    /// `PadMetrics.contentMaxWidth` wide and leading-aligned under the title.
    func padPageContent() -> some View {
        modifier(PadPageContent())
    }
}

extension View {
    /// A side column's content (Calendar's and Checks' detail card beside the page): the same top as the page content.
    func padSidePanelContent() -> some View {
        padding(.horizontal, MangoSpacing.l).padding(.top, MangoSpacing.xs).padding(.bottom, MangoSpacing.xl)
    }
}

private struct PadPageContent: ViewModifier {
    @Environment(\.padPageInset) private var inset

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: PadMetrics.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.top, MangoSpacing.xs)
            .padding(.bottom, MangoSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Search field

/// A page's search field, for the title row's trailing edge (where the system bar's search field would sit), so the
/// page keeps the same title position as every other.
struct PadSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: MangoSpacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(minWidth: 32, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .mangoFont(.body)
        .padding(.horizontal, MangoSpacing.s)
        .frame(minHeight: 44)
        .frame(minWidth: 200, idealWidth: 300, maxWidth: 300)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

// MARK: Section header

/// A section's header on an iPad page: one size (title 3, semibold), an optional trailing accessory (a count, a button).
struct PadSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: MangoSpacing.xs) {
            Text(title).mangoFont(.title3, weight: .semibold).lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: MangoSpacing.xs)
            accessory
        }
    }
}

// MARK: Cards and tiles

extension View {
    /// On a `PadTileGrid` of `Card`s: each card fills its row's height, so a row's cards end level.
    func padEqualHeightCards() -> some View {
        environment(\.cardFillsHeight, true)
    }

    /// The iPad card surface: the standard padding, filling its width (and, in a `PadTileGrid` row, the row's height),
    /// on the theme's surface with the standard corner radius.
    func padCardSurface(padding: CGFloat = MangoSpacing.cardPadding) -> some View {
        modifier(PadCardSurface(padding: padding))
    }
}

private struct PadCardSurface: ViewModifier {
    let padding: CGFloat
    @Environment(\.phoneTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mangoSurface()
    }
}

/// The iPad's figure tile is the shared `Tile`.
typealias PadTile<Value: View, Caption: View> = Tile<Value, Caption>

/// `PadTileGrid` with its minimum column width scaled with Dynamic Type, so larger text gets fewer, wider columns
/// rather than truncated names and dates. What the iPad screens use.
struct PadGrid<Content: View>: View {
    @ScaledMetric private var minimumColumnWidth: CGFloat
    let maximumColumns: Int
    let balanced: Bool
    let content: Content

    init(minimumColumnWidth: CGFloat, maximumColumns: Int = .max, balanced: Bool = true, @ViewBuilder content: () -> Content) {
        _minimumColumnWidth = ScaledMetric(wrappedValue: minimumColumnWidth, relativeTo: .body)
        self.maximumColumns = maximumColumns
        self.balanced = balanced
        self.content = content()
    }

    var body: some View {
        PadTileGrid(minimumColumnWidth: minimumColumnWidth, maximumColumns: maximumColumns, balanced: balanced) { content }
    }
}

/// Tiles (or cards) in rows of equal-width columns, as many as fit at `minimumColumnWidth` (at most `maximumColumns`),
/// where every item of a row is offered the row's tallest height: a row's tiles always end level.
struct PadTileGrid: Layout {
    var minimumColumnWidth: CGFloat = 190
    var maximumColumns: Int = .max
    var spacing: CGFloat = MangoSpacing.tile
    /// Evens the rows out (`columns(for:count:)`); off for long lists, where the last row may be short.
    var balanced = true

    struct Cache {
        var width: CGFloat = -1
        var columns = 1
        var columnWidth: CGFloat = 0
        var rowHeights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    /// As many columns as fit, then balanced: the fewest columns that still need no more rows, so six tiles that fit
    /// five to a row go three and three rather than five and an orphan.
    func columns(for width: CGFloat, count: Int) -> Int {
        // An unbounded or NaN width (a flex frame measuring its child's maximum) fits every tile in one row.
        guard width.isFinite else { return max(1, min(maximumColumns, max(count, 1))) }
        let fitting = Int(((width + spacing) / (minimumColumnWidth + spacing)).rounded(.down))
        let columns = max(1, min(fitting, maximumColumns, max(count, 1)))
        guard balanced, count > 0 else { return columns }
        let rows = (count + columns - 1) / columns
        return (count + rows - 1) / rows
    }

    private func measure(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width else { return }
        let columns = columns(for: width, count: subviews.count)
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var heights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            let row = subviews[index..<min(index + columns, subviews.count)]
            heights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0)
            index += columns
        }
        cache = Cache(width: width, columns: columns, columnWidth: columnWidth, rowHeights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // No width, or an unbounded one (`.infinity`, asked by a flex frame to find its maximum), measures at the ideal width:
        // the tiles side by side at their minimum column width. (`Int(.infinity)` in `columns(for:count:)` crashed Checks.)
        var width = proposal.width ?? (minimumColumnWidth * CGFloat(min(subviews.count, 2)) + spacing)
        if !width.isFinite {
            let ideal = max(1, min(maximumColumns, max(subviews.count, 1)))
            width = minimumColumnWidth * CGFloat(ideal) + spacing * CGFloat(ideal - 1)
        }
        measure(width: width, subviews: subviews, cache: &cache)
        let height = cache.rowHeights.reduce(0, +) + spacing * CGFloat(max(cache.rowHeights.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (row, height) in cache.rowHeights.enumerated() {
            for column in 0..<cache.columns {
                let index = row * cache.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (cache.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: cache.columnWidth, height: height))
            }
            y += height + spacing
        }
    }
}

// MARK: Shared screens on the iPad

private struct UsesPadPageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True under the iPad's sidebar (`PadRootView`): the screens shared with the iPhone (Home, Month, Search) then
    /// use the iPad page scaffold instead of the iPhone's navigation bar title.
    public var usesPadPage: Bool {
        get { self[UsesPadPageKey.self] }
        set { self[UsesPadPageKey.self] = newValue }
    }
}

extension View {
    /// A screen shared with the iPhone: `PageHeader` (the display-face title, context pickers, the primary action and `actions` at
    /// the trailing edge) on both devices; the iPad's sidebar screens use the page inset, the iPhone the 16 pt gutter.
    func phonePageTitle<Actions: View>(_ title: String, subtitle: String? = nil, contexts: [ContextPicker] = [],
                                       primary: PageAction? = nil, keepsSearchBar: Bool = false,
                                       keepsNavigationBar: Bool = false,
                                       @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        modifier(PhonePageTitle(title: title, subtitle: subtitle, contexts: contexts, primary: primary,
                                keepsSearchBar: keepsSearchBar, keepsNavigationBar: keepsNavigationBar, actions: actions()))
    }

    /// The content frame of a screen shared with the iPhone: the iPhone's 16 pt padding, the iPad page frame under the
    /// iPad's sidebar.
    func phonePageContent() -> some View {
        modifier(PhonePageContent())
    }
}

/// The page title of a screen shared by the iPhone and iPad: `PageHeader` on both (the iPad at its page inset, the
/// iPhone at the 16 pt gutter), so the title is in the set's display face.
private struct PhonePageTitle<Actions: View>: ViewModifier {
    let title: String
    let subtitle: String?
    let contexts: [ContextPicker]
    let primary: PageAction?
    let keepsSearchBar: Bool
    /// A sheet's or pushed screen's: the iPhone keeps the system bar (Done, back) with an inline title in the display face.
    let keepsNavigationBar: Bool
    let actions: Actions
    @Environment(\.usesPadPage) private var usesPadPage

    @ViewBuilder
    func body(content: Content) -> some View {
        if keepsNavigationBar, !usesPadPage {
            content.mangoNavigationTitle(title)
        } else {
            page(content)
        }
    }

    private func page(_ content: Content) -> some View {
        content.padPage(title, subtitle: subtitle, contexts: contexts, primary: primary, keepsSearchBar: keepsSearchBar,
                        isPhone: !usesPadPage) { actions }
    }
}

private struct PhonePageContent: ViewModifier {
    @Environment(\.usesPadPage) private var usesPadPage

    func body(content: Content) -> some View {
        if usesPadPage {
            content.padPageContent()
        } else {
            content.padding(16)
        }
    }
}
