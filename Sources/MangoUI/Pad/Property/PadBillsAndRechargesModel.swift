import Combine
import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// Every action the merged Bills & recharges screen offers (step 10, Task 11), each one of the Mac's Recharges tab or
/// bills panel actions, made through the device writer (filed years checked, a refusal under the row it was made on).
public enum PadBillsAction: String, CaseIterable, Sendable {
    /// An invoice recorded without its document: attach one from the library (`UtilityInvoiceIntake.attach`).
    case linkDocument
    /// Record or correct the invoice's total (`Recharges.saveInvoice`).
    case correctTotal
    /// An invoice no payment settles yet: the bank movement that paid it (`Recharges.saveInvoice`).
    case linkPayment
    /// Paid and not on a statement: onto the tenancy's draft statement (`draftStatement` + `setLine`).
    case addToRecharge
    /// On a draft statement: the statement is sent (`Recharges.markSent`).
    case markSent
    /// Sent and owed: the tenant's credit that pays it (`Recharges.linkPayment`).
    case recordPayment
    /// A payment link taken off a statement (`Recharges.unlinkPayment`).
    case unlinkPayment
    /// A sent statement nothing pays goes back to draft (`Recharges.reopen`).
    case reopen
    /// A statement removed (`Recharges.deleteStatement`).
    case deleteStatement
    /// The statement a bill is on: its charges, payments and actions.
    case openStatement
    /// The next month's statement made (or the draft opened) to email to the tenant.
    case prepareEmail
    /// Rent credits matched to their receipts, then tenant credits to the statements they pay.
    case matchCredits
    /// The utility sites in the built-in browser, where invoices are fetched.
    case utilityInvoices

    public var title: String {
        switch self {
        case .linkDocument: "Link document…"
        case .correctTotal: "Correct total…"
        case .linkPayment: "Link payment…"
        case .addToRecharge: "Add to recharge"
        case .markSent: "Mark sent"
        case .recordPayment: "Record payment…"
        case .unlinkPayment: "Unlink payment"
        case .reopen: "Reopen as draft"
        case .deleteStatement: "Delete statement"
        case .openStatement: "View statement"
        case .prepareEmail: "Prepare email"
        case .matchCredits: "Match tenant credits"
        case .utilityInvoices: "Utility invoices"
        }
    }

    /// The name a filed-year question gives the edit.
    var edit: String {
        switch self {
        case .linkDocument: "Link invoice"
        case .correctTotal: "Correct invoice total"
        case .linkPayment: "Link payment"
        case .addToRecharge: "Add to recharge"
        case .markSent: "Mark sent"
        case .recordPayment: "Record payment"
        case .unlinkPayment: "Recharge payment unlinked"
        case .reopen: "Recharge statement reopened"
        case .deleteStatement: "Recharge statement deleted"
        case .prepareEmail: "Prepare statement"
        case .matchCredits: "Rent and recharge payments matched"
        case .openStatement, .utilityInvoices: title
        }
    }

    /// The icon button the action is drawn as in a row; nil for the ones drawn as text.
    var rowAction: RowAction? {
        switch self {
        case .linkDocument: .linkDocument
        case .linkPayment: .linkPayment
        case .addToRecharge: .addToRecharge
        case .markSent: .markSent
        case .recordPayment: .recordPayment
        case .unlinkPayment: .unlink
        case .openStatement: .view
        case .prepareEmail: .email
        case .utilityInvoices: .openSite
        case .deleteStatement: .discard
        case .correctTotal, .reopen, .matchCredits: nil
        }
    }

    /// What `bill` offers: its document, its total, the next step of its stage and its statement.
    public static func available(for bill: UtilityBill) -> [PadBillsAction] {
        var actions: [PadBillsAction] = []
        guard let invoice = bill.invoice else { return bill.statement == nil ? [] : [.openStatement] }
        if invoice.documentId == nil { actions.append(.linkDocument) }
        switch bill.stage {
        case .invoiceIn: actions.append(.linkPayment)
        case .linkedToPayment: actions.append(.addToRecharge)
        case .inRecharge: actions.append(.markSent)
        case .sentToTenant: actions.append(.recordPayment)
        case .missingInvoice, .paidByTenant: break
        }
        // A bill on a sent statement can't change its charge (the Mac refuses it too).
        if bill.stage < .sentToTenant { actions.append(.correctTotal) }
        if bill.statement != nil { actions.append(.openStatement) }
        return actions
    }

    /// The Mac's Bills panel and Recharges tab actions, by the name the Mac gives them, and the action that answers each
    /// here. `testEveryMacBillAndRechargeActionIsListed` keeps the two lists whole.
    static let macActions: [(mac: String, pad: PadBillsAction)] = [
        ("Add the invoice…", .linkDocument),
        ("Match to a payment…", .linkPayment),
        ("Add to a recharge…", .addToRecharge),
        ("Open statement… to send", .openStatement),
        ("Mark sent", .markSent),
        ("Record tenant payment", .recordPayment),
        ("Accept (suggested payment)", .recordPayment),
        ("Open statement…", .openStatement),
        ("Unlink payment", .unlinkPayment),
        ("Reopen statement", .reopen),
        ("Delete statement", .deleteStatement),
        ("Match payments", .matchCredits),
        ("Utility invoices…", .utilityInvoices),
        ("Prepare <month>…", .prepareEmail),
        ("Correct invoice total", .correctTotal),
    ]
}

extension UtilityBillStage {
    /// The name the iPad's grid, legend and panel give the stage (the Mac's "Missing invoice" is an expected bill here).
    public var padName: String {
        switch self {
        case .missingInvoice: "Expected"
        case .invoiceIn: "Invoice in"
        case .linkedToPayment: "Linked to payment"
        case .inRecharge: "In a statement"
        case .sentToTenant: "Sent"
        case .paidByTenant: "Paid by tenant"
        }
    }

    /// The legend, in the stages' order.
    public static var padLegend: [UtilityBillStage] { allCases }
}

/// Bills & recharges on the iPad (step 10, Task 11), one screen for the selected tenancy: the year's summary
/// (`Recharges.yearFigures`), the provider × month bills grid by stage, and the statements list. A bill selected in the grid
/// opens the document panel; a statement opens its own sheet. Nothing here computes a figure: it reads the Mac's read
/// models, and every write goes through `PadWriteModel`.
@MainActor
public final class PadBillsAndRechargesModel: ObservableObject {
    public struct Statement: Equatable, Identifiable, Sendable {
        public var row: Recharges.MonthRow
        public var lines: [Recharges.LineDetail]
        public var suggestions: [Recharges.PaymentSuggestion]
        public var id: Int64 { row.id }
        public var statement: RechargeStatement { row.statement }
        /// The statement's payments' credits, by id.
        public var credits: [Int64: Transaction]
        var rowId: String { "statement\(id)" }
    }

    public struct Snapshot: Equatable, Sendable {
        public var statements: [Statement]
        public var figures: [Int: RechargeYearFigures]
        /// The month the next statement is for.
        public var nextMonth: Date
        public var today: Date
    }

    @Published public private(set) var statements: [Statement] = []
    @Published public private(set) var figures: [Int: RechargeYearFigures] = [:]
    @Published public private(set) var nextMonth: Date
    /// The year the summary and the grid cover (nil: `defaultYear`).
    @Published public var chosenYear: Int?
    /// The bill whose panel is open (`UtilityBill.id`).
    @Published public var selectedBillId: String?
    /// The statement whose sheet is open.
    @Published public var openStatementId: Int64?
    /// The draft statement whose email is being prepared (from the list, or This month's step 4).
    @Published public var emailStatementId: Int64?

    public let property: PadPropertyModel
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private var generation = 0
    private var isPreloaded = false
    private var forwarding: AnyCancellable?

    /// The row a refusal of a screen-wide action shows under.
    static let screenRow = "billsAndRecharges"

    public init(property: PadPropertyModel, write: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.property = property
        self.write = write
        self.dbQueue = dbQueue
        self.today = today
        nextMonth = today()
        // The panel and the grid read the bills the property model holds: they change when it does.
        forwarding = property.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Reading

    public func preload(_ snapshot: Snapshot) {
        statements = snapshot.statements
        figures = snapshot.figures
        nextMonth = snapshot.nextMonth
        isPreloaded = true
    }

    public func reload() async {
        guard !isPreloaded else { return }
        generation += 1
        let mine = generation
        guard let propertyId = property.property?.id, let tenancyId = property.selectedTenancyId else {
            statements = []
            figures = [:]
            return
        }
        let day = today()
        let reader = dbQueue
        guard let read = try? await reader.read({ db in try Self.read(db, propertyId: propertyId, tenancyId: tenancyId, today: day) }),
              mine == generation else { return }
        statements = read.statements
        figures = read.figures
        nextMonth = read.nextMonth
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, propertyId: Int64?, tenancyId: Int64?, today: Date) -> Snapshot {
        let empty = Snapshot(statements: [], figures: [:], nextMonth: today, today: today)
        guard let propertyId, let tenancyId else { return empty }
        return (try? dbQueue.read { db in try read(db, propertyId: propertyId, tenancyId: tenancyId, today: today) }) ?? empty
    }

    nonisolated static func read(_ db: Database, propertyId: Int64, tenancyId: Int64, today: Date) throws -> Snapshot {
        let suggestions = try Recharges.paymentSuggestions(db: db, propertyId: propertyId)
        let statements = try Recharges.overview(db: db, tenancyId: tenancyId).map { row in
            let ids = row.payments.map(\.transactionId)
            let credits = Dictionary(uniqueKeysWithValues: try Transaction.filter(keys: ids).fetchAll(db).compactMap { credit in
                credit.id.map { ($0, credit) }
            })
            return Statement(row: row, lines: try Recharges.lineDetails(db: db, statementId: row.id),
                             suggestions: suggestions.filter { $0.statement.id == row.id }, credits: credits)
        }
        return Snapshot(statements: statements, figures: try Recharges.yearFigures(db: db, tenancyId: tenancyId),
                        nextMonth: try Recharges.nextMonth(db: db, tenancyId: tenancyId, today: today), today: today)
    }

    // MARK: Year

    public var currency: Currency { property.property?.currency ?? .gbp }

    /// The years with a statement, an invoice or figures, latest first (this year when there are none).
    public var years: [Int] {
        let found = Set(statements.map { MonthRange.components(of: $0.statement.month).year }
                        + (property.bills?.years ?? []) + figures.keys)
        return found.isEmpty ? [MonthRange.components(of: today()).year] : found.sorted(by: >)
    }

    /// This year, else the latest before it with anything (as the Mac's tab opens).
    public var defaultYear: Int {
        let current = MonthRange.components(of: today()).year
        return years.first { $0 <= current } ?? current
    }

    public var year: Int { chosenYear ?? defaultYear }

    // MARK: Summary

    public struct Summary: Equatable, Sendable {
        public var outstandingMinorUnits: Int
        public var outstandingCaption: String
        public var overdue: Int
        public var year: Int
        public var rechargedMinorUnits: Int
        public var rechargedCaption: String
        public var billsPaidMinorUnits: Int
        public var differenceMinorUnits: Int
        public var differenceCaption: String
        /// Why the year's difference is what it is, one line per reason, with the statements behind it.
        public var reasons: [Reason]
    }

    public struct Reason: Equatable, Identifiable, Sendable {
        public var text: String
        public var statementIds: [Int64]
        public var statementNames: [String]
        public var id: String { text }
    }

    /// The statements sent and not yet paid, oldest first.
    public var awaiting: [Statement] {
        statements.filter { $0.statement.status == .sent }.sorted { $0.statement.month < $1.statement.month }
    }

    /// Whether a sent statement is overdue as its pill says: sent, nothing received yet, past the matching window.
    func isOverdue(_ statement: Statement) -> Bool {
        guard statement.statement.status == .sent, statement.row.payments.reduce(0, { $0 + $1.amountMinorUnits }) == 0,
              statement.row.outstandingMinorUnits > 0, let sent = statement.statement.sentAt else { return false }
        return MonthRange.calendar.date(byAdding: .day, value: Recharges.paymentWindowDays, to: MonthRange.calendar.startOfDay(for: sent))! < today()
    }

    public func summary(year: Int) -> Summary {
        let figure = figures[year] ?? RechargeYearFigures(year: year)
        let waiting = awaiting
        let owed: String = switch waiting.count {
        case 0: "Nothing owed"
        case 1: "\(RechargeEmail.monthName(waiting[0].statement.month, language: .english)) awaiting payment"
        default: "\(waiting.count) statements awaiting payment"
        }
        let difference = figure.difference
        return Summary(
            outstandingMinorUnits: waiting.reduce(0) { $0 + $1.row.outstandingMinorUnits }, outstandingCaption: owed,
            overdue: waiting.filter(isOverdue).count, year: year,
            rechargedMinorUnits: figure.recharged,
            rechargedCaption: "\(figure.statements) statement\(figure.statements == 1 ? "" : "s") · \(Money.format(figure.received, currency: currency)) received",
            billsPaidMinorUnits: figure.billsPaid, differenceMinorUnits: difference,
            differenceCaption: RechargeYearFigures.differenceCaption(difference),
            reasons: reasons(figure))
    }

    private func reasons(_ figure: RechargeYearFigures) -> [Reason] {
        figure.explanations(currency: currency).map { item in
            Reason(text: item.text, statementIds: item.gaps.map(\.statementId),
                   statementNames: item.gaps.map { RechargeEmail.monthName($0.month, language: .english) })
        }
    }

    // MARK: Grid

    /// The months of `year` with a bill, oldest first.
    public func months(year: Int) -> [Date] {
        Array(Set((property.bills?.bills ?? []).map(\.month).filter { MonthRange.components(of: $0).year == year })).sorted()
    }

    /// The bill a cell tap selects: the cell's first.
    public func select(_ cell: UtilityBillCell) {
        selectedBillId = cell.bills.first?.id
    }

    public func closePanel() { selectedBillId = nil }

    public var selectedBill: UtilityBill? {
        guard let id = selectedBillId else { return nil }
        return property.bills?.bills.first { $0.id == id }
    }

    /// The cell holding the selected bill.
    public var selectedCell: UtilityBillCell? {
        guard let bill = selectedBill, let grid = property.bills else { return nil }
        return grid.rows.first { $0.providerId == bill.providerId }.flatMap { grid.cell(row: $0, month: bill.month) }
    }

    /// The document the panel shows for the selected bill: its invoice's.
    public var selectedDocumentId: Int64? { selectedBill?.invoice?.documentId }

    /// What the panel adds under the document's details for `bill`: its stage, the statement it is on, what the tenant
    /// has paid of that, and when it was sent.
    public func facts(for bill: UtilityBill) -> [Fact] {
        var facts = [Fact(label: "Stage", value: bill.isPartiallyPaid ? "Sent, part paid" : bill.stage.padName)]
        if let statement = bill.statement {
            let status = switch statement.status { case .draft: "Draft"; case .sent: "Sent"; case .paid: "Paid" }
            facts.append(Fact(label: "In statement", value: "\(RechargeEmail.monthName(statement.month, language: .english)) · \(status)".unbroken))
            if let sent = bill.statement?.sentAt, bill.stage >= .sentToTenant {
                facts.append(Fact(label: "Sent", value: PhoneDateFormat.day(sent).unbroken))
            }
            if statement.status != .draft {
                facts.append(Fact(label: "Paid by", value: "Tenant · \(Money.format(bill.tenantPaidMinorUnits, currency: currency)) of \(Money.format(bill.statementTotalMinorUnits, currency: currency))".unbroken))
            }
        }
        return facts
    }

    public struct Fact: Equatable, Sendable {
        public var label: String
        public var value: String
    }

    // MARK: Which actions

    /// The actions offered on `bill`: none while the user only views Property.
    public func actions(for bill: UtilityBill) -> [PadBillsAction] {
        write.canEdit ? PadBillsAction.available(for: bill) : []
    }

    /// The actions a statement offers (the screen-wide ones, matching, are `canEdit`).
    public func actions(for statement: Statement) -> [PadBillsAction] {
        guard write.canEdit else { return [] }
        switch statement.statement.status {
        case .draft: return [.prepareEmail, .markSent, .deleteStatement]
        case .sent: return statement.row.payments.isEmpty ? [.recordPayment, .reopen, .deleteStatement] : [.recordPayment]
        case .paid: return []
        }
    }

    /// The statement's one inline step on the list: "Prepare email" on a draft.
    public func listAction(for statement: Statement) -> PadBillsAction? {
        guard write.canEdit else { return nil }
        switch statement.statement.status {
        case .draft: return .prepareEmail
        case .sent: return statement.suggestions.isEmpty ? nil : .recordPayment
        case .paid: return nil
        }
    }

    // MARK: Choices

    /// Library documents that read as the property's utility invoices and aren't recorded yet.
    public func invoiceDocuments() async -> [EvidenceDocument] {
        guard let propertyId = property.property?.id else { return [] }
        return (try? await dbQueue.read { db in try UtilityInvoiceIntake.pendingDocuments(db: db, propertyId: propertyId) }) ?? []
    }

    /// The bank movements that could have paid `bill`'s invoice, best first.
    public func paymentCandidates(for bill: UtilityBill) async -> [Transaction] {
        guard let propertyId = property.property?.id, let invoice = bill.invoice else { return [] }
        return (try? await dbQueue.read { db in
            let provider = try UtilityProvider.fetchOne(db, key: invoice.providerId)
            return try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: propertyId, provider: provider,
                                                              amountMinorUnits: invoice.amountMinorUnits, issueDate: invoice.issueDate,
                                                              excludingInvoice: invoice.id)
        }) ?? []
    }

    /// The tenant credits that might pay `bill`'s sent statement.
    public func paymentSuggestions(for bill: UtilityBill) async -> [Recharges.PaymentSuggestion] {
        guard let propertyId = property.property?.id, let statementId = bill.statement?.id else { return [] }
        return (try? await dbQueue.read { db in
            try Recharges.paymentSuggestions(db: db, propertyId: propertyId).filter { $0.statement.id == statementId }
        }) ?? []
    }

    // MARK: Writes on a bill

    /// Attaches document `documentId` to `bill`'s invoice.
    @discardableResult
    public func linkInvoice(_ bill: UtilityBill, documentId: Int64) async -> Bool {
        guard let invoiceId = bill.invoice?.id else { return false }
        return await runBill(.linkDocument, bill, origin: .documentLink, scope: FiledYearEditCheck.Scope()) { db in
            try UtilityInvoiceIntake.attach(db: db, documentId: documentId, toInvoice: invoiceId)
        }
    }

    /// Records transaction `transactionId` as the payment of `bill`'s invoice.
    @discardableResult
    public func linkPayment(_ bill: UtilityBill, transactionId: Int64) async -> Bool {
        guard let invoiceId = bill.invoice?.id else { return false }
        return await runBill(.linkPayment, bill, origin: .propertyMatching, scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            guard var invoice = try UtilityInvoice.fetchOne(db, key: invoiceId) else { throw RechargeError.invoiceNotFound }
            invoice.transactionId = transactionId
            try Recharges.saveInvoice(db: db, &invoice)
        }
    }

    /// Records `bill`'s invoice as `amountMinorUnits` (its total). A sent statement's invoice is refused, as on the Mac.
    @discardableResult
    public func correctTotal(_ bill: UtilityBill, to amountMinorUnits: Int) async -> Bool {
        guard let invoiceId = bill.invoice?.id, amountMinorUnits > 0 else { return false }
        return await runBill(.correctTotal, bill, origin: .edit, scope: Self.scope(bill)) { db in
            guard var invoice = try UtilityInvoice.fetchOne(db, key: invoiceId) else { throw RechargeError.invoiceNotFound }
            invoice.amountMinorUnits = amountMinorUnits
            try Recharges.saveInvoice(db: db, &invoice)
        }
    }

    /// Puts `bill`'s invoice on the tenancy's draft statement: the latest one when it is a draft for the bill's month
    /// or later, else the bill's month's (made when there is none).
    @discardableResult
    public func addToRecharge(_ bill: UtilityBill) async -> Bool {
        guard let invoiceId = bill.invoice?.id, let tenancyId = property.selectedTenancyId else { return false }
        let month = bill.month
        return await runBill(.addToRecharge, bill, origin: .edit, scope: Self.scope(bill)) { db in
            let latest = try Recharges.statements(db: db, tenancyId: tenancyId).first
            let statement = if let latest, latest.status == .draft, latest.month >= month {
                latest
            } else {
                try Recharges.draftStatement(db: db, tenancyId: tenancyId, month: month, addPending: false)
            }
            try Recharges.setLine(db: db, statementId: statement.id!, invoiceId: invoiceId)
        }
    }

    /// Marks `bill`'s draft statement sent today.
    @discardableResult
    public func markSent(_ bill: UtilityBill) async -> Bool {
        guard let statementId = bill.statement?.id else { return false }
        let day = today()
        return await runBill(.markSent, bill, origin: .edit, scope: Self.scope(bill)) { db in
            _ = try Recharges.markSent(db: db, statementId: statementId, at: day)
        }
    }

    /// Links the suggested tenant credit to `bill`'s statement.
    @discardableResult
    public func recordPayment(_ bill: UtilityBill, _ suggestion: Recharges.PaymentSuggestion) async -> Bool {
        guard let statementId = suggestion.statement.id, let transactionId = suggestion.transaction.id else { return false }
        let amount = suggestion.amountMinorUnits
        return await runBill(.recordPayment, bill, origin: .propertyMatching, scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            _ = try Recharges.linkPayment(db: db, statementId: statementId, transactionId: transactionId, amountMinorUnits: amount)
        }
    }

    /// The bill's bank movements: what a statement change can reach.
    private static func scope(_ bill: UtilityBill) -> FiledYearEditCheck.Scope {
        FiledYearEditCheck.Scope(transactionIds: bill.payments.compactMap(\.id))
    }

    private func runBill(_ action: PadBillsAction, _ bill: UtilityBill, origin: WriteOrigin, scope: FiledYearEditCheck.Scope,
                         _ body: @escaping @Sendable (Database) throws -> Void) async -> Bool {
        let saved = await write.perform(rowId: bill.id, origin: origin, edit: action.edit, scope: scope, body)
        if saved { await refresh() }
        return saved
    }

    // MARK: Writes on a statement

    /// Marks the draft statement sent today.
    @discardableResult
    public func markSent(_ statement: Statement) async -> Bool {
        let id = statement.id
        let day = today()
        return await runStatement(statement, .markSent, origin: .edit) { db in
            _ = try Recharges.markSent(db: db, statementId: id, at: day)
        }
    }

    /// Links the suggested tenant credit to the sent statement.
    @discardableResult
    public func recordPayment(_ statement: Statement, _ suggestion: Recharges.PaymentSuggestion) async -> Bool {
        guard let transactionId = suggestion.transaction.id else { return false }
        let id = statement.id
        let amount = suggestion.amountMinorUnits
        return await runStatement(statement, .recordPayment, origin: .propertyMatching, transactions: [transactionId]) { db in
            _ = try Recharges.linkPayment(db: db, statementId: id, transactionId: transactionId, amountMinorUnits: amount)
        }
    }

    /// Takes the payment link off the statement.
    @discardableResult
    public func unlink(_ statement: Statement, payment: RechargePayment) async -> Bool {
        let id = statement.id
        let transactionId = payment.transactionId
        return await runStatement(statement, .unlinkPayment, origin: .propertyMatching, transactions: [transactionId]) { db in
            _ = try Recharges.unlinkPayment(db: db, statementId: id, transactionId: transactionId)
        }
    }

    /// A sent statement nothing pays goes back to draft.
    @discardableResult
    public func reopen(_ statement: Statement) async -> Bool {
        let id = statement.id
        return await runStatement(statement, .reopen, origin: .edit) { db in _ = try Recharges.reopen(db: db, statementId: id) }
    }

    @discardableResult
    public func delete(_ statement: Statement) async -> Bool {
        let id = statement.id
        let saved = await runStatement(statement, .deleteStatement, origin: .edit) { db in _ = try Recharges.deleteStatement(db: db, id: id) }
        if saved, openStatementId == id { openStatementId = nil }
        return saved
    }

    /// Makes the next month's statement (the invoices since the last one) and opens it; its email is prepared from there.
    @discardableResult
    public func prepareNext() async -> Bool {
        guard let tenancyId = property.selectedTenancyId else { return false }
        let month = nextMonth
        let made = await write.saving(rowId: Self.screenRow, origin: .edit, edit: PadBillsAction.prepareEmail.edit,
                                      scope: .everyYear) { db in
            try Recharges.draftStatement(db: db, tenancyId: tenancyId, month: month).id
        }
        guard let made, let id = made else { return false }
        await refresh()
        openStatementId = id
        return true
    }

    /// The Prepare email sheet's model for draft statement `statementId`: the library's files through `open` (downloaded
    /// when not on this iPad), Mark as sent through this screen's writer, the screen read again once it is.
    public func prepareEmailModel(statementId: Int64, open: (@Sendable (String) async throws -> URL)?) -> PrepareEmailModel {
        let month = statements.first { $0.id == statementId }.map { RechargeEmail.monthName($0.statement.month, language: .english) }
        return PrepareEmailModel(statementId: statementId, monthName: month ?? "Statement", dbQueue: dbQueue, write: write,
                                 open: open, today: today, onMarkedSent: { [weak self] in await self?.refresh() })
    }

    /// Rent matching, then exact recharge payments (the Mac's "Match payments").
    @discardableResult
    public func matchCredits() async -> Bool {
        guard let propertyId = property.property?.id else { return false }
        let saved = await write.perform(rowId: Self.screenRow, origin: .propertyMatching, edit: PadBillsAction.matchCredits.edit,
                                        scope: .everyYear) { db in
            _ = try RentReceiptMatching.match(db: db, propertyId: propertyId)
            _ = try Recharges.matchPayments(db: db, propertyId: propertyId)
        }
        if saved { await refresh() }
        return saved
    }

    private func runStatement(_ statement: Statement, _ action: PadBillsAction, origin: WriteOrigin, transactions: [Int64] = [],
                              _ body: @escaping @Sendable (Database) throws -> Void) async -> Bool {
        // What the statement's lines were paid with, and the credit: what a change to it can reach.
        let paid = statement.lines.compactMap { $0.invoice?.transactionId } + statement.lines.compactMap(\.line.transactionId)
        let scope = FiledYearEditCheck.Scope(transactionIds: paid + statement.row.payments.map(\.transactionId) + transactions)
        let saved = await write.perform(rowId: statement.rowId, origin: origin, edit: action.edit, scope: scope, body)
        if saved { await refresh() }
        return saved
    }

    private func refresh() async {
        isPreloaded = false
        await property.reload()
        await reload()
    }
}
