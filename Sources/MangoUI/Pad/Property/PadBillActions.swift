import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// What a utility bill on the iPad offers next, by how far it has got (step 8, Task 8). Each is one of the Mac's
/// BudgetCore writes, made through the device writer.
public enum PadBillAction: String, CaseIterable, Sendable {
    /// An invoice recorded without its document: attach one from the library (`UtilityInvoiceIntake.attach`).
    case linkInvoice
    /// An invoice no payment settles yet: the bank movement that paid it (`Recharges.saveInvoice`).
    case linkPayment
    /// Paid and not on a statement: onto the tenancy's draft statement (`draftStatement` + `setLine`).
    case addToRecharge
    /// On a draft statement: the statement is sent (`Recharges.markSent`).
    case markSent
    /// Sent and owed: the tenant's credit that pays it (`Recharges.linkPayment`).
    case recordPayment

    public var title: String {
        switch self {
        case .linkInvoice: "Link invoice…"
        case .linkPayment: "Link payment…"
        case .addToRecharge: "Add to recharge"
        case .markSent: "Mark sent"
        case .recordPayment: "Record payment…"
        }
    }

    /// The name a filed-year question gives the edit.
    var edit: String {
        switch self {
        case .linkInvoice: "Link invoice"
        case .linkPayment: "Link payment"
        case .addToRecharge: "Add to recharge"
        case .markSent: "Mark sent"
        case .recordPayment: "Record payment"
        }
    }

    /// The actions `bill`'s stage offers (a missing invoice and a bill the tenant paid offer none here).
    public static func available(for bill: UtilityBill) -> [PadBillAction] {
        var actions: [PadBillAction] = []
        if let invoice = bill.invoice, invoice.documentId == nil { actions.append(.linkInvoice) }
        switch bill.stage {
        case .invoiceIn: actions.append(.linkPayment)
        case .linkedToPayment: actions.append(.addToRecharge)
        case .inRecharge: actions.append(.markSent)
        case .sentToTenant: actions.append(.recordPayment)
        case .missingInvoice, .paidByTenant: break
        }
        return actions
    }
}

/// The Bills grid's actions on the iPad: the choices each needs (read as the Mac reads them) and the writes, each
/// through `PadWriteModel` (the device writer, filed years checked, a refusal under the bill's row). After a write
/// the grid reads again.
@MainActor
public final class PadBillActions: ObservableObject {
    public let property: PadPropertyModel
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date

    public init(property: PadPropertyModel, write: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.property = property
        self.write = write
        self.dbQueue = dbQueue
        self.today = today
    }

    /// The actions offered on `bill`: none while the user only views Property.
    public func actions(for bill: UtilityBill) -> [PadBillAction] {
        write.canEdit ? PadBillAction.available(for: bill) : []
    }

    /// The bills of the selected cell.
    public var selectedBills: [UtilityBill] {
        guard let grid = property.bills, let id = property.selectedCellId else { return [] }
        for row in grid.rows {
            for month in Set(grid.bills.map(\.month)) {
                if let cell = grid.cell(row: row, month: month), cell.id == id { return cell.bills }
            }
        }
        return []
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

    // MARK: Writes

    /// Attaches document `documentId` to `bill`'s invoice.
    @discardableResult
    public func linkInvoice(_ bill: UtilityBill, documentId: Int64) async -> Bool {
        guard let invoiceId = bill.invoice?.id else { return false }
        return await run(.linkInvoice, bill, origin: .documentLink, scope: FiledYearEditCheck.Scope()) { db in
            try UtilityInvoiceIntake.attach(db: db, documentId: documentId, toInvoice: invoiceId)
        }
    }

    /// Records transaction `transactionId` as the payment of `bill`'s invoice.
    @discardableResult
    public func linkPayment(_ bill: UtilityBill, transactionId: Int64) async -> Bool {
        guard let invoiceId = bill.invoice?.id else { return false }
        return await run(.linkPayment, bill, origin: .propertyMatching, scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            guard var invoice = try UtilityInvoice.fetchOne(db, key: invoiceId) else { throw RechargeError.invoiceNotFound }
            invoice.transactionId = transactionId
            try Recharges.saveInvoice(db: db, &invoice)
        }
    }

    /// Puts `bill`'s invoice on the tenancy's draft statement: the latest one when it is a draft for the bill's month
    /// or later, else the bill's month's (made when there is none).
    @discardableResult
    public func addToRecharge(_ bill: UtilityBill) async -> Bool {
        guard let invoiceId = bill.invoice?.id, let tenancyId = property.selectedTenancyId else { return false }
        let month = bill.month
        return await run(.addToRecharge, bill, origin: .edit, scope: Self.scope(bill)) { db in
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
        return await run(.markSent, bill, origin: .edit, scope: Self.scope(bill)) { db in
            _ = try Recharges.markSent(db: db, statementId: statementId, at: day)
        }
    }

    /// Links the suggested tenant credit to `bill`'s statement.
    @discardableResult
    public func recordPayment(_ bill: UtilityBill, _ suggestion: Recharges.PaymentSuggestion) async -> Bool {
        guard let statementId = suggestion.statement.id, let transactionId = suggestion.transaction.id else { return false }
        let amount = suggestion.amountMinorUnits
        return await run(.recordPayment, bill, origin: .propertyMatching, scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            _ = try Recharges.linkPayment(db: db, statementId: statementId, transactionId: transactionId, amountMinorUnits: amount)
        }
    }

    /// The bill's bank movements: what a statement change can reach.
    private static func scope(_ bill: UtilityBill) -> FiledYearEditCheck.Scope {
        FiledYearEditCheck.Scope(transactionIds: bill.payments.compactMap(\.id))
    }

    private func run(_ action: PadBillAction, _ bill: UtilityBill, origin: WriteOrigin, scope: FiledYearEditCheck.Scope,
                     _ body: @escaping @Sendable (Database) throws -> Void) async -> Bool {
        let saved = await write.perform(rowId: bill.id, origin: origin, edit: action.edit, scope: scope, body)
        if saved { await property.reload() }
        return saved
    }
}
