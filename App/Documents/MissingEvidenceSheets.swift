// App/Documents/MissingEvidenceSheets.swift
import SwiftUI
import BudgetCore
import GRDB

/// Link existing… (Missing evidence): library documents for one checklist item — the ones
/// that may be its evidence first (`EvidenceMatcher` for a transaction, then
/// `MissingEvidence.candidates`), then every document of an expected kind, or any document
/// found by searching. Each Link applies at once (the screen has no Save) and the sheet stays
/// open to link more.
struct LinkEvidenceSheet: View {
    let item: MissingEvidence.Item
    @ObservedObject var viewModel: MissingEvidenceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var anyKind = false
    @State private var index: EvidenceDocumentSearch.Index?
    @State private var linkedIds: Set<Int64> = []
    @State private var suggestions: [MissingEvidence.Candidate] = []
    @State private var results: [EvidenceDocumentSearch.Entry] = []
    /// The sheet's own messages (the screen behind keeps its own).
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    /// Bumped on each load, so the list is re-filtered from the fresh index.
    @State private var generation = 0

    var body: some View {
        SheetScaffold(title: "Link existing document", subtitle: subtitle, error: errorMessage, width: SheetMetrics.listWidth,
                      cancelTitle: "Done", onCancel: { dismiss() }) {
            HStack(spacing: 8) {
                SearchField("Search names, kinds, notes, text or an amount", text: $query)
                if !item.expectedKindRefs.isEmpty {
                    Toggle("Any kind", isOn: $anyKind)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("Show documents of every kind, not only the ones this item needs")
                }
            }
            List {
                if index == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading documents…").foregroundStyle(.secondary)
                    }
                }
                if !suggestions.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("Suggested") {
                        ForEach(suggestions, id: \.documentId) { suggestion in
                            if let entry = entry(suggestion.documentId) {
                                pickRow(entry, reasons: suggestion.reasons)
                            }
                        }
                    }
                }
                Section(sectionTitle) {
                    if results.isEmpty, index != nil {
                        Text("No documents.").foregroundStyle(.secondary)
                    }
                    ForEach(results) { entry in pickRow(entry) }
                }
            }
            .frame(height: 380)
            .sheetListFrame()
            if let info = infoMessage {
                SheetCaption(info)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
        .task(id: SearchKey(text: query, anyKind: anyKind, generation: generation)) {
            guard let index else { results = []; return }
            let text = query.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let requirement = item.requirement, anyKind = anyKind || item.expectedKindRefs.isEmpty
            let found = await Task.detached(priority: .userInitiated) {
                Array(EvidenceDocumentSearch.entries(index, filter: EvidenceDocumentSearch.Filter(text: text))
                    .filter { anyKind || requirement.accepts($0.summary.kindRef) }
                    .prefix(100))
            }.value
            if !Task.isCancelled { results = found }
        }
    }

    private var subtitle: String {
        var parts = [item.title]
        if let date = item.expectedDate { parts.append(DocumentFormat.day(date).unbroken) }
        if let slot = item.expectedPeriod { parts.append(MissingEvidenceFormat.slot(slot).unbroken) }
        return parts.joined(separator: " · ") + "\nNeeds: " + MissingEvidenceViewModel.kindsText(names: item.expectedKindNames)
    }

    private var sectionTitle: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "Search results" }
        return anyKind || item.expectedKindRefs.isEmpty ? "All documents" : "Documents of the expected kind"
    }

    private func entry(_ id: Int64) -> EvidenceDocumentSearch.Entry? {
        index?.entries.first { $0.id == id }
    }

    private func load() async {
        let dbQueue = viewModel.dbQueue, item = item
        do {
            let (index, linked, documents, paid) = try await Task.detached(priority: .userInitiated) {
                try dbQueue.read { db in
                    let isTransaction = item.target.entity.type == .transaction
                    return (try EvidenceDocumentSearch.Index(db: db),
                            Set(try EvidenceLinks.documents(db: db, for: item.target.entity).compactMap(\.id)),
                            isTransaction ? try EvidenceDocument.fetchAll(db) : [],
                            isTransaction ? try EvidenceMatcher.linkedDebits(db: db) : [:])
                }
            }.value
            self.index = index
            generation += 1
            linkedIds = linked
            var ranked: [MissingEvidence.Candidate] = []
            if item.target.entity.type == .transaction {
                let catalog = try await TransactionCatalog.load(dbQueue)
                let transactionId = item.target.entity.id
                ranked = await Task.detached(priority: .userInitiated) {
                    EvidenceMatcher.documentSuggestions(for: transactionId, documents: documents, index: catalog.matcherIndex,
                                                        excluding: linked, linkedDebits: paid, limit: 8)
                        .filter { suggestion in
                            documents.first { $0.id == suggestion.documentId }.map { item.requirement.accepts($0.kindRef) } ?? false
                        }
                        .map { MissingEvidence.Candidate(documentId: $0.documentId, score: $0.score, reasons: $0.reasons) }
                }.value
            }
            let shown = Set(ranked.map(\.documentId))
            let more = MissingEvidence.candidates(for: item, documents: index.entries.map(\.summary), excluding: linked.union(shown))
            suggestions = Array((ranked + more).prefix(8))
        } catch {
            errorMessage = "Couldn't load documents: \(error.localizedDescription)"
        }
    }

    private func pickRow(_ entry: EvidenceDocumentSearch.Entry, reasons: [String] = []) -> some View {
        let summary = entry.summary
        return HStack(spacing: 10) {
            EvidenceDocumentPickRow(summary: summary, reasons: reasons)
            Spacer(minLength: 8)
            if linkedIds.contains(summary.id) {
                PickerLinkedMark()
            } else {
                PickerLinkButton(accessibilityTitle: "Link \(summary.displayName)", help: "Link to this item") {
                    switch viewModel.link(documentId: summary.id, to: item) {
                    case .success(let note):
                        infoMessage = note
                        errorMessage = nil
                        linkedIds.insert(summary.id)
                        // Its kind or period may have been filled in: re-read the list.
                        Task { await load() }
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private struct SearchKey: Equatable {
        let text: String
        let anyKind: Bool
        let generation: Int
    }
}

/// Mark not available… (Missing evidence): why the item won't get a document, and a note.
/// The item then counts as done.
struct WaiveEvidenceSheet: View {
    let item: MissingEvidence.Item
    @ObservedObject var viewModel: MissingEvidenceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var reason: EvidenceWaiverReason
    @State private var note: String
    @State private var errorMessage: String?

    init(item: MissingEvidence.Item, viewModel: MissingEvidenceViewModel) {
        self.item = item
        self.viewModel = viewModel
        _reason = State(initialValue: item.waiver?.reason ?? .notAvailable)
        _note = State(initialValue: item.waiver?.note ?? "")
    }

    var body: some View {
        SheetScaffold(title: item.waiver == nil ? "Mark not available" : "Edit waiver", subtitle: item.title,
                      error: errorMessage, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction(item.waiver == nil ? "Mark not available" : "Save") {
                          errorMessage = viewModel.waive(item, reason: reason, note: note)
                          if errorMessage == nil { dismiss() }
                      }) {
            SheetForm {
                LabeledContent("Reason") {
                    Picker("Reason", selection: $reason) {
                        Text("Not available").tag(EvidenceWaiverReason.notAvailable)
                        Text("Other reason").tag(EvidenceWaiverReason.other)
                    }
                    .pickerStyle(.radioGroup)
                }
                LabeledContent("Note") {
                    TextField("Note", text: $note, prompt: Text("e.g. the bank no longer issues these"), axis: .vertical)
                        .lineLimit(2...4)
                }
                SheetFormNote("The item counts as done; Remove waiver brings it back.")
            }
        }
    }
}

/// Formats for checklist items.
enum MissingEvidenceFormat {
    /// "6 Apr 2025 – 5 May 2025": a slot's first and last days.
    static func slot(_ slot: DateInterval) -> String {
        let last = slot.end.addingTimeInterval(-86_400)
        return "\(DocumentFormat.day(slot.start)) – \(DocumentFormat.day(max(last, slot.start)))"
    }
}
