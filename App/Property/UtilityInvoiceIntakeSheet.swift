// App/Property/UtilityInvoiceIntakeSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction
import GRDB

/// Utility invoice intake (plan phase 5 Task 2): files dropped or added (copied into the
/// evidence library at once), library documents not recorded yet, and new files from the
/// source folders, each read with its provider's rules (OCR for images) and matched to its
/// bank debit. Nothing is recorded until Save; documents this sheet added that end up unused
/// (cancelled, or left out) are removed from the library when it closes. All the logic is
/// `UtilityInvoiceIntake`.
@MainActor
final class UtilityInvoiceIntakeModel: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        var proposal: UtilityInvoiceIntake.Proposal
        var include: Bool
        var providerId: Int64?
        var invoiceNumber: String
        /// `nil` until read or entered: never defaulted.
        var issueDate: Date?
        var amountText: String
        var transactionId: Int64?
        var candidates: [Transaction]
    }

    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary
    let propertyId: Int64
    let currency: Currency
    @Published private(set) var providers: [UtilityProvider] = []
    @Published var rows: [Row] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// Files dropped or added that this sheet put into the library (not there before);
    /// library and folder-scan picks aren't in it and stay.
    private var addedDocumentIds: Set<Int64> = []

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, propertyId: Int64, currency: Currency) {
        self.dbQueue = dbQueue
        self.library = library
        self.propertyId = propertyId
        self.currency = currency
        loadProviders()
    }

    func loadProviders() {
        providers = (try? dbQueue.read { [propertyId] db in try Recharges.providers(db: db, propertyId: propertyId) }) ?? []
    }

    func addProvider(_ preset: UtilityInvoiceRules.Preset) {
        do {
            try dbQueue.write { [propertyId] db in
                var provider = UtilityProvider(propertyId: propertyId, name: preset.name, kind: preset.kind,
                                               bankDescriptionPattern: preset.bankDescriptionPattern, invoiceRules: preset.rules)
                try Recharges.saveProvider(db: db, &provider)
            }
            loadProviders()
        } catch {
            errorMessage = RechargeMessages.text(for: error)
        }
    }

    /// Copies the files into the library and proposes an invoice for each.
    func addFiles(_ urls: [URL]) {
        let (files, skipped) = EvidenceFiles.files(urls)
        infoMessage = EvidenceFiles.skippedMessage(skipped)
        guard !files.isEmpty else { return }
        run { library, propertyId in
            var proposals: [UtilityInvoiceIntake.Proposal] = []
            var added: [Int64] = []
            for url in files {
                let result = try EvidenceFiles.withAccess(url) { try library.addAnalyzing(url) }
                if result.isNew, let id = result.document.id { added.append(id) }
                proposals.append(try UtilityInvoiceIntake.propose(document: result.document, library: library, propertyId: propertyId))
            }
            return (proposals, added)
        }
    }

    /// Library documents that read as utility invoices and aren't recorded.
    func addFromLibrary() {
        run { library, propertyId in
            let documents = try library.database.read { db in try UtilityInvoiceIntake.pendingDocuments(db: db, propertyId: propertyId) }
            return (try documents.map { try UtilityInvoiceIntake.propose(document: $0, library: library, propertyId: propertyId) }, [])
        }
    }

    /// Scans the registered source folders and adds their new files that read as utility
    /// invoices, then proposes every unrecorded one.
    func scanSourceFolders() {
        let providers = providers
        run { library, propertyId in
            let scanner = SourceFolderScanner(library: library)
            for folder in try scanner.sourceFolders() {
                let result = try scanner.scan(folder)
                for file in result.new + result.changed {
                    let text = file.analysis?.extractedText
                    guard UtilityInvoiceIntake.isUtilityInvoice(text: text, fileName: (file.relativePath as NSString).lastPathComponent,
                                                                kind: file.analysis?.metadata.kind, providers: providers) else { continue }
                    try scanner.addToLibrary(file, from: folder)
                }
            }
            let documents = try library.database.read { db in try UtilityInvoiceIntake.pendingDocuments(db: db, propertyId: propertyId) }
            return (try documents.map { try UtilityInvoiceIntake.propose(document: $0, library: library, propertyId: propertyId) }, [])
        }
    }

    private func run(_ work: @escaping @Sendable (EvidenceLibrary, Int64) throws -> ([UtilityInvoiceIntake.Proposal], [Int64])) {
        isWorking = true
        errorMessage = nil
        let library = library, propertyId = propertyId
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work(library, propertyId) } }.value
            isWorking = false
            switch result {
            case .success(let (proposals, added)):
                addedDocumentIds.formUnion(added)
                append(proposals)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private func append(_ proposals: [UtilityInvoiceIntake.Proposal]) {
        let staged = Set(rows.compactMap(\.proposal.documentId))
        for proposal in proposals where proposal.documentId.map({ !staged.contains($0) }) ?? true {
            var row = Row(proposal: proposal, include: proposal.missing.isEmpty, providerId: proposal.reading.providerId,
                          invoiceNumber: proposal.reading.invoiceNumber ?? "",
                          issueDate: proposal.reading.issueDate,
                          amountText: proposal.reading.amountMinorUnits.map(Money.formatInput) ?? "",
                          transactionId: proposal.transactionId, candidates: [])
            refreshCandidates(&row)
            rows.append(row)
        }
        if proposals.isEmpty { infoMessage = "No new utility invoices found." }
    }

    /// The payments the row's amount and date could match.
    func refreshCandidates(_ row: inout Row) {
        guard let amount = Money.parseMinorUnits(row.amountText), amount != 0 else { row.candidates = []; return }
        guard let issueDate = row.issueDate else { row.candidates = []; return }
        let provider = providers.first { $0.id == row.providerId }
        row.candidates = (try? dbQueue.read { [propertyId] db in
            try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: propertyId, provider: provider, amountMinorUnits: amount,
                                                       issueDate: issueDate)
        }) ?? []
        if let chosen = row.transactionId, !row.candidates.contains(where: { $0.id == chosen }) { row.transactionId = nil }
    }

    func invoice(for row: Row) -> UtilityInvoice? {
        guard let providerId = row.providerId, let issueDate = row.issueDate, let amount = Money.parseMinorUnits(row.amountText),
              amount != 0 else { return nil }
        return UtilityInvoice(providerId: providerId, invoiceNumber: row.invoiceNumber, periodStart: row.proposal.reading.periodStart,
                              periodEnd: row.proposal.reading.periodEnd, issueDate: issueDate, amountMinorUnits: amount,
                              documentId: row.proposal.documentId, transactionId: row.transactionId)
    }

    /// Removes the documents this sheet added that no invoice records and nothing links to
    /// (the sheet was cancelled, or they were left out), so nothing changes without Save.
    func discardUnsavedDocuments() {
        let ids = addedDocumentIds
        addedDocumentIds = []
        guard !ids.isEmpty else { return }
        let unused = (try? dbQueue.read { db in
            try ids.filter { id in
                try UtilityInvoice.filter(Column("documentId") == id).fetchCount(db) == 0
                    && DocumentLink.filter(Column("documentId") == id).fetchCount(db) == 0
            }
        }) ?? []
        for id in unused { try? library.remove(id) }
    }

    var includedCount: Int { rows.filter(\.include).count }
    var canSave: Bool {
        let included = rows.filter(\.include)
        let debits = included.compactMap(\.transactionId)
        return !included.isEmpty && included.allSatisfy { invoice(for: $0) != nil } && Set(debits).count == debits.count
    }

    /// What a row still needs before it can be saved.
    func missing(_ row: Row) -> [String] {
        var missing: [String] = []
        if row.providerId == nil { missing.append("provider") }
        if row.issueDate == nil { missing.append("issue date") }
        if Money.parseMinorUnits(row.amountText).map({ $0 == 0 }) ?? true { missing.append("amount") }
        if let debit = row.transactionId, rows.contains(where: { $0.id != row.id && $0.include && $0.transactionId == debit }) {
            missing.append("a debit of its own (another row uses this one)")
        }
        return missing
    }

    /// The row's candidates less the debits other rows have chosen (one invoice per debit).
    func availableCandidates(_ row: Row) -> [Transaction] {
        let taken = Set(rows.filter { $0.id != row.id }.compactMap(\.transactionId))
        return row.candidates.filter { !taken.contains($0.id!) }
    }

    /// Records the included rows in one transaction; `true` when done.
    func save() -> Bool {
        let invoices = rows.filter(\.include).compactMap(invoice(for:))
        do {
            try dbQueue.write { db in
                for var invoice in invoices { try UtilityInvoiceIntake.record(db: db, &invoice) }
            }
            return true
        } catch {
            errorMessage = RechargeMessages.text(for: error)
            return false
        }
    }
}

enum RechargeMessages {
    static func text(for error: Error) -> String {
        guard let error = error as? RechargeError else { return error.localizedDescription }
        switch error {
        case .duplicateInvoiceNumber: return "An invoice with that number is already recorded for this provider."
        case .duplicateName: return "There's already a provider with that name."
        case .invalidPeriod: return "The period's end is before its start."
        case .invoiceOnSentStatement: return "That invoice is on a sent statement: its amount and period can't change."
        case .transactionOnAnotherInvoice: return "That bank movement already settles another invoice."
        case let .invalidPattern(pattern): return "“\(pattern)” isn't a valid regular expression."
        case .laterStatementExists: return "A later month's statement exists: prepare the months in order."
        default: return "Couldn't save (\(error))."
        }
    }
}

struct UtilityInvoiceIntakeSheet: View {
    @StateObject private var model: UtilityInvoiceIntakeModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var picking = false
    @State private var dropTargeted = false

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, propertyId: Int64, currency: Currency) {
        _model = StateObject(wrappedValue: UtilityInvoiceIntakeModel(dbQueue: dbQueue, library: library, propertyId: propertyId, currency: currency))
    }

    var body: some View {
        SheetScaffold(title: "Utility invoices",
                      subtitle: "Drop invoices here, add files, or pick up the ones already in the library or the source folders. Check each line, then Save: the invoice is recorded and its document becomes the evidence of its debit.",
                      error: model.errorMessage, width: 820, onCancel: { model.discardUnsavedDocuments(); dismiss() },
                      primary: SheetAction("Save \(model.includedCount)", isEnabled: model.canSave) { if model.save() { dismiss() } }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(model.providers.isEmpty ? "No providers yet" : model.providers.map(\.name).joined(separator: " · "))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Menu("Add provider") {
                        ForEach(UtilityInvoiceRules.presets) { preset in
                            Button("\(preset.name) (\(preset.kind.displayName.lowercased()))") { model.addProvider(preset) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Button("Add files…") { picking = true }
                    Button("From library") { model.addFromLibrary() }
                    Button("Scan source folders") { model.scanSourceFolders() }
                }
                .disabled(model.isWorking)
                if let info = model.infoMessage {
                    Text(info).font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.rows.isEmpty {
                            Text("Drop invoice files here.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                        ForEach($model.rows) { $row in
                            rowView($row)
                            Divider()
                        }
                    }
                    .padding(6)
                }
                .frame(minHeight: 160, maxHeight: 420)
                .background {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(dropTargeted ? theme.accent : Color.secondary.opacity(0.3), lineWidth: dropTargeted ? 2 : 1)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    model.addFiles(urls)
                    return !urls.isEmpty
                } isTargeted: { dropTargeted = $0 }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: EvidenceFiles.contentTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
        // However it closes (Save, Cancel, Escape): unused new documents go.
        .onDisappear { model.discardUnsavedDocuments() }
    }

    private func rowView(_ row: Binding<UtilityInvoiceIntakeModel.Row>) -> some View {
        let value = row.wrappedValue
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(value.proposal.fileName, isOn: row.include)
                    .lineLimit(1)
                if value.proposal.usedOCR {
                    Text("OCR").font(.caption).foregroundStyle(.secondary).help("Read from the image: check every figure")
                }
                Spacer()
                if let start = value.proposal.reading.periodStart, let end = value.proposal.reading.periodEnd {
                    Text(PropertyFormat.period(start, end)).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Picker("Provider", selection: row.providerId) {
                    Text("Choose…").tag(Int64?.none)
                    ForEach(model.providers) { Text($0.name).tag(Int64?.some($0.id!)) }
                }
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: value.providerId) { _, _ in model.refreshCandidates(&row.wrappedValue) }
                TextField("Invoice no.", text: row.invoiceNumber).frame(width: 170)
                if value.issueDate != nil {
                    DatePicker("Issued", selection: utcOptionalDay(row.issueDate, default: PropertyDays.utcToday(Date())), displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: value.issueDate) { _, _ in model.refreshCandidates(&row.wrappedValue) }
                } else {
                    Button("Set issue date") { row.wrappedValue.issueDate = PropertyDays.utcToday(Date()); model.refreshCandidates(&row.wrappedValue) }
                }
                MoneyField("Amount", text: row.amountText, currency: model.currency, width: 90)
                    .onChange(of: value.amountText) { _, _ in model.refreshCandidates(&row.wrappedValue) }
                Picker("Paid by", selection: row.transactionId) {
                    Text(value.candidates.isEmpty ? "No matching debit" : "Not linked").tag(Int64?.none)
                    ForEach(model.availableCandidates(value), id: \.id) { transaction in
                        Text("\(transaction.date.formatted(date: .abbreviated, time: .omitted)) · \(transaction.rawDescription)")
                            .tag(Int64?.some(transaction.id!))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 160)
            }
            if !model.missing(value).isEmpty {
                Text("Missing: \(model.missing(value).joined(separator: ", "))").font(.callout).foregroundStyle(theme.expense)
            }
        }
    }
}
