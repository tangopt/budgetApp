// App/DocumentImport/ImportWaitingPanel.swift
import SwiftUI
import BudgetCore

/// "Waiting for later" (spec 2026-10-24 §1): the files kept after an import, each with when it was kept and
/// why it was left out — or, once the recognisers know it, what it is now ("Now recognised as …"). A row
/// can be imported, copied to a folder or discarded (Mango deletes its own copy only, after asking);
/// the header imports every file the recognisers now know, or all of them.
struct ImportWaitingPanel: View {
    @ObservedObject var center: ImportCenterModel

    @State private var discarding: ImportWaitingFile?
    @State private var notice: String?
    @State private var failures: [ImportSetAsideFailure] = []
    @State private var isWorking = false

    private var rows: [ImportWaitingFile] { center.waiting }
    private var suggested: [ImportWaitingFile] { rows.filter { $0.suggestion != nil } }

    /// The most rows shown before the table scrolls: the history keeps its room at 1100×700.
    static let maxVisibleRows = 4

    var body: some View {
        Panel("Waiting for later", subtitle: rows.count == 1 ? "1 file" : "\(rows.count) files", accessory: {
            HStack(spacing: 8) {
                if !suggested.isEmpty {
                    Button("Import suggested (\(suggested.count))") { importFiles(suggested) }
                        .controlSize(.small).disabled(isWorking)
                }
                Button("Import all") { importFiles(rows) }
                    .controlSize(.small).disabled(isWorking || rows.isEmpty)
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                if let notice { InlineBanner(.info, notice, onDismiss: { self.notice = nil }) }
                if !failures.isEmpty {
                    InlineBanner(.warning, onDismiss: { failures = [] }) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                                Text("\(failure.fileName): \(failure.reason)").lineLimit(2).truncationMode(.middle)
                            }
                        }
                    }
                }
                ScrollView {
                    DataTable(columns: columns, rows: rows)
                        .cellsRebuilt(when: Busy(isWorking: isWorking, inReview: rows.map { center.isInOpenReview($0) }))
                }
                .frame(maxHeight: CGFloat(Self.maxVisibleRows) * 40 + 30)
                .fixedSize(horizontal: false, vertical: rows.count <= Self.maxVisibleRows)
            }
        }
        .confirmationDialog("Discard this file?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                            presenting: discarding) { file in
            Button("Discard", role: .destructive) { discard(file) }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("Mango deletes its copy. Your original, if you still have it, isn't touched.")
        }
    }

    private struct Busy: Equatable {
        var isWorking: Bool
        var inReview: [Bool]
    }

    private var columns: [DataTableColumn<ImportWaitingFile>] {
        [
            DataTableColumn("File", width: .fill(min: 170), accessibilityValue: { $0.originalFileName }) { file, _ in
                Text(file.originalFileName).lineLimit(1).truncationMode(.middle).help(file.originalFileName)
            },
            .date("Kept") { $0.keptAt },
            DataTableColumn("Why", width: .fill(min: 170), accessibilityValue: { $0.suggestion ?? $0.reason }) { file, _ in
                if let suggestion = file.suggestion {
                    StatusPill(suggestion, tone: .accent, help: "Left out because: \(file.reason)")
                } else {
                    Text(file.reason).lineLimit(1).truncationMode(.tail).help(file.reason)
                }
            },
            DataTableColumn("", alignment: .trailing) { file, kind in
                if kind == .row { actions(file) }
            }
        ]
    }

    private func actions(_ file: ImportWaitingFile) -> some View {
        HStack(spacing: 6) {
            Button("Import") { importFiles([file]) }
            Button("Copy to a folder…") { copy(file) }
            Button("Discard…") { discarding = file }
                .disabled(center.isInOpenReview(file))
                .help(center.isInOpenReview(file) ? "It's in the review that's open" : "Deletes Mango's copy")
        }
        .controlSize(.small)
        .disabled(isWorking)
        .fixedSize()
    }

    // MARK: Actions

    private func importFiles(_ files: [ImportWaitingFile]) {
        guard !files.isEmpty else { return }
        notice = nil
        failures = []
        if !center.importWaiting(files.compactMap(\.id)) {
            notice = files.count == 1 ? "Mango's copy of this file isn't here yet: it hasn't arrived from the household's other device."
                                      : "Mango's copies of these files aren't here yet: they haven't arrived from the household's other device."
        }
    }

    private func copy(_ file: ImportWaitingFile) {
        isWorking = true
        notice = nil
        Task {
            if let outcome = await center.copyToFolder(file) { failures = outcome.failed }
            isWorking = false
        }
    }

    private func discard(_ file: ImportWaitingFile) {
        guard let id = file.id else { return }
        isWorking = true
        Task {
            do {
                try await center.discardWaiting([id])
            } catch {
                failures = [ImportSetAsideFailure(fileName: file.originalFileName, reason: "Couldn't discard it: \(error.localizedDescription)")]
            }
            isWorking = false
        }
    }
}
