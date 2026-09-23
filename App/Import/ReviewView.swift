// App/Import/ReviewView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ReviewView: View {
    @ObservedObject var viewModel: ImportViewModel
    let categories: [Category]
    let onCommitted: () -> Void

    @State private var showUnparsed = true
    @State private var showDuplicates = false
    @State private var isForcing = false
    @State private var focusedRowId: UUID?
    @State private var showReady = false

    private var uncategorizedCount: Int {
        viewModel.stagedRows.filter { $0.chosenCategoryId == nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.unparsedLines.isEmpty {
                GroupBox {
                    DisclosureGroup(isExpanded: $showUnparsed) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("These lines couldn't be auto-parsed and were not imported. Enter them manually if they're real transactions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(viewModel.unparsedLines.enumerated()), id: \.offset) { _, line in
                                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                            Button("Dismiss") { viewModel.dismissUnparsedLines() }
                        }
                    } label: {
                        Label("\(viewModel.unparsedLines.count) line(s) couldn't be auto-parsed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !viewModel.duplicates.isEmpty {
                GroupBox {
                    DisclosureGroup(isExpanded: $showDuplicates) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Already imported for this account, so skipped. Import them anyway only if they're genuinely separate transactions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(viewModel.duplicates.enumerated()), id: \.offset) { _, duplicate in
                                        HStack {
                                            Text(duplicate.date.formatted(date: .abbreviated, time: .omitted))
                                            Text(duplicate.rawDescription)
                                            Spacer()
                                            MoneyText(minorUnits: duplicate.amountMinorUnits, font: .caption)
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                            .frame(maxHeight: 120)
                            HStack {
                                Button("Import anyway") {
                                    isForcing = true
                                    Task {
                                        await viewModel.forceImportDuplicates()
                                        isForcing = false
                                    }
                                }
                                .disabled(isForcing)
                                Button("Dismiss") { viewModel.dismissDuplicates() }
                            }
                        }
                    } label: {
                        Text("\(viewModel.duplicateCount) duplicate transaction(s) skipped")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            List(selection: $focusedRowId) {
                if !viewModel.needsAttentionRows.isEmpty {
                    Section("Needs your attention (\(viewModel.needsAttentionRows.count))") {
                        ForEach(viewModel.needsAttentionRows) { row in
                            reviewRow(row, showInlineConfirm: true).tag(row.id)
                        }
                    }
                }
                if !viewModel.readyRows.isEmpty {
                    DisclosureGroup("Ready to confirm (\(viewModel.readyRows.count))", isExpanded: $showReady) {
                        ForEach(viewModel.readyRows) { row in
                            reviewRow(row, showInlineConfirm: false).tag(row.id)
                        }
                    }
                }
            }
            .frame(minHeight: 240)
            .onKeyPress(.return) {
                guard let focusedRowId,
                      let row = viewModel.stagedRows.first(where: { $0.id == focusedRowId }),
                      row.chosenCategoryId != nil else { return .ignored }
                // Advance through rows in the order they're actually displayed (needs
                // attention first, then ready only if that group is expanded), computed
                // before confirmRow mutates stagedRows and so the two groupings.
                let visibleOrder = viewModel.needsAttentionRows + (showReady ? viewModel.readyRows : [])
                let remainingVisible = visibleOrder.filter { $0.id != focusedRowId }
                // On failure, keep focus on the row so its error and state stay put.
                guard viewModel.confirmRow(row) else { return .handled }
                self.focusedRowId = remainingVisible.first?.id
                return .handled
            }

            if uncategorizedCount > 0 {
                Text("\(uncategorizedCount) transaction(s) will be saved as Uncategorized for you to assign later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Button("Confirm \(viewModel.readyRows.count) ready") {
                    if viewModel.confirmReady() && viewModel.stagedRows.isEmpty {
                        onCommitted()
                    }
                }
                .disabled(viewModel.readyRows.isEmpty)
                .keyboardShortcut(.defaultAction)
                // The only way to commit rows with no category picked at all (they can't
                // use Confirm/Confirm-ready) — they're saved as Uncategorized to assign later.
                Button("Save \(viewModel.stagedRows.count) remaining as Uncategorized") {
                    if viewModel.saveRemainingAsUncategorized() { onCommitted() }
                }
                .disabled(viewModel.stagedRows.isEmpty)
                Button("Cancel import", role: .cancel) { viewModel.cancel() }
            }
        }
    }

    private func reviewRow(_ row: ReviewRow, showInlineConfirm: Bool) -> some View {
        HStack {
            ConfidenceDot(source: row.staged.source, confidence: row.staged.confidence)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.staged.parsed.rawDescription)
                Text(row.staged.parsed.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(minorUnits: row.staged.parsed.amountMinorUnits)
            categoryPicker(for: row).frame(width: 200)
            if showInlineConfirm {
                Button("Confirm") { _ = viewModel.confirmRow(row) }
                    .disabled(row.chosenCategoryId == nil)
            }
        }
    }

    private func categoryPicker(for row: ReviewRow) -> some View {
        let binding = Binding<Int64?>(
            get: { row.chosenCategoryId },
            set: { newValue in
                if let index = viewModel.stagedRows.firstIndex(where: { $0.id == row.id }) {
                    viewModel.stagedRows[index].chosenCategoryId = newValue
                }
            }
        )
        return Picker("", selection: binding) {
            Text("Uncategorized").tag(Int64?.none)
            ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
        }
        .labelsHidden()
    }
}
