#if canImport(UIKit)
import SwiftUI
import WebKit
import BudgetCore

/// The open site: a `WKWebView` over the default (persistent) website data store, with `WKDownload` capture into the
/// tray (step 10, Task 5; the delegate code is the spike's, docs/superpowers/plans/2026-10-27-step10-spike-findings.md).
/// No script is injected and nothing is read from the page; navigations follow `BrowserModel.decision`.
struct BrowserWebView: UIViewRepresentable {
    let model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(model.loadRequest, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        private let model: BrowserModel
        private var loaded: UUID?
        private var observations: [NSKeyValueObservation] = []
        /// Each download's temporary folder and the host it came from.
        private var downloads: [ObjectIdentifier: (folder: URL, file: URL?, host: String?)] = [:]

        init(model: BrowserModel) { self.model = model }

        func attach(_ webView: WKWebView) {
            model.goBack = { [weak webView] in webView?.goBack() }
            model.goForward = { [weak webView] in webView?.goForward() }
            observations = [
                webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.model.isLoading = view.isLoading } },
                webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.model.canGoBack = view.canGoBack } },
                webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.model.canGoForward = view.canGoForward } },
                webView.observe(\.url) { [weak self] view, _ in
                    MainActor.assumeIsolated { if let host = view.url?.host { self?.model.currentHost = host } }
                },
            ]
        }

        func detach() {
            observations = []
            model.goBack = {}
            model.goForward = {}
        }

        func load(_ request: BrowserModel.LoadRequest?, in webView: WKWebView) {
            guard let request, request.id != loaded else { return }
            loaded = request.id
            // The model checked it; the policy below checks every navigation again.
            webView.load(URLRequest(url: request.url))
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            switch BrowserModel.decision(for: action.request.url, isMainFrame: action.targetFrame?.isMainFrame ?? true,
                                         shouldPerformDownload: action.shouldPerformDownload) {
            case .allow: return .allow
            case .download: return .download
            case .cancel:
                if action.targetFrame?.isMainFrame ?? true {
                    model.notice = "Mango opens secure (https) pages only, so that page wasn't opened."
                }
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            let http = response.response as? HTTPURLResponse
            switch BrowserModel.responseDecision(mimeType: response.response.mimeType,
                                                 contentDisposition: http?.value(forHTTPHeaderField: "Content-Disposition"),
                                                 isMainFrame: response.isForMainFrame, canShowMIMEType: response.canShowMIMEType) {
            case .download: return .download
            case .allow, .cancel: return .allow
            }
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 102 "Frame load interrupted" is a response that became a download; a cancel is the policy's own.
            let code = (error as NSError).code
            guard code != 102, code != NSURLErrorCancelled else { return }
            model.notice = "The page couldn't be opened. Check the connection and try again."
        }

        // MARK: Downloads

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mango-download-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return nil
            }
            let file = folder.appendingPathComponent(DownloadsTray.displayName(suggestedFilename))
            downloads[ObjectIdentifier(download)] = (folder, file, download.originalRequest?.url?.host ?? model.currentHost)
            return file
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)), let file = entry.file else { return }
            Task {
                await model.handleCapturedDownload(at: file, suggestedName: file.lastPathComponent, host: entry.host)
                try? FileManager.default.removeItem(at: entry.folder)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) {
                try? FileManager.default.removeItem(at: entry.folder)
            }
            model.notice = "The download didn't finish. Try again."
        }
    }
}
#endif
