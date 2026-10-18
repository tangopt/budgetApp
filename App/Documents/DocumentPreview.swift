// App/Documents/DocumentPreview.swift
import SwiftUI
import PDFKit
import QuickLook
import UniformTypeIdentifiers
import AppKit

/// A library file's first page at a glance (the inspector's top panel): a PDF's page 1 or an
/// image, scaled to fit `height`, or the file's icon for anything else (spreadsheets,
/// archives). Click it for Quick Look. Loaded off the main thread when shown, so only the
/// selected document is ever read.
struct DocumentThumbnail: View {
    let url: URL
    var height: CGFloat = 220

    private enum Content {
        case page(NSImage, pageCount: Int)
        case image(NSImage)
        case icon(NSImage)
        case missing
    }

    @State private var content: Content?
    @State private var loadedURL: URL?
    @State private var quickLook: URL?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                switch content {
                case let .page(image, _), let .image(image):
                    Button { quickLook = url } label: {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .background(Color.white)
                            .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look")
                    .accessibilityLabel("Preview: Quick Look")
                case let .icon(icon):
                    Button { quickLook = url } label: {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 64, height: 64)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look")
                    .accessibilityLabel("Quick Look")
                case .missing:
                    ContentUnavailableView("File missing", systemImage: "doc.questionmark",
                                           description: Text("The library's copy of this document isn't there."))
                case nil:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: height)
            .frame(height: height)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .quickLookPreview($quickLook)
        .task(id: url) {
            guard loadedURL != url else { return }
            content = nil
            let url = url
            let height = height
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(url, height: height) }.value
            guard !Task.isCancelled else { return }
            content = loaded.content
            loadedURL = url
        }
    }

    private var caption: String? {
        switch content {
        case let .page(_, pageCount): return pageCount == 1 ? "1 page · Click for Quick Look" : "Page 1 of \(pageCount) · Click for Quick Look"
        case .image: return "Click for Quick Look"
        case .icon: return "No preview for this kind of file · Click for Quick Look"
        case .missing, nil: return nil
        }
    }

    /// `Content` isn't Sendable (AppKit objects); it's created here and only read on the main
    /// actor afterwards.
    private struct Loaded: @unchecked Sendable {
        let content: Content
    }

    nonisolated private static func load(_ url: URL, height: CGFloat) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded(content: .missing) }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let document = PDFDocument(url: url), let page = document.page(at: 0) {
            // Drawn at twice the shown height, so it stays sharp on a Retina screen.
            let bounds = page.bounds(for: .mediaBox)
            let scale = 2 * height / max(bounds.height, 1)
            let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            return Loaded(content: .page(image, pageCount: document.pageCount))
        }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image), let image = NSImage(contentsOf: url) {
            return Loaded(content: .image(image))
        }
        return Loaded(content: .icon(NSWorkspace.shared.icon(forFile: url.path)))
    }
}
