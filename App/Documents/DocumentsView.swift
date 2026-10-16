// App/Documents/DocumentsView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// The Documents screen (spec 2026-10-16 §3): the library list (search, filters, drop files
/// to add), the selected document's preview, and its inspector (details, links, suggested
/// transactions). Add documents… and Review folder… are in the toolbar.
struct DocumentsView: View {
    @ObservedObject var viewModel: DocumentsViewModel
    /// Shows a linked transaction where it lives (its Budget cell, or Uncategorized).
    let openTransaction: (Transaction) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings

    @State private var importing = false
    @State private var reviewing: SourceFolder?
    @State private var dropTargeted = false

    var body: some View {
        HSplitView {
            libraryList
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
            detail
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { viewModel.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: {
                    Label("Add documents…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Add documents…")
                .accessibilityLabel("Add documents")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if viewModel.sourceFolders.isEmpty {
                        Text("No evidence folders yet")
                    }
                    ForEach(viewModel.sourceFolders) { folder in
                        Button(folder.name) { reviewing = folder }
                    }
                    Divider()
                    Button("Manage folders…") { openSettings() }
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .accessibilityLabel("Review a folder")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .help("Review a folder: add and link the files it has that aren't in the library")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: EvidenceFiles.contentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): viewModel.add(urls)
            case .failure(let error): viewModel.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $reviewing, onDismiss: { viewModel.load() }) { folder in
            FolderReviewSheet(folder: folder, scanner: viewModel.scanner, dbQueue: viewModel.dbQueue)
        }
    }

    // MARK: List

    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField
            DocumentFilterBar(viewModel: viewModel)
            messages
            List(selection: $viewModel.selectedId) {
                ForEach(viewModel.entries) { entry in
                    DocumentListRow(entry: entry)
                        .tag(entry.id)
                }
            }
            .listStyle(.inset)
            .overlay { emptyState }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.accent, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                viewModel.add(urls)
                return !urls.isEmpty
            } isTargeted: { dropTargeted = $0 }
            footer
        }
        .padding(12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search names, kinds, notes, text or an amount", text: $viewModel.queryText)
                .textFieldStyle(.plain)
            if !viewModel.queryText.isEmpty {
                Button { viewModel.queryText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder
    private var messages: some View {
        if let error = viewModel.errorMessage {
            banner(error, systemImage: "exclamationmark.triangle.fill", color: theme.expense) { viewModel.errorMessage = nil }
        }
        if let info = viewModel.infoMessage {
            banner(info, systemImage: "info.circle", color: .secondary) { viewModel.infoMessage = nil }
        }
    }

    private func banner(_ text: String, systemImage: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.entries.isEmpty {
            if viewModel.index.entries.isEmpty {
                ContentUnavailableView("No documents yet", systemImage: "doc.on.doc",
                                       description: Text("Drop receipts, notices and statements here, or use Add documents…. Budget keeps its own copy; your files aren't changed."))
            } else {
                Text("No documents match.").foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            let shown = viewModel.entries.count, total = viewModel.index.entries.count
            Text(shown == total ? "\(total) document\(total == 1 ? "" : "s")" : "\(shown) of \(total) documents")
            if viewModel.addingCount > 0 {
                ProgressView().controlSize(.small)
                Text("Adding \(viewModel.addingCount)…")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let document = viewModel.selected {
            HSplitView {
                DocumentPreview(url: viewModel.fileURL(document))
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                DocumentInspector(viewModel: viewModel, document: document, openTransaction: openTransaction)
                    .id(document.id)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 460, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("No document selected", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a document to see it, edit its details and link it to transactions."))
        }
    }
}

/// A document in the library list: its name, kind · date · amount, and its link count (or
/// "Not linked").
private struct DocumentListRow: View {
    let entry: EvidenceDocumentSearch.Entry
    @Environment(\.theme) private var theme

    var body: some View {
        let summary = entry.summary
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(summary.displayName).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(DocumentFormat.caption(kind: summary.kind, date: summary.docDate, amountMinorUnits: summary.amountMinorUnits,
                                            currency: summary.currency))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if entry.linkCount > 0 {
                    DocumentCountBadge(count: entry.linkCount)
                } else {
                    Text("Not linked")
                        .foregroundStyle(theme.pending)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch entry.summary.textStatus {
        case .image: return "photo"
        case .noText: return "doc"
        default: return "doc.text"
        }
    }
}

/// The list's filters: kind, year, account, links and source folder.
private struct DocumentFilterBar: View {
    @ObservedObject var viewModel: DocumentsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Kind", selection: $viewModel.filter.kind) {
                    Text("All kinds").tag(DocumentKind?.none)
                    Divider()
                    ForEach(DocumentKind.byDisplayName.filter(viewModel.index.kinds.contains), id: \.self) { kind in
                        Text(kind.displayName).tag(DocumentKind?.some(kind))
                    }
                }
                .accessibilityLabel("Kind")
                Picker("Year", selection: $viewModel.filter.year) {
                    Text("All years").tag(Int?.none)
                    Divider()
                    ForEach(viewModel.index.years, id: \.self) { year in
                        Text(String(year)).tag(Int?.some(year))
                    }
                }
                .accessibilityLabel("Year")
            }
            HStack(spacing: 6) {
                Picker("Account", selection: $viewModel.filter.accountId) {
                    Text("All accounts").tag(Int64?.none)
                    Divider()
                    ForEach(viewModel.accounts) { account in
                        Text(account.displayName).tag(account.id)
                    }
                }
                .accessibilityLabel("Account")
                Picker("Links", selection: $viewModel.filter.linkState) {
                    Text("Linked or not").tag(EvidenceDocumentSearch.LinkState.any)
                    Text("Linked").tag(EvidenceDocumentSearch.LinkState.linked)
                    Text("Not linked").tag(EvidenceDocumentSearch.LinkState.unlinked)
                }
                .accessibilityLabel("Links")
                if !viewModel.sourceFolders.isEmpty {
                    Picker("Folder", selection: $viewModel.filter.sourceFolderId) {
                        Text("Any folder").tag(Int64?.none)
                        Divider()
                        ForEach(viewModel.sourceFolders) { folder in
                            Text(folder.name).tag(folder.id)
                        }
                    }
                    .accessibilityLabel("Source folder")
                }
            }
            if viewModel.filter.hasFilters {
                Button("Reset filters") { viewModel.resetFilters() }
                    .buttonStyle(.link)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
    }
}
