import SwiftUI
import BudgetCore

/// "Everything is in": the totals, where it landed, and Done; below it Undo import (statement rows only).
struct PhoneImportSummaryView: View {
    @Bindable var model: PhoneImportModel
    let onDone: () -> Void
    var onOpenAccount: ((Int64) -> Void)?
    var onReviewUncategorised: (() -> Void)?
    @Binding var confirmingUndo: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.phoneTheme) private var theme

    private var totals: PhoneImportBatch.Totals { model.batch.totals }
    private var rows: Int { totals.newRows }
    private var canUndo: Bool { !model.batch.undoRunIds.isEmpty && model.statementsCanUndo }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.m) {
                    heading
                    tiles
                    landed
                    skipped
                    if model.isUndone { InlineBanner(tone: .neutral, text: "Import undone: the rows are removed. Linked documents stay saved.") }
                }
                .padding(MangoSpacing.m)
            }
            bottom
        }
        .alert("Undo didn’t go through", isPresented: Binding(get: { model.undoProblem != nil }, set: { if !$0 { model.undoProblem = nil } })) {
            Button("OK", role: .cancel) { model.undoProblem = nil }
        } message: {
            Text(model.undoProblem ?? "")
        }
        .confirmationDialog(PhoneImportCopy.undoConfirmTitle, isPresented: $confirmingUndo, titleVisibility: .visible) {
            Button(PadStatementImportCopy.undo, role: .destructive) { Task { await model.undoImport() } }
            Button(PhoneImportCopy.cancel, role: .cancel) {}
        } message: {
            Text(PhoneImportBatchCopy.undoNote(rows: rows))
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: MangoSpacing.xs) {
            Image(systemName: "checkmark.circle.fill").mangoFont(.largeTitle).foregroundStyle(theme.income).accessibilityHidden(true)
            Text(model.batch.files.isEmpty ? "Nothing to import" : PhoneImportBatchCopy.title)
                .mangoFont(.title2, weight: .bold).accessibilityAddTraits(.isHeader)
        }
    }

    private var tiles: some View {
        let layout = dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: MangoSpacing.tile))
            : AnyLayout(HStackLayout(spacing: MangoSpacing.tile))
        return layout {
            ImportCountTile(count: totals.newRows, caption: totals.newRows == 1 ? "new row" : "new rows")
            ImportCountTile(count: totals.alreadyInMango, caption: "already in Mango")
            if totals.documentsSaved > 0 {
                ImportCountTile(count: totals.documentsLinked, caption: totals.documentsLinked == 1 ? "document linked" : "documents linked")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var landed: some View {
        let accounts = model.batch.accountsTouched
        let documents = model.batch.documentsSaved
        if !accounts.isEmpty || !documents.isEmpty || model.uncategorised > 0 {
            Card(title: "Where it landed") {
                ForEach(Array(accounts.enumerated()), id: \.offset) { _, line in
                    landedRow(title: line.name ?? "Account", detail: PhoneImportBatchCopy.newRows(line.rows), symbol: "building.columns") {
                        if let id = line.accountId { onOpenAccount?(id) }
                    }
                }
                ForEach(Array(documents.enumerated()), id: \.offset) { _, document in
                    landedRow(title: document.title, detail: document.linked ? "Saved and linked" : "Saved", symbol: "doc.text") {}
                }
                if model.uncategorised > 0 {
                    landedRow(title: PhoneImportBatchCopy.review(uncategorised: model.uncategorised), detail: nil, symbol: "tray.full") {
                        onReviewUncategorised?()
                    }
                }
            }
        }
    }

    private func landedRow(title: String, detail: String?, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MangoSpacing.s) {
                Image(systemName: symbol).foregroundStyle(theme.accent).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).mangoFont(.body).lineLimit(1).truncationMode(.middle)
                    if let detail { Text(detail.figuresUnbroken).mangoFont(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").mangoFont(.footnote, weight: .semibold).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var skipped: some View {
        let files = model.batch.files.filter {
            switch $0.outcome {
            case .notImported, .cantRead, .sentToMac: true
            default: false
            }
        }
        if !files.isEmpty {
            Card(title: PhoneImportCopy.notImported) {
                ForEach(files) { file in
                    HStack(spacing: MangoSpacing.s) {
                        Text(file.name).mangoFont(.body).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: MangoSpacing.xs)
                        Text(file.outcome.settledWords).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var bottom: some View {
        ImportBottomBar {
            Button(PhoneImportCopy.done, action: onDone).buttonStyle(ImportPrimaryButtonStyle())
            if canUndo && !model.isUndone {
                Button(PadStatementImportCopy.undo) { confirmingUndo = true }
                    .buttonStyle(ImportTextButtonStyle(destructive: true))
                    .disabled(model.isWorking)
                Text(PhoneImportBatchCopy.undoNote(rows: rows))
                    .mangoFont(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension PhoneImportModel {
    /// Whether Undo import is offered: the household's statement import is there to run it.
    var statementsCanUndo: Bool { canUndoRuns }
}
