import SwiftUI
import BudgetCore

/// Missing evidence on the iPad (step 8, Task 10): the tax year's checklist on the left, grouped by usual source with
/// each source's progress, and the selected item's side panel on the right (`PadMissingEvidencePanel`). Links only:
/// waivers and rules are the Mac's.
struct PadMissingEvidenceView: View {
    @ObservedObject var model: PadMissingEvidenceModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    @Environment(\.phoneTheme) private var theme
    /// The document shown in the shared panel (a suggestion or attached document the user opened).
    @State private var openDocumentId: Int64?

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                list.frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(theme.background)
            .navigationTitle("Missing evidence")
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await model.reload()
            await write.refresh()
        }
        .onChange(of: model.selectedItemId) { _, _ in openDocumentId = nil }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            PadFlowRow {
                Picker("Tax year", selection: $model.year) {
                    ForEach(model.years, id: \.self) { Text($0.label.unbroken).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Toggle("Missing only", isOn: $model.missingOnly).fixedSize()
            }
            .padding(.horizontal, 16).padding(.top, 8)
            let progress = model.progress
            Text("\(progress.done) of \(progress.total) done")
                .figureText()
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            let groups = model.groups
            if groups.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: model.items.isEmpty ? "Nothing to collect" : "Nothing missing",
                           message: model.items.isEmpty ? "No rule asks for evidence in this tax year." : "Every item has its evidence.")
                    .padding(.top, 40)
                Spacer()
            } else {
                List(selection: $model.selectedItemId) {
                    ForEach(groups, id: \.source) { group in
                        Section {
                            ForEach(group.items) { item in row(item).tag(item.id) }
                        } header: {
                            PadFlowRow {
                                Text(group.source)
                                Text("\(group.progress.done) of \(group.progress.total)").figureText()
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func row(_ item: MissingEvidence.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PadEvidenceStatusIcon(status: item.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.figuresUnbroken).lineLimit(2)
                if let date = item.expectedDate {
                    DateText(date, font: .footnote).foregroundStyle(.secondary)
                } else if let slot = item.expectedPeriod {
                    Text(PadEvidenceFormat.slot(slot)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selectedItem {
            PadMissingEvidencePanel(item: item, model: model, write: write, openDocumentId: $openDocumentId)
                .documentPanel(selection: $openDocumentId) { documentId in documentBlock(documentId, item: item) }
        } else {
            ContentUnavailableView("Select an item", systemImage: "checklist")
        }
    }
}

extension PadMissingEvidenceView {
    /// Under an opened document's details: what it is to this item. A suggestion offers "Link to this item" (Edit on
    /// Documents); a refusal shows under the item; an attached one says why it doesn't count, when it doesn't.
    @ViewBuilder
    fileprivate func documentBlock(_ documentId: Int64, item: MissingEvidence.Item) -> some View {
        let attached = model.panel?.itemId == item.id ? model.panel?.attached.first { $0.id == documentId } : nil
        let suggested = model.panel?.itemId == item.id ? model.panel?.suggestions.first { $0.id == documentId } : nil
        VStack(alignment: .leading, spacing: 12) {
            if let attached {
                InlineBanner(tone: attached.counts ? .neutral : .amber,
                             text: attached.explanation ?? "Attached to “\(item.title)”")
            }
            if let suggested {
                Card(title: "Link this document") {
                    if !suggested.reasons.isEmpty {
                        Text(suggested.reasons.joined(separator: " · ").figuresUnbroken)
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.canLink {
                        Button { Task { await model.link(documentId: documentId, to: item) } } label: {
                            Text("Link to this item").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    PadRefusalBanner(message: write.message(for: PadMissingEvidenceModel.itemRow(item.id)))
                }
            }
        }
    }
}

/// Its views side by side when they fit the width, else stacked (a row of captions or controls in a narrow column).
struct PadFlowRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: spacing) { content() }
            VStack(alignment: .leading, spacing: 4) { content() }
        }
    }
}

/// An item's status as an icon: done, not available, or missing.
struct PadEvidenceStatusIcon: View {
    let status: MissingEvidence.Status
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        switch status {
        case .satisfied:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .waived:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Not available")
        case .missing:
            Image(systemName: "circle").foregroundStyle(.orange).accessibilityLabel("Missing")
        }
    }
}

enum PadEvidenceFormat {
    /// "6 Apr 2025 – 5 May 2025": a slot's first and last days, unbreakable.
    static func slot(_ slot: DateInterval) -> String {
        let last = max(slot.end.addingTimeInterval(-86_400), slot.start)
        return "\(PhoneDateFormat.day(slot.start)) – \(PhoneDateFormat.day(last))".unbroken
    }

    static func status(_ status: MissingEvidence.Status) -> String {
        switch status {
        case .satisfied: "Done"
        case .waived: "Not available"
        case .missing: "Missing"
        }
    }
}
