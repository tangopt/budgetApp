import SwiftUI
import BudgetCore

/// The selected Missing evidence item on the iPad (step 8, Task 10), as the Mac's side panel shows it: what it needs,
/// the documents attached to its record (why each doesn't count when it doesn't), and the library documents that could
/// satisfy it, each with "Link" while the user has Edit on Documents. A refusal shows under the item; what a link did
/// shows as a note. Waivers and rules are the Mac's.
struct PadMissingEvidencePanel: View {
    let item: MissingEvidence.Item
    @ObservedObject var model: PadMissingEvidenceModel
    @ObservedObject var write: PadWriteModel
    /// Set to a document's id to show it in the document panel.
    @Binding var openDocumentId: Int64?
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PadWriteNotices(write: write)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title.figuresUnbroken).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                if let note = model.note(for: item.id) {
                    InlineBanner(tone: .neutral, text: note.figuresUnbroken)
                }
                PadRefusalBanner(message: write.message(for: PadMissingEvidenceModel.itemRow(item.id)))
                Card(title: "Requirement") {
                    HStack(spacing: 8) {
                        PadEvidenceStatusIcon(status: item.status)
                        Text(PadEvidenceFormat.status(item.status))
                    }
                    Text("Needs " + item.expectedKindNames.joined(separator: " or "))
                        .fixedSize(horizontal: false, vertical: true)
                    if let date = item.expectedDate {
                        figureRow("Date", DateText(date))
                    }
                    if let amount = item.expectedAmountMinorUnits {
                        figureRow("Amount", MoneyText(minorUnits: amount, currency: item.currency ?? .eur, role: .neutral))
                    }
                    if let text = item.waiver?.note, item.status == .waived, !text.isEmpty {
                        Text(text).italic().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Card(title: attachedTitle) { attachedSection }
                Card(title: "Suggested documents") { suggestionsSection }
            }
            .padding(20)
        }
    }

    /// The rule (when the title isn't its name), its slot, and where the documents usually come from.
    private var subtitle: String? {
        var parts: [String] = []
        if item.title != item.requirement.name { parts.append(item.requirement.name) }
        if let slot = item.expectedPeriod { parts.append(PadEvidenceFormat.slot(slot)) }
        if let source = item.usualSource { parts.append(source) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var attached: [MissingEvidence.AttachedDocument] {
        model.panel?.itemId == item.id ? model.panel?.attached ?? [] : MissingEvidence.attached(item, catalog: model.catalog)
    }

    private var attachedTitle: String {
        attached.isEmpty ? "Attached documents" : "Attached documents (\(attached.count))"
    }

    @ViewBuilder
    private var attachedSection: some View {
        if attached.isEmpty {
            Text("Nothing attached yet.").foregroundStyle(.secondary)
        }
        ForEach(attached) { document in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: document.counts ? "paperclip" : "exclamationmark.triangle")
                    .foregroundStyle(document.counts ? Color.secondary : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.document.displayName).lineLimit(2).truncationMode(.middle)
                    PadFlowRow {
                        Text(document.kindName).fixedSize(horizontal: false, vertical: true)
                        DateText(document.document.docDate, font: .footnote)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    if let explanation = document.explanation {
                        Text(explanation).font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                viewButton(document.id, name: document.document.displayName)
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if let panel = model.panel, panel.itemId == item.id {
            if panel.suggestions.isEmpty {
                Text("No library document looks like this item's evidence. Add the file on the Mac.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(panel.suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.document.displayName).lineLimit(2).truncationMode(.middle)
                        PadFlowRow {
                            Text(suggestion.kindName).fixedSize(horizontal: false, vertical: true)
                            DateText(suggestion.document.docDate, font: .footnote)
                            if let amount = suggestion.document.amountMinorUnits {
                                MoneyText(minorUnits: amount, currency: suggestion.document.currency ?? .eur, role: .neutral, font: .footnote)
                            }
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                        if !suggestion.reasons.isEmpty {
                            Text(suggestion.reasons.joined(separator: " · ").figuresUnbroken)
                                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        viewButton(suggestion.id, name: suggestion.document.displayName)
                        if model.canLink {
                            Button("Link") { Task { await model.link(documentId: suggestion.id, to: item) } }
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel("Link \(suggestion.document.displayName)")
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking in the library…").foregroundStyle(.secondary)
            }
        }
    }

    private func viewButton(_ documentId: Int64, name: String) -> some View {
        Button("View") { openDocumentId = documentId }
            .buttonStyle(.bordered)
            .accessibilityLabel("View \(name)")
    }

    private func figureRow<Value: View>(_ label: String, _ value: Value) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 12)
                value
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary).fixedSize()
                value
            }
        }
    }
}
