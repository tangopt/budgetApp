// App/Documents/MissingEvidencePanel.swift
import SwiftUI
import QuickLook
import BudgetCore
import struct BudgetCore.Transaction
import GRDB

/// What the Missing evidence side panel reads beside the checklist (off the main thread): the
/// library (searching it, and the documents that could satisfy the item), the transactions the
/// matcher ranks documents against, and which files are on this Mac. Read once while the page
/// shows, and again after a change (a link, an unlink, a kind changed, the item's documents
/// changed anywhere).
@MainActor
final class MissingEvidencePanelModel: ObservableObject {
    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary

    @Published private(set) var index: EvidenceDocumentSearch.Index?
    /// The documents that could satisfy `suggestionsItemId`'s item, best first.
    @Published private(set) var suggestions: [MissingEvidence.Candidate] = []
    @Published private(set) var suggestionsItemId: String?
    @Published private(set) var results: [EvidenceDocumentSearch.Entry] = []
    /// The documents shown whose library file is on this Mac.
    @Published private(set) var onDevice: Set<Int64> = []
    @Published var quickLook: URL?
    /// The files Quick Look steps through (the attached documents, then the one opened).
    @Published private(set) var quickLookURLs: [URL] = []
    /// The library failed to load.
    @Published private(set) var loadError: String?

    private var documents: [EvidenceDocument] = []
    private var linkedDebits: [Int64: [EvidenceMatcher.LinkedDebit]] = [:]
    private var matcherIndex: EvidenceMatcher.Index?
    private var libraryIsStale = true
    /// The item the suggestions were made for, as it was (its documents changed: read again).
    private var lastItem: MissingEvidence.Item?

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary) {
        self.dbQueue = dbQueue
        self.library = library
    }

    /// The library changed (the panel wrote, or the item's documents did): read it again next time.
    func invalidate() { libraryIsStale = true }

    /// Reads what's stale, then the suggestions for `item` and which files are here.
    func refresh(for item: MissingEvidence.Item) async {
        if let last = lastItem, last.id == item.id, last != item { libraryIsStale = true }
        lastItem = item
        let dbQueue = dbQueue
        do {
            if libraryIsStale || index == nil {
                let (index, documents, paid) = try await Task.detached(priority: .userInitiated) {
                    try dbQueue.read { db in
                        (try EvidenceDocumentSearch.Index(db: db), try EvidenceDocument.fetchAll(db), try EvidenceMatcher.linkedDebits(db: db))
                    }
                }.value
                guard !Task.isCancelled else { return }
                self.index = index
                self.documents = documents
                linkedDebits = paid
                libraryIsStale = false
            }
            if item.target.entity.type == .transaction, matcherIndex == nil {
                let built = try await Task.detached(priority: .userInitiated) {
                    try dbQueue.read { db in
                        EvidenceMatcher.Index(transactions: try Transaction.fetchAll(db), accounts: try Account.fetchAll(db),
                                              categories: try Category.fetchAll(db))
                    }
                }.value
                guard !Task.isCancelled else { return }
                matcherIndex = built
            }
            loadError = nil
        } catch {
            loadError = "Couldn't read the library: \(error.localizedDescription)"
            return
        }
        guard let index else { return }
        let documents = documents, paid = linkedDebits, matcherIndex = matcherIndex
        let linked = Set(MissingEvidence.attached(item, catalog: index.catalog).map(\.id))
        let found = await Task.detached(priority: .userInitiated) { () -> [MissingEvidence.Candidate] in
            var matched: [EvidenceMatcher.DocumentSuggestion] = []
            if item.target.entity.type == .transaction, let matcherIndex {
                matched = EvidenceMatcher.documentSuggestions(for: item.target.entity.id, documents: documents, index: matcherIndex,
                                                              excluding: linked, linkedDebits: paid, limit: 8)
            }
            return MissingEvidence.suggestions(for: item, summaries: index.entries.map(\.summary), matched: matched, excluding: linked, limit: 6)
        }.value
        guard !Task.isCancelled else { return }
        suggestions = found
        suggestionsItemId = item.id
        let shown = item.satisfyingDocuments + item.otherDocuments + found.compactMap { summary($0.documentId) }
        await checkOnDevice(shown)
    }

    /// Library documents matching `text` (names, kinds, notes, text, an amount), at most 20.
    func search(_ text: String) async {
        guard let index, !text.isEmpty else { results = []; return }
        let found = await Task.detached(priority: .userInitiated) {
            Array(EvidenceDocumentSearch.entries(index, filter: EvidenceDocumentSearch.Filter(text: text)).prefix(20))
        }.value
        guard !Task.isCancelled else { return }
        results = found
        await checkOnDevice(found.map(\.summary))
    }

    func summary(_ documentId: Int64) -> EvidenceDocumentSummary? {
        index?.entries.first { $0.id == documentId }?.summary
    }

    private func checkOnDevice(_ summaries: [EvidenceDocumentSummary]) async {
        let library = library
        let files = summaries.filter { !onDevice.contains($0.id) }.map { ($0.id, $0.storedRelativePath) }
        guard !files.isEmpty else { return }
        let present = await Task.detached(priority: .userInitiated) {
            Set(files.filter { library.isOnThisDevice(storedRelativePath: $0.1) }.map(\.0))
        }.value
        onDevice.formUnion(present)
    }

    func url(_ document: EvidenceDocumentSummary) -> URL? {
        onDevice.contains(document.id) ? library.fileURL(storedRelativePath: document.storedRelativePath) : nil
    }

    /// Quick Look on `document`, the item's attached documents a step away.
    func openQuickLook(_ document: EvidenceDocumentSummary, attached: [EvidenceDocumentSummary]) {
        guard let url = url(document) else { return }
        var urls = attached.compactMap(self.url)
        if !urls.contains(url) { urls.append(url) }
        quickLookURLs = urls
        quickLook = url
    }
}

/// The Missing evidence side panel (spec 2026-10-26): one checklist item, checked and fixed in
/// place — what it needs and why it's missing (each attached document that doesn't count, and
/// why), its transaction, its attached documents (page 1, Quick Look, Change kind…, Unlink),
/// the library documents that could satisfy it (Link), a search of the library, Add file… and a
/// drop zone, and Mark not available. Every change is an explicit button, written off the main
/// thread; the checklist's observation brings the row (and the summary) up to date.
struct MissingEvidencePanel: View {
    let item: MissingEvidence.Item
    @ObservedObject var viewModel: MissingEvidenceViewModel
    @ObservedObject var model: MissingEvidencePanelModel
    let openTransaction: (Transaction) -> Void
    let waive: () -> Void
    let onClose: () -> Void
    @Environment(\.theme) private var theme

    /// The attached document whose page shows.
    @State private var previewedId: Int64?
    /// The attached document whose kind is being changed, and the kind picked.
    @State private var editingKind: (id: Int64, kind: DocumentKindRef)?
    @State private var kindErrors: [Int64: String] = [:]
    /// What the last change did, or why it was refused.
    @State private var note: (text: String, isError: Bool)?
    @State private var query = ""
    @State private var sentToImports = false

    private var catalog: DocumentKindCatalog { viewModel.kindCatalog }
    private var attached: [MissingEvidence.AttachedDocument] { MissingEvidence.attached(item, catalog: catalog) }
    private var linkedIds: Set<Int64> { Set(attached.map(\.id)) }

    var body: some View {
        PropertySidePanel(title: item.title, subtitle: subtitle, onClose: onClose) {
            if let note {
                Text(note.text)
                    .font(.callout)
                    .foregroundStyle(note.isError ? theme.expense : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            List {
                Section("Requirement") { requirementSection }
                if item.target.entity.type == .transaction {
                    Section("Transaction") { transactionSection }
                }
                Section(attached.isEmpty ? "Attached documents" : "Attached documents (\(attached.count))") { attachedSection }
                Section("Suggested documents") { suggestionsSection }
                Section("Search the library") { searchSection }
            }
            .wrapProbeClips()
        }
        .quickLookPreview($model.quickLook, in: model.quickLookURLs)
        .task(id: item) {
            if previewedId.map({ id in !attached.contains { $0.id == id } }) ?? true { previewedId = attached.first?.id }
            await model.refresh(for: item)
        }
        .task(id: SearchKey(text: query.trimmingCharacters(in: .whitespaces), isReady: model.index != nil)) {
            let text = query.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            await model.search(text)
        }
        .onChange(of: item.id) {
            note = nil
            editingKind = nil
            kindErrors = [:]
            query = ""
            sentToImports = false
        }
    }

    /// The rule (when the title isn't its name), its slot, and where the documents usually come from.
    private var subtitle: String? {
        var parts: [String] = []
        if item.title != item.requirement.name { parts.append(item.requirement.name) }
        if let slot = item.expectedPeriod { parts.append(MissingEvidenceFormat.slot(slot).unbroken) }
        if let source = item.usualSource { parts.append(source) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Space bar on the checklist: Quick Look on the document whose page shows.
    static func quickLookPreviewed(item: MissingEvidence.Item, model: MissingEvidencePanelModel, catalog: DocumentKindCatalog) {
        let attached = MissingEvidence.attached(item, catalog: catalog).map(\.document)
        if let first = attached.first(where: { model.url($0) != nil }) { model.openQuickLook(first, attached: attached) }
    }

    // MARK: Requirement

    @ViewBuilder
    private var requirementSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusPill
                if item.status == .missing, !item.isDone, !attached.isEmpty {
                    Text(attached.count == 1 ? "1 document attached" : "\(attached.count) documents attached")
                        .font(.caption).foregroundStyle(.secondary)
                        .figureText()
                }
            }
            Text("Needs " + MissingEvidenceViewModel.kindsText(names: item.expectedKindNames))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // Why it's still missing (or waived): each attached document that doesn't count.
            ForEach(item.status == .satisfied ? [] : attached.filter { !$0.counts }) { document in
                Label {
                    Text(document.explanation ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.pending)
                }
                .font(.callout)
                .help(document.document.displayName)
            }
            if item.status == .missing, attached.isEmpty {
                Text("Nothing attached yet.").font(.callout).foregroundStyle(.secondary)
            }
            if let waiver = item.waiver, item.status == .waived, let text = waiver.note, !text.isEmpty {
                Text(text).font(.callout).italic().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                switch item.status {
                case .missing:
                    Button("Mark not available…", action: waive)
                case .waived:
                    Button("Edit waiver…", action: waive)
                    Button("Remove waiver") { viewModel.removeWaiver(item) }
                        .help("Ask for a document again")
                case .satisfied:
                    EmptyView()
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch item.status {
        case .missing: StatusPill("Missing", tone: .warning, systemImage: "circle.dashed")
        case .satisfied: StatusPill("Has document", tone: .positive, systemImage: "checkmark")
        case .waived: StatusPill(item.waiver?.reason == .other ? "Waived" : "Not available", tone: .neutral, systemImage: "minus.circle")
        }
    }

    // MARK: Transaction

    private var transactionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                if let date = item.expectedDate {
                    GridRow {
                        label("Date")
                        DateText(date: date, font: .callout)
                    }
                }
                GridRow {
                    label("Description")
                    Text(item.title).lineLimit(2).truncationMode(.middle).help(item.title)
                }
                if let account = item.accountName {
                    GridRow {
                        label("Account")
                        Text(account).lineLimit(1).truncationMode(.middle).help(account)
                    }
                }
                GridRow {
                    label("Category")
                    Text(item.categoryName ?? "Uncategorized").lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(item.categoryName == nil ? .secondary : .primary)
                }
                if let amount = item.expectedAmountMinorUnits, let currency = item.currency {
                    GridRow {
                        label("Amount")
                        MoneyText(minorUnits: amount, currency: currency, font: .callout.monospacedDigit(), role: .neutral)
                    }
                }
                if let date = item.expectedDate {
                    GridRow {
                        label("Tax year")
                        Text(UKTaxYear.containing(date).label).figureText()
                    }
                }
            }
            .font(.callout)
            Button("Show in Search") { viewModel.show(transactionOf: item, with: openTransaction) }
                .buttonStyle(.link)
                .help("Open the transaction in Search, on its day and account (leaves this page)")
        }
        .padding(.vertical, 2)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    // MARK: Attached documents

    @ViewBuilder
    private var attachedSection: some View {
        ForEach(attached) { document in
            attachedRow(document)
        }
        if let previewed = attached.first(where: { $0.id == previewedId }) ?? attached.first {
            Group {
                if let url = model.url(previewed.document) {
                    DocumentThumbnail(url: url, height: 150) { model.openQuickLook(previewed.document, attached: attached.map(\.document)) }
                } else {
                    Text("Not on this Mac yet").foregroundStyle(.secondary).frame(minHeight: 60)
                }
            }
            .frame(maxWidth: .infinity)
        }
        HStack(spacing: 8) {
            ImportShortcutButton("Add file…", shortcut: MissingEvidenceRow.shortcut(item)) { sentToImports = true }
                .controlSize(.small)
                .help("Import a file and link it to this item (reviewed in Imports)")
            Text(attached.isEmpty ? "or drop a file here" : "Drop a file to add it")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .importDropTarget(MissingEvidenceRow.shortcut(item)) { sentToImports = true }
        if sentToImports {
            Text("Sent to Imports: Confirm import links it here.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attachedRow(_ document: MissingEvidence.AttachedDocument) -> some View {
        let summary = document.document
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: document.counts ? "paperclip" : "exclamationmark.triangle")
                    .foregroundStyle(document.counts ? Color.secondary : theme.pending)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.displayName).lineLimit(1).truncationMode(.middle).help(summary.displayName)
                    DocumentCaptionLine(kindName: document.kindName, date: summary.docDate,
                                        amountMinorUnits: summary.amountMinorUnits, currency: summary.currency)
                        .font(.caption).foregroundStyle(.secondary)
                    if let shortfall = document.shortfall {
                        Text("Doesn't count: \(shortfall.text)").font(.caption).foregroundStyle(theme.pending)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let editing = editingKind, editing.id == document.id {
                kindEditor(document, kind: editing.kind)
            } else {
                HStack(spacing: 8) {
                    Button("Change kind…") {
                        kindErrors[document.id] = nil
                        editingKind = (document.id, summary.kindRef)
                    }
                    Button("Unlink") { unlink(document) }
                        .help("Remove the link (the document stays in the library)")
                        .accessibilityLabel("Unlink \(summary.displayName)")
                    Spacer(minLength: 0)
                    quickLookButton(summary)
                }
                .controlSize(.small)
                .padding(.leading, 20)
            }
            if let error = kindErrors[document.id] {
                Text(error).font(.caption).foregroundStyle(theme.expense)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 2)
        .background(previewedId == document.id && attached.count > 1 ? theme.accent.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { previewedId = document.id }
        .accessibilityElement(children: .contain)
    }

    /// The kinds to choose from: the ones this item needs first, then every built-in kind by
    /// name and the custom kinds (the custom-kinds catalog).
    private func kindEditor(_ document: MissingEvidence.AttachedDocument, kind: DocumentKindRef) -> some View {
        let selection = Binding<DocumentKindRef>(get: { editingKind?.kind ?? kind },
                                                 set: { editingKind = (document.id, $0) })
        let custom = catalog.customKinds.compactMap { kind in kind.id.map { (id: $0, name: kind.name) } }
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Kind", selection: selection) {
                if !item.expectedKindRefs.isEmpty {
                    Section("This needs") {
                        ForEach(Array(zip(item.expectedKindRefs, item.expectedKindNames)), id: \.0) { ref, name in
                            Text(name).tag(ref)
                        }
                    }
                }
                Section("All kinds") {
                    ForEach(DocumentKind.byDisplayName.filter { !item.expectedKindRefs.contains(.builtIn($0)) }, id: \.self) { kind in
                        Text(kind.displayName).tag(DocumentKindRef.builtIn(kind))
                    }
                    ForEach(custom.filter { !item.expectedKindRefs.contains(.custom($0.id)) }, id: \.id) { kind in
                        Text(kind.name).tag(DocumentKindRef.custom(kind.id))
                    }
                }
                // A custom kind gone since the checklist was read stays shown until changed.
                if case .custom(let id) = kind, catalog.custom(id: id) == nil, !item.expectedKindRefs.contains(kind) {
                    Text(document.kindName).tag(kind)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Kind of \(document.document.displayName)")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { editingKind = nil }
                Button("Save") { saveKind(document) }
                    .buttonStyle(.borderedProminent).prominentTint()
                    .disabled((editingKind?.kind ?? kind) == document.document.kindRef || viewModel.isCheckingFiledYears)
            }
        }
        .controlSize(.small)
        .padding(.leading, 20)
    }

    private func saveKind(_ document: MissingEvidence.AttachedDocument) {
        guard let kind = editingKind?.kind else { return }
        let name = catalog.displayName(kind)
        viewModel.changeKind(documentId: document.id, to: kind) { error in
            if let error {
                kindErrors[document.id] = error
            } else {
                editingKind = nil
                kindErrors[document.id] = nil
                note = ("Filed “\(document.document.displayName)” as \(name).", false)
                model.invalidate()
            }
        }
    }

    private func unlink(_ document: MissingEvidence.AttachedDocument) {
        viewModel.unlink(documentId: document.id, from: item) { error in
            if let error {
                note = (error, true)
            } else {
                note = ("Unlinked “\(document.document.displayName)”.", false)
                model.invalidate()
            }
        }
    }

    private func quickLookButton(_ summary: EvidenceDocumentSummary) -> some View {
        Button { model.openQuickLook(summary, attached: attached.map(\.document)) } label: {
            Image(systemName: "eye")
        }
        .buttonStyle(.borderless)
        .disabled(model.url(summary) == nil)
        .help(model.url(summary) == nil ? "Not on this Mac yet" : "Quick Look")
        .accessibilityLabel("Quick Look \(summary.displayName)")
    }

    // MARK: Suggestions and search

    @ViewBuilder
    private var suggestionsSection: some View {
        if model.loadError != nil {
            Text(model.loadError ?? "").font(.callout).foregroundStyle(theme.expense).fixedSize(horizontal: false, vertical: true)
        } else if model.suggestionsItemId != item.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking in the library…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if model.suggestions.isEmpty {
            Text("No library document looks like this item's evidence: search below, or add the file.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(model.suggestions, id: \.documentId) { suggestion in
                if let summary = model.summary(suggestion.documentId) {
                    pickRow(summary, reasons: suggestion.reasons)
                }
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        SearchField("Name, kind, amount or date", text: $query)
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            if model.results.isEmpty {
                Text("No documents match.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.results) { entry in pickRow(entry.summary) }
        }
    }

    private func pickRow(_ summary: EvidenceDocumentSummary, reasons: [String] = []) -> some View {
        HStack(spacing: 6) {
            EvidenceDocumentPickRow(summary: summary, reasons: reasons)
                .frame(maxWidth: .infinity, alignment: .leading)
            quickLookButton(summary)
            if linkedIds.contains(summary.id) {
                PickerLinkedMark()
            } else {
                PickerLinkButton(accessibilityTitle: "Link \(summary.displayName)", help: "Link to this item") { link(summary) }
                    .disabled(viewModel.isCheckingFiledYears)
            }
        }
        .padding(.vertical, 2)
    }

    private func link(_ summary: EvidenceDocumentSummary) {
        viewModel.link(documentId: summary.id, to: item) { result in
            switch result {
            case .success(let text): note = (text, false)
            case .failure(let error): note = (error.localizedDescription, true)
            }
            model.invalidate()
        }
    }

    private struct SearchKey: Equatable {
        let text: String
        let isReady: Bool
    }
}
