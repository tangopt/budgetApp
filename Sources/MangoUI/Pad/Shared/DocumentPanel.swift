import SwiftUI
import BudgetCore
#if canImport(UIKit)
import PDFKit
import QuickLookThumbnailing
#endif

/// One document, wherever it appears on the iPad (step 10, Task 2): a 380 pt panel on the right with the title and a
/// close button, the document's thumbnail, "Open full view" and "Download/Share", its details (Kind, From, Period,
/// Amount, Date, Linked to), then the screen's own block (`extra`: Documents' edits, Missing evidence's "Link"). It
/// finds its database and file hook in `\.documentPanelSource`. Nothing here edits anything; `extra`'s buttons do.
public struct DocumentPanel<Extra: View>: View {
    let documentId: Int64
    let onClose: () -> Void
    let extra: Extra
    @Environment(\.documentPanelSource) private var source
    @Environment(\.phoneTheme) private var theme
    @State private var model: DocumentPanelModel?
    @State private var showsFullView = false

    public init(documentId: Int64, onClose: @escaping () -> Void, @ViewBuilder extra: () -> Extra) {
        self.documentId = documentId
        self.onClose = onClose
        self.extra = extra()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let model {
                        DocumentThumbnailView(file: model.file, onOpen: { showsFullView = true }, onRetry: { Task { await model.retry() } })
                        buttons(model)
                        if let details = model.details { DocumentDetailsCard(details: details) }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    }
                    extra
                }
                .padding(16)
            }
        }
        .frame(width: DocumentPanelLayout.width)
        .background(theme.background)
        .onAppear {
            guard model == nil else { return }
            let loaded = DocumentPanelModel(documentId: documentId, source: source)
            if loaded.loadNow() { model = loaded }
        }
        .task(id: documentId) {
            if model?.documentId == documentId, model?.file.isReady == true { return }
            let loaded = DocumentPanelModel(documentId: documentId, source: source)
            model = loaded
            await loaded.load()
        }
        .documentFullViewCover(isPresented: $showsFullView, documentId: documentId)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model?.title ?? "")
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 16).padding(.trailing, 4)
        .padding(.vertical, 4)
    }

    private func buttons(_ model: DocumentPanelModel) -> some View {
        VStack(spacing: 8) {
            Button { showsFullView = true } label: {
                Label("Open full view", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!model.file.isReady)
            if case .ready(let url) = model.file {
                ShareLink(item: url) {
                    Label("Download/Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {} label: {
                    Label("Download/Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(true)
            }
        }
        .controlSize(.large)
    }
}

extension DocumentPanel where Extra == EmptyView {
    public init(documentId: Int64, onClose: @escaping () -> Void) {
        self.init(documentId: documentId, onClose: onClose) { EmptyView() }
    }
}

extension DocumentPanelModel.File {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// The details rows (Kind, From, Period, Amount, Date, Linked to) in a card, as the panel and the full view's details
/// list them. A figure keeps one line (its row stacks when it doesn't fit beside its label); names truncate in the
/// middle; the linked records may wrap between their figures.
struct DocumentDetailsCard: View {
    let details: DocumentPanelDetails

    var body: some View {
        Card {
            let rows = details.rows
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                DocumentDetailRow(row: row)
            }
        }
    }
}

struct DocumentDetailRow: View {
    let row: DocumentPanelDetails.Row

    var body: some View {
        if row.label == "Linked to" {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.label).foregroundStyle(.secondary)
                ForEach(Array(row.value.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    Text(String(line).figuresUnbroken)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if row.isFigure {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 12)
                    Text(row.value).figureText()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).foregroundStyle(.secondary)
                    Text(row.value).figureText()
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 12)
                Text(row.value).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// The document's first page as a picture, or why it isn't there: "Downloading…", or a failure with Try again. Tapping
/// the picture opens the full view.
struct DocumentThumbnailView: View {
    let file: DocumentPanelModel.File
    let onOpen: () -> Void
    let onRetry: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        switch file {
        case .loading:
            HStack(spacing: 8) { ProgressView(); Text(PadDocumentsModel.downloadingCopy) }
                .frame(maxWidth: .infinity, minHeight: 160)
        case .failed(let copy):
            VStack(alignment: .leading, spacing: 8) {
                InlineBanner(tone: .amber, text: copy)
                Button("Try again", action: onRetry).buttonStyle(.bordered)
            }
        case .ready(let url):
            Button(action: onOpen) {
                thumbnail(url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open full view")
        }
    }

    @ViewBuilder
    private func thumbnail(_ url: URL) -> some View {
        #if canImport(UIKit)
        DocumentThumbnailImage(url: url)
        #else
        Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
        #endif
    }
}

#if canImport(UIKit)
/// The first page of a file: a PDF's own page, any other file Quick Look's.
struct DocumentThumbnailImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityHidden(true)
            } else {
                Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .task(id: url) { image = await Self.render(url) }
    }

    static func render(_ url: URL) async -> UIImage? {
        let size = CGSize(width: 340, height: 240)
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 680, height: 480), for: .mediaBox)
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .all)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }
}
#endif

// MARK: - The host

/// `.documentPanel(selection:)`: puts the panel for the selected document on the right of the screen. When the screen's
/// own content keeps at least 420 pt beside the 380 pt panel the panel stands beside it; otherwise (portrait with the
/// sidebar open) it covers the content's trailing edge, which keeps its width. Closing clears the selection.
struct DocumentPanelHost<PanelExtra: View>: ViewModifier {
    @Binding var selection: Int64?
    let extra: (Int64) -> PanelExtra
    @Environment(\.phoneTheme) private var theme

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let placement = DocumentPanelLayout.placement(containerWidth: geometry.size.width)
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let id = selection, placement == .beside {
                        Divider()
                        panel(id)
                    }
                }
                if let id = selection, placement == .overlay {
                    HStack(spacing: 0) {
                        Divider()
                        panel(id)
                    }
                    .frame(maxHeight: .infinity)
                    .background(theme.background)
                    .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
                    .transition(.move(edge: .trailing))
                }
            }
        }
    }

    private func panel(_ id: Int64) -> some View {
        DocumentPanel(documentId: id, onClose: { selection = nil }) { extra(id) }
            .id(id)
    }
}

extension View {
    /// The document panel for `selection`, with the screen's own block under the details.
    public func documentPanel<PanelExtra: View>(selection: Binding<Int64?>,
                                                @ViewBuilder extra: @escaping (Int64) -> PanelExtra) -> some View {
        modifier(DocumentPanelHost(selection: selection, extra: extra))
    }

    /// The document panel for `selection`.
    public func documentPanel(selection: Binding<Int64?>) -> some View {
        documentPanel(selection: selection) { _ in EmptyView() }
    }

    /// The full-view modal: full screen on the iPad (a sheet on the Mac, where MangoUI builds for tests).
    func documentFullViewCover(isPresented: Binding<Bool>, documentId: Int64) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) { DocumentFullView(documentId: documentId) }
        #else
        sheet(isPresented: isPresented) { DocumentFullView(documentId: documentId) }
        #endif
    }
}
