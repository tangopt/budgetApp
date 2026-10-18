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

/// The intake sheet (UI polish §4.2): Add files…, From library and Scan source folders; the
/// files as a table — tick, the file with its period and what it still needs, then provider,
/// invoice number, issue date, amount and the debit that paid it, each in its own aligned
/// column; a drop zone while there's nothing yet (the table takes drops too); the providers
/// the invoices are read with, and Add provider.
struct UtilityInvoiceIntakeSheet: View {
    @StateObject private var model: UtilityInvoiceIntakeModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var picking = false
    @State private var dropTargeted = false

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, propertyId: Int64, currency: Currency) {
        _model = StateObject(wrappedValue: UtilityInvoiceIntakeModel(dbQueue: dbQueue, library: library, propertyId: propertyId, currency: currency))
    }

    /// With a model already holding lines (the snapshot harness).
    init(model: UtilityInvoiceIntakeModel) {
        _model = StateObject(wrappedValue: model)
    }

    private var saveTitle: String {
        let count = model.includedCount
        return count == 0 ? "Save" : "Save \(count) invoice\(count == 1 ? "" : "s")"
    }

    var body: some View {
        SheetScaffold(title: "Utility invoices",
                      subtitle: "Drop invoices here, add files, or pick up the ones already in the library or the source folders. Check each line, then Save: the invoice is recorded and its document becomes the evidence of its debit.",
                      error: model.errorMessage, width: SheetMetrics.workspaceWidth, onCancel: { model.discardUnsavedDocuments(); dismiss() },
                      primary: SheetAction(saveTitle, isEnabled: model.canSave) { if model.save() { dismiss() } }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button("Add files…") { picking = true }
                        .help("PDFs or images of invoices: copied into the library and read")
                    Button("From library") { model.addFromLibrary() }
                        .help("Documents in the library that read as utility invoices and aren't recorded yet")
                    Button("Scan source folders") { model.scanSourceFolders() }
                        .help("New files in the source folders that read as utility invoices")
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                        Text("Reading…").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if !model.rows.isEmpty {
                        Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .disabled(model.isWorking)
                if let info = model.infoMessage {
                    InlineBanner(.info, info) { model.infoMessage = nil }
                }
                if model.rows.isEmpty {
                    dropZone
                } else {
                    rowsPanel
                }
                providersRow
                    .disabled(model.isWorking)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: EvidenceFiles.contentTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
        // However it closes (Save, Cancel, Escape): unused new documents go.
        .onDisappear { model.discardUnsavedDocuments() }
    }

    /// "3 invoices · 2 to save · 1 needs something".
    private var status: String {
        let needing = model.rows.filter { $0.include && !model.missing($0).isEmpty }.count
        var parts = ["\(model.rows.count) invoice\(model.rows.count == 1 ? "" : "s")", "\(model.includedCount) ticked"]
        if needing > 0 { parts.append("\(needing) need\(needing == 1 ? "s" : "") something") }
        return parts.joined(separator: " · ")
    }

    // MARK: Drop

    private func droppable<Content: View>(_ content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                model.addFiles(urls)
                return !urls.isEmpty
            } isTargeted: { dropTargeted = $0 }
    }

    private var dropZone: some View {
        droppable(
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(dropTargeted ? theme.accent : .secondary)
                    .accessibilityHidden(true)
                Text("Drop invoice PDFs or images here").font(.title3.weight(.semibold))
                Text("Or use Add files…, From library or Scan source folders above. Each is read with its provider's rules.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius)
                .fill(dropTargeted ? theme.accent.opacity(0.06) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius)
                .strokeBorder(dropTargeted ? theme.accent : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 4])))
        )
    }

    // MARK: Rows

    /// A row of the table: the id of its row in `model.rows`. Cells find their row by id, never
    /// by position, so a reload or a removal can't leave a cell (a focused field) pointing past
    /// the end (the statement sheet's lines do the same).
    private struct IntakeLine: Identifiable {
        let id: UUID
    }

    private typealias Row = UtilityInvoiceIntakeModel.Row

    /// The row `id` as it is now (`nil` once it's gone).
    private func row(_ id: UUID) -> Row? { model.rows.first { $0.id == id } }

    /// A field of the row `id` as a binding, by id: the row as it is now (`fallback` once it's
    /// gone), and a write to a row that's gone does nothing.
    private func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<Row, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { row(id)?[keyPath: keyPath] ?? fallback },
                set: { value in
                    guard let index = model.rows.firstIndex(where: { $0.id == id }) else { return }
                    model.rows[index][keyPath: keyPath] = value
                })
    }

    /// The debits that could have paid row `id`, again after a change to what they match on.
    private func refreshCandidates(_ id: UUID) {
        guard let index = model.rows.firstIndex(where: { $0.id == id }) else { return }
        model.refreshCandidates(&model.rows[index])
    }

    private var rowsPanel: some View {
        let lines = model.rows.map { IntakeLine(id: $0.id) }
        return droppable(
            Panel(padding: 10) {
                // Always in a scroll view (its height the rows', at most 340 pt), so the table
                // keeps its identity as rows come and go.
                ScrollView { DataTable(columns: columns, rows: lines) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius).strokeBorder(theme.accent, lineWidth: 2)
                }
            }
        )
    }

    private var columns: [DataTableColumn<IntakeLine>] {
        [
            DataTableColumn("", alignment: .center, width: .fixed(30)) { line, _ in
                Toggle("Include", isOn: binding(line.id, \.include, fallback: false))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("Save \(row(line.id)?.proposal.fileName ?? "the file")")
            },
            DataTableColumn("File", width: .fill(min: 200)) { line, _ in fileCell(line.id) },
            DataTableColumn("Provider", width: .fixed(144)) { line, _ in providerCell(line.id) },
            DataTableColumn("Invoice no.", width: .fixed(124)) { line, _ in
                TextField("Invoice no.", text: binding(line.id, \.invoiceNumber, fallback: ""))
                    .accessibilityLabel("Invoice number")
            },
            // Issued and Amount as narrow as their controls, so the file's name gets the room.
            DataTableColumn("Issued", width: .fit) { line, _ in issuedCell(line.id) },
            DataTableColumn("Amount (\(model.currency.rawValue.uppercased()))", alignment: .trailing, width: .min(92)) { line, _ in
                MoneyField("Amount", text: binding(line.id, \.amountText, fallback: ""), currency: model.currency, width: 76, showsCurrency: false)
                    .onChange(of: row(line.id)?.amountText) { _, _ in refreshCandidates(line.id) }
            },
            DataTableColumn("Paid by", width: .fixed(190)) { line, _ in paidByCell(line.id) }
        ]
    }

    /// The file (and OCR, when it was read from an image), then what it still needs — or,
    /// when nothing, the period the invoice covers.
    @ViewBuilder
    private func fileCell(_ id: UUID) -> some View {
        if let row = row(id) {
            let missing = model.missing(row)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: row.proposal.usedOCR ? "photo" : "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(row.proposal.fileName).lineLimit(1).truncationMode(.middle).help(row.proposal.fileName)
                    if row.proposal.usedOCR {
                        StatusPill("OCR", tone: .warning, help: "Read from the image: check every figure")
                    }
                }
                if !missing.isEmpty && row.include {
                    Label("Needs \(missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(theme.pending)
                        .lineLimit(1)
                        .help("Missing: \(missing.joined(separator: ", "))")
                } else if let start = row.proposal.reading.periodStart, let end = row.proposal.reading.periodEnd {
                    Text(RechargeFormat.period(start, end)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            .opacity(row.include ? 1 : 0.55)
        }
    }

    private func providerCell(_ id: UUID) -> some View {
        Picker("Provider", selection: binding(id, \.providerId, fallback: nil)) {
            Text("Choose…").tag(Int64?.none)
            ForEach(model.providers) { Text($0.name).tag(Int64?.some($0.id!)) }
        }
        .labelsHidden()
        .accessibilityLabel("Provider")
        // Still to choose: outlined in the to-do colour.
        .overlay {
            if let row = row(id), row.providerId == nil && row.include {
                RoundedRectangle(cornerRadius: 6).strokeBorder(theme.pending, lineWidth: 1.5)
            }
        }
        .onChange(of: row(id)?.providerId) { _, _ in refreshCandidates(id) }
    }

    @ViewBuilder
    private func issuedCell(_ id: UUID) -> some View {
        if row(id)?.issueDate != nil {
            DatePicker("Issued", selection: utcOptionalDay(binding(id, \.issueDate, fallback: nil), default: PropertyDays.utcToday(AppClock.now)),
                       displayedComponents: .date)
                .labelsHidden()
                .fixedSize()
                .onChange(of: row(id)?.issueDate) { _, _ in refreshCandidates(id) }
        } else {
            Button("Set date") {
                binding(id, \.issueDate, fallback: nil).wrappedValue = PropertyDays.utcToday(AppClock.now)
                refreshCandidates(id)
            }
            .controlSize(.small)
            .help("Not read from the invoice: set its issue date")
        }
    }

    @ViewBuilder
    private func paidByCell(_ id: UUID) -> some View {
        if let row = row(id) {
            Picker("Paid by", selection: binding(id, \.transactionId, fallback: nil)) {
                Text(row.candidates.isEmpty ? "No matching debit" : "Not linked").tag(Int64?.none)
                ForEach(model.availableCandidates(row), id: \.id) { transaction in
                    Text("\(DocumentFormat.day(transaction.date)) · \(transaction.rawDescription)")
                        .tag(Int64?.some(transaction.id!))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Paid by")
        }
    }

    // MARK: Providers

    private var providersRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Read with").foregroundStyle(.secondary)
            if model.providers.isEmpty {
                Text("No providers yet: add one so invoices are recognised.").font(.callout).foregroundStyle(.secondary)
            } else {
                ChipFlow {
                    ForEach(model.providers) { provider in
                        NameChip(systemImage: RechargeFormat.icon(provider.kind), title: provider.name)
                    }
                }
            }
            Menu("Add provider") {
                ForEach(UtilityInvoiceRules.presets) { preset in
                    Button("\(preset.name) (\(preset.kind.displayName.lowercased()))") { model.addProvider(preset) }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Adds a provider from a preset (with its reading rules); edit it in Providers… on the Recharges tab")
        }
    }
}
