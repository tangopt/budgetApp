// App/Documents/FolderReviewSheet.swift
import SwiftUI
import BudgetCore
import GRDB

/// Reviewing a source folder (spec 2026-10-16 §3): scans it (analysing the files not in the
/// library), then lists the new files with the transaction each may be evidence for — the
/// clear best matches ticked — for Add & link selected; changed files (add the new version,
/// whose links move to it, or keep as is); and missing files (for information).
/// The folder itself is only read.
@MainActor
final class FolderReviewModel: ObservableObject {
    enum Phase: Equatable {
        case scanning(SourceFolderScanner.Progress?)
        case ready
        case applying
        case failed(String)
    }

    /// A new file and what the user chose for it.
    struct NewItem: Identifiable {
        let file: SourceFolderScanner.ScannedFile
        var isSelected: Bool
        /// The transaction to link it to, nil for none.
        var transactionId: Int64?

        var id: String { file.relativePath }
    }

    let scanner: SourceFolderScanner
    let dbQueue: DatabaseQueue
    @Published private(set) var folder: SourceFolder
    @Published private(set) var phase: Phase = .scanning(nil)
    @Published private(set) var result: SourceFolderScanner.ScanResult?
    @Published var newItems: [NewItem] = []
    @Published private(set) var changed: [SourceFolderScanner.ScannedFile] = []
    /// The names of the documents changed files were in the library as.
    @Published private(set) var previousNames: [Int64: String] = [:]
    @Published private(set) var catalog: TransactionCatalog?
    @Published var errorMessage: String?
    @Published private(set) var summary: String?
    private var scanTask: Task<Void, Never>?

    init(folder: SourceFolder, scanner: SourceFolderScanner, dbQueue: DatabaseQueue) {
        self.folder = folder
        self.scanner = scanner
        self.dbQueue = dbQueue
    }

    var selectedCount: Int { newItems.filter(\.isSelected).count }

    func start() {
        guard scanTask == nil else { return }
        let scanner = scanner, folder = folder, dbQueue = dbQueue
        phase = .scanning(nil)
        let report: @Sendable (SourceFolderScanner.Progress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, case .scanning = self.phase else { return }
                self.phase = .scanning(progress)
            }
        }
        scanTask = Task { [weak self] in
            async let catalog = try? TransactionCatalog.load(dbQueue)
            let detached = Task.detached(priority: .userInitiated) { () -> Result<SourceFolderScanner.ScanResult, Error> in
                Result { try scanner.scan(folder, options: .init(analyzeNewFiles: true, suggestionLimit: 5), progress: report) }
            }
            let outcome = await withTaskCancellationHandler { await detached.value } onCancel: { detached.cancel() }
            let loaded = await catalog
            guard let self else { return }
            self.catalog = loaded
            switch outcome {
            case .success(let result): self.show(result)
            case .failure(is CancellationError): self.phase = .failed("The scan was cancelled.")
            case .failure(let error): self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
    }

    private func show(_ result: SourceFolderScanner.ScanResult) {
        self.result = result
        folder = result.folder
        newItems = result.new.map { file in
            let confident = EvidenceMatcher.confidentMatch(file.suggestions)
            return NewItem(file: file, isSelected: confident != nil, transactionId: confident?.transactionId)
        }
        changed = result.changed
        let ids = result.changed.compactMap(\.previousDocumentId)
        previousNames = (try? dbQueue.read { db in
            try EvidenceDocumentSummary.filter(keys: ids).fetchAll(db)
        }.reduce(into: [Int64: String]()) { $0[$1.id] = $1.displayName }) ?? [:]
        phase = .ready
    }

    /// Adds the ticked new files to the library and links each to its chosen transaction.
    func addSelected() {
        let chosen = newItems.filter(\.isSelected)
        guard !chosen.isEmpty, phase == .ready else { return }
        phase = .applying
        errorMessage = nil
        let scanner = scanner, folder = folder
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (done: Set<String>, linked: Int, failures: [String]) in
                var done = Set<String>(), linked = 0, failures: [String] = []
                for item in chosen {
                    do {
                        let added = try scanner.addToLibrary(item.file, from: folder)
                        done.insert(item.id)
                        if let transactionId = item.transactionId, let documentId = added.document.id {
                            try scanner.library.link(documentId, to: .transaction(transactionId))
                            linked += 1
                        }
                    } catch {
                        failures.append("\(item.file.relativePath): \(error.localizedDescription)")
                    }
                }
                return (done, linked, failures)
            }.value
            newItems.removeAll { outcome.done.contains($0.id) }
            let added = outcome.done.count
            summary = "Added \(added) document\(added == 1 ? "" : "s")" + (outcome.linked > 0 ? ", linked \(outcome.linked)." : ".")
            if !outcome.failures.isEmpty { errorMessage = "Couldn't add " + outcome.failures.joined(separator: "; ") }
            phase = .ready
        }
    }

    /// Adds the changed file's current content (off the main thread); the earlier version's
    /// links move to the new one, and the change is cleared. The earlier version stays in the
    /// library, unlinked.
    func addNewVersion(_ file: SourceFolderScanner.ScannedFile) {
        guard let folderId = folder.id, phase == .ready else { return }
        phase = .applying
        errorMessage = nil
        let scanner = scanner, folder = folder
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Int, Error> in
                Result {
                    let added = try scanner.addToLibrary(file, from: folder)
                    var moved = 0
                    if let previous = file.previousDocumentId, let current = added.document.id {
                        moved = try scanner.library.moveLinks(from: previous, to: current)
                    }
                    try scanner.acknowledgeChange(folderId: folderId, relativePath: file.relativePath)
                    return moved
                }
            }.value
            switch outcome {
            case .success(let moved):
                changed.removeAll { $0.relativePath == file.relativePath }
                summary = "Added the new version of \(file.relativePath)"
                    + (moved > 0 ? "; its \(moved) link\(moved == 1 ? "" : "s") moved to it." : ".")
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            phase = .ready
        }
    }

    /// Keeps the library as it is and stops reporting the change.
    func keep(_ file: SourceFolderScanner.ScannedFile) {
        guard let folderId = folder.id else { return }
        do {
            try scanner.acknowledgeChange(folderId: folderId, relativePath: file.relativePath)
            changed.removeAll { $0.relativePath == file.relativePath }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FolderReviewSheet: View {
    @StateObject private var model: FolderReviewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    init(folder: SourceFolder, scanner: SourceFolderScanner, dbQueue: DatabaseQueue) {
        _model = StateObject(wrappedValue: FolderReviewModel(folder: folder, scanner: scanner, dbQueue: dbQueue))
    }

    var body: some View {
        SheetScaffold(title: "Review “\(model.folder.name)”", subtitle: subtitle, error: model.errorMessage, width: 760,
                      cancelTitle: model.phase == .ready ? "Close" : "Cancel",
                      onCancel: {
                          model.cancel()
                          dismiss()
                      },
                      primary: SheetAction("Add & link selected (\(model.selectedCount))",
                                           isEnabled: model.phase == .ready && model.selectedCount > 0,
                                           action: model.addSelected)) {
            content
                .frame(height: 460)
        }
        .onAppear { model.start() }
    }

    private var subtitle: String {
        var parts = [model.folder.path]
        if let summary = model.summary { parts.append(summary) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .scanning(let progress):
            VStack(alignment: .leading, spacing: 6) {
                if let progress, progress.phase == .reading, progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    Text("Reading \(progress.completed) of \(progress.total)\(progress.currentPath.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text(progress.map { "Listing files… \($0.completed)" } ?? "Listing files…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("New files are read to propose their kind, date, amount and transaction. Nothing in the folder is changed.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        case .failed(let message):
            VStack(alignment: .leading) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(theme.expense)
                Spacer()
            }
        case .ready, .applying:
            lists
                .disabled(model.phase == .applying)
                .overlay {
                    if model.phase == .applying { ProgressView("Adding…") }
                }
        }
    }

    private var lists: some View {
        List {
            Section("New — not in the library (\(model.newItems.count))") {
                if model.newItems.isEmpty {
                    Text("Nothing new.").foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Select all") { setAll(true) }
                        Button("Select none") { setAll(false) }
                        Spacer()
                        Text("Ticked files are copied into the library; a chosen transaction is linked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                ForEach($model.newItems) { $item in
                    newRow($item)
                }
            }
            if !model.changed.isEmpty {
                Section("Changed since added (\(model.changed.count))") {
                    ForEach(model.changed, id: \.relativePath) { file in changedRow(file) }
                }
            }
            if let missing = model.result?.missing, !missing.isEmpty {
                Section("Missing from the folder (\(missing.count))") {
                    ForEach(missing, id: \.relativePath) { file in
                        HStack {
                            Text(file.relativePath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("Last seen \(file.lastSeenAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .help(file.documentId == nil ? "Not in the library" : "Its library copy is kept")
                    }
                }
            }
            if let result = model.result {
                Section {
                    Text(otherCounts(result)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func setAll(_ selected: Bool) {
        for index in model.newItems.indices { model.newItems[index].isSelected = selected }
    }

    private func newRow(_ item: Binding<FolderReviewModel.NewItem>) -> some View {
        let file = item.wrappedValue.file
        let metadata = file.analysis?.metadata
        return HStack(alignment: .top, spacing: 8) {
            Toggle(file.relativePath, isOn: item.isSelected)
                .labelsHidden()
                .accessibilityLabel("Add \(file.relativePath)")
            VStack(alignment: .leading, spacing: 3) {
                Text(file.relativePath).lineLimit(1).truncationMode(.middle).help(file.relativePath)
                Text(DocumentFormat.caption(kind: metadata?.kind ?? .other, date: metadata?.docDate,
                                            amountMinorUnits: metadata?.amountMinorUnits, currency: metadata?.currency)
                     + (file.analysis?.textStatus == .image ? " · image only" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                linkChoice(item)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func linkChoice(_ item: Binding<FolderReviewModel.NewItem>) -> some View {
        let file = item.wrappedValue.file
        if file.suggestions.isEmpty {
            Text("No matching transaction").font(.caption).foregroundStyle(.secondary)
        } else {
            let chosen = item.wrappedValue.transactionId.flatMap { id in file.suggestions.first { $0.transactionId == id } }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "link").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                Menu {
                    ForEach(file.suggestions, id: \.transactionId) { suggestion in
                        Button(menuTitle(suggestion)) {
                            item.wrappedValue.transactionId = suggestion.transactionId
                            item.wrappedValue.isSelected = true
                        }
                    }
                    Divider()
                    Button("Don't link") { item.wrappedValue.transactionId = nil }
                } label: {
                    Text(chosen.map(menuTitle) ?? "Don't link")
                }
                .fixedSize()
                .controlSize(.small)
                .accessibilityLabel("Transaction to link")
                if let chosen {
                    Text(chosen.reasons.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(chosen.reasons.joined(separator: "\n"))
                }
            }
        }
    }

    /// "31 Jan 2024 · COBR. REC. TOT 076 · −€1,234.56".
    private func menuTitle(_ suggestion: EvidenceMatcher.Suggestion) -> String {
        guard let info = model.catalog?.info(suggestion.transactionId) else { return "Transaction #\(suggestion.transactionId)" }
        return [info.transaction.date.formatted(date: .abbreviated, time: .omitted), info.transaction.rawDescription,
                Money.format(info.transaction.amountMinorUnits, currency: info.currency)].joined(separator: " · ")
    }

    private func changedRow(_ file: SourceFolderScanner.ScannedFile) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.relativePath).lineLimit(1).truncationMode(.middle).help(file.relativePath)
                Text("Before: " + (file.previousDocumentId.flatMap { model.previousNames[$0] } ?? "not in the library")
                     + (file.changeDetectedAt.map { " · change noticed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Now: \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)), modified \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
                     + (file.documentId != nil ? " · already in the library" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if file.documentId == nil {
                Button("Add new version") { model.addNewVersion(file) }
                    .help("Copy the current file into the library and move the earlier version's links to it (the earlier version stays, unlinked)")
            }
            Button("Keep as is") { model.keep(file) }
                .help("Stop reporting this change")
        }
        .controlSize(.small)
    }

    private func otherCounts(_ result: SourceFolderScanner.ScanResult) -> String {
        var parts = ["\(result.inLibrary.count) already in the library"]
        if !result.notDownloaded.isEmpty { parts.append("\(result.notDownloaded.count) not downloaded from iCloud (not read)") }
        if !result.unreadable.isEmpty { parts.append("\(result.unreadable.count) unreadable") }
        if !result.ignored.isEmpty { parts.append("\(result.ignored.count) ignored") }
        return parts.joined(separator: " · ")
    }
}
