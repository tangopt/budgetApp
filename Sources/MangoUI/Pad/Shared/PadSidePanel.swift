import SwiftUI

/// The width rules of the iPad's one side panel (2026-10-28 round 2): resizable between a minimum and a maximum, the
/// width remembered on this device, and placed beside the page, over its trailing edge, or (in a narrow window) as a
/// sheet.
public enum PadSidePanelLayout {
    public static let minimumWidth: CGFloat = 320
    public static let maximumWidth: CGFloat = 720
    public static let standardWidth: CGFloat = 400
    /// What the page keeps beside an open panel.
    public static let minimumContentWidth: CGFloat = 420
    /// Below this container width the panel is a sheet.
    public static let sheetBelowWidth: CGFloat = 560
    public static let defaultsKey = "padSidePanelWidth"

    public enum Placement: Equatable, Sendable { case beside, overlay, sheet }

    /// `width` held between the minimum and the maximum, and no wider than leaves the page its minimum when it can.
    public static func clamp(_ width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let room = containerWidth - minimumContentWidth
        let upper = max(minimumWidth, min(maximumWidth, room))
        return min(max(width, minimumWidth), upper)
    }

    public static func placement(containerWidth: CGFloat, panelWidth: CGFloat) -> Placement {
        if containerWidth < sheetBelowWidth { return .sheet }
        return containerWidth - clamp(panelWidth, containerWidth: containerWidth) >= minimumContentWidth ? .beside : .overlay
    }

    /// The remembered width (this device's), `standardWidth` before the first drag.
    public static func storedWidth(_ defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.double(forKey: defaultsKey)
        guard stored > 0 else { return standardWidth }
        return min(max(CGFloat(stored), minimumWidth), maximumWidth)
    }

    public static func store(_ width: CGFloat, _ defaults: UserDefaults = .standard) {
        defaults.set(Double(min(max(width, minimumWidth), maximumWidth)), forKey: defaultsKey)
    }
}

/// The panel's one shape: a header (title, subtitle, action icons, close) over scrolling content, at one padding. The
/// host (`padSidePanel`) gives it its width.
struct PadSidePanel<Actions: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let onClose: () -> Void
    let actions: Actions
    let content: Content
    @Environment(\.phoneTheme) private var theme

    init(title: String, subtitle: String? = nil, onClose: @escaping () -> Void,
         @ViewBuilder actions: () -> Actions = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.m) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MangoSpacing.m)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: MangoSpacing.xxs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).mangoFont(.headline).lineLimit(2).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle.figuresUnbroken).mangoFont(.footnote).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
            PadIconButton(systemImage: "xmark", label: "Close", action: onClose)
        }
        .padding(.leading, MangoSpacing.m).padding(.trailing, MangoSpacing.xxs)
        .padding(.vertical, MangoSpacing.xxs)
    }
}

/// A flat icon button of 44 pt, in the accent (or red when destructive): what panels, sheets and forms use in place of
/// a bordered text button where the icon is clear (Save = checkmark, Cancel/Close = xmark, delete = trash).
struct PadIconButton: View {
    let systemImage: String
    let label: String
    var destructive = false
    var prominent = false
    let action: () -> Void
    @Environment(\.phoneTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .mangoFont(.body, weight: .semibold)
                .foregroundStyle(destructive ? theme.expense : (prominent ? theme.accent : Color.secondary))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: Host

private struct PadSidePanelHost<Panel: View>: ViewModifier {
    let isPresented: Bool
    let onClose: () -> Void
    let panel: () -> Panel
    @Environment(\.phoneTheme) private var theme
    @State private var width = PadSidePanelLayout.storedWidth()
    @State private var dragStart: CGFloat?

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let container = geometry.size.width
            let placement = PadSidePanelLayout.placement(containerWidth: container, panelWidth: width)
            let shown = PadSidePanelLayout.clamp(width, containerWidth: container)
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if isPresented, placement == .beside {
                        handle(container: container, shown: shown)
                        panel().frame(width: shown)
                    }
                }
                if isPresented, placement == .overlay {
                    HStack(spacing: 0) {
                        handle(container: container, shown: shown)
                        panel().frame(width: shown)
                    }
                    .frame(maxHeight: .infinity)
                    .background(theme.background)
                    .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
                    .transition(.move(edge: .trailing))
                }
            }
            .sheet(isPresented: Binding(get: { isPresented && placement == .sheet }, set: { if !$0 { onClose() } })) {
                panel().presentationDetents([.large])
            }
        }
    }

    /// The panel's leading edge: a hairline with a wide grab area; dragging it left widens the panel.
    private func handle(container: CGFloat, shown: CGFloat) -> some View {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? shown
                    dragStart = start
                    width = PadSidePanelLayout.clamp(start - drag.translation.width, containerWidth: container)
                }
                .onEnded { _ in
                    dragStart = nil
                    PadSidePanelLayout.store(width)
                })
            .accessibilityElement()
            .accessibilityLabel("Panel width")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 40 : -40
                width = PadSidePanelLayout.clamp(shown + step, containerWidth: container)
                PadSidePanelLayout.store(width)
            }
    }
}

extension View {
    /// The iPad's one right side panel for a detail: beside the page when there is room, over its trailing edge when
    /// there is less, a sheet only in a narrow window. Its leading edge drags to resize; the width is remembered.
    /// `panel` builds a `PadSidePanel` (or the shared `DocumentPanel`).
    func padSidePanel<Panel: View>(isPresented: Bool, onClose: @escaping () -> Void,
                                   @ViewBuilder panel: @escaping () -> Panel) -> some View {
        modifier(PadSidePanelHost(isPresented: isPresented, onClose: onClose, panel: panel))
    }
}

extension ToolbarContent {
    /// A sheet toolbar's icon button without the system's glass capsule: flat, like the panels' icons.
    func padFlatToolbarItem() -> some ToolbarContent {
        #if os(iOS)
        return sharedBackgroundVisibility(.hidden)
        #else
        return self
        #endif
    }
}

private struct PadFormChrome: ViewModifier {
    @Environment(\.phoneTheme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .mangoFont(.body)
            .tint(theme.accent)
    }
}

extension View {
    /// An edit sheet's form in the app's font and theme instead of the system Form look.
    func padFormChrome() -> some View { modifier(PadFormChrome()) }
}
