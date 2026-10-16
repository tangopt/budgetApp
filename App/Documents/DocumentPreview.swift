// App/Documents/DocumentPreview.swift
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import AppKit

/// A library file's preview: a PDF in a scrolling `PDFView`, an image scaled to fit, or the
/// file's icon for anything else (spreadsheets, archives). Loaded off the main thread when
/// shown, so only the selected document is ever read.
struct DocumentPreview: View {
    let url: URL

    private enum Content {
        case pdf(PDFDocument)
        case image(NSImage)
        case other(NSImage)
        case missing
    }

    @State private var content: Content?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            switch content {
            case .pdf(let document):
                PDFKitView(document: document)
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .accessibilityLabel("Image preview")
            case .other(let icon):
                VStack(spacing: 8) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text("No preview for this kind of file. Use Open to view it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .missing:
                ContentUnavailableView("File missing", systemImage: "doc.questionmark",
                                       description: Text("The library's copy of this document isn't there."))
            case nil:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            guard loadedURL != url else { return }
            content = nil
            let url = url
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(url) }.value
            guard !Task.isCancelled else { return }
            content = loaded.content
            loadedURL = url
        }
    }

    /// `Content` isn't Sendable (AppKit and PDFKit objects); it's created here and only read on
    /// the main actor afterwards.
    private struct Loaded: @unchecked Sendable {
        let content: Content
    }

    nonisolated private static func load(_ url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded(content: .missing) }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let document = PDFDocument(url: url) {
            return Loaded(content: .pdf(document))
        }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image), let image = NSImage(contentsOf: url) {
            return Loaded(content: .image(image))
        }
        return Loaded(content: .other(NSWorkspace.shared.icon(forFile: url.path)))
    }
}

/// `PDFView` in SwiftUI: continuous pages, scaled to the width.
private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        view.setAccessibilityLabel("PDF preview")
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
