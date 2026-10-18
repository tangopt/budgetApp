// App/Documents/DocumentsView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// The Documents screen (spec 2026-10-16 §3, UI polish §4.2): two panes — the library as a
/// table (search, filter chips, documents by the year they're dated in; drop files to add; a
/// context menu, double-click opens), taking the width, and beside it a column of fixed width
/// with the selected document's inspector (first page, links, suggested transactions,
/// details) — or, with nothing selected, the library at a glance. Add documents… and Review
/// folder… are in the toolbar.
struct DocumentsView: View {
    @ObservedObject var viewModel: DocumentsViewModel
    /// Shows a linked transaction where it lives (its Budget cell, or Uncategorized).
    let openTransaction: (Transaction) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings

    @State private var importing = false
    @State private var reviewing: SourceFolder?
    @State private var dropTargeted = false
    /// The document the list's Link… and Remove… act on.
    @State private var linkingFromList = false
    @State private var removing: EvidenceDocument?

    var body: some View {
        HSplitView {
            // The list takes the width; the column beside keeps one width whether or not a
            // document is selected, so the list's columns don't jump.
            libraryList
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            detail
                .frame(minWidth: 400, idealWidth: 420, maxWidth: 460, maxHeight: .infinity)
        }
        .onAppear { viewModel.load() }
        .sheet(isPresented: $linkingFromList) {
            if let document = viewModel.selected {
                LinkTransactionSheet(documentName: document.displayName, viewModel: viewModel)
            }
        }
        .confirmationDialog("Remove “\(removing?.displayName ?? "")” from the library?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { document in
            Button("Remove from library", role: .destructive) { if let id = document.id { viewModel.remove(id) } }
        } message: { _ in
            Text("Budget deletes its copy and its links. The original file, if you still have it, isn't touched. This can't be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: {
                    Label("Add documents…", systemImage: "doc.badge.plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .help("Add documents…: copy files into the library")
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
            SearchField("Search names, kinds, notes, text or an amount", text: $viewModel.queryText)
            DocumentFilterBar(viewModel: viewModel)
            messages
            DocumentsTable(viewModel: viewModel, actions: listActions)
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
        .padding(ScreenMetrics.padding)
    }

    @ViewBuilder
    private var messages: some View {
        if let error = viewModel.errorMessage {
            InlineBanner(.error, error) { viewModel.errorMessage = nil }
        }
        if let info = viewModel.infoMessage {
            InlineBanner(.info, info) { viewModel.infoMessage = nil }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.entries.isEmpty {
            if viewModel.index.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Drop files here to add them").foregroundStyle(.secondary)
                }
            } else {
                Text("No documents match.").foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            let shown = viewModel.entries.count, total = viewModel.index.entries.count
            Text(shown == total ? "\(total) document\(total == 1 ? "" : "s")" : "\(shown) of \(total) documents")
                .monospacedDigit()
            if viewModel.addingCount > 0 {
                ProgressView().controlSize(.small)
                Text("Adding \(viewModel.addingCount)…")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// The list's context menu and double-click.
    private var listActions: DocumentsTable.Actions {
        DocumentsTable.Actions(
            open: { id in if let document = viewModel.document(id) { viewModel.open(document) } },
            showInFinder: { id in if let document = viewModel.document(id) { viewModel.showInFinder(document) } },
            link: { id in
                viewModel.selectedId = id
                linkingFromList = viewModel.selected?.id == id
            },
            remove: { id in removing = viewModel.document(id) })
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let document = viewModel.selected {
            DocumentInspector(viewModel: viewModel, document: document, openTransaction: openTransaction)
                .id(document.id)
        } else {
            DocumentsOverview(viewModel: viewModel, addDocuments: { importing = true })
        }
    }
}

/// The library as a table: name, kind, date, amount and links, by the year documents are
/// dated in (latest first). Selecting a row shows it beside, and the list scrolls to the
/// selection (a document just added, or picked in the overview); the context menu opens,
/// shows in Finder, links or removes; a double-click opens.
private struct DocumentsTable: View {
    struct Actions {
        let open: (Int64) -> Void
        let showInFinder: (Int64) -> Void
        let link: (Int64) -> Void
        let remove: (Int64) -> Void
    }

    @ObservedObject var viewModel: DocumentsViewModel
    let actions: Actions
    @Environment(\.theme) private var theme
    /// A selection to bring into view once its row is listed (the list loads after it's set).
    @State private var pendingScroll: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            table
                .onChange(of: viewModel.selectedId) { _, id in
                    pendingScroll = id
                    scroll(proxy)
                }
                .onChange(of: viewModel.entries.map(\.id)) { _, _ in scroll(proxy) }
                .onAppear {
                    pendingScroll = viewModel.selectedId
                    scroll(proxy)
                }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = pendingScroll, viewModel.entries.contains(where: { $0.id == id }) else { return }
        pendingScroll = nil
        // After the rows are laid out.
        DispatchQueue.main.async { proxy.scrollTo(id) }
    }

    private var table: some View {
        Table(of: EvidenceDocumentSearch.Entry.self, selection: $viewModel.selectedId) {
            TableColumn("Name") { entry in
                DocumentNameCell(summary: entry.summary)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Kind") { entry in
                StatusPill(entry.summary.kind.displayName)
            }
            .width(min: 96, ideal: 112, max: 124)
            TableColumn("Date") { entry in
                DateText(date: entry.summary.docDate)
            }
            .width(90)
            TableColumn("Amount") { entry in
                if let amount = entry.summary.amountMinorUnits, let currency = entry.summary.currency {
                    // A document's amount, as stated on it: neither a gain nor a loss.
                    MoneyText(minorUnits: amount, currency: currency, role: .neutral, alignment: .trailing)
                } else {
                    Text("—").foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // A cap, so the room left over goes to the names.
            .width(min: 84, ideal: 96, max: 112)
            TableColumn(Text(Image(systemName: "link")).accessibilityLabel("Links")) { entry in
                DocumentLinksCell(count: entry.linkCount)
            }
            .width(34)
        } rows: {
            ForEach(viewModel.sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        TableRow(entry)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(section.title).fontWeight(.semibold).monospacedDigit()
                        Text(section.entries.count == 1 ? "1 document" : "\(section.entries.count) documents")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, ids.count == 1 {
                Button("Open") { actions.open(id) }
                Button("Show in Finder") { actions.showInFinder(id) }
                Divider()
                Button("Link to transaction…") { actions.link(id) }
                Divider()
                Button("Remove from Library…", role: .destructive) { actions.remove(id) }
            }
        } primaryAction: { ids in
            ids.forEach(actions.open)
        }
        .accessibilityLabel("Documents")
    }
}

/// A document's type glyph and name.
private struct DocumentNameCell: View {
    let summary: EvidenceDocumentSummary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: DocumentFormat.icon(summary.textStatus))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(summary.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(summary.displayName)
    }
}

/// How many records a document is linked to; a dashed circle in the "to do" colour when none.
private struct DocumentLinksCell: View {
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if count > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "link")
                    Text("\(count)").monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .help(count == 1 ? "Linked to 1 record" : "Linked to \(count) records")
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(theme.pending)
                    .help("Not linked yet")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 0 ? "Not linked" : (count == 1 ? "1 link" : "\(count) links"))
    }
}

/// The list's filters as chips (the Search screen's): kind, year, account, links and source
/// folder, then Reset — one row when they fit, else two.
private struct DocumentFilterBar: View {
    @ObservedObject var viewModel: DocumentsViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                firstChips
                secondChips
                reset
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    firstChips
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    secondChips
                    reset
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var firstChips: some View {
        FilterPickerChip("All kinds", name: "Kind", all: DocumentKind?.none, selection: $viewModel.filter.kind,
                         options: DocumentKind.byDisplayName.filter(viewModel.index.kinds.contains).map { (value: Optional($0), title: $0.displayName) })
        FilterPickerChip("All years", name: "Year", all: Int?.none, selection: $viewModel.filter.year,
                         options: viewModel.index.years.map { (value: Optional($0), title: String($0)) })
        FilterPickerChip("All accounts", name: "Account", all: Int64?.none, selection: $viewModel.filter.accountId,
                         options: viewModel.accounts.compactMap { account in account.id.map { (value: Optional($0), title: account.displayName) } })
    }

    @ViewBuilder
    private var secondChips: some View {
        FilterPickerChip("Linked or not", name: "Links", all: EvidenceDocumentSearch.LinkState.any, selection: $viewModel.filter.linkState,
                         options: [(value: .linked, title: "Linked"), (value: .unlinked, title: "Not linked")])
        if !viewModel.sourceFolders.isEmpty {
            FilterPickerChip("Any folder", name: "Folder", all: Int64?.none, selection: $viewModel.filter.sourceFolderId,
                             options: viewModel.sourceFolders.compactMap { folder in folder.id.map { (value: Optional($0), title: folder.name) } })
        }
    }

    @ViewBuilder
    private var reset: some View {
        if viewModel.filter.hasFilters {
            Button("Reset filters") { viewModel.resetFilters() }
                .buttonStyle(.link)
        }
    }
}

/// The detail while nothing is selected: the library at a glance — its figures, documents by
/// kind, and the newest ones not linked to anything yet (click one to open it) — with Add
/// documents…. An empty library gets the one thing to do.
private struct DocumentsOverview: View {
    @ObservedObject var viewModel: DocumentsViewModel
    let addDocuments: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        // On the window's fill, as the inspector it gives way to (the split's second pane would
        // otherwise be the system's white in a theme with its own background).
        content.background(theme.windowFill)
    }

    @ViewBuilder
    private var content: some View {
        let overview = viewModel.overview
        if overview.total == 0 {
            emptyLibrary
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                    Panel("Library", subtitle: "Select a document to see and link it") {
                        Button("Add documents…", action: addDocuments)
                            .buttonStyle(.borderedProminent).prominentTint()
                    } content: {
                        FigureStrip([
                            FigureTile(title: "Documents", value: .text("\(overview.total)")),
                            FigureTile(title: "Linked", value: .text("\(overview.linked)")),
                            FigureTile(title: "Not linked", value: .text("\(overview.unlinked)"),
                                       caption: overview.unlinked == 0 ? "All linked" : "Waiting for a record",
                                       captionIsWarning: overview.unlinked > 0),
                            FigureTile(title: "Image only", value: .text("\(overview.imageOnly)"),
                                       caption: overview.imageOnly == 0 ? nil : "Check their details by eye")
                        ])
                    }
                    TwoUpRow {
                        Panel("By kind", fillsHeight: true) {
                            BreakdownBars(counts: overview.byKind.map { BreakdownItem($0.kind.displayName, count: $0.count, id: $0.kind.rawValue) },
                                          maxItems: 10, otherLabel: "Other kinds")
                        }
                    } second: {
                        Panel("Not linked yet", subtitle: overview.unlinked > overview.recentUnlinked.count
                              ? "The \(overview.recentUnlinked.count) added last of \(overview.unlinked)" : nil, fillsHeight: true) {
                            if overview.unlinked > 0 {
                                Button("Show all ›") { viewModel.filter.linkState = .unlinked }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        } content: {
                            unlinkedList(overview.recentUnlinked)
                        }
                    }
                }
                .padding(ScreenMetrics.padding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func unlinkedList(_ entries: [EvidenceDocumentSearch.Entry]) -> some View {
        if entries.isEmpty {
            Label("Every document is linked to a record.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    Button { viewModel.selectedId = entry.id } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                DocumentNameCell(summary: entry.summary)
                                Text(entry.summary.kind.displayName)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    .padding(.leading, 21)
                            }
                            Spacer(minLength: 8)
                            DateText(date: entry.summary.docDate, font: .callout)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(entry.summary.displayName)")
                }
            }
        }
    }

    private var emptyLibrary: some View {
        EmptyState(systemImage: "doc.on.doc", title: "No documents yet",
                   message: "Add receipts, notices and statements, or drop them on the list. Budget keeps its own copy; your files aren't changed.") {
            Button("Add documents…", action: addDocuments)
                .buttonStyle(.borderedProminent).prominentTint()
        }
        .fillingScreen()
        .padding(ScreenMetrics.padding)
    }
}
