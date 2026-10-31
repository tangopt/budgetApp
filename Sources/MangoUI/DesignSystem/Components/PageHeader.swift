import SwiftUI

/// The page's one primary action (design review §3.4: at most one per page, so the type holds exactly one).
struct PageAction {
    let title: String
    let systemImage: String?
    let perform: () -> Void

    init(_ title: String, systemImage: String? = nil, perform: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }
}

/// What the header may hold, as numbers the tests can check.
enum PageHeaderRules {
    /// Context pickers on the context line: a page is about one thing (a tenancy), and may also be about a period
    /// (Bills: the tenancy and its year). Extras are dropped.
    static let maxContexts = 2

    static func contexts(_ pickers: [ContextPicker]) -> [ContextPicker] { Array(pickers.prefix(maxContexts)) }

    /// Whether the context line is drawn at all.
    static func hasContextLine(contexts: Int, subtitle: String?) -> Bool {
        contexts > 0 || !(subtitle ?? "").isEmpty
    }
}

/// A page's title row on the iPhone and iPad (design review §3.4): the title in the set's display face, a context line
/// under it (the context picker(s), then secondary text), and at the trailing edge up to two icon buttons (`trailing`)
/// and at most one primary action. At the page inset from the edge.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let contexts: [ContextPicker]
    let primary: PageAction?
    let trailing: Trailing
    /// Space above the title: the iPad's 24 pt, less on the iPhone, where the status bar already gives some.
    let topPadding: CGFloat
    @Environment(\.phoneTheme) private var theme
    @Environment(\.padPageInset) private var inset
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(title: String, subtitle: String? = nil, contexts: [ContextPicker] = [], primary: PageAction? = nil,
         topPadding: CGFloat = MangoSpacing.l, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.contexts = PageHeaderRules.contexts(contexts)
        self.primary = primary
        self.trailing = trailing()
        self.topPadding = topPadding
    }

    var body: some View {
        HStack(alignment: .center, spacing: MangoSpacing.s) {
            VStack(alignment: .leading, spacing: MangoSpacing.xxs) {
                Text(title)
                    .mangoFont(.largeTitle, weight: .bold)
                    .lineLimit(1).minimumScaleFactor(0.65).truncationMode(.middle)   // shrinks before it truncates (a narrow column beside a panel)
                    .accessibilityAddTraits(.isHeader)
                if PageHeaderRules.hasContextLine(contexts: contexts.count, subtitle: subtitle) {
                    HStack(spacing: MangoSpacing.xs) {
                        ForEach(contexts.indices, id: \.self) { contexts[$0] }
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle.figuresUnbroken)
                                .mangoFont(.subheadline).foregroundStyle(theme.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: MangoSpacing.s)
            HStack(spacing: MangoSpacing.xs) {
                trailing
                if let primary { primaryButton(primary) }
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, inset)
        .padding(.top, topPadding)
        .padding(.bottom, MangoSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background)
    }

    /// The primary button with its label; icon only when the row is too narrow for it (the label stays its
    /// accessibility name).
    @ViewBuilder
    private func primaryButton(_ primary: PageAction) -> some View {
        if let symbol = primary.systemImage {
            ViewThatFits(in: .horizontal) {
                Button(action: primary.perform) { Label(primary.title, systemImage: symbol) }
                    .buttonStyle(.pad(.primary))
                Button(action: primary.perform) { Image(systemName: symbol) }
                    .buttonStyle(.pad(.primary))
                    .accessibilityLabel(primary.title)
            }
        } else {
            Button(primary.title, action: primary.perform).buttonStyle(.pad(.primary))
        }
    }
}

extension View {
    /// An inline navigation title in the set's display face, for the screens that keep the system navigation bar (a
    /// pushed screen's back button, a sheet's Done): the system title can't take a custom font, so the title is drawn
    /// as the bar's principal item and the system one stays only as the back button's label and VoiceOver's name.
    func mangoNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).mangoFont(.headline).lineLimit(1).truncationMode(.middle).accessibilityAddTraits(.isHeader)
                }
            }
    }
}
