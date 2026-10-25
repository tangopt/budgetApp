// App/DocumentImport/ImportHistoryView.swift
import SwiftUI
import BudgetCore

/// Nothing in progress: the last import's result (or why reading failed), how to start one,
/// and "Import history" — each confirmed import, newest first, with the selected one's
/// details docked beside it: what became of each file, the backup taken before it, and
/// "Undo import…" (asked first; refused, with what changed since, when it can't be undone).
struct ImportHistoryView: View {
    @ObservedObject var center: ImportCenterModel
    let pickFiles: () -> Void
    @State private var setAsideFiles: [SetAsideFile]?

    static let tableMinimumWidth: CGFloat = 400
    static let detailWidth: CGFloat = 340
    /// The table and the details side by side: the Imports screen's minimum with no review open.
    static let minimumWidth = tableMinimumWidth + ScreenMetrics.spacing + detailWidth

    private var selectedRun: ImportRun? {
        center.selectedRunId.flatMap { id in center.runs.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            switch center.phase {
            case .finished(let summary):
                InlineBanner(.success, "Imported: \(summary.text)" + (summary.backupPath == nil ? "" : ". The database was backed up first."),
                             onDismiss: center.discard)
            case .failed(let message):
                InlineBanner(.error, message, onDismiss: center.discard)
            default:
                EmptyView()
            }
            if center.runs.isEmpty, center.waiting.isEmpty, center.phase == .idle {
                EmptyState(systemImage: "tray.and.arrow.down", title: "Import documents",
                           message: "Drop files or folders anywhere in the window, or choose File ▸ Import… (⇧⌘I). Each file is recognised and placed for you to review; nothing is saved until you confirm the import.") {
                    Button("Import…", action: pickFiles).buttonStyle(.borderedProminent)
                }
                .fillingScreen()
            } else {
                HStack(spacing: 8) {
                    Text("Drop files or folders anywhere in the window to import them")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Import…", action: pickFiles).buttonStyle(.borderedProminent)
                }
                if !center.waiting.isEmpty {
                    ImportWaitingPanel(center: center)
                }
                HStack(alignment: .top, spacing: ScreenMetrics.spacing) {
                    ScrollView {
                        ImportHistoryTable(runs: center.runs, selectedRunId: $center.selectedRunId)
                    }
                    .frame(minWidth: Self.tableMinimumWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if let run = selectedRun, let runId = run.id {
                        ImportRunDetailPanel(run: run, files: center.runFiles[runId] ?? [],
                                             confirmedBy: run.appUserId.flatMap { center.userNames[$0] },
                                             conflicts: center.undoRefusals[runId] ?? [],
                                             undo: { _ = try await center.undo(runId) },
                                             dismissConflicts: { center.dismissUndoRefusal(runId) },
                                             close: { center.selectedRunId = nil })
                            // Another run starts with its own confirmation and refusal state.
                            .id(runId)
                            .frame(width: Self.detailWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: offerSetAside)
        .onChange(of: finishedRunId) { offerSetAside() }
        .sheet(isPresented: Binding(get: { setAsideFiles != nil }, set: { if !$0 { setAsideFiles = nil } })) {
            SetAsideSheet(files: setAsideFiles ?? [], actions: .of(center), done: { setAsideFiles = nil })
        }
    }

    private var finishedRunId: Int64? {
        if case .finished(let summary) = center.phase { return summary.runId }
        return nil
    }

    /// A finished run that left files unimported opens the sheet, once (the session remembers the run it was offered for).
    private func offerSetAside() {
        let offer = center.takeSetAsideOffer()
        if !offer.isEmpty { setAsideFiles = offer }
    }
}

// MARK: The table

/// "Import history": each confirmed import, newest first; a row opens its details.
struct ImportHistoryTable: View {
    let runs: [ImportRun]
    @Binding var selectedRunId: Int64?

    var body: some View {
        Panel("Import history") {
            if runs.isEmpty {
                Text("No imports yet: drop files or folders here to start one.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                DataTable(columns: Self.columns, rows: runs, onSelect: { run in
                    selectedRunId = selectedRunId == run.id ? nil : run.id
                }, selectedId: selectedRunId)
                .cellsRebuilt(when: 0)
            }
        }
    }

    private static var columns: [DataTableColumn<ImportRun>] {
        [
            .date("Date") { $0.confirmedAt },
            .text("Entry point", width: .fit) { $0.entryPoint },
            // A sentence of figures: it wraps (the figures in it stay whole) rather than truncate at 1100×700.
            DataTableColumn("Summary", width: .fill(min: 160), accessibilityValue: { [$0.summary, $0.undoSummary].compactMap { $0 }.joined(separator: ", ") }) { run, _ in
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.summary.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                    if let undo = run.undoSummary {
                        Text(undo.figuresUnbroken).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 3)
            },
            .status("") { run in
                run.undoneAt == nil ? nil : StatusPill("Undone", tone: .neutral, help: run.undoSummary)
            }
        ]
    }
}

// MARK: The details

/// The selected run, docked beside the history: when and from where, what became of each
/// file (with why), the backup taken first, and Undo import….
struct ImportRunDetailPanel: View {
    let run: ImportRun
    let files: [ImportRunFile]
    /// Who confirmed it (nil: unknown, or the user is gone).
    var confirmedBy: String?
    /// Why the last undo was refused (what changed since).
    let conflicts: [ImportUndoConflict]
    /// Undoes the run, or records why it can't be; throws when the run is gone or already undone.
    let undo: () async throws -> Void
    let dismissConflicts: () -> Void
    let close: () -> Void

    @State private var confirmingUndo = false
    @State private var isUndoing = false
    @State private var failure: String?

    var body: some View {
        Panel(padding: 12, fillsHeight: true) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if !conflicts.isEmpty {
                        InlineBanner(.warning, onDismiss: dismissConflicts) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.refusalTitle(conflicts.count).figuresUnbroken).fontWeight(.medium)
                                ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
                                    Text(conflict.message.figuresUnbroken).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if let failure {
                        InlineBanner(.error, failure, onDismiss: { self.failure = nil })
                    }
                    filesBlock
                    if let path = run.backupPath {
                        block("Backup") {
                            Text("The database was copied before this import to:")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(path).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled).help(path)
                        }
                    }
                    undoButton
                }
                .padding(.trailing, 4)
            }
        }
        .confirmationDialog("Undo this import?", isPresented: $confirmingUndo) {
            Button("Undo import", role: .destructive, action: performUndo)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It removes what it added and puts back what it changed.")
        }
    }

    /// "Can't undo: 2 things changed since".
    static func refusalTitle(_ count: Int) -> String {
        "Can't undo: \(count) thing\(count == 1 ? "" : "s") changed since"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.summary).font(.headline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    DateText(date: run.confirmedAt, font: .caption)
                    Text("· \(run.entryPoint)").font(.caption).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                if let confirmedBy {
                    Text("Confirmed by \(confirmedBy)").font(.caption).foregroundStyle(.secondary)
                }
                if run.undoneAt != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        StatusPill("Undone", tone: .neutral)
                        if let summary = run.undoSummary {
                            Text(summary.figuresUnbroken).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close the details")
                .accessibilityLabel("Close the details")
        }
    }

    private var filesBlock: some View {
        block(files.count == 1 ? "1 file" : "\(files.count) files") {
            if files.isEmpty {
                Text("No files recorded.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(file.fileName).lineLimit(1).truncationMode(.middle).help(file.fileName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        StatusPill(file.outcome.title, tone: file.outcome.tone)
                    }
                    if !file.detail.isEmpty {
                        Text(file.detail.figuresUnbroken).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var undoButton: some View {
        HStack(spacing: 8) {
            if run.undoneAt != nil {
                Button("Undone") {}
                    .disabled(true)
                    .help(run.undoSummary ?? "This import was undone")
            } else {
                Button("Undo import…") { confirmingUndo = true }
                    .disabled(isUndoing)
                    .help("Removes what this import added and puts back what it changed")
                if isUndoing {
                    ProgressView().controlSize(.small).accessibilityLabel("Undoing the import")
                }
            }
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
    }

    private func performUndo() {
        isUndoing = true
        dismissConflicts()
        failure = nil
        Task {
            do {
                try await undo()
            } catch ImportUndoError.alreadyUndone {
                failure = "This import was already undone."
            } catch ImportUndoError.runNotFound {
                failure = "This import is no longer in the history."
            } catch {
                failure = "Couldn't undo the import: \(error.localizedDescription)"
            }
            isUndoing = false
        }
    }
}

extension ImportFileOutcome {
    /// What became of a file, as its pill says.
    var title: String {
        switch self {
        case .filed: return "Filed"
        case .linked: return "Linked"
        case .recorded: return "Recorded"
        case .duplicate: return "Duplicate"
        case .leftOut: return "Left out"
        case .transactions: return "Transactions"
        }
    }

    var tone: StatusPill.Tone {
        switch self {
        case .filed, .linked, .recorded, .transactions: return .positive
        case .duplicate, .leftOut: return .neutral
        }
    }
}
