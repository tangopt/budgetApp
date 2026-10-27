import Combine
import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Property
import struct BudgetCore.Transaction

/// Every action the iPad's Tenancies screen offers (step 10, Task 13), each one of the Mac Tenancies tab's or its rent
/// receipt panel's, made through the device writer (filed years checked, a refusal under the row it was made on).
public enum PadTenanciesAction: String, CaseIterable, Sendable {
    /// A tenancy made by hand (`Tenancies.save`).
    case newTenancy
    /// Its terms and rent history (`Tenancies.save` + `setRents`).
    case editTenancy
    /// The tenancy with its receipts and their credit links (`Tenancies.delete`), behind a confirmation.
    case deleteTenancy
    /// A library document linked as the tenancy's contract.
    case addContract
    /// The contract's documents: view or unlink.
    case contractDocuments
    /// Rent credits matched to the receipts they paid (`RentReceiptMatching.match`).
    case matchCredits
    /// The utility sites in the built-in browser.
    case utilityInvoices
    /// Portal das Finanças in the built-in browser: the receipts' PDFs go through the tray and Check and link.
    case fetchFromPortal
    /// The receipt in the document panel.
    case viewReceipt
    /// A rent credit linked to the receipt (`RentReceiptMatching.link`).
    case linkPayment
    /// The credit that paid it swapped for another.
    case changePayment
    /// A credit taken off the receipt (`RentReceiptMatching.unlink`).
    case unlinkPayment
    /// The credit that paid it: its details, and the Edit it offers.
    case showCredit
    /// A library document linked as the receipt's PDF.
    case addDocument
    /// The receipt's PDF swapped for another from the library.
    case replaceDocument
    /// The receipt's documents: view or unlink.
    case receiptDocuments
    /// The receipt's PDF selected on the Documents screen.
    case showInDocuments

    public var title: String {
        switch self {
        case .newTenancy: "New tenancy"
        case .editTenancy: "Edit tenancy"
        case .deleteTenancy: "Delete tenancy"
        case .addContract: "Add contract"
        case .contractDocuments: "Contract documents"
        case .matchCredits: "Match credits"
        case .utilityInvoices: "Utility invoices"
        case .fetchFromPortal: "Fetch from Portal das Finanças"
        case .viewReceipt: "View receipt"
        case .linkPayment: "Link payment"
        case .changePayment: "Change"
        case .unlinkPayment: "Unlink payment"
        case .showCredit: "Show the credit"
        case .addDocument: "Add the receipt PDF"
        case .replaceDocument: "Replace PDF"
        case .receiptDocuments: "Documents"
        case .showInDocuments: "Show in Documents"
        }
    }

    /// The name a filed-year question gives the edit.
    var edit: String {
        switch self {
        case .newTenancy: "Tenancy added"
        case .editTenancy: "Tenancy saved"
        case .deleteTenancy: "Tenancy deleted, with its receipts and recharge statements"
        case .addContract: "Contract linked"
        case .matchCredits: "Rent credits matched to receipts"
        case .linkPayment: "Link payment"
        case .changePayment: "Change payment"
        case .unlinkPayment: "Rent credit unlinked from its receipt"
        case .addDocument: "Receipt PDF linked"
        case .replaceDocument: "Receipt PDF replaced"
        case .contractDocuments, .receiptDocuments: "Document unlinked"
        case .utilityInvoices, .fetchFromPortal, .viewReceipt, .showCredit, .showInDocuments: title
        }
    }

    /// The icon button the action is drawn as in a row (the shared vocabulary); nil for the ones drawn as text.
    var rowAction: RowAction? {
        switch self {
        case .viewReceipt: .view
        case .linkPayment: .linkPayment
        case .unlinkPayment: .unlink
        case .addDocument, .addContract: .linkDocument
        case .fetchFromPortal, .utilityInvoices: .openSite
        case .newTenancy, .editTenancy, .deleteTenancy, .contractDocuments, .matchCredits, .changePayment, .showCredit,
             .replaceDocument, .receiptDocuments, .showInDocuments: nil
        }
    }

    /// Whether the action writes (hidden, not disabled, without Edit on Property).
    public var edits: Bool {
        switch self {
        case .newTenancy, .editTenancy, .deleteTenancy, .addContract, .matchCredits, .linkPayment, .changePayment, .unlinkPayment,
             .addDocument, .replaceDocument: true
        case .contractDocuments, .receiptDocuments, .utilityInvoices, .fetchFromPortal, .viewReceipt, .showCredit, .showInDocuments: false
        }
    }

    /// The Mac's Tenancies tab and receipt panel actions, by the name the Mac gives them, and the action that answers each
    /// here. `testEveryMacTenancyActionIsListed` keeps the two lists whole. The receipts export (.xlsx) is imported on the
    /// Mac (Check and link sends it there); its receipts' PDFs come through the portal's downloads.
    static let macActions: [(mac: String, pad: PadTenanciesAction)] = [
        ("New tenancy…", .newTenancy),
        ("Match credits", .matchCredits),
        ("Utility invoices…", .utilityInvoices),
        ("Import receipts…", .fetchFromPortal),
        ("Edit…", .editTenancy),
        ("Add contract…", .addContract),
        ("Contract documents…", .contractDocuments),
        ("Delete tenancy…", .deleteTenancy),
        ("Receipt details", .viewReceipt),
        ("View receipt PDF", .viewReceipt),
        ("Open in Preview", .viewReceipt),
        ("Show in Documents", .showInDocuments),
        ("Show the credit", .showCredit),
        ("Edit transaction", .showCredit),
        ("Unlink the credit", .unlinkPayment),
        ("Replace PDF…", .replaceDocument),
        ("Add the receipt PDF…", .addDocument),
        ("Add another PDF…", .addDocument),
        ("Documents…", .receiptDocuments),
    ]
}

/// A tenancy being made or edited in the form: text as typed, checked and built into a `Tenancy` and its rents on Save.
public struct PadTenancyDraft: Equatable, Identifiable, Sendable {
    public struct RentRow: Equatable, Identifiable, Sendable {
        public let id: UUID
        public var from: Date
        public var amountText: String

        public init(id: UUID = UUID(), from: Date, amountText: String) {
            self.id = id
            self.from = from
            self.amountText = amountText
        }
    }

    public let id = UUID()
    public let existing: Tenancy?
    public let propertyId: Int64
    public var reference = ""
    public var contract = ""
    public var tenant = ""
    public var email = ""
    public var start: Date
    public var end: Date?
    public var advanceMonths = 0
    public var depositMonths = 0
    public var notes = ""
    public var rents: [RentRow] = []

    public init(_ tenancy: Tenancy?, rents: [TenancyRent], propertyId: Int64, today: Date) {
        existing = tenancy
        self.propertyId = propertyId
        start = today
        guard let tenancy else { return }
        reference = tenancy.referenceLabel
        contract = tenancy.contractNumber ?? ""
        tenant = tenancy.tenantName ?? ""
        email = tenancy.tenantEmail ?? ""
        start = tenancy.startDate
        end = tenancy.endDate
        advanceMonths = tenancy.advanceRentMonths
        depositMonths = tenancy.depositMonths
        notes = tenancy.notes ?? ""
        self.rents = rents.map { RentRow(from: $0.fromDate, amountText: Money.formatInput($0.monthlyAmountMinorUnits)) }
    }

    public static func == (lhs: PadTenancyDraft, rhs: PadTenancyDraft) -> Bool { lhs.id == rhs.id }

    /// Whether Save is offered: a reference is typed.
    public var canSave: Bool { !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The tenancy and rents the form describes, or why not (in plain words, shown inside the form).
    public func build() -> Result<(Tenancy, [TenancyRent]), PadTenancyDraftError> {
        var rents: [TenancyRent] = []
        for row in self.rents {
            guard let amount = Money.parseMinorUnits(row.amountText), amount >= 0 else {
                return .failure(PadTenancyDraftError("“\(row.amountText)” isn't an amount."))
            }
            rents.append(TenancyRent(tenancyId: existing?.id ?? 0, fromDate: row.from, monthlyAmountMinorUnits: amount))
        }
        var tenancy = existing ?? Tenancy(propertyId: propertyId, referenceLabel: "", startDate: start)
        tenancy.referenceLabel = reference
        tenancy.contractNumber = contract
        tenancy.tenantName = tenant
        tenancy.tenantEmail = email
        tenancy.startDate = start
        tenancy.endDate = end
        tenancy.advanceRentMonths = advanceMonths
        tenancy.depositMonths = depositMonths
        tenancy.notes = notes
        return .success((tenancy, rents))
    }
}

public struct PadTenancyDraftError: Error, Equatable, LocalizedError, Sendable {
    public var message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    /// The Mac's words for what a tenancy save refuses.
    init?(_ error: PropertyError) {
        switch error {
        case .blankReference: message = "Enter the tenancy's reference."
        case .duplicateContractNumber: message = "Another tenancy of this property has that contract number."
        case .negativeMonths: message = "Months can't be negative."
        case .negativeAmount: message = "Amounts can't be negative."
        case .duplicateRentDate: message = "Two rents start on the same day."
        case .invalidDateRange: message = "An end date is before its start date."
        case .invalidEmail(let text): message = "“\(text)” isn't an email address."
        case .tenancyNotFound: message = "The tenancy no longer exists."
        case .propertyNotFound: message = "The property no longer exists."
        default: return nil
        }
    }
}

/// The iPad Tenancies screen's state (step 10, Task 13): the selected tenancy's rent history, contract documents and rent
/// receipts (by month, with the credits that paid them), the receipt open in the document panel, and every write. It
/// replaces step 8's Rent receipts model. Nothing here computes a figure: it reads the Mac's read models
/// (`PropertyPage.receiptRows`, `Tenancies.rents`) and writes through `PadWriteModel`.
@MainActor
public final class PadTenanciesModel: ObservableObject {
    public enum ReceiptStatus: Equatable, Sendable {
        case paid, partPaid, notMatched, cancelled

        public var name: String {
            switch self {
            case .paid: "Paid"
            case .partPaid: "Part paid"
            case .notMatched: "Not matched"
            case .cancelled: "Cancelled"
            }
        }
    }

    public struct Receipt: Equatable, Identifiable, Sendable {
        public var row: TenancyReceiptRow
        /// The bank (or the account's name) each paying credit sits in, by account id.
        public var banks: [Int64: String]
        public var currency: Currency
        public var receipt: RentReceipt { row.receipt }
        public var id: Int64 { row.id }
        /// The rent the receipt's active links cover.
        public var coveredMinorUnits: Int { row.paidMinorUnits }
        public var isCovered: Bool { coveredMinorUnits >= receipt.amountReceivedMinorUnits }
        var rowId: String { "receipt\(id)" }

        public var status: ReceiptStatus {
            if receipt.status == .cancelled { return .cancelled }
            if row.isPaid { return .paid }
            return row.payments.isEmpty ? .notMatched : .partPaid
        }

        /// One line per credit that paid it.
        public var paidLines: [PaidLine] {
            row.payments.map { info in
                let transaction = info.transaction
                let bank = banks[transaction.accountId] ?? ""
                return PaidLine(transactionId: transaction.id ?? 0,
                                text: PadTenanciesModel.paidLine(amountMinorUnits: transaction.amountMinorUnits, date: transaction.date,
                                                                 bank: bank, currency: currency))
            }
        }
    }

    /// "Rent paid: tenant transfer of €1,200.00 on 12 Oct 2026 · BBVA", and the credit it names.
    public struct PaidLine: Equatable, Sendable {
        public var transactionId: Int64
        public var text: String
    }

    public struct Snapshot: Equatable, Sendable {
        public var tenancyId: Int64?
        public var rents: [TenancyRent]
        /// The documents linked as the tenancy's contract.
        public var contractDocumentIds: [Int64]
        /// Latest rent period first.
        public var receipts: [Receipt]

        public static let empty = Snapshot(tenancyId: nil, rents: [], contractDocumentIds: [], receipts: [])
    }

    /// One year of receipts, latest month first.
    public struct Year: Equatable, Identifiable, Sendable {
        public var year: Int
        public var receipts: [Receipt]
        public var id: Int { year }
    }

    @Published public private(set) var detail: Snapshot = .empty
    /// The receipt whose panel is open.
    @Published public var selectedReceiptId: Int64?

    public let property: PadPropertyModel
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private var generation = 0
    private var isPreloaded = false
    private var forwarding: AnyCancellable?

    /// How many credits "Link payment" and "Change" offer.
    static let choiceLimit = 5
    /// The row a refusal of a screen-wide action shows under.
    static let screenRow = "tenancies"
    /// Where a refusal of a tenancy's own edit shows (inside its form, or under its details).
    static func tenancyRow(_ id: Int64?) -> String { "tenancy\(id ?? 0)" }
    static let formRow = "tenancyForm"

    public init(property: PadPropertyModel, write: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.property = property
        self.write = write
        self.dbQueue = dbQueue
        self.today = today
        forwarding = property.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Reading

    public func preload(_ snapshot: Snapshot) {
        detail = snapshot
        isPreloaded = true
    }

    public func reload() async {
        guard !isPreloaded else { return }
        await read()
    }

    private func read() async {
        generation += 1
        let mine = generation
        guard let tenancyId = property.selectedTenancyId else {
            detail = .empty
            selectedReceiptId = nil
            return
        }
        let reader = dbQueue
        guard let read = try? await reader.read({ db in try Self.read(db, tenancyId: tenancyId) }), mine == generation else { return }
        detail = read
        if let id = selectedReceiptId, !read.receipts.contains(where: { $0.id == id }) { selectedReceiptId = nil }
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, tenancyId: Int64?) -> Snapshot {
        guard let tenancyId else { return .empty }
        return (try? dbQueue.read { db in try read(db, tenancyId: tenancyId) }) ?? .empty
    }

    nonisolated static func read(_ db: Database, tenancyId: Int64) throws -> Snapshot {
        let currency = try Tenancy.fetchOne(db, key: tenancyId).flatMap { try Property.fetchOne(db, key: $0.propertyId) }?.currency ?? .gbp
        let rows = try TenancyReceipts.rows(db: db, tenancyId: tenancyId)
        let accountIds = Set(rows.flatMap { $0.payments.map(\.transaction.accountId) })
        let banks = Dictionary(uniqueKeysWithValues: try Account.filter(keys: Array(accountIds)).fetchAll(db).compactMap { account in
            account.id.map { ($0, bankLabel(account)) }
        })
        let receipts = rows.sorted { $0.receipt.periodStart > $1.receipt.periodStart }.map {
            Receipt(row: $0, banks: banks, currency: currency)
        }
        return Snapshot(tenancyId: tenancyId, rents: try Tenancies.rents(db: db, tenancyId: tenancyId),
                        contractDocumentIds: try EvidenceLinks.documents(db: db, for: .tenancy(tenancyId)).compactMap(\.id),
                        receipts: receipts)
    }

    /// The bank's name where the account has one, else the account's.
    nonisolated static func bankLabel(_ account: Account) -> String {
        let bank = account.bankName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return bank.isEmpty ? account.displayName : bank
    }

    // MARK: Words

    /// The line under a receipt's details: "Rent paid: tenant transfer of €1,200.00 on 12 Oct 2026 · BBVA".
    public nonisolated static func paidLine(amountMinorUnits: Int, date: Date, bank: String, currency: Currency) -> String {
        let line = "Rent paid: tenant transfer of \(Money.format(amountMinorUnits, currency: currency)) on \(PhoneDateFormat.day(date))"
        return bank.isEmpty ? line : "\(line) · \(bank)"
    }

    public var currency: Currency { property.property?.currency ?? .gbp }

    /// "October 2026" for a receipt's rent period.
    public static func monthTitle(_ receipt: Receipt) -> String {
        RechargeEmail.monthName(receipt.receipt.periodStart, language: .english)
    }

    /// The tenancy's receipts by year, latest year first.
    public var years: [Year] {
        let byYear = Dictionary(grouping: detail.receipts) { MonthRange.components(of: $0.receipt.periodStart).year }
        return byYear.keys.sorted(by: >).map { Year(year: $0, receipts: byYear[$0]!) }
    }

    /// The tenancy's rent today (else its latest).
    public var rentInForce: TenancyRent? {
        let day = today()
        return detail.rents.last { $0.fromDate <= day } ?? detail.rents.last
    }

    public var issuedCount: Int { detail.receipts.filter { $0.receipt.status == .issued }.count }
    public var paidCount: Int { detail.receipts.filter { $0.status == .paid }.count }

    // MARK: Selection

    public var selectedReceipt: Receipt? {
        guard let id = selectedReceiptId else { return nil }
        return detail.receipts.first { $0.id == id }
    }

    /// The receipt's PDF the panel opens (the first one linked).
    public var selectedDocumentId: Int64? { selectedReceipt?.row.documentIds.first }

    public func select(_ receipt: Receipt) { selectedReceiptId = receipt.id }
    public func closePanel() { selectedReceiptId = nil }

    // MARK: What is offered

    /// The screen-wide actions, in the More menu's order: edits only with Edit on Property.
    public func screenActions(hasBrowser: Bool) -> [PadTenanciesAction] {
        var actions: [PadTenanciesAction] = []
        if write.canEdit { actions.append(.newTenancy) }
        if hasBrowser { actions.append(contentsOf: [.fetchFromPortal, .utilityInvoices]) }
        if write.canEdit { actions.append(.matchCredits) }
        return actions
    }

    /// The selected tenancy's own actions.
    public func tenancyActions() -> [PadTenanciesAction] {
        var actions: [PadTenanciesAction] = []
        if write.canEdit { actions.append(contentsOf: [.editTenancy, .addContract]) }
        if !detail.contractDocumentIds.isEmpty { actions.append(.contractDocuments) }
        if write.canEdit { actions.append(.deleteTenancy) }
        return actions
    }

    /// What `receipt` offers: view always; the credit and PDF actions its state asks for, edits only with Edit.
    public func actions(for receipt: Receipt) -> [PadTenanciesAction] {
        var actions: [PadTenanciesAction] = [.viewReceipt]
        let issued = receipt.receipt.status == .issued
        let documents = receipt.row.documentCount
        if write.canEdit, issued, !receipt.isCovered { actions.append(.linkPayment) }
        if !receipt.row.payments.isEmpty {
            actions.append(.showCredit)
            if write.canEdit { actions.append(contentsOf: [.changePayment, .unlinkPayment]) }
        }
        if documents == 0, issued {
            if write.canEdit { actions.append(.addDocument) }
            actions.append(.fetchFromPortal)
        }
        if documents > 0 {
            actions.append(contentsOf: [.showInDocuments, .receiptDocuments])
            if write.canEdit {
                if documents == 1 { actions.append(.replaceDocument) }
                actions.append(.addDocument)
            }
        }
        return actions
    }

    /// The portal's saved site: the tax site named like Portal das Finanças, else the first tax site.
    static func portalSite(in sites: [SavedSite]) -> SavedSite? {
        PadThisMonthModel.site(in: sites, kind: .tax, name: "Portal das Finanças")
    }

    // MARK: Candidates

    /// The property's rent credits with something left after their rent and recharge links, closest to the receipt's date
    /// (else its rent period's start) first.
    public func candidates(for receipt: Receipt) async -> [Transaction] {
        guard let propertyId = property.property?.id else { return [] }
        let expected = receipt.receipt.receiptDate ?? receipt.receipt.periodStart
        let limit = Self.choiceLimit
        return (try? await dbQueue.read { db in
            let credits = try RentReceiptMatching.candidateCredits(db: db, propertyId: propertyId)
                .filter { try Recharges.creditRemainder(db: db, transactionId: $0.id!) > 0 }
            return Array(credits.sorted { abs($0.date.timeIntervalSince(expected)) < abs($1.date.timeIntervalSince(expected)) }.prefix(limit))
        }) ?? []
    }

    /// Library documents that could be `receipt`'s PDF: rent receipts not linked to a receipt yet, those of its period first.
    public func receiptDocuments(for receipt: Receipt) async -> [EvidenceDocument] {
        let period = receipt.receipt.periodStart
        return (try? await dbQueue.read { db in
            let linked = Set(try EvidenceLinks.linkedDocumentIds(db: db, .rentReceipt).values.flatMap { $0 })
            let own = Set(receipt.row.documentIds)
            return try EvidenceDocument.filter(Column("kind") == DocumentKind.rentReceipt.rawValue).fetchAll(db)
                .filter { document in document.id.map { !linked.contains($0) && !own.contains($0) } ?? false }
                .sorted { Self.distance($0, to: period) < Self.distance($1, to: period) }
        }) ?? []
    }

    /// Library documents that could be the tenancy's contract: rent contracts not linked to a tenancy yet.
    public func contractCandidates() async -> [EvidenceDocument] {
        let own = Set(detail.contractDocumentIds)
        return (try? await dbQueue.read { db in
            let linked = Set(try EvidenceLinks.linkedDocumentIds(db: db, .tenancy).values.flatMap { $0 })
            return try EvidenceDocument.filter(Column("kind") == DocumentKind.rentContract.rawValue)
                .order(Column("docDate").desc).fetchAll(db)
                .filter { document in document.id.map { !linked.contains($0) && !own.contains($0) } ?? false }
        }) ?? []
    }

    private nonisolated static func distance(_ document: EvidenceDocument, to day: Date) -> TimeInterval {
        guard let when = document.periodStart ?? document.docDate else { return .greatestFiniteMagnitude }
        return abs(when.timeIntervalSince(day))
    }

    /// The documents linked to `entity`, for the sheets that list them.
    public func linkedDocuments(of entity: EvidenceEntity) async -> [EvidenceDocument] {
        (try? await dbQueue.read { db in try EvidenceLinks.documents(db: db, for: entity) }) ?? []
    }

    /// A credit as a search row, for its detail sheet (and the Edit it offers).
    public func creditRow(transactionId: Int64) async -> TransactionSearch.Row? {
        try? await dbQueue.read { db in
            guard let transaction = try Transaction.fetchOne(db, key: transactionId) else { return nil }
            let account = try Account.fetchOne(db, key: transaction.accountId)
            let category = try transaction.categoryId.flatMap { try Category.fetchOne(db, key: $0) }
            return TransactionSearch.Row(transaction: transaction, category: category, categoryName: category?.name ?? "",
                                         accountName: account?.displayName ?? "", currency: account?.currency ?? .gbp,
                                         isLinkedTransfer: false, outgoingTransactionId: nil)
        }
    }

    // MARK: Writes: payments

    /// Links credit `transactionId` to `receipt` (the rent it still needs, as far as the credit goes).
    @discardableResult
    public func link(_ receipt: Receipt, transactionId: Int64) async -> Bool {
        let receiptId = receipt.id
        let saved = await write.perform(rowId: receipt.rowId, origin: .propertyMatching, edit: PadTenanciesAction.linkPayment.edit,
                                        scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            _ = try RentReceiptMatching.link(db: db, receiptId: receiptId, transactionId: transactionId)
        }
        if saved { await refresh() }
        return saved
    }

    /// Swaps the credit `old` that paid `receipt` for `transactionId`, in one write: both or neither.
    @discardableResult
    public func change(_ receipt: Receipt, from old: Int64, to transactionId: Int64) async -> Bool {
        let receiptId = receipt.id
        let saved = await write.perform(rowId: receipt.rowId, origin: .propertyMatching, edit: PadTenanciesAction.changePayment.edit,
                                        scope: FiledYearEditCheck.Scope(transactionIds: [old, transactionId])) { db in
            _ = try RentReceiptMatching.unlink(db: db, receiptId: receiptId, transactionId: old)
            _ = try RentReceiptMatching.link(db: db, receiptId: receiptId, transactionId: transactionId)
        }
        if saved { await refresh() }
        return saved
    }

    /// Takes credit `transactionId` off `receipt` (the credit stays in the bank's records).
    @discardableResult
    public func unlink(_ receipt: Receipt, transactionId: Int64) async -> Bool {
        let receiptId = receipt.id
        let saved = await write.perform(rowId: receipt.rowId, origin: .propertyMatching, edit: PadTenanciesAction.unlinkPayment.edit,
                                        scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            _ = try RentReceiptMatching.unlink(db: db, receiptId: receiptId, transactionId: transactionId)
        }
        if saved { await refresh() }
        return saved
    }

    /// Links the property's rent credits to the receipts they paid.
    @discardableResult
    public func matchCredits() async -> Bool {
        guard let propertyId = property.property?.id else { return false }
        let saved = await write.perform(rowId: Self.screenRow, origin: .propertyMatching, edit: PadTenanciesAction.matchCredits.edit,
                                        scope: .everyYear) { db in
            _ = try RentReceiptMatching.match(db: db, propertyId: propertyId)
        }
        if saved { await refresh() }
        return saved
    }

    // MARK: Writes: documents

    /// Links library document `documentId` as `receipt`'s PDF; with `replacing`, the documents now linked are unlinked.
    @discardableResult
    public func linkDocument(_ receipt: Receipt, documentId: Int64, replacing: [Int64] = []) async -> Bool {
        let entity = EvidenceEntity.rentReceipt(receipt.id)
        let saved = await write.perform(rowId: receipt.rowId, origin: .documentLink,
                                        edit: (replacing.isEmpty ? PadTenanciesAction.addDocument : .replaceDocument).edit,
                                        scope: FiledYearEditCheck.Scope()) { db in
            for old in replacing { _ = try EvidenceLinks.unlink(db: db, documentId: old, from: entity) }
            _ = try EvidenceLinks.link(db: db, documentId: documentId, to: entity, role: "Receipt")
        }
        if saved { await refresh() }
        return saved
    }

    /// Links library document `documentId` as the selected tenancy's contract.
    @discardableResult
    public func linkContract(documentId: Int64) async -> Bool {
        guard let tenancyId = property.selectedTenancyId else { return false }
        let saved = await write.perform(rowId: Self.tenancyRow(tenancyId), origin: .documentLink,
                                        edit: PadTenanciesAction.addContract.edit, scope: FiledYearEditCheck.Scope()) { db in
            _ = try EvidenceLinks.link(db: db, documentId: documentId, to: .tenancy(tenancyId), role: "Contract")
        }
        if saved { await refresh() }
        return saved
    }

    /// Takes `documentId` off `entity` (the document stays in the library).
    @discardableResult
    public func unlinkDocument(_ documentId: Int64, from entity: EvidenceEntity, rowId: String) async -> Bool {
        let saved = await write.perform(rowId: rowId, origin: .documentLink, edit: "Document unlinked", scope: FiledYearEditCheck.Scope()) { db in
            _ = try EvidenceLinks.unlink(db: db, documentId: documentId, from: entity)
        }
        if saved { await refresh() }
        return saved
    }

    // MARK: Writes: tenancies

    /// A blank form for a new tenancy of the property, or the selected tenancy's to edit.
    public func draft(editing tenancy: Tenancy?) -> PadTenancyDraft? {
        guard let propertyId = property.property?.id else { return nil }
        return PadTenancyDraft(tenancy, rents: tenancy == nil ? [] : detail.rents, propertyId: propertyId,
                               today: MonthRange.calendar.startOfDay(for: today()))
    }

    /// Saves the tenancy and its rent history together; the new or edited tenancy is selected. A refusal shows in the form.
    @discardableResult
    public func save(_ draft: PadTenancyDraft) async -> Bool {
        let built: (Tenancy, [TenancyRent])
        switch draft.build() {
        case .success(let value): built = value
        case .failure(let failure):
            write.refuse(rowId: Self.formRow, message: failure.message)
            return false
        }
        let action: PadTenanciesAction = draft.existing == nil ? .newTenancy : .editTenancy
        let saved = await write.saving(rowId: Self.formRow, origin: .edit, edit: action.edit, scope: .everyYear) { db -> Int64 in
            var tenancy = built.0
            do {
                try Tenancies.save(db: db, &tenancy)
                _ = try Tenancies.setRents(db: db, tenancyId: tenancy.id!, built.1)
            } catch let error as PropertyError {
                if let words = PadTenancyDraftError(error) { throw words }
                throw error
            }
            return tenancy.id!
        }
        guard let id = saved else { return false }
        isPreloaded = false
        property.selectedTenancyId = id
        await refresh()
        return true
    }

    /// Deletes the tenancy with its rent history, receipts and their credit links (linked documents stay in the library).
    @discardableResult
    public func delete(_ tenancy: Tenancy) async -> Bool {
        guard let id = tenancy.id else { return false }
        let saved = await write.perform(rowId: Self.tenancyRow(id), origin: .edit, edit: PadTenanciesAction.deleteTenancy.edit,
                                        scope: .everyYear) { db in
            _ = try Tenancies.delete(db: db, id: id)
        }
        if saved {
            selectedReceiptId = nil
            await refresh()
        }
        return saved
    }

    private func refresh() async {
        isPreloaded = false
        await property.reload()
        await read()
    }
}
