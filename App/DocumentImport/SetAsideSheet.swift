// App/DocumentImport/SetAsideSheet.swift
import SwiftUI
import BudgetCore

/// "Files not imported" (spec 2026-10-24 §1): the files an import (or a discarded review) left out, each to keep
/// for later in Mango's own copy or copy to a folder. Nothing happens until a button is pressed; the originals
/// are only read. Files that can't be kept or copied are listed with why, never swallowed.
struct SetAsideSheet: View {
    /// What the sheet does with files (the import centre's, or a demo's).
    struct Actions {
        /// Keeps the files for later; throws when the waiting list can't be written.
        var keep: ([SetAsideFile]) async throws -> ImportWaitingList.KeepResult
        /// Copies the files to a folder the user chooses; nil when none was chosen.
        var copy: ([SetAsideFile]) async -> SetAsideCopyOutcome?
    }

    let files: [SetAsideFile]
    let actions: Actions
    /// Closes the sheet (a discarding review then closes).
    let done: () -> Void

    private enum Done: Hashable { case kept, copied }

    @State private var results: [String: Set<Done>] = [:]
    @State private var failures: [ImportSetAsideFailure] = []
    @State private var error: String?
    @State private var isWorking = false

    static let title = "Files not imported"
    static let subtitle = "Mango can keep its own copy for later, or copy them to a folder. Your originals aren't touched."

    var body: some View {
        VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(Self.subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files, id: \.sha256) { file in
                        row(file)
                        if file.sha256 != files.last?.sha256 { Divider() }
                    }
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: files.count <= 5)
            .sheetListFrame()
            if !failures.isEmpty {
                InlineBanner(.warning, onDismiss: { failures = [] }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not done for \(failures.count) \(failures.count == 1 ? "file" : "files")").fontWeight(.medium)
                        ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                            Text("\(failure.fileName): \(failure.reason)").foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
            }
            if let error { SheetErrorText(error) }
            HStack(spacing: 8) {
                Button("Keep all for later") { keep(files) }
                    .disabled(isWorking || allKept)
                Button("Copy all to a folder…") { copy(files) }
                    .disabled(isWorking)
                if isWorking { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Spacer(minLength: 0)
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent).prominentTint()
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
            .padding(.top, 4)
        }
        .padding(SheetMetrics.padding)
        .frame(width: SheetMetrics.listWidth, alignment: .topLeading)
    }

    private var allKept: Bool { files.allSatisfy { results[$0.sha256.lowercased(), default: []].contains(.kept) } }

    private func row(_ file: SetAsideFile) -> some View {
        let done = results[file.sha256.lowercased(), default: []]
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName).lineLimit(1).truncationMode(.middle).help(file.fileName)
                Text(file.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(file.reason)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if done.contains(.kept) {
                StatusPill("Kept", tone: .positive)
            } else {
                Button("Keep for later") { keep([file]) }.controlSize(.small).disabled(isWorking)
            }
            if done.contains(.copied) {
                StatusPill("Copied", tone: .positive)
            } else {
                Button("Copy to a folder…") { copy([file]) }.controlSize(.small).disabled(isWorking)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func keep(_ batch: [SetAsideFile]) {
        isWorking = true
        error = nil
        Task {
            do {
                let result = try await actions.keep(batch)
                let failed = Set(result.failed.map(\.sha256))
                for file in batch where !failed.contains(file.sha256.lowercased()) { results[file.sha256.lowercased(), default: []].insert(.kept) }
                failures = result.failed
            } catch {
                self.error = "Couldn't keep the files: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    private func copy(_ batch: [SetAsideFile]) {
        isWorking = true
        error = nil
        Task {
            if let outcome = await actions.copy(batch) {
                let failed = Set(outcome.failed.map(\.sha256))
                for file in batch where !failed.contains(file.sha256.lowercased()) { results[file.sha256.lowercased(), default: []].insert(.copied) }
                failures = outcome.failed
            }
            isWorking = false
        }
    }
}

extension SetAsideSheet.Actions {
    /// The import centre's own actions.
    @MainActor
    static func of(_ center: ImportCenterModel) -> Self {
        Self(keep: { try await center.keepForLater($0) }, copy: { await center.copyToFolder($0) })
    }
}
