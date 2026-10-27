import SwiftUI
import BudgetCore

/// Documents on the iPad: the library on the left (search, All / Unlinked, grouped by kind), the selected document's
/// detail on the right with a Quick Look preview. With Edit on Documents the detail offers Change kind…, Link to… and
/// each link's Unlink (`PadDocumentActions`); a refusal shows under what it was made on. Nothing changes until an
/// explicit button is pressed.
struct PadDocumentsView: View {
    @ObservedObject var model: PadDocumentsModel
    @ObservedObject var actions: PadDocumentActions
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    @Environment(\.phoneTheme) private var theme
    @State private var showsPreview = false
    @State private var choice: PadChoiceRequest?
    @State private var kindEditor: KindEditor?

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                list.frame(minWidth: 280, idealWidth: 360, maxWidth: 420)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(theme.background)
            .navigationTitle("Documents")
            .searchable(text: $model.query, prompt: "Search documents")
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
        .sheet(isPresented: $showsPreview, onDismiss: { model.closePreview() }) {
            #if canImport(UIKit)
            if case .ready(let url) = model.preview { PadDocumentPreview(url: url).ignoresSafeArea() }
            #endif
        }
        .onChange(of: model.preview) { _, preview in
            if case .ready = preview { showsPreview = true }
        }
    }

    private var list: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $model.filter) {
                ForEach(PadDocumentsModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.top, 8)
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
                                    Text(document.displayName).lineLimit(2)
                                    Text(PhoneDateFormat.day(document.docDate)).font(.footnote).foregroundStyle(.secondary)
                                }
                                .tag(document.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let document = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PadWriteNotices(write: write)
                    Text(document.displayName).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Card {
                        row("Kind", Text(model.catalog.displayName(of: document)))
                        if actions.canEdit {
                            HStack(spacing: 8) {
                                Button("Change kind…") { kindEditor = KindEditor(documentId: document.id, name: document.displayName, kind: document.kindRef) }
                                Button("Link to…") { linkTo(document) }
                            }
                            .buttonStyle(.bordered)
                        }
                        PadRefusalBanner(message: write.message(for: PadDocumentActions.documentRow(document.id)))
                        Divider()
                        row("Date", DateText(document.docDate))
                        if document.periodStart != nil || document.periodEnd != nil {
                            Divider()
                            row("Period", Text("\(PhoneDateFormat.day(document.periodStart)) – \(PhoneDateFormat.day(document.periodEnd))".figuresUnbroken))
                        }
                    }
                    Card(title: "Linked to") {
                        if model.links.isEmpty {
                            Text("Not linked to anything").foregroundStyle(.secondary)
                        } else {
                            ForEach(model.links) { line in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(line.title.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                                            if let subtitle = line.subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        if actions.canEdit {
                                            Button("Unlink") { Task { await actions.unlink(documentId: document.id, line) } }
                                                .buttonStyle(.bordered)
                                                .accessibilityLabel("Unlink \(line.title)")
                                        }
                                    }
                                    PadRefusalBanner(message: write.message(for: PadDocumentActions.linkRow(line.id)))
                                }
                            }
                        }
                    }
                    previewControl
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("Select a document", systemImage: "doc")
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

    private func row<Value: View>(_ label: String, _ value: Value) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value.multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var previewControl: some View {
        switch model.preview {
        case .downloading:
            HStack { ProgressView(); Text(PadDocumentsModel.downloadingCopy) }
        case .failed(let copy):
            VStack(alignment: .leading, spacing: 8) {
                InlineBanner(tone: .amber, text: copy)
                Button("Try again") { Task { await model.openPreview() } }.buttonStyle(.bordered)
            }
        case .idle, .ready:
            Button { Task { await model.openPreview() } } label: { Label("Preview", systemImage: "eye") }
                .buttonStyle(.borderedProminent)
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
            }
            .navigationTitle("Change kind")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let kind else { return }
                        Task {
                            _ = await save(kind)
                            dismiss()
                        }
                    }
                    .disabled(kind == nil || kind == editor.kind)
                }
            }
        }
    }
}
