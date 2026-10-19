// App/Settings/EvidenceSourcesSettings.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore

/// Settings ▸ Evidence: the folders the app scans for evidence (spec 2026-10-16 §3) — add,
/// remove, scan now, with each folder's last scan and counts. Scans only read the folders;
/// what a scan found is reviewed and accepted from the Documents screen (Review a folder).
struct EvidenceSourcesSettings: View {
    @ObservedObject private var current = AppEnvironment.Current.shared

    var body: some View {
        if let environment = current.environment {
            EvidenceSourcesList(model: EvidenceSourcesModel(scanner: SourceFolderScanner(library: environment.evidenceLibrary)))
        } else {
            ContentUnavailableView("Budget isn't open", systemImage: "folder.badge.questionmark",
                                   description: Text("Open the Budget window to manage evidence folders."))
                .frame(height: 300)
        }
    }
}

@MainActor
final class EvidenceSourcesModel: ObservableObject {
    struct Scanning: Equatable {
        var folderId: Int64
        var progress: SourceFolderScanner.Progress?
    }

    let scanner: SourceFolderScanner
    @Published private(set) var folders: [SourceFolder] = []
    @Published private(set) var summaries: [Int64: SourceFolderScanner.Summary] = [:]
    /// This session's latest scan of each folder, for the counts the database doesn't keep
    /// (not downloaded, unreadable).
    @Published private(set) var results: [Int64: SourceFolderScanner.ScanResult] = [:]
    @Published private(set) var scanning: Scanning?
    @Published var errorMessage: String?
    private var scanTask: Task<Void, Never>?

    init(scanner: SourceFolderScanner) {
        self.scanner = scanner
        reload()
    }

    func reload() {
        do {
            folders = try scanner.sourceFolders()
            summaries = try scanner.summaries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try scanner.register(url)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func remove(_ folder: SourceFolder) {
        guard let id = folder.id else { return }
        if scanning?.folderId == id { cancelScan() }
        do {
            try scanner.removeSourceFolder(id)
            results[id] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func scan(_ folder: SourceFolder) {
        guard scanning == nil, let id = folder.id else { return }
        scanning = Scanning(folderId: id)
        errorMessage = nil
        let scanner = scanner
        // Held only while the scan runs.
        let report: @Sendable (SourceFolderScanner.Progress) -> Void = { progress in
            Task { @MainActor in self.showProgress(progress, folderId: id) }
        }
        scanTask = Task { [weak self] in
            let detached = Task.detached(priority: .userInitiated) { () -> Result<SourceFolderScanner.ScanResult, Error> in
                // Counts only: new files are analysed when they're reviewed (Documents).
                Result { try scanner.scan(folder, options: .init(analyzeNewFiles: false), progress: report) }
            }
            let outcome = await withTaskCancellationHandler { await detached.value } onCancel: { detached.cancel() }
            guard let self else { return }
            self.scanning = nil
            switch outcome {
            case .success(let result): self.results[id] = result
            case .failure(is CancellationError): break
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
            self.reload()
        }
    }

    private func showProgress(_ progress: SourceFolderScanner.Progress, folderId: Int64) {
        guard scanning?.folderId == folderId else { return }
        scanning?.progress = progress
    }

    func cancelScan() {
        scanTask?.cancel()
    }
}

private struct EvidenceSourcesList: View {
    @StateObject var model: EvidenceSourcesModel
    @Environment(\.theme) private var theme
    @State private var choosingFolder = false
    @State private var folderToRemove: SourceFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folders Budget looks in for receipts, notices and statements. Scanning only reads them; nothing in them is moved or changed. Review what a scan found from the Documents screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                if model.folders.isEmpty {
                    Text("No folders yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.folders) { folder in
                    row(folder)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 300)

            HStack {
                Button("Add Folder…") { choosingFolder = true }
                Spacer()
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(theme.expense)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 8)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): model.add(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Remove \(folderToRemove?.name ?? "folder")?", isPresented: Binding(
            get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }
        ), presenting: folderToRemove) { folder in
            Button("Remove", role: .destructive) { model.remove(folder) }
        } message: { _ in
            Text("Budget stops scanning it. Documents already added from it stay in the library, and the folder itself isn't touched.")
        }
    }

    private func row(_ folder: SourceFolder) -> some View {
        let id = folder.id ?? -1
        let isScanning = model.scanning?.folderId == id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(theme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).fontWeight(.medium)
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                if isScanning {
                    scanProgress(model.scanning?.progress)
                } else {
                    Text(status(folder))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isScanning {
                Button("Cancel") { model.cancelScan() }
            } else {
                Button("Scan Now") { model.scan(folder) }
                    .disabled(model.scanning != nil)
            }
            Button {
                folderToRemove = folder
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove \(folder.name)")
            .accessibilityLabel("Remove \(folder.name)")
        }
        .padding(.vertical, 3)
    }

    private func scanProgress(_ progress: SourceFolderScanner.Progress?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let progress, progress.phase == .reading, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                // The count stays whole; the file's path truncates.
                HStack(spacing: 0) {
                    Text("Reading \(progress.completed) of \(progress.total)").figureText()
                    if let path = progress.currentPath {
                        Text(" · \(path)").lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear)
                Text(progress.map { "Listing files… \($0.completed)" } ?? "Listing files…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .figureText()
            }
        }
        .frame(maxWidth: 360)
    }

    /// "Last scanned 16 Oct 2026 at 19:30 · 120 files · 80 in library · 40 not in library · 1 changed · 2 missing".
    private func status(_ folder: SourceFolder) -> String {
        guard let lastScan = folder.lastScanAt, let id = folder.id else { return "Not scanned yet" }
        var parts = ["Last scanned \(lastScan.formatted(date: .abbreviated, time: .shortened))"]
        if let summary = model.summaries[id] {
            parts.append(Self.count(summary.fileCount, "file"))
            parts.append("\(summary.inLibraryCount) in library")
            parts.append("\(summary.notInLibraryCount) not in library")
            if summary.changedCount > 0 { parts.append("\(summary.changedCount) changed") }
            if summary.missingCount > 0 { parts.append("\(summary.missingCount) missing") }
        }
        if let result = model.results[id] {
            if !result.notDownloaded.isEmpty { parts.append("\(result.notDownloaded.count) not downloaded") }
            if !result.unreadable.isEmpty { parts.append("\(result.unreadable.count) unreadable") }
        }
        // Wraps between its figures, never inside one.
        return parts.map(\.unbroken).joined(separator: " · ")
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}
