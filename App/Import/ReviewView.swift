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
                                            MoneyText(minorUnits: duplicate.amountMinorUnits)
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

            Table(viewModel.stagedRows) {
                TableColumn("Date") { row in Text(row.staged.parsed.date.formatted(date: .abbreviated, time: .omitted)) }
                TableColumn("Description") { row in Text(row.staged.parsed.rawDescription) }
                TableColumn("Amount") { row in MoneyText(minorUnits: row.staged.parsed.amountMinorUnits) }
                TableColumn("Category") { row in
                    categoryPicker(for: row)
                }
                TableColumn("Source") { row in Text(row.staged.source.rawValue) }
            }

            if uncategorizedCount > 0 {
                Text("\(uncategorizedCount) transaction(s) will be saved as Uncategorized for you to assign later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Confirm all \(viewModel.stagedRows.count) transactions") {
                    // Errors (e.g. a database failure — the commit is all-or-nothing) are
                    // surfaced via viewModel.errorMessage instead of being swallowed.
                    if viewModel.commit() {
                        onCommitted()
                    }
                }
                .disabled(viewModel.stagedRows.isEmpty)
                .keyboardShortcut(.defaultAction)
                Button("Cancel import", role: .cancel) { viewModel.cancel() }
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
