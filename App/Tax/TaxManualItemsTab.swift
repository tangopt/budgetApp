// App/Tax/TaxManualItemsTab.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore
import GRDB

/// Things for the return that aren't bank movements (a UK accountant's invoice in GBP, postage),
/// each with its documents. Added and edited in a sheet whose changes — documents included —
/// are written by Save, like Edit transaction.
struct TaxManualItemsTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    @State private var editing: ManualItemDraft?
    @State private var deleting: TaxManualItem?

    var body: some View {
        PropertySection("Manual items · \(page.row.year.label)", accessory: {
            Button("Add item…") { editing = ManualItemDraft(new: page) }
                .buttonStyle(.borderless)
        }) {
            if page.manualItems.isEmpty {
                Text("None. Add what isn't in the bank movements, e.g. the UK accountant's fee paid in pounds.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(page.manualItems, id: \.id) { item in
                        GridRow {
                            Text(item.date.map(DocumentFormat.day) ?? "—").monospacedDigit().lineLimit(1).fixedSize()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label).lineLimit(1)
                                Text("\(item.expenseType.displayName)\(item.isWholeProperty ? " · whole property" : "")")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            PropertyMoney(minorUnits: item.amountMinorUnits, currency: item.currency, neutral: true)
                                .gridColumnAlignment(.trailing)
                            DocumentCountBadge(count: page.manualItemDocumentCounts[item.id ?? -1] ?? 0)
                            HStack(spacing: 8) {
                                Button("Edit…") { editing = ManualItemDraft(item) }
                                    .accessibilityLabel("Edit \(item.label)")
                                Button("Delete…", role: .destructive) { deleting = item }
                                    .accessibilityLabel("Delete \(item.label)")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
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
            Text("Its document links go too; the documents stay in the library.")
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
    @State private var picking = false
    @State private var dropTargeted = false
    @Environment(\.theme) private var theme

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
                      subtitle: UKTaxYear(startYear: draft.item.startYear).label, error: error, width: 520, onCancel: { dismiss() },
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
                        MoneyField("Amount", text: $amountText, currency: currency, width: 120)
                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                LabeledContent("Date") {
                    HStack {
                        Toggle("Dated", isOn: $hasDate).labelsHidden()
                        if hasDate {
                            DatePicker("Date", selection: utcDay($date), displayedComponents: .date).labelsHidden()
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
                    TextField("Note", text: $notes)
                }
                LabeledContent("Documents") {
                    documentsList
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: EvidenceFiles.contentTypes, allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { documents.addFiles(urls) }
        }
    }

    private var documentsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(documents.shown) { document in
                let id = document.id ?? -1
                let unlinking = documents.staging.willUnlink(id), linking = documents.staging.willLink(id)
                HStack(spacing: 6) {
                    Image(systemName: unlinking ? "minus.circle" : linking ? "plus.circle" : "paperclip")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(document.displayName).lineLimit(1).truncationMode(.middle).strikethrough(unlinking)
                    Text(unlinking ? "will be unlinked" : linking ? "will be linked" : "").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("Open") { documents.open(document) }
                    Button(unlinking || linking ? "Undo" : "Unlink") { documents.toggleUnlink(id) }
                        .accessibilityLabel(unlinking || linking ? "Undo for \(document.displayName)" : "Unlink \(document.displayName)")
                }
                .controlSize(.small)
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
