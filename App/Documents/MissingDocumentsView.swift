// App/Documents/MissingDocumentsView.swift
import SwiftUI
import BudgetCore

private struct OpenMissingDocumentsKey: EnvironmentKey {
    static let defaultValue: (Int) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Opens the Missing documents centre filtered to a tax year (the year's checklist links to it).
    var openMissingDocuments: (Int) -> Void {
        get { self[OpenMissingDocumentsKey.self] }
        set { self[OpenMissingDocumentsKey.self] = newValue }
    }
}

/// The Missing documents centre (step 20): everything Mango expects a document for and doesn't have, across tax,
/// tenancy and property, not tied to one tax year. Grouped by area (Tax, Tenancy, Property), oldest due first, with
/// area, year and due-soon / overdue filters and a search. A row's icon buttons: Attach file… (the importer, linked to
/// the row's record), Open site (the saved site it is usually found on), Not expected (reversible below).
struct MissingDocumentsView: View {
    @ObservedObject var viewModel: MissingDocumentsViewModel
    /// Opens Property ▸ Recharges (a utility bill without its invoice is taken there).
    var openProperty: (Int64) -> Void = { _ in }
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var claim = ObservationDemand.screenClaim()
    @State private var marking: MissingDocumentRow?
    @State private var showNotExpected = false

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            filterBar
            if let message = viewModel.errorMessage {
                Text(message.figuresUnbroken).font(.callout).foregroundStyle(.red).lineLimit(2)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 640)
        .padding(ScreenMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { viewModel.claim(claim) }
        .onDisappear { viewModel.release(claim) }
        .sheet(item: $marking) { row in
            NotExpectedSheet(row: row, viewModel: viewModel)
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Area", selection: $viewModel.area) {
                Text("All areas").tag(MissingDocumentArea?.none)
                ForEach(MissingDocumentArea.allCases, id: \.self) { Text($0.title).tag(MissingDocumentArea?.some($0)) }
            }
            .labelsHidden().fixedSize().accessibilityLabel("Area")
            Picker("Year", selection: $viewModel.year) {
                Text("Any year").tag(MissingDocumentsViewModel.YearChoice.any)
                Section("Tax year") {
                    ForEach(viewModel.taxYears, id: \.self) { Text(UKTaxYear(startYear: $0).label).tag(MissingDocumentsViewModel.YearChoice.taxYear($0)) }
                }
                Section("Calendar year") {
                    ForEach(viewModel.calendarYears, id: \.self) { Text(String($0)).tag(MissingDocumentsViewModel.YearChoice.calendarYear($0)) }
                }
            }
            .labelsHidden().fixedSize().accessibilityLabel("Year")
            Picker("Due", selection: $viewModel.timing) {
                Text("Any time").tag(MissingDocumentFilter.Timing.any)
                Text("Due soon").tag(MissingDocumentFilter.Timing.dueSoon)
                Text("Overdue").tag(MissingDocumentFilter.Timing.overdue)
            }
            .labelsHidden().fixedSize().accessibilityLabel("Due")
            SearchField("Search", text: $viewModel.queryText)
                .frame(maxWidth: 260)
            Spacer(minLength: 8)
            let count = viewModel.shown.count
            Text("\(count) missing".figuresUnbroken).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.shown.isEmpty && viewModel.notExpected.isEmpty {
            ContentUnavailableView(viewModel.result.missingCount == 0 ? "Nothing missing" : "Nothing matches",
                                   systemImage: viewModel.result.missingCount == 0 ? "checkmark.seal" : "line.3.horizontal.decrease.circle",
                                   description: Text(viewModel.result.missingCount == 0 ? "Every document Mango expects is in the library." : "Change the filters to see more."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                    ForEach(MissingDocumentArea.allCases, id: \.self) { area in
                        let rows = viewModel.shown(in: area)
                        if !rows.isEmpty { areaPanel(area, rows) }
                    }
                    notExpectedPanel
                }
            }
        }
    }

    private func areaPanel(_ area: MissingDocumentArea, _ rows: [MissingDocumentRow]) -> some View {
        Panel(area.title, subtitle: "\(rows.count) missing") {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    MissingDocumentRowView(row: row, sites: viewModel.sites, markNotExpected: { marking = row },
                                           openProperty: openProperty, openSite: { openURL($0.url) })
                    if row.id != rows.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private var notExpectedPanel: some View {
        let rows = viewModel.notExpected
        if !rows.isEmpty {
            Panel("Not expected", subtitle: "\(rows.count) marked") {
                DisclosureGroup("Show", isExpanded: $showNotExpected) {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).lineLimit(1).truncationMode(.middle)
                                    if let note = row.item?.waiver?.note {
                                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button { viewModel.restore(row) } label: { Image(systemName: "arrow.uturn.backward") }
                                    .buttonStyle(.borderless).help("Expect it again").accessibilityLabel("Expect it again")
                                    .disabled(!row.canMarkNotExpected)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }
}

/// One missing document: what, where from, when, how much, and its icon buttons.
struct MissingDocumentRowView: View {
    let row: MissingDocumentRow
    let sites: [SavedSite]
    let markNotExpected: () -> Void
    let openProperty: (Int64) -> Void
    let openSite: (SavedSite) -> Void
    @Environment(\.documentImport) private var documentImport

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1).truncationMode(.middle)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text(DocumentFormat.day(row.due).figuresUnbroken).font(.callout).monospacedDigit()
                .foregroundStyle(row.due < AppClock.now ? .orange : .secondary).lineLimit(1)
                .frame(width: 96, alignment: .trailing)
            Text(amount.figuresUnbroken).font(.callout).monospacedDigit().lineLimit(1)
                .frame(width: 90, alignment: .trailing)
            actions.frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    /// "Tenancy · Room A · Portal das Finanças".
    private var caption: String {
        [row.context, row.usualSource, row.isFiledYear ? "Filed year, read only" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private var amount: String {
        guard let value = row.amountMinorUnits, let currency = row.currency else { return "" }
        return Money.format(value, currency: currency)
    }

    private var site: SavedSite? { MissingDocuments.site(for: row, in: sites) }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if row.source == .evidence, let item = row.item {
                Button { documentImport?.pickShortcut(MissingEvidenceRow.shortcut(item)) } label: { Image(systemName: "doc.badge.plus") }
                    .disabled(!row.canAttach || documentImport == nil).help("Attach file…").accessibilityLabel("Attach file…")
            } else if row.source == .utilityBill, let propertyId = row.propertyId {
                Button { openProperty(propertyId) } label: { Image(systemName: "house") }
                    .help("Add the invoice in Property").accessibilityLabel("Add the invoice in Property")
            }
            Button { if let site { openSite(site) } } label: { Image(systemName: "safari") }
                .disabled(site == nil).help(site.map { "Open \($0.name)" } ?? "No saved site for this").accessibilityLabel("Open site")
            Button(action: markNotExpected) { Image(systemName: "nosign") }
                .disabled(!row.canMarkNotExpected).help("Not expected").accessibilityLabel("Not expected")
        }
        .buttonStyle(.borderless)
    }
}

/// Not expected: a reason and an optional note; the row moves to the Not expected panel, where it can be restored.
struct NotExpectedSheet: View {
    let row: MissingDocumentRow
    @ObservedObject var viewModel: MissingDocumentsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var reason: EvidenceWaiverReason = .notAvailable
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        SheetScaffold(title: "Not expected", subtitle: row.title, error: errorMessage, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Not expected") {
                          viewModel.markNotExpected(row, reason: reason, note: note) { error in
                              errorMessage = error
                              if error == nil { dismiss() }
                          }
                      }) {
            SheetForm {
                LabeledContent("Reason") {
                    Picker("Reason", selection: $reason) {
                        Text("Not available").tag(EvidenceWaiverReason.notAvailable)
                        Text("Other reason").tag(EvidenceWaiverReason.other)
                    }
                    .pickerStyle(.radioGroup)
                }
                LabeledContent("Note") {
                    TextField("Note", text: $note, prompt: Text("e.g. the bank no longer issues these"), axis: .vertical).lineLimit(2...4)
                }
                SheetFormNote("It leaves the list; Not expected at the bottom brings it back.")
            }
        }
    }
}
