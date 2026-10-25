// App/Documents/LinkPickers.swift
import SwiftUI
import BudgetCore

/// Link to transaction… (Documents screen): the transactions the document may be evidence
/// for first (`EvidenceMatcher`), then any transaction found by searching (after a pause in
/// typing, off the main thread). Each Link applies at once — the Documents screen has no
/// Save — and the sheet stays open to link more (one notice → several instalments).
struct LinkTransactionSheet: View {
    let documentName: String
    @ObservedObject var viewModel: DocumentsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var role: String?
    @State private var results: [EvidenceTransactionInfo] = []

    var body: some View {
        SheetScaffold(title: "Link to transaction", subtitle: documentName, error: viewModel.errorMessage, width: SheetMetrics.listWidth,
                      cancelTitle: "Done", onCancel: { dismiss() }) {
            HStack(spacing: 8) {
                SearchField("Search descriptions, categories or an amount", text: $query)
                Picker("Role", selection: $role) {
                    Text("No role").tag(String?.none)
                    Divider()
                    ForEach(EvidenceRoles.presets, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .fixedSize()
                .help("The role new links get")
            }
            List {
                if viewModel.catalog == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading transactions…").foregroundStyle(.secondary)
                    }
                }
                if !viewModel.suggestions.isEmpty {
                    Section("Suggested") {
                        ForEach(viewModel.suggestions, id: \.transactionId) { suggestion in
                            if let info = viewModel.catalog?.info(suggestion.transactionId) {
                                pickRow(info, reasons: suggestion.reasons)
                            }
                        }
                    }
                }
                if viewModel.catalog != nil, viewModel.suggestions.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No suggestions for this document: search for its transaction above.")
                        .foregroundStyle(.secondary)
                }
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("Search results") {
                        if results.isEmpty, viewModel.catalog != nil {
                            Text("No transactions match.").foregroundStyle(.secondary)
                        }
                        ForEach(results) { info in pickRow(info) }
                    }
                }
            }
            .frame(height: 380)
            .sheetListFrame()
        }
        .checkingFiledYears(viewModel.isCheckingFiledYears)
        .task(id: SearchKey(text: query, isReady: viewModel.catalog != nil)) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let catalog = viewModel.catalog else { results = []; return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { catalog.search(text) }.value
            if !Task.isCancelled { results = found }
        }
    }

    private func pickRow(_ info: EvidenceTransactionInfo, reasons: [String] = []) -> some View {
        HStack(spacing: 10) {
            EvidenceTransactionRow(info: info, reasons: reasons)
            if viewModel.linkedTransactionIds.contains(info.id) {
                PickerLinkedMark()
            } else {
                PickerLinkButton(accessibilityTitle: "Link to \(info.transaction.rawDescription)", help: "Link to this transaction") {
                    viewModel.link(transactionId: info.id, role: role)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Link document… (Edit transaction): documents that would propose this transaction first,
/// then any document found by searching (after a pause in typing, off the main thread); Add
/// file… hands files to the importer with the transaction as their link target (reviewed in
/// Imports, linked by Confirm import). Link only stages the link — Edit transaction's Save
/// writes it, Cancel discards it.
struct LinkDocumentSheet: View {
    @ObservedObject var model: TransactionDocumentsModel
    let transactionName: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [EvidenceDocumentSearch.Entry] = []

    var body: some View {
        SheetScaffold(title: "Link document", subtitle: transactionName, error: model.errorMessage, width: SheetMetrics.listWidth,
                      cancelTitle: "Done", onCancel: { dismiss() }) {
            HStack(spacing: 8) {
                SearchField("Search names, kinds, notes, text or an amount", text: $query)
                if let shortcut = model.attachShortcut(from: .linkPicker) {
                    ImportShortcutButton("Add file…", shortcut: shortcut) { model.sentToImports = true }
                        .help("Import a file and link it to this transaction (reviewed in Imports)")
                }
            }
            if model.sentToImports {
                Text(ImportShortcutButton.opensWhenClosed).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            List {
                if model.pickerIndex == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading documents…").foregroundStyle(.secondary)
                    }
                }
                if !model.pickerSuggestions.isEmpty {
                    Section("Suggested") {
                        ForEach(model.pickerSuggestions, id: \.documentId) { suggestion in
                            if let entry = model.pickerEntry(suggestion.documentId) {
                                pickRow(entry, reasons: suggestion.reasons)
                            }
                        }
                    }
                }
                Section(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Not linked yet, or partly paid" : "Search results") {
                    if results.isEmpty, model.pickerIndex != nil {
                        Text("No documents.").foregroundStyle(.secondary)
                    }
                    ForEach(results) { entry in pickRow(entry) }
                }
            }
            .frame(height: 380)
            .sheetListFrame()
        }
        .onAppear { model.loadPicker() }
        .task(id: SearchKey(text: query, isReady: model.pickerIndex != nil)) {
            guard let index = model.pickerIndex else { results = []; return }
            let text = query.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            // Before typing: documents not linked yet, and part-paid ones (the rest of a bill paid in instalments).
            let filter = EvidenceDocumentSearch.Filter(text: text, linkState: text.isEmpty ? .unlinkedOrPartlyPaid : .any)
            let found = await Task.detached(priority: .userInitiated) {
                Array(EvidenceDocumentSearch.entries(index, filter: filter).prefix(100))
            }.value
            if !Task.isCancelled { results = found }
        }
    }

    private func pickRow(_ entry: EvidenceDocumentSearch.Entry, reasons: [String] = []) -> some View {
        let summary = entry.summary
        return HStack(spacing: 10) {
            // A part-paid document says so where nothing else is said about it.
            EvidenceDocumentPickRow(summary: summary, reasons: reasons.isEmpty && entry.isPartlyPaid ? ["Partly paid"] : reasons)
            Spacer(minLength: 8)
            if model.staging.isLinked(summary.id) {
                PickerLinkedMark(title: model.staging.willLink(summary.id) ? "Will be linked" : "Linked")
            } else {
                PickerLinkButton(accessibilityTitle: "Link \(summary.displayName)", help: "Link on Save") {
                    model.stageLink(summary.id)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// What a picker's search re-runs on: the text, and whether its data has loaded.
private struct SearchKey: Equatable {
    let text: String
    let isReady: Bool
}
