// App/Documents/DocumentKindsSheet.swift
import SwiftUI
import BudgetCore

/// Documents ▸ Kinds… (spec 2026-10-24 §2): the kinds the user made, with their areas and document
/// counts. Rename (name and area) and Merge into… (a built-in kind or another of theirs) are staged
/// (`CustomKindsDraft`) and applied together on Save in one write (`CustomDocumentKinds.save`),
/// which also renames the documents, re-points learnt and evidence rules; Cancel discards them. A
/// Save that would change a filed return is refused whole, the years and documents said in the sheet.
struct DocumentKindsSheet: View {
    @ObservedObject var viewModel: DocumentsViewModel
    @Environment(\.dismiss) private var dismiss
    /// The custom kinds as they are now: when they change (synced, made by an import), the table is read again, staged edits kept.
    @Environment(\.documentKinds) private var kinds
    /// Cancel with staged edits: "Discard changes?".
    @State private var confirmingDiscard = false
    @State private var draft: CustomKindsDraft?
    /// The kind whose rename or merge is being edited under the table.
    @State private var editing: Editing?
    @State private var error: String?
    @State private var saving = false

    struct Editing: Equatable {
        enum Mode { case rename, merge }
        var kindId: Int64
        var mode: Mode
        var name: String
        var area: DocumentArea
        var target: DocumentKindRef?
    }

    /// `initial`/`editing`/`error`: a state to open on (the snapshot harness); normally read on appear.
    init(viewModel: DocumentsViewModel, initial: CustomKindsDraft? = nil, editing: Editing? = nil, error: String? = nil) {
        self.viewModel = viewModel
        _draft = State(initialValue: initial)
        _editing = State(initialValue: editing)
        _error = State(initialValue: error)
    }

    var body: some View {
        SheetScaffold(title: "Kinds",
                      subtitle: "The kinds you made while importing. Renames and merges apply together when you save; built-in kinds can't be changed.",
                      error: error ?? draft?.problem, width: SheetMetrics.listWidth, onCancel: cancel,
                      primary: SheetAction(saving ? "Saving…" : "Save", isEnabled: draft?.canSave == true && editing == nil && !saving) { save() }) {
            if let draft {
                if draft.rows.isEmpty {
                    SheetEmptyState(systemImage: "tag", title: "No kinds of your own yet",
                                    message: "Choose New kind… in an import's kind menu to make one.", minHeight: 200)
                } else {
                    ScrollView {
                        DataTable(columns: columns(draft), rows: draft.rows)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .sheetListFrame()
                    if let editing {
                        editor(editing, draft: draft)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task {
            guard draft == nil else { return }
            await reload()
        }
        .onChange(of: kinds.customKinds) { Task { await reload() } }
        .onChange(of: draft) { error = nil }
        .interactiveDismissDisabled(draft?.hasChanges == true)
        .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The renames and merges you staged aren't saved.")
        }
    }

    /// Reads the kinds (again), keeping what's staged (`CustomKindsDraft.refreshed`).
    private func reload() async {
        switch await viewModel.loadKinds() {
        case .success(let rows): draft = draft?.refreshed(rows: rows) ?? CustomKindsDraft(rows: rows)
        case .failure(let failure): error = "Couldn't read the kinds: \(failure.localizedDescription)"
        }
        if let state = editing, draft?.rows.contains(where: { $0.id == state.kindId }) != true { editing = nil }
    }

    private func cancel() {
        if draft?.hasChanges == true { confirmingDiscard = true } else { dismiss() }
    }

    // MARK: Table

    private func columns(_ draft: CustomKindsDraft) -> [DataTableColumn<CustomKindRow>] {
        [
            .text("Name", { draft.name(of: $0.id) }, detail: { draft.status(of: $0.id) }),
            .text("Area", width: .fit, { draft.mergeTarget(of: $0.id) == nil ? draft.area(of: $0.id).libraryArea : "—" }),
            DataTableColumn("Documents", alignment: .trailing, width: .fit, accessibilityValue: { Self.documents($0.documents) }) { row, _ in
                Text("\(row.documents)").monospacedDigit().figureText()
            },
            .actions { row in
                var actions = [
                    DataTableAction("Rename…", systemImage: "pencil", inline: true) {
                        editing = Editing(kindId: row.id, mode: .rename, name: draft.name(of: row.id), area: draft.area(of: row.id))
                    },
                    DataTableAction("Merge into…", systemImage: "arrow.triangle.merge", inline: true) {
                        editing = Editing(kindId: row.id, mode: .merge, name: row.name, area: row.area,
                                          target: draft.mergeTarget(of: row.id) ?? draft.mergeTargets(for: row.id).first?.ref)
                    }
                ]
                if draft.status(of: row.id) != nil || draft.mergeTarget(of: row.id) != nil {
                    actions.append(DataTableAction("Undo this change", systemImage: "arrow.uturn.backward", inline: true) {
                        self.draft?.revert(row.id)
                        if editing?.kindId == row.id { editing = nil }
                    })
                }
                return actions
            }
        ]
    }

    private static func documents(_ count: Int) -> String { count == 1 ? "1 document" : "\(count) documents" }

    // MARK: Editor

    /// Under the table: the kind's new name and area, or the kind to merge it into, then Apply
    /// (staged: nothing is written before Save) or Cancel.
    private func editor(_ state: Editing, draft: CustomKindsDraft) -> some View {
        let binding = Binding<Editing>(get: { editing ?? state }, set: { editing = $0 })
        let original = draft.rows.first { $0.id == state.kindId }
        return Panel(state.mode == .rename ? "Rename “\(original?.name ?? "")”" : "Merge “\(original?.name ?? "")” into…", padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SheetForm {
                    switch state.mode {
                    case .rename:
                        LabeledContent("Name") {
                            TextField("Name", text: binding.name)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Area") {
                            Picker("Area", selection: binding.area) {
                                ForEach(DocumentArea.allCases, id: \.self) { Text($0.libraryArea).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    case .merge:
                        LabeledContent("Into") {
                            Picker("Into", selection: binding.target) {
                                ForEach(draft.mergeTargets(for: state.kindId), id: \.ref) { target in
                                    Text(target.label).tag(Optional(target.ref))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .sheetFieldNote(mergeNote(original))
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }
                    Button("Apply") { apply(state.kindId) }
                        .disabled(state.mode == .merge && state.target == nil)
                }
                .controlSize(.small)
            }
        }
    }

    /// Why Save was refused; for a filed year, with the staged merge(s) to undo.
    static func refusal(_ failure: Error, draft: CustomKindsDraft) -> String {
        guard case .changesFiledYear = failure as? CustomDocumentKinds.Failure, let guidance = draft.refusalGuidance else {
            return failure.localizedDescription
        }
        return failure.localizedDescription + " " + guidance
    }

    private func mergeNote(_ row: CustomKindRow?) -> String {
        let count = row?.documents ?? 0
        let documents = count == 0 ? "Its learnt and evidence rules follow" : "Its \(Self.documents(count)), learnt and evidence rules follow"
        return "\(documents); the kind goes. Applied when you save."
    }

    private func apply(_ id: Int64) {
        guard let state = editing, state.kindId == id else { return }
        switch state.mode {
        case .rename: draft?.rename(id, name: state.name, area: state.area)
        case .merge: if let target = state.target { draft?.merge(id, into: target) }
        }
        editing = nil
    }

    private func save() {
        guard let draft, draft.canSave else { return }
        saving = true
        Task {
            let result = await viewModel.saveKinds(draft.edits)
            saving = false
            switch result {
            case .success(let saved):
                viewModel.infoMessage = CustomKindsDraft.savedMessage(saved)
                dismiss()
            case .failure(let failure):
                // A filed year that would move (years and documents named, and the merge to undo), a name taken
                // meanwhile…: nothing was written.
                error = Self.refusal(failure, draft: draft)
            }
        }
    }
}
