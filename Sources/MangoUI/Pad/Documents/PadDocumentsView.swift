import SwiftUI
import BudgetCore

/// Documents on the iPad: the library on the left (search, All / Unlinked, grouped by kind), the selected document's
/// detail on the right with a Quick Look preview.
struct PadDocumentsView: View {
    @ObservedObject var model: PadDocumentsModel
    let syncStatus: SyncStatus
    @Environment(\.phoneTheme) private var theme
    @State private var showsPreview = false

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
        .task(id: SyncReloadTrigger(syncStatus)) { await model.reload() }
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
                    Text(document.displayName).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Card {
                        row("Kind", Text(model.catalog.displayName(of: document)))
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
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.title)
                                    if let subtitle = line.subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
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
