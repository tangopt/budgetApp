import SwiftUI
import BudgetCore

/// Everything else ▸ Evidence on the iPad (step 10, Task 14): the whole UK tax year's evidence, not just the flat's. A
/// tax-year switch, Missing/All, the year's progress, then the items by area (Employment & income, UK tax, Pension &
/// gifts, the property), each with why it's needed, where it comes from, "Open site" (the built-in browser at the saved
/// site, whose downloads go through the tray and Check and link) and "Link existing document". Utility bills are not
/// evidence: one line points to Bills & recharges. The selected item opens in the shared document panel with the library
/// document that could satisfy it: "Link this document" (the panel's one primary button), "Search the library", "Mark
/// not available". Edits show only with Edit on Documents; a refusal shows under the item.
struct PadEvidenceView: View {
    @ObservedObject var model: PadEvidenceModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    /// Bills & recharges, where utility bills are tracked.
    let showBills: () -> Void
    @State private var request: PadChoiceRequest?
    @Environment(\.phoneTheme) private var theme
    @Environment(\.padBrowser) private var browser

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.section) {
                    PadWriteNotices(write: write)
                    header
                    if model.areas.isEmpty {
                        EmptyState(symbol: "checkmark.seal", title: "Nothing to show",
                                   message: "No evidence you can see is asked for in this tax year.")
                            .padding(.top, 40)
                    }
                    ForEach(model.shownAreas) { area in areaSection(area) }
                    otherRows
                    utilityPointer
                }
                .padPageContent()
            }
            .background(theme.background)
            .offlineBannerSlot()
            .padPage("Missing documents", subtitle: "Whole tax year · tax, tenancy and property")
        }
        .modifier(PadEvidencePanelHost(isOpen: model.selectedItem != nil, onClose: { model.selectedItemId = nil }) { panel })
        .task(id: SyncReloadTrigger(syncStatus)) { await model.reload() }
        .sheet(item: $request) { PadChoiceSheet(request: $0) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { yearSwitch; Spacer(minLength: 8); showSwitch }
                VStack(alignment: .leading, spacing: 8) { yearSwitch; showSwitch }
            }
            progressLine
        }
    }

    private var yearSwitch: some View {
        Picker("Tax year", selection: $model.year) {
            ForEach(model.years, id: \.self) { Text($0.label.unbroken).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var showSwitch: some View {
        Picker("Show", selection: $model.missingOnly) {
            Text("Missing").tag(true)
            Text("All").tag(false)
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var progressLine: some View {
        let progress = model.progress
        return HStack(spacing: 10) {
            ProgressView(value: progress.fractionDone).frame(maxWidth: 160).tint(theme.income)
            Text("\(progress.done) of \(progress.total) collected").figureText().mangoFont(.subheadline, weight: .semibold)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Areas

    private func areaSection(_ area: EvidenceArea) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let missing = area.missingCount
            Text("\(area.title.uppercased()) · \(missing == 0 ? "nothing missing" : "\(missing) missing")".figuresUnbroken)
                .mangoFont(.caption, weight: .bold).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            if area.items.isEmpty {
                Text(model.missingOnly && missing == 0 && !(model.areas.first { $0.area == area.area }?.items.isEmpty ?? true)
                     ? "Everything here is collected." : "Nothing asked for in this tax year.")
                    .mangoFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(area.items) { item in row(item) }
        }
    }

    private func row(_ item: EvidenceItem) -> some View {
        let isSelected = item.id == model.selectedItemId
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button { model.selectedItemId = item.id } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        PadEvidenceStatusIcon(status: item.item.status)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.item.title.figuresUnbroken).mangoFont(.body, weight: .semibold).lineLimit(2).truncationMode(.middle)
                            if let detail = Self.detail(item.item) {
                                Text(detail).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            (Text("Why: ").bold() + Text(item.why))
                                .mangoFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let source = item.source {
                                (Text("Fetch from: ") + Text(source).bold().foregroundColor(.primary))
                                    .mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the item")
                if browser != nil, item.suggestedSiteKind != nil {
                    RowIconButton(.openSite, item: item.item.title, size: .small) { openSite(item) }
                }
                if model.canLink, item.canLink {
                    RowIconButton(.linkDocument, item: item.item.title, size: .small) { searchLibrary(item) }
                }
            }
            if let note = model.note(for: item.id), !isSelected {
                InlineBanner(tone: .neutral, text: note.figuresUnbroken)
            }
            PadRefusalBanner(message: model.refusal(for: item.id))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MangoRadius.card, style: .continuous).fill(isSelected ? theme.accent.opacity(0.08) : theme.surface))
        .overlay(RoundedRectangle(cornerRadius: MangoRadius.card, style: .continuous).stroke(isSelected ? theme.accent : .clear, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("pad-evidence-\(item.id)")
    }

    /// The date or slot an item is about, and its amount when it has one: "6 Apr 2025 – 5 May 2025".
    static func detail(_ item: MissingEvidence.Item) -> String? {
        var parts: [String] = []
        if let date = item.expectedDate { parts.append(PhoneDateFormat.day(date).unbroken) }
        else if let slot = item.expectedPeriod { parts.append(PadEvidenceFormat.slot(slot)) }
        if let amount = item.expectedAmountMinorUnits { parts.append(Money.format(amount, currency: item.currency ?? .eur).unbroken) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The centre's other rows for the year: a tenancy's utility payments with no invoice, documents waiting for their payment.
    @ViewBuilder
    private var otherRows: some View {
        if !model.others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("TENANCY BILLS AND PAYMENTS · \(model.others.count) MISSING".figuresUnbroken)
                    .mangoFont(.caption, weight: .bold).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                ForEach(model.others) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title.figuresUnbroken).mangoFont(.body, weight: .semibold).lineLimit(2).truncationMode(.middle)
                        Text([row.context, PhoneDateFormat.day(row.due), row.amountMinorUnits.map { Money.format($0, currency: row.currency ?? .eur) }]
                            .compactMap { $0 }.joined(separator: " · ").figuresUnbroken)
                            .mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: MangoRadius.card, style: .continuous).fill(theme.surface))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var utilityPointer: some View {
        HStack(spacing: 4) {
            Text(TaxYearEvidence.utilityPointer.replacingOccurrences(of: " Bills & recharges.", with: ""))
                .mangoFont(.footnote).foregroundStyle(.secondary)
            Button("Bills & recharges", action: showBills)
                .buttonStyle(.pad(.textLink, size: .small))
                .accessibilityHint("Opens Bills & recharges")
        }
    }

    // MARK: Panel

    @ViewBuilder
    private var panel: some View {
        if let item = model.selectedItem {
            if let documentId = model.panelDocumentId {
                DocumentPanel(documentId: documentId, onClose: { model.selectedItemId = nil }) {
                    PadEvidenceItemBlock(model: model, item: item, documentId: documentId,
                                         openSite: browser != nil && item.suggestedSiteKind != nil ? { openSite(item) } : nil,
                                         searchLibrary: { searchLibrary(item) })
                }
                .id(documentId)
            } else {
                PadEvidenceItemPanel(model: model, item: item,
                                     openSite: browser != nil && item.suggestedSiteKind != nil ? { openSite(item) } : nil,
                                     searchLibrary: { searchLibrary(item) })
            }
        }
    }

    // MARK: Actions

    private func openSite(_ item: EvidenceItem) {
        guard let browser else { return }
        browser.present(PadEvidenceModel.site(for: item, in: browser.sites))
    }

    private func searchLibrary(_ item: EvidenceItem) {
        Task {
            let documents = await model.libraryChoices(for: item)
            request = PadChoiceRequest(title: "Link existing document", button: "Link",
                                       empty: "No document in the library is of a kind this item takes. Fetch it from the site first.",
                                       currency: item.item.currency ?? .eur,
                                       choices: documents.map { PadChoice(id: $0.id, title: $0.displayName, date: $0.docDate,
                                                                          amountMinorUnits: $0.amountMinorUnits) },
                                       choose: { id in await model.link(documentId: id, to: item) })
        }
    }
}

/// Under the panel's document details: what this document is to the selected item. A suggestion offers "Link this
/// document" (the panel's one primary button); then "Search the library" and "Mark not available" as text links, the
/// other suggestions, what the last change did and a refusal.
struct PadEvidenceItemBlock: View {
    @ObservedObject var model: PadEvidenceModel
    let item: EvidenceItem
    let documentId: Int64?
    var openSite: (() -> Void)?
    let searchLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.item.title.figuresUnbroken).mangoFont(.headline).lineLimit(2).truncationMode(.middle)
                Text("Needs " + (item.item.expectedKindNames.isEmpty ? "any document" : item.item.expectedKindNames.joined(separator: " or ")))
                    .mangoFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.note(for: item.id) {
                InlineBanner(tone: .neutral, text: note.figuresUnbroken)
            }
            if let documentId, let attached = model.attachedDocument(documentId) {
                InlineBanner(tone: attached.counts ? .neutral : .amber,
                             text: attached.explanation ?? "Linked to this item: it counts.")
            }
            if let documentId, let suggestion = model.suggestion(documentId) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PadStatusPill(text: "Suggested", tone: .neutral)
                    if !suggestion.reasons.isEmpty {
                        Text(suggestion.reasons.joined(separator: " · ").figuresUnbroken)
                            .mangoFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.canLink, item.canLink {
                    Button { Task { await model.link(documentId: documentId, to: item) } } label: {
                        Text("Link this document").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pad(.primary))
                }
            }
            PadRefusalBanner(message: model.refusal(for: item.id))
            links
            others
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private var links: some View {
        let canSearch = model.canLink && item.canLink
        let canWaive = model.canMarkNotAvailable && item.canLink && item.state == .missing
        if canSearch || canWaive || openSite != nil {
            PadFlowRow(spacing: 4) {
                if let openSite, documentId == nil {
                    Button(action: openSite) { Label("Open site", systemImage: RowAction.openSite.systemImage) }
                        .buttonStyle(.pad(.secondary, size: .small))
                }
                if canSearch { Button("Search the library", action: searchLibrary).buttonStyle(.pad(.textLink, size: .small)) }
                if canWaive {
                    Button("Mark not available") { Task { await model.markNotAvailable(item) } }
                        .buttonStyle(.pad(.textLink, size: .small))
                }
            }
        }
    }

    /// The panel's other documents for the item: attached ones and the other suggestions, each shown in the panel on View.
    @ViewBuilder
    private var others: some View {
        let attached = (model.panel?.itemId == item.id ? model.panel?.attached ?? [] : []).filter { $0.id != documentId }
        let suggestions = (model.panel?.itemId == item.id ? model.panel?.suggestions ?? [] : []).filter { $0.id != documentId }
        if !attached.isEmpty || !suggestions.isEmpty {
            Divider()
            ForEach(attached) { document in
                otherRow(document.id, name: document.document.displayName, caption: document.counts ? "Linked" : "Linked · doesn't count")
            }
            ForEach(suggestions) { suggestion in
                otherRow(suggestion.id, name: suggestion.document.displayName, caption: "Suggested · \(suggestion.kindName)")
            }
        }
    }

    private func otherRow(_ id: Int64, name: String, caption: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).mangoFont(.subheadline).lineLimit(1).truncationMode(.middle)
                Text(caption).mangoFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RowIconButton(.view, item: name, size: .small) { model.openDocumentId = id }
        }
    }
}

/// The selected item when there is no document to show yet: its title with a close button, why it's needed, and the same
/// block (Open site, Search the library, Mark not available), at the document panel's width.
struct PadEvidenceItemPanel: View {
    @ObservedObject var model: PadEvidenceModel
    let item: EvidenceItem
    var openSite: (() -> Void)?
    let searchLibrary: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        PadSidePanel(title: "No document yet", onClose: { model.selectedItemId = nil }) {
            Text(item.why).mangoFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let source = item.source {
                (Text("Fetch from: ") + Text(source).bold()).mangoFont(.callout).lineLimit(1).truncationMode(.middle)
            }
            if model.panel?.itemId == item.id {
                Text("No library document looks like this item's evidence yet.")
                    .mangoFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking in the library…").foregroundStyle(.secondary)
                }
            }
            PadEvidenceItemBlock(model: model, item: item, documentId: nil, openSite: openSite, searchLibrary: searchLibrary)
        }
    }
}

/// The Evidence panel beside the list (or over its trailing edge when the list would keep less than 420 pt), as the
/// document panel's host places it.
private struct PadEvidencePanelHost<Panel: View>: ViewModifier {
    let isOpen: Bool
    let onClose: () -> Void
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        content.padSidePanel(isPresented: isOpen, onClose: onClose, panel: panel)
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
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.income).accessibilityLabel("Done")
        case .waived:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Not available")
        case .missing:
            Image(systemName: "circle").foregroundStyle(theme.warning).accessibilityLabel("Missing")
        }
    }
}

enum PadEvidenceFormat {
    /// "6 Apr 2025 – 5 May 2025": a slot's first and last days, unbreakable.
    static func slot(_ slot: DateInterval) -> String {
        let last = max(slot.end.addingTimeInterval(-86_400), slot.start)
        return "\(PhoneDateFormat.day(slot.start)) – \(PhoneDateFormat.day(last))".unbroken
    }
}
