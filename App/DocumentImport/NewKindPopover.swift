// App/DocumentImport/NewKindPopover.swift
import SwiftUI
import BudgetCore

extension EnvironmentValues {
    /// The kinds the review's chooser offers (`ImportSession.kindChoices`): the built-ins, the saved
    /// custom kinds, then the review's new ones. The preview sets it; the built-ins alone otherwise.
    @Entry var importKindChoices: [ImportKindChoice] = ImportKindChoice.choices(catalog: DocumentKindCatalog(customKinds: []), pending: [])
}

/// "New kind…" in the review's kind chooser (spec 2026-10-24 §2): a name and an area. Create files
/// the document as the new kind at once (it stays in the review until Confirm import saves it);
/// it is disabled while the name is empty or already a kind's, which is said beside the name.
struct NewKindPopover: View {
    let choices: [ImportKindChoice]
    let create: (String, DocumentArea) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var area: DocumentArea = .property
    @FocusState private var nameFocused: Bool
    @Environment(\.theme) private var theme

    /// `initialName`: a name to open with (the snapshot harness); normally empty.
    init(choices: [ImportKindChoice], initialName: String = "", create: @escaping (String, DocumentArea) -> Void,
         cancel: @escaping () -> Void) {
        self.choices = choices
        self.create = create
        self.cancel = cancel
        _name = State(initialValue: initialName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var taken: String? { ImportKindChoice.takenName(name, among: choices) }
    private var canCreate: Bool { !trimmed.isEmpty && taken == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New kind").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name, prompt: Text("e.g. Boiler service"))
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { if canCreate { create(trimmed, area) } }
                if let taken {
                    Text(ImportResolutionError.kindNameTaken(taken).localizedDescription)
                        .font(.caption).foregroundStyle(theme.expense)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Area", selection: $area) {
                    ForEach(DocumentArea.allCases, id: \.self) { Text($0.libraryArea).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Text("Where its documents are filed: the area in their names.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Saved when you confirm the import.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create(trimmed, area) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { nameFocused = true }
    }
}
