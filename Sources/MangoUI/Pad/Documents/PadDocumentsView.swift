import SwiftUI
import BudgetCore

/// Documents on the iPad: the library (search, All / Unlinked, grouped by kind) with the selected document in the shared
/// document panel on the right (`DocumentPanel`: thumbnail, full view, details). With Edit on Documents the panel's own
/// block offers Change kind…, Link to… and each link's Unlink (`PadDocumentActions`); a refusal shows under what it was
/// made on. Nothing changes until an explicit button is pressed.
struct PadDocumentsView: View {
    @ObservedObject var model: PadDocumentsModel
    @ObservedObject var actions: PadDocumentActions
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    @Environment(\.phoneTheme) private var theme
    @State private var choice: PadChoiceRequest?
    @State private var kindEditor: KindEditor?

    var body: some View {
        NavigationStack {
            PadPageInsetReading { inset in list(inset: inset) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background)
                .documentPanel(selection: $model.selectedId) { documentId in
                    if let document = model.all.first(where: { $0.id == documentId }) { panelBlock(document) }
                }
            .padPage("Documents") {
                PadSearchField(text: $model.query, prompt: "Search documents")
            }
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await model.reload()
            await write.refresh()
        }
        .sheet(item: $choice) { PadChoiceSheet(request: $0) }
        .sheet(item: $kindEditor) { editor in
            PadKindSheet(editor: editor, catalog: model.catalog, warning: actions.kindWarning) { kind in
                await actions.changeKind(documentId: editor.documentId, to: kind)
            }
        }
    }

    private func list(inset: CGFloat) -> some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $model.filter) {
                ForEach(PadDocumentsModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset).padding(.top, MangoSpacing.xs)
            let groups = model.groups
            if groups.isEmpty {
                EmptyState(symbol: "folder", title: model.all.isEmpty ? "No documents" : "Nothing matches",
                           message: model.all.isEmpty ? "Documents appear here once the Mac has shared them." : "Try another search or filter.")
                    .padding(.top, 40)
                Spacer()
            } else {
                List(selection: $model.selectedId) {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.documents) { document in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.displayName).lineLimit(2).truncationMode(.middle)
                                    Text(PhoneDateFormat.day(document.docDate)).mangoFont(.footnote).foregroundStyle(.secondary)
                                }
                                .tag(document.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .contentMargins(.horizontal, inset - MangoSpacing.m, for: .scrollContent)
            }
        }
    }

    /// Documents' own block under the panel's details: the view-only note, the edits (Change kind…, Link to…), a
    /// refusal under the document, and each link with its Unlink (a refusal under the link).
    @ViewBuilder
    private func panelBlock(_ document: EvidenceDocumentSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PadWriteNotices(write: write)
            if actions.canEdit {
                Card(title: "Edit") {
                    HStack(spacing: 8) {
                        Button("Change kind…") { kindEditor = KindEditor(documentId: document.id, name: document.displayName, kind: document.kindRef) }
                        Button("Link to…") { linkTo(document) }
                    }
                    .buttonStyle(.pad(.secondary))
                    PadRefusalBanner(message: write.message(for: PadDocumentActions.documentRow(document.id)))
                    ForEach(model.links) { line in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(line.title.figuresUnbroken)
                                    .lineLimit(2).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Unlink") { Task { await actions.unlink(documentId: document.id, line) } }
                                    .buttonStyle(.pad(.destructive, size: .small))
                                    .accessibilityLabel("Unlink \(line.title)")
                            }
                            PadRefusalBanner(message: write.message(for: PadDocumentActions.linkRow(line.id)))
                        }
                    }
                }
            }
        }
    }

    private func linkTo(_ document: EvidenceDocumentSummary) {
        Task {
            let choices = await actions.linkChoices(for: document.id)
            choice = PadChoiceRequest(title: "Link to…", button: "Link", empty: "No transaction looks like this document's. Link it on the Mac.",
                                      currency: document.currency ?? .eur, choices: choices) { transactionId in
                await actions.link(documentId: document.id, transactionId: transactionId)
            }
        }
    }
}

/// The document whose kind is being changed.
struct KindEditor: Identifiable {
    let documentId: Int64
    let name: String
    let kind: DocumentKindRef
    var id: Int64 { documentId }
}

/// Change kind…: the built-in kinds by name, then the custom kinds (`DocumentKindCatalog.all`), the multi-link warning above them, and Save. Nothing
/// is written until Save.
struct PadKindSheet: View {
    let editor: KindEditor
    let catalog: DocumentKindCatalog
    let warning: String?
    let save: (DocumentKindRef) async -> Bool
    @State private var kind: DocumentKindRef?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let warning {
                    Section { Label(warning, systemImage: "link").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
                Section {
                    Picker("Kind", selection: Binding(get: { kind ?? editor.kind }, set: { kind = $0 })) {
                        ForEach(catalog.all, id: \.self) { Text(catalog.displayName($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text(editor.name)
                }
            }.padFormChrome()
            .navigationTitle("Change kind")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { PadIconButton(systemImage: "xmark", label: "Cancel") { dismiss() } }.padFlatToolbarItem()
                ToolbarItem(placement: .confirmationAction) {
                    PadIconButton(systemImage: "checkmark", label: "Save", prominent: true) {
                        guard let kind else { return }
                        Task {
                            _ = await save(kind)
                            dismiss()
                        }
                    }
                    .disabled(kind == nil || kind == editor.kind)
                }.padFlatToolbarItem()
            }
        }
    }
}
