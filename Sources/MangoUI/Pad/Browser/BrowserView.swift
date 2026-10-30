import SwiftUI
import BudgetCore

/// The iPad's built-in browser (step 10, Task 5), as agreed in the mockup: the saved sites' strip with "Add site" on
/// top, the open site in the middle (back, forward, its host read-only, "Open in Safari", "Close site"), and the
/// Downloads tray on the right. Sign-in is typed or pasted on the site. "Open in Safari" is the way out for a site
/// that needs Safari: a PDF shared back from there (More… ▸ Mango) lands in the same tray.
///
/// Check (the magnifier) opens the check-and-link sheet (`CheckAndLinkSheet`) once the app has given the model its
/// `checkSource`; before that it previews the file (or calls `onCheck`).
public struct BrowserView: View {
    @Bindable var model: BrowserModel
    /// False in the snapshot routes: a still placeholder where the web view goes (a web view draws nothing there).
    var showsWebView = true
    var onCheck: ((TrayItem) -> Void)?
    let onDone: () -> Void
    @State private var addingSite = false
    @State private var showsTray = true
    @State private var previewing: TrayItem?
    @State private var checking: TrayItem?
    @Environment(\.openURL) private var openURL
    @Environment(\.phoneTheme) private var theme

    /// The tray's width beside the site.
    static let trayWidth: CGFloat = 320

    public init(model: BrowserModel, showsWebView: Bool = true, onCheck: ((TrayItem) -> Void)? = nil, onDone: @escaping () -> Void) {
        self.model = model
        self.showsWebView = showsWebView
        self.onCheck = onCheck
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            SavedSitesStrip(sites: model.sites, currentId: model.currentSite?.id, canEdit: model.canEditSites, onOpen: { model.load($0) },
                            onRemove: { site in Task { await model.removeSite(id: site.id) } }, onAdd: { addingSite = true })
            Divider()
            if let notice = model.notice {
                InlineBanner(tone: .amber, text: notice)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .onTapGesture { model.notice = nil }
            }
            HStack(spacing: 0) {
                siteArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsTray {
                    Divider()
                    TrayListView(items: model.downloadedItems, onCheck: check,
                                 onDiscard: { item in Task { await model.discard(item) } }, canCheck: model.canCheck)
                        .frame(width: Self.trayWidth)
                }
            }
        }
        .background(theme.background)
        .task { await model.reload() }
        .sheet(isPresented: $addingSite) {
            AddSiteSheet { name, address, kind in
                let site = try await model.addSite(name: name, address: address, kind: kind)
                model.load(site)
            }
        }
        .sheet(item: $checking) { item in
            if let source = model.checkSource {
                CheckAndLinkHost(item: item, tray: model.tray, source: source, showsLivePreview: showsWebView) {
                    checking = nil
                    Task { await model.refreshTray() }
                }
            }
        }
        #if canImport(UIKit)
        .sheet(item: $previewing) { item in
            NavigationStack {
                PadDocumentPreview(url: model.fileURL(for: item))
                    .mangoNavigationTitle(item.fileName)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { previewing = nil } } }
            }
        }
        #endif
    }

    private func check(_ item: TrayItem) {
        if model.checkSource != nil { checking = item } else if let onCheck { onCheck(item) } else { previewing = item }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Sites & downloads").mangoFont(.title3, weight: .semibold).lineLimit(1)
            Spacer(minLength: 8)
            Button {
                showsTray.toggle()
            } label: {
                Label(TrayListView.title(count: model.downloadedItems.count).figuresUnbroken, systemImage: RowAction.download.systemImage)
            }
            .buttonStyle(.pad(.secondary, size: .small))
            .accessibilityHint(showsTray ? "Hides the tray" : "Shows the tray")
            Button("Done", action: onDone).buttonStyle(.pad(.primary, size: .small))
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder
    private var siteArea: some View {
        if model.currentSite != nil {
            VStack(spacing: 0) {
                siteBar
                Divider()
                webContent
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: RowAction.openSite.systemImage).mangoFont(.largeTitle).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(model.sites.isEmpty ? "Add the sites you fetch bills and statements from." : "Choose a site above.")
                    .mangoFont(.headline).multilineTextAlignment(.center)
                Text("Sign in on the site by typing or pasting; Mango never keeps your password. Every PDF you download lands in Downloads.")
                    .mangoFont(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if model.sites.isEmpty, model.canEditSites {
                    Button("Add site") { addingSite = true }.buttonStyle(.pad(.primary))
                }
            }
            .frame(maxWidth: 420).padding(24)
        }
    }

    private var siteBar: some View {
        HStack(spacing: 4) {
            iconButton("chevron.backward", label: "Back", enabled: model.canGoBack) { model.goBack() }
            iconButton("chevron.forward", label: "Forward", enabled: model.canGoForward) { model.goForward() }
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").mangoFont(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(model.currentHost ?? "").mangoFont(.subheadline).lineLimit(1).truncationMode(.middle)
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).frame(minHeight: 36)
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Address, \(model.currentHost ?? "")")
            // Labelled where they fit; icons (with their labels for VoiceOver) in a narrow bar or at larger text.
            ViewThatFits(in: .horizontal) {
                siteActions(iconOnly: false)
                siteActions(iconOnly: true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func siteActions(iconOnly: Bool) -> some View {
        HStack(spacing: 4) {
            if let url = model.currentURL {
                Button { openURL(url) } label: { Label("Open in Safari", systemImage: "safari") }
                    .buttonStyle(.pad(.secondary, size: .small))
                    .help("Open in Safari")
            }
            Button { model.closeSite() } label: { Label("Close site", systemImage: "xmark") }
                .buttonStyle(.pad(.textLink, size: .small))
                .help("Close site")
        }
        .labelStyle(iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleOnly))
        .fixedSize()
    }

    @ViewBuilder
    private var webContent: some View {
        #if canImport(UIKit)
        if showsWebView {
            BrowserWebView(model: model)
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    /// Where the page draws, in the snapshot routes.
    private var placeholder: some View {
        Rectangle().fill(Color.secondary.opacity(0.06))
            .overlay {
                Text(model.currentSite?.name ?? "").mangoFont(.title3).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .padding()
            }
    }

    private func iconButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).mangoFont(.body, weight: .semibold)
                .frame(width: PadButtonSize.small.minimumTapTarget, height: PadButtonSize.small.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

/// Either of two label styles, picked at run time.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
