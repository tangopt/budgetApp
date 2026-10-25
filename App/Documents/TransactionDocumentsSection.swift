// App/Documents/TransactionDocumentsSection.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction
import GRDB

/// A transaction's documents (spec 2026-10-16 §2) while Edit transaction is open: the saved
/// links plus links and unlinks staged until Save (`EvidenceLinkStaging`), which writes them
/// with the transaction (`TransactionEditChanges.documents`). Cancel discards them. A file
/// dropped here (or Link document… ▸ Add file…) goes to the importer with the transaction as
/// its link target (`attachShortcut`): Confirm import files and links it, not Save.
@MainActor
final class TransactionDocumentsModel: ObservableObject {
    let transactionId: Int64?
    let library: EvidenceLibrary?
    let dbQueue: DatabaseQueue?
    @Published private(set) var staging = EvidenceLinkStaging(saved: [])
    /// Every document shown (saved and staged), by id.
    @Published private(set) var documentsById: [Int64: EvidenceDocument] = [:]
    @Published var errorMessage: String?
    /// Files were handed to the importer from Edit transaction (their review opens once it closes).
    @Published var sentToImports = false
    /// Link document…'s data: every document, and the ones that would propose this transaction.
    @Published private(set) var pickerIndex: EvidenceDocumentSearch.Index?
    @Published private(set) var pickerSuggestions: [EvidenceMatcher.DocumentSuggestion] = []
    /// The documents whose library file is on this Mac, checked off the main thread after each change to what's shown.
    @Published private(set) var onDevice: Set<Int64> = []
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

    /// What a file added here hands the importer (`origin`: the drop or Link document…'s Add file…).
    func attachShortcut(from origin: AttachOrigin) -> ImportShortcut? {
        transactionId.map { .attach(.transaction($0), role: nil, from: origin) }
    }

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
            refreshOnDevice()
        } catch {
            errorMessage = "Couldn't read the documents: \(error.localizedDescription)"
        }
    }

    private func refreshOnDevice() {
        guard let library else { return }
        let files = documentsById.compactMap { id, document in (id, document.storedRelativePath) }
        Task {
            let present = await Task.detached(priority: .userInitiated) {
                Set(files.filter { library.isOnThisDevice(storedRelativePath: $0.1) }.map(\.0))
            }.value
            onDevice = present
        }
    }

    func loadPicker() {
        guard let dbQueue, let transactionId else { return }
        let excluded = Set(staging.shownIds.filter(staging.isLinked))
        Task {
            do {
                async let catalog = TransactionCatalog.load(dbQueue)
                let (index, all, paid) = try await Task.detached(priority: .userInitiated) {
                    try dbQueue.read { db in
                        (try EvidenceDocumentSearch.Index(db: db), try EvidenceDocument.fetchAll(db), try EvidenceMatcher.linkedDebits(db: db))
                    }
                }.value
                pickerIndex = index
                let matcherIndex = try await catalog.matcherIndex
                pickerSuggestions = await Task.detached(priority: .userInitiated) {
                    EvidenceMatcher.documentSuggestions(for: transactionId, documents: all, index: matcherIndex, excluding: excluded,
                                                        linkedDebits: paid, limit: 8)
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
        refreshOnDevice()
    }

    /// Unlink, or Undo of a staged change (Save writes it).
    func toggleUnlink(_ documentId: Int64) {
        staging.toggleUnlink(documentId)
    }

    func open(_ document: EvidenceDocument) {
        guard let library else { return }
        NSWorkspace.shared.open(library.fileURL(for: document))
    }
}

/// Edit transaction's Documents row: each document (Open; Unlink, or Undo of a staged
/// change, shown as "will be linked" / "will be unlinked"), Link document…, and a drop target
/// handing files to the importer (linked by Confirm import). The rest is written by the sheet's Save.
struct TransactionDocumentsSection: View {
    @ObservedObject var model: TransactionDocumentsModel
    let transactionName: String
    @Environment(\.theme) private var theme
    @Environment(\.documentKinds) private var kinds
    @State private var picking = false
    /// The saved document whose first page shows below the list.
    @State private var selectedId: Int64?
    @State private var quickLook: URL?

    /// The saved documents, in the list's order.
    private var saved: [EvidenceDocument] { model.shown.filter { model.staging.isSaved($0.id ?? -1) } }

    /// The selected saved document (one staged to link isn't previewed until Save), else the first.
    private var previewed: EvidenceDocument? {
        saved.first { $0.id == selectedId } ?? saved.first
    }

    /// Every saved document's library file that is on this Mac, for Quick Look's arrows.
    private func savedURLs(_ library: EvidenceLibrary) -> [URL] {
        saved.filter { model.onDevice.contains($0.id ?? -1) }.map { library.fileURL(for: $0) }
    }

    /// Quick Look on the selected document (nothing when its file isn't here), the others a step away.
    private func openQuickLook(_ library: EvidenceLibrary) {
        guard let previewed, model.onDevice.contains(previewed.id ?? -1) else { return }
        quickLook = library.fileURL(for: previewed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.shown) { document in
                row(document)
            }
            if let previewed, let library = model.library {
                let here = model.onDevice.contains(previewed.id ?? -1)
                Group {
                    if here {
                        DocumentThumbnail(url: library.fileURL(for: previewed), height: 140, onQuickLook: { openQuickLook(library) })
                    } else {
                        Text("Not on this Mac yet").foregroundStyle(.secondary).frame(minHeight: 60)
                    }
                }
                .frame(maxWidth: .infinity)
                .focusable()
                .onKeyPress(.space) {
                    guard here else { return .ignored }
                    openQuickLook(library)
                    return .handled
                }
                Button("Quick Look") { openQuickLook(library) }
                    .controlSize(.small)
                    .disabled(!here)
                    .help("Preview the documents (Space)")
            }
            HStack(spacing: 8) {
                Button("Link document…") { picking = true }
                    .controlSize(.small)
                Text(model.shown.isEmpty ? "or drop a file here" : "Drop a file to add it")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.sentToImports {
                Text(ImportShortcutButton.opensWhenClosed).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(theme.expense).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .importDropTarget(model.attachShortcut(from: .transaction)) { model.sentToImports = true }
        .onAppear { model.load() }
        .quickLookPreview($quickLook, in: model.library.map(savedURLs) ?? [])
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
                Group {
                    if unlinking || linking {
                        Text(unlinking ? "Will be unlinked on Save" : "Will be linked on Save").italic().lineLimit(1)
                    } else {
                        DocumentCaptionLine(kindName: kinds.displayName(of: document), date: document.docDate,
                                            amountMinorUnits: document.amountMinorUnits, currency: document.currency)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
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
        .padding(.vertical, 1)
        .background(previewed?.id == document.id ? theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { if !linking { selectedId = document.id } }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Preview") { if !linking { selectedId = document.id } }
    }
}
