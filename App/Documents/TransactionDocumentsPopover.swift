// App/Documents/TransactionDocumentsPopover.swift
import SwiftUI
import QuickLook
import BudgetCore
import GRDB

/// What a transaction's paperclip opens: its documents (kind, canonical name, day, amount,
/// "Also on N other transactions"), the selected one's first page (or "Not on this Mac yet"),
/// and Quick Look over every one of them that is on this Mac (the button, or the space bar).
/// Quick Look opens the library files themselves, never a copy.
struct TransactionDocumentsList: View {
    let documents: [TransactionDocument]
    let library: EvidenceLibrary?
    /// The documents whose file is on this Mac, read once when the list loaded (off the main thread).
    let onDevice: Set<Int64>
    @State private var selected: Int64?
    @State private var quickLook: URL?
    @FocusState private var listFocused: Bool

    init(documents: [TransactionDocument], library: EvidenceLibrary?, onDevice: Set<Int64>, selected: Int64? = nil) {
        self.documents = documents
        self.library = library
        self.onDevice = onDevice
        _selected = State(initialValue: selected ?? documents.first?.id)
    }

    private func url(_ document: TransactionDocument) -> URL? {
        guard let library, onDevice.contains(document.id) else { return nil }
        return library.fileURL(storedRelativePath: document.storedRelativePath)
    }

    /// Every document of the transaction that is on this Mac, in the list's order.
    private var urls: [URL] { documents.compactMap(url) }

    private var current: TransactionDocument? { documents.first { $0.id == selected } ?? documents.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(documents.count == 1 ? "1 document" : "\(documents.count) documents")
                .font(.headline).figureText()
            List(documents, selection: $selected) { document in
                row(document).tag(document.id)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Quick Look") { selected = document.id; openQuickLook() }
            }
            .frame(height: min(CGFloat(documents.count) * 46 + 8, 190))
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onChange(of: documents) { _, new in
                if !new.contains(where: { $0.id == selected }) { selected = new.first?.id }
            }
            .onKeyPress(.space) {
                openQuickLook()
                return .handled
            }
            if let current {
                preview(current)
            }
            HStack {
                Spacer()
                Button("Quick Look", action: openQuickLook)
                    .disabled(urls.isEmpty)
                    .help("Preview the documents (Space)")
            }
        }
        .padding(12)
        .frame(width: 520)
        .quickLookPreview($quickLook, in: urls)
    }

    private func openQuickLook() {
        guard let current else { return }
        quickLook = url(current) ?? urls.first
    }

    private func row(_ document: TransactionDocument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(document.displayName)
                .lineLimit(1).truncationMode(.middle)
                .help(document.displayName)
            HStack(spacing: 8) {
                StatusPill(document.kindLabel, tone: .neutral)
                DateText(date: document.docDate, font: .caption)
                if let amount = document.amountMinorUnits, let currency = document.currency {
                    MoneyText(minorUnits: amount, currency: currency, font: .caption.monospacedDigit(), role: .neutral).fixedSize()
                }
                if document.otherTransactionCount > 0 {
                    Text(document.otherTransactionCount == 1 ? "Also on 1 other transaction"
                         : "Also on \(document.otherTransactionCount) other transactions")
                        .figureText()
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func preview(_ document: TransactionDocument) -> some View {
        if let url = url(document) {
            DocumentThumbnail(url: url, height: 220, onQuickLook: openQuickLook)
                .frame(maxWidth: .infinity)
        } else {
            Text("Not on this Mac yet")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }
}

/// The popover behind a transaction's paperclip: reads the documents off the main actor when it opens.
struct TransactionDocumentsPopover: View {
    let transactionId: Int64
    @State private var documents: [TransactionDocument]?
    @State private var failure: String?
    @State private var library: EvidenceLibrary?
    @State private var onDevice: Set<Int64> = []

    var body: some View {
        Group {
            if let documents {
                TransactionDocumentsList(documents: documents, library: library, onDevice: onDevice)
            } else if let failure {
                Text(failure).foregroundStyle(.secondary).padding(12).frame(width: 300)
            } else {
                ProgressView().padding(24).frame(width: 300)
            }
        }
        .task(id: transactionId) {
            guard let environment = AppEnvironment.Current.shared.environment else { failure = "No library is open."; return }
            let dbQueue = environment.dbQueue
            library = environment.evidenceLibrary
            let id = transactionId
            let library = environment.evidenceLibrary
            do {
                let (loaded, present) = try await Task.detached(priority: .userInitiated) { () -> ([TransactionDocument], Set<Int64>) in
                    let documents = try dbQueue.read { db in
                        try TransactionDocuments.documents(db: db, transactionId: id, catalog: DocumentKindCatalog.load(db: db))
                    }
                    return (documents, Set(documents.filter { library.isOnThisDevice(storedRelativePath: $0.storedRelativePath) }.map(\.id)))
                }.value
                onDevice = present
                documents = loaded
            } catch {
                failure = "Couldn't read the documents: \(error.localizedDescription)"
            }
        }
    }
}
