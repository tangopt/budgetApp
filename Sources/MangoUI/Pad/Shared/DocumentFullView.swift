import SwiftUI
import BudgetCore
#if canImport(UIKit)
import PDFKit
#endif

/// A document at full size, as a modal over whatever screen opened it (step 10, Task 2): every page with pinch zoom
/// (a PDF through PDFKit, any other file through Quick Look), a page indicator, zoom buttons, Share/Download, and
/// "Show details", which opens the same details as the panel beside the pages. Done closes it. Nothing is edited here.
public struct DocumentFullView: View {
    let documentId: Int64
    @Environment(\.documentPanelSource) private var source
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var model: DocumentPanelModel?
    @State private var showsDetails: Bool
    #if canImport(UIKit)
    @StateObject private var pdf = DocumentPDFController()
    #endif

    public init(documentId: Int64, showsDetails: Bool = false) {
        self.documentId = documentId
        _showsDetails = State(initialValue: showsDetails)
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let placement = DocumentPanelLayout.placement(containerWidth: geometry.size.width)
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        pages.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showsDetails, placement == .beside { Divider(); details }
                    }
                    if showsDetails, placement == .overlay {
                        HStack(spacing: 0) { Divider(); details }
                            .frame(maxHeight: .infinity)
                            .background(theme.background)
                            .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
                    }
                }
            }
            .background(theme.background)
            .navigationTitle(model?.title ?? "")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(showsDetails ? "Hide details" : "Show details", systemImage: "info.circle") { showsDetails.toggle() }
                    if case .ready(let url) = model?.file {
                        ShareLink(item: url) { Label("Download/Share", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
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
    }

    @ViewBuilder
    private var pages: some View {
        switch model?.file {
        case nil, .loading?:
            HStack(spacing: 8) { ProgressView(); Text(PadDocumentsModel.downloadingCopy) }
        case .failed(let copy)?:
            VStack(alignment: .leading, spacing: 8) {
                InlineBanner(tone: .amber, text: copy)
                Button("Try again") { Task { await model?.retry() } }.buttonStyle(.pad(.secondary))
            }
            .padding(24)
        case .ready(let url)?:
            #if canImport(UIKit)
            if url.pathExtension.lowercased() == "pdf" {
                ZStack(alignment: .bottom) {
                    DocumentPDFView(url: url, controller: pdf).ignoresSafeArea(edges: .bottom)
                    controls
                }
            } else {
                PadDocumentPreview(url: url).ignoresSafeArea(edges: .bottom)
            }
            #else
            Text(url.lastPathComponent).foregroundStyle(.secondary)
            #endif
        }
    }

    #if canImport(UIKit)
    /// "Page 2 of 5" and the zoom buttons, over the pages' foot.
    private var controls: some View {
        HStack(spacing: 12) {
            Text("Page \(pdf.page) of \(pdf.pageCount)").figureText().font(.subheadline)
            Divider().frame(height: 20)
            Button { pdf.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("Zoom out")
            Button { pdf.fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .accessibilityLabel("Fit to width")
            Button { pdf.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("Zoom in")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 16)
    }
    #endif

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let details = model?.details { DocumentDetailsCard(details: details) }
            }
            .padding(16)
        }
        .frame(width: DocumentPanelLayout.width)
    }
}

#if canImport(UIKit)
/// The PDF's page count and current page, and the zoom buttons' actions.
@MainActor
final class DocumentPDFController: ObservableObject {
    @Published var page = 1
    @Published var pageCount = 0
    weak var view: PDFView?

    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func fit() { view?.autoScales = true }

    func refresh() {
        guard let view, let document = view.document else { return }
        pageCount = document.pageCount
        if let current = view.currentPage { page = document.index(for: current) + 1 }
    }
}

/// PDFKit's view: all pages in one scrolling column, pinch zoom, fitted to the width until zoomed.
struct DocumentPDFView: UIViewRepresentable {
    let url: URL
    let controller: DocumentPDFController

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageBreakMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.document = PDFDocument(url: url)
        controller.view = view
        context.coordinator.observe(view, controller: controller)
        controller.refresh()
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            controller.refresh()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: NSObjectProtocol?

        func observe(_ view: PDFView, controller: DocumentPDFController) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { _ in
                MainActor.assumeIsolated { controller.refresh() }
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
#endif
