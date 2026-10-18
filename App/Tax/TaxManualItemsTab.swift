// App/Tax/TaxManualItemsTab.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore
import GRDB

/// Things for the return that aren't bank movements (a UK accountant's invoice in GBP, postage),
/// each with its documents. Added and edited in a sheet whose changes — documents included —
/// are written by Save, like Edit transaction. Shown as a table (UI polish §4.2): day, item
/// and tax line, the amount in its currency and in GBP at the year's HMRC rate, documents, and
/// edit/delete icons; grouped by currency with a total each, and a total in GBP.
struct TaxManualItemsTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    @State private var editing: ManualItemDraft?
    @State private var deleting: TaxManualItem?

    /// A row of the table: an item, a currency's total, or the total in GBP.
    private struct Row: Identifiable {
        let id: String
        var item: TaxManualItem?
        var title: String
        var currency: Currency?
        var amount: Int?
        var gbp: Int?
        var documentCount = 0
        /// A total that adds whole-property items at 100% (as entered, not the person's part).
        var isAsEntered = false
    }

    /// Whether any item is the whole property's amount (the totals then add it as entered).
    private var hasWholePropertyItems: Bool { page.manualItems.contains(where: \.isWholeProperty) }

    /// An amount in GBP at the year's HMRC rate (`nil` when there's no rate for its currency).
    private func gbp(_ minorUnits: Int, _ currency: Currency) -> Int? {
        guard currency != .gbp else { return minorUnits }
        return page.rates.first { $0.currencyCode == currency.rawValue.uppercased() }?.gbp(minorUnits)
    }

    private func row(_ item: TaxManualItem) -> Row {
        Row(id: "item-\(item.id ?? 0)", item: item, title: item.label, currency: item.currency, amount: item.amountMinorUnits,
            gbp: gbp(item.amountMinorUnits, item.currency), documentCount: page.manualItemDocumentCounts[item.id ?? -1] ?? 0)
    }

    /// The items by currency (the property's first), each with its total; a total in GBP when
    /// there's more than one currency.
    private var sections: [DataTableSection<Row>] {
        let first = page.property?.currency ?? .gbp
        let currencies = Currency.allCases.filter { currency in page.manualItems.contains { $0.currency == currency } }
            .sorted { ($0 == first ? 0 : 1) < ($1 == first ? 0 : 1) }
        func sum(_ values: [Int?]) -> Int? { values.reduce(Optional(0)) { total, value in total.flatMap { a in value.map { a + $0 } } } }
        var sections = currencies.map { currency -> DataTableSection<Row> in
            let rows = page.manualItems.filter { $0.currency == currency }.map(row)
            let total = Row(id: "total-\(currency.rawValue)", title: "Total",
                            currency: currency, amount: rows.reduce(0) { $0 + ($1.amount ?? 0) }, gbp: sum(rows.map(\.gbp)),
                            isAsEntered: rows.contains { $0.item?.isWholeProperty == true })
            return DataTableSection(currencies.count > 1 ? "In \(currency.rawValue.uppercased())" : nil, rows: rows, total: total)
        }
        if currencies.count > 1 {
            let all = page.manualItems.map(row)
            sections.append(DataTableSection(nil, rows: [], total: Row(id: "total", title: "All items, in GBP", gbp: sum(all.map(\.gbp)),
                                                                         isAsEntered: hasWholePropertyItems)))
        }
        return sections
    }

    private var rateNote: String {
        let foreign = Set(page.manualItems.map(\.currency)).subtracting([.gbp])
        guard !foreign.isEmpty else { return "Amounts in GBP." }
        let rates = foreign.compactMap { currency in page.rates.first { $0.currencyCode == currency.rawValue.uppercased() } }
        guard rates.count == foreign.count else { return "No HMRC average rate for \(page.row.year.label) yet: GBP shows once it's set in Settings." }
        return "GBP at HMRC's average rate, " + rates.map(TaxFormat.unitsPerPound).joined(separator: ", ") + "."
    }

    private var columns: [DataTableColumn<Row>] {
        [
            .date("Date") { $0.item?.date },
            DataTableColumn("Item", width: .fill(min: 200), accessibilityValue: { row in
                [row.title, row.item.map { $0.isWholeProperty ? "the whole property's amount" : "" },
                 row.isAsEntered ? "as entered, whole-property items at 100%" : nil].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: ", ")
            }) { row, kind in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).fontWeight(kind == .total ? .semibold : .regular).lineLimit(1)
                    if row.item?.isWholeProperty == true {
                        Text("The whole property's amount").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help("The person's split applies to it")
                    }
                    if row.isAsEntered {
                        Text("As entered (whole-property items at 100%)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help("The rental accounts apply the person's split to the whole-property items")
                    }
                }
                .help([row.title, row.item?.notes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
            },
            DataTableColumn("Tax line", accessibilityValue: { $0.item?.expenseType.displayName }) { row, _ in
                if let item = row.item {
                    Text(item.expenseType.displayName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            },
            // Every item is a cost or income named for the return: as given, uncoloured (spec §1.4).
            DataTableColumn("Amount", alignment: .trailing, width: .min(104), accessibilityValue: { row in
                guard let amount = row.amount, let currency = row.currency else { return nil }
                return Money.format(amount, currency: currency)
            }) { row, kind in
                if let amount = row.amount, let currency = row.currency {
                    MoneyText(minorUnits: amount, currency: currency,
                              font: kind == .total ? .body.monospacedDigit().weight(.semibold) : .body.monospacedDigit(), role: .neutral)
                }
            },
            .money("GBP", role: .neutral, minWidth: 104, currency: { _ in .gbp }) { $0.gbp },
            .documents { $0.documentCount },
            .actions { row in
                guard let item = row.item else { return [] }
                return [
                    DataTableAction("Edit \(item.label)", systemImage: "pencil", inline: true) { editing = ManualItemDraft(item) },
                    DataTableAction("Delete \(item.label)…", systemImage: "trash", role: .destructive, inline: true) { deleting = item }
                ]
            }
        ]
    }

    var body: some View {
        Panel("Manual items", subtitle: page.manualItems.isEmpty ? nil : "What isn't in the bank movements, for \(page.row.year.label). \(rateNote)") {
            Button("Add item…") { editing = ManualItemDraft(new: page) }
                .controlSize(.small)
        } content: {
            if page.manualItems.isEmpty {
                Text("No manual items yet: add what isn't in the bank movements, e.g. the UK accountant's fee paid in pounds.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                DataTable(columns: columns, sections: sections)
            }
        }
        .sheet(item: $editing) { draft in
            TaxManualItemSheet(viewModel: viewModel, draft: draft)
        }
        .confirmationDialog("Delete “\(deleting?.label ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = deleting?.id { viewModel.deleteManualItem(id) }
                deleting = nil
            }
        } message: {
            Text("Its document links go too; the documents stay in the library. This can't be undone.")
        }
    }
}

/// The sheet's starting point: a new item for the year, or one to edit.
struct ManualItemDraft: Identifiable {
    let id = UUID()
    var item: TaxManualItem

    init(_ item: TaxManualItem) { self.item = item }

    init(new page: TaxOverview.YearPage) {
        item = TaxManualItem(startYear: page.row.year.startYear, personId: page.row.person.id ?? 0, propertyId: page.property?.id,
                             expenseType: .accountancy, label: "", amountMinorUnits: 0, currency: .gbp)
    }
}

/// A record's documents while its sheet is open: saved links plus staged links and unlinks
/// (`EvidenceLinkStaging`), which Save applies. A file added here is copied into the library
/// at once and only its link is staged.
@MainActor
final class StagedDocumentsModel: ObservableObject {
    let library: EvidenceLibrary
    @Published private(set) var staging = EvidenceLinkStaging(saved: [])
    @Published private(set) var documentsById: [Int64: EvidenceDocument] = [:]
    @Published private(set) var addingCount = 0
    @Published var errorMessage: String?

    init(library: EvidenceLibrary, entity: EvidenceEntity?) {
        self.library = library
        if let entity, let documents = try? library.documents(for: entity) {
            staging = EvidenceLinkStaging(saved: documents.compactMap(\.id))
            for document in documents { if let id = document.id { documentsById[id] = document } }
        }
    }

    var shown: [EvidenceDocument] { staging.shownIds.compactMap { documentsById[$0] } }

    func toggleUnlink(_ id: Int64) { staging.toggleUnlink(id) }

    func addFiles(_ urls: [URL]) {
        let (files, _) = EvidenceFiles.files(urls)
        guard !files.isEmpty else { return }
        let library = library
        addingCount += files.count
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (added: [EvidenceDocument], failures: [String]) in
                var added: [EvidenceDocument] = [], failures: [String] = []
                for url in files {
                    do {
                        added.append(try EvidenceFiles.withAccess(url) { try library.addAnalyzing(url) }.document)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (added, failures)
            }.value
            addingCount -= files.count
            for document in outcome.added {
                guard let id = document.id else { continue }
                documentsById[id] = document
                staging.stageLink(id)
            }
            errorMessage = outcome.failures.isEmpty ? nil : "Couldn't add " + outcome.failures.joined(separator: "; ")
        }
    }

    func open(_ document: EvidenceDocument) {
        NSWorkspace.shared.open(library.fileURL(for: document))
    }
}

struct TaxManualItemSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let draft: ManualItemDraft
    @Environment(\.dismiss) private var dismiss
    @StateObject private var documents: StagedDocumentsModel
    @State private var label: String
    @State private var expenseType: TaxExpenseType
    @State private var currency: Currency
    @State private var amountText: String
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var isWholeProperty: Bool
    @State private var notes: String
    @State private var error: String?

    init(viewModel: TaxYearsViewModel, draft: ManualItemDraft) {
        self.viewModel = viewModel
        self.draft = draft
        let item = draft.item
        _documents = StateObject(wrappedValue: StagedDocumentsModel(library: viewModel.library, entity: item.id.map { .taxManualItem($0) }))
        _label = State(initialValue: item.label)
        _expenseType = State(initialValue: item.expenseType)
        _currency = State(initialValue: item.currency)
        _amountText = State(initialValue: item.id == nil ? "" : Money.formatInput(item.amountMinorUnits))
        _hasDate = State(initialValue: item.date != nil)
        _date = State(initialValue: item.date ?? UKTaxYear(startYear: item.startYear).lastDay)
        _isWholeProperty = State(initialValue: item.isWholeProperty)
        _notes = State(initialValue: item.notes ?? "")
    }

    private var amount: Int? { Money.parseMinorUnits(amountText) }
    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty && (amount ?? -1) >= 0 && documents.addingCount == 0
    }

    var body: some View {
        SheetScaffold(title: draft.item.id == nil ? "Add manual item" : "Edit manual item",
                      subtitle: UKTaxYear(startYear: draft.item.startYear).label, error: error, width: SheetMetrics.formWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: isValid) { save() }) {
            SheetForm {
                LabeledContent("Description") {
                    TextField("Description", text: $label, prompt: Text("e.g. UK accountant"))
                }
                LabeledContent("Tax line") {
                    Picker("Tax line", selection: $expenseType) {
                        ForEach(TaxExpenseType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                }
                LabeledContent("Amount") {
                    HStack {
                        // The picker beside it names the currency: the field doesn't repeat it.
                        MoneyField("Amount", text: $amountText, currency: currency, width: 120, showsCurrency: false)
                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                LabeledContent("Date") {
                    HStack(spacing: 10) {
                        // Named beside the tick: a SheetForm row hides its controls' own labels.
                        NamedCheckbox(title: "Dated", isOn: $hasDate)
                        if hasDate {
                            DatePicker("Date", selection: utcDay($date), displayedComponents: .date).labelsHidden().fixedSize()
                        }
                    }
                }
                if draft.item.propertyId != nil {
                    LabeledContent("Whose") {
                        Picker("Whose", selection: $isWholeProperty) {
                            Text("This person's own amount").tag(false)
                            Text("The whole property's (the split applies)").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                    }
                }
                LabeledContent("Note") {
                    TextField("Note", text: $notes, prompt: Text("Optional"))
                }
                LabeledContent("Documents") {
                    StagedDocumentsField(documents: documents)
                }
            }
        }
    }

    private func save() {
        guard let amount else { error = MoneyField.invalidAmountMessage(amountText); return }
        var item = draft.item
        item.label = label
        item.expenseType = expenseType
        item.currency = currency
        item.amountMinorUnits = amount
        item.date = hasDate ? date : nil
        item.isWholeProperty = draft.item.propertyId != nil && isWholeProperty
        item.notes = notes
        error = viewModel.saveManualItem(item, documents: documents.staging.changes)
        if error == nil { dismiss() }
    }
}

/// A sheet's Documents row: the record's documents with staged links and unlinks, "Add
/// document…" and a drop target (`StagedDocumentsModel`; Save applies the changes).
struct StagedDocumentsField: View {
    @ObservedObject var documents: StagedDocumentsModel
    @State private var picking = false
    @State private var dropTargeted = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(documents.shown) { document in
                let id = document.id ?? -1
                let unlinking = documents.staging.willUnlink(id), linking = documents.staging.willLink(id)
                HStack(spacing: 6) {
                    Image(systemName: unlinking ? "minus.circle" : linking ? "plus.circle" : "paperclip")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(document.displayName).lineLimit(1).truncationMode(.middle).strikethrough(unlinking)
                        .help(document.displayName)
                    if unlinking || linking {
                        Text(unlinking ? "will be unlinked" : "will be linked").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button { documents.open(document) } label: { Image(systemName: "arrow.up.forward.square") }
                        .help("Open \(document.displayName)")
                        .accessibilityLabel("Open \(document.displayName)")
                    Button { documents.toggleUnlink(id) } label: {
                        Image(systemName: unlinking || linking ? "arrow.uturn.backward.circle" : "xmark.circle")
                    }
                    .help(unlinking || linking ? "Undo" : "Unlink (the document stays in the library)")
                    .accessibilityLabel(unlinking || linking ? "Undo for \(document.displayName)" : "Unlink \(document.displayName)")
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                Button("Add document…") { picking = true }.controlSize(.small)
                if documents.addingCount > 0 {
                    ProgressView().controlSize(.small)
                } else {
                    Text("or drop a file here").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = documents.errorMessage {
                Text(message).font(.callout).foregroundStyle(theme.expense)
            }
        }
        .padding(4)
        .background { RoundedRectangle(cornerRadius: 6).strokeBorder(dropTargeted ? theme.accent : Color.clear, lineWidth: 2) }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            documents.addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $picking, allowedContentTypes: EvidenceFiles.contentTypes, allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { documents.addFiles(urls) }
        }
    }
}
