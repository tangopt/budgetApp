// App/Documents/TransactionDocumentsSection.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction
import GRDB

/// A transaction's documents (spec 2026-10-16 §2) while Edit transaction is open: the saved
/// links plus links and unlinks staged until Save (`EvidenceLinkStaging`), which writes them
/// with the transaction (`TransactionEditChanges.documents`). Cancel discards them. A file
/// added here is copied into the library at once (so Save has a document to link) and only
/// staged; after Cancel it stays in the library, unlinked.
@MainActor
final class TransactionDocumentsModel: ObservableObject {
    let transactionId: Int64?
    let library: EvidenceLibrary?
    let dbQueue: DatabaseQueue?
    @Published private(set) var staging = EvidenceLinkStaging(saved: [])
    /// Every document shown (saved and staged), by id.
    @Published private(set) var documentsById: [Int64: EvidenceDocument] = [:]
    @Published private(set) var addingCount = 0
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// Link document…'s data: every document, and the ones that would propose this transaction.
    @Published private(set) var pickerIndex: EvidenceDocumentSearch.Index?
    @Published private(set) var pickerSuggestions: [EvidenceMatcher.DocumentSuggestion] = []
    private var loaded = false

    init(transactionId: Int64?, library: EvidenceLibrary?, dbQueue: DatabaseQueue?) {
        self.transactionId = transactionId
        self.library = library
        self.dbQueue = dbQueue
    }

    /// The model for the main window's library (unavailable before the transaction is saved,
    /// or with no library open).
    static func make(transactionId: Int64?) -> TransactionDocumentsModel {
        let environment = AppEnvironment.Current.shared.environment
        return TransactionDocumentsModel(transactionId: transactionId, library: environment?.evidenceLibrary, dbQueue: environment?.dbQueue)
    }

    var isAvailable: Bool { transactionId != nil && library != nil }

    /// The documents to list: saved ones (those being unlinked included), then staged ones.
    var shown: [EvidenceDocument] { staging.shownIds.compactMap { documentsById[$0] } }

    /// Reads the saved links once (re-appearing keeps what's staged).
    func load() {
        guard !loaded, let library, let transactionId else { return }
        do {
            let documents = try library.documents(for: .transaction(transactionId))
            staging = EvidenceLinkStaging(saved: documents.compactMap(\.id))
            for document in documents { if let id = document.id { documentsById[id] = document } }
            loaded = true
        } catch {
            errorMessage = "Couldn't read the documents: \(error.localizedDescription)"
        }
    }

    func loadPicker() {
        guard let dbQueue, let transactionId else { return }
        let excluded = Set(staging.shownIds.filter(staging.isLinked))
        Task {
            do {
                async let catalog = TransactionCatalog.load(dbQueue)
                let (index, all) = try await Task.detached(priority: .userInitiated) {
                    try dbQueue.read { db in (try EvidenceDocumentSearch.Index(db: db), try EvidenceDocument.fetchAll(db)) }
                }.value
                pickerIndex = index
                let matcherIndex = try await catalog.matcherIndex
                pickerSuggestions = await Task.detached(priority: .userInitiated) {
                    EvidenceMatcher.documentSuggestions(for: transactionId, documents: all, index: matcherIndex, excluding: excluded, limit: 8)
                }.value
            } catch {
                errorMessage = "Couldn't load documents: \(error.localizedDescription)"
            }
        }
    }

    func pickerEntry(_ documentId: Int64) -> EvidenceDocumentSearch.Entry? {
        pickerIndex?.entries.first { $0.id == documentId }
    }

    /// Stages a link (Save writes it).
    func stageLink(_ documentId: Int64) {
        guard let library else { return }
        if documentsById[documentId] == nil {
            do {
                guard let document = try library.document(id: documentId) else { throw EvidenceLibraryError.documentNotFound }
                documentsById[documentId] = document
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        staging.stageLink(documentId)
        errorMessage = nil
    }

    /// Unlink, or Undo of a staged change (Save writes it).
    func toggleUnlink(_ documentId: Int64) {
        staging.toggleUnlink(documentId)
    }

    /// Copies each file into the library now (analysing it, off the main thread) and stages
    /// its link. Folders are skipped and named.
    func addFiles(_ urls: [URL]) {
        guard let library else { return }
        let (files, folders) = EvidenceFiles.files(urls)
        infoMessage = EvidenceFiles.skippedMessage(folders)
        guard !files.isEmpty else { return }
        addingCount += files.count
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (added: [EvidenceDocument], failures: [String]) in
                var added: [EvidenceDocument] = [], failures: [String] = []
                for url in files {
                    do {
                        added.append(try EvidenceFiles.withAccess(url) { try library.addAnalyzing(url) }.document)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (added, failures)
            }.value
            addingCount -= files.count
            for document in outcome.added {
                guard let id = document.id else { continue }
                documentsById[id] = document
                staging.stageLink(id)
            }
            errorMessage = outcome.failures.isEmpty ? nil : "Couldn't add " + outcome.failures.joined(separator: "; ")
            if pickerIndex != nil { loadPicker() }
        }
    }

    func open(_ document: EvidenceDocument) {
        guard let library else { return }
        NSWorkspace.shared.open(library.fileURL(for: document))
    }
}

/// Edit transaction's Documents row: each document (Open; Unlink, or Undo of a staged
/// change, shown as "will be linked" / "will be unlinked"), Link document…, and a drop target
/// for files to add. Everything is written by the sheet's Save.
struct TransactionDocumentsSection: View {
    @ObservedObject var model: TransactionDocumentsModel
    let transactionName: String
    @Environment(\.theme) private var theme
    @State private var picking = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.shown) { document in
                row(document)
            }
            HStack(spacing: 8) {
                Button("Link document…") { picking = true }
                    .controlSize(.small)
                if model.addingCount > 0 {
                    ProgressView().controlSize(.small)
                    Text("Adding…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.shown.isEmpty ? "or drop a file here" : "Drop a file to add it")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let info = model.infoMessage {
                Text(info).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(theme.expense).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dropTargeted ? theme.accent : Color.clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onAppear { model.load() }
        .sheet(isPresented: $picking) {
            LinkDocumentSheet(model: model, transactionName: transactionName)
        }
    }

    private func row(_ document: EvidenceDocument) -> some View {
        let id = document.id ?? -1
        let unlinking = model.staging.willUnlink(id), linking = model.staging.willLink(id)
        return HStack(spacing: 6) {
            Image(systemName: unlinking ? "minus.circle" : linking ? "plus.circle" : "paperclip")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.displayName)
                    .lineLimit(1).truncationMode(.middle)
                    .strikethrough(unlinking)
                    .foregroundStyle(unlinking ? .secondary : .primary)
                Text(unlinking ? "Will be unlinked on Save" : linking ? "Will be linked on Save"
                     : DocumentFormat.caption(kind: document.kind, date: document.docDate,
                                              amountMinorUnits: document.amountMinorUnits, currency: document.currency))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .italic(unlinking || linking)
            }
            .help(document.displayName)
            Spacer(minLength: 6)
            Button("Open") { model.open(document) }
                .help("Open in its default app")
            Button(unlinking || linking ? "Undo" : "Unlink") { model.toggleUnlink(id) }
                .help(unlinking || linking ? "Keep the documents as they are" : "Remove the link on Save (the document stays in the library)")
                .accessibilityLabel(unlinking || linking ? "Undo for \(document.displayName)" : "Unlink \(document.displayName)")
        }
        .controlSize(.small)
    }
}
