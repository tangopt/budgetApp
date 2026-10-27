import Foundation
import BudgetCore
import GRDB

/// Property ▸ Recharges on the iPad (step 8, Task 8): the selected tenancy's statements, latest month first, as the
/// Mac's `Recharges.overview` and `lineDetails` read them, with the tenant credits that might pay each sent one.
/// A draft can be marked sent; a sent one can have a tenant payment recorded. Lines change only on a draft, and only
/// from Bills ("Add to recharge"): nothing here edits a sent statement's lines.
@MainActor
public final class PadRechargesModel: ObservableObject {
    public struct Statement: Equatable, Identifiable, Sendable {
        public var row: Recharges.MonthRow
        public var lines: [Recharges.LineDetail]
        public var suggestions: [Recharges.PaymentSuggestion]
        public var id: Int64 { row.id }
        public var statement: RechargeStatement { row.statement }

        /// The action this statement's status offers.
        public var action: PadBillAction? {
            switch row.statement.status {
            case .draft: .markSent
            case .sent: .recordPayment
            case .paid: nil
            }
        }

        /// The row a refusal shows under.
        var rowId: String { "statement\(id)" }
    }

    @Published public private(set) var statements: [Statement] = []
    public let property: PadPropertyModel
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private var generation = 0

    public init(property: PadPropertyModel, write: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.property = property
        self.write = write
        self.dbQueue = dbQueue
        self.today = today
    }

    /// Shows an already read list (the snapshot routes' first frame).
    public func preload(_ statements: [Statement]) {
        self.statements = statements
    }

    public func reload() async {
        generation += 1
        let mine = generation
        guard let propertyId = property.property?.id, let tenancyId = property.selectedTenancyId else {
            statements = []
            return
        }
        let reader = dbQueue
        guard let read = try? await reader.read({ db in try Self.read(db, propertyId: propertyId, tenancyId: tenancyId) }),
              mine == generation else { return }
        statements = read
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, propertyId: Int64?, tenancyId: Int64?) -> [Statement] {
        guard let propertyId, let tenancyId else { return [] }
        return (try? dbQueue.read { db in try read(db, propertyId: propertyId, tenancyId: tenancyId) }) ?? []
    }

    nonisolated static func read(_ db: Database, propertyId: Int64, tenancyId: Int64) throws -> [Statement] {
        let suggestions = try Recharges.paymentSuggestions(db: db, propertyId: propertyId)
        return try Recharges.overview(db: db, tenancyId: tenancyId).map { row in
            Statement(row: row, lines: try Recharges.lineDetails(db: db, statementId: row.id),
                      suggestions: suggestions.filter { $0.statement.id == row.id })
        }
    }

    /// The actions offered on `statement`: none while the user only views Property.
    public func action(for statement: Statement) -> PadBillAction? {
        write.canEdit ? statement.action : nil
    }

    /// Marks the draft statement sent today.
    @discardableResult
    public func markSent(_ statement: Statement) async -> Bool {
        let id = statement.id
        let day = today()
        return await run(statement, edit: PadBillAction.markSent.edit, origin: .edit) { db in
            _ = try Recharges.markSent(db: db, statementId: id, at: day)
        }
    }

    /// Links the suggested tenant credit to the sent statement.
    @discardableResult
    public func recordPayment(_ statement: Statement, _ suggestion: Recharges.PaymentSuggestion) async -> Bool {
        guard let transactionId = suggestion.transaction.id else { return false }
        let id = statement.id
        let amount = suggestion.amountMinorUnits
        return await run(statement, edit: PadBillAction.recordPayment.edit, origin: .propertyMatching, transactions: [transactionId]) { db in
            _ = try Recharges.linkPayment(db: db, statementId: id, transactionId: transactionId, amountMinorUnits: amount)
        }
    }

    private func run(_ statement: Statement, edit: String, origin: WriteOrigin, transactions: [Int64] = [],
                     _ body: @escaping @Sendable (Database) throws -> Void) async -> Bool {
        // What the statement's lines were paid with, and the credit: what a change to it can reach.
        let paid = statement.lines.compactMap { $0.invoice?.transactionId } + statement.lines.compactMap(\.line.transactionId)
        let scope = FiledYearEditCheck.Scope(transactionIds: paid + transactions)
        let saved = await write.perform(rowId: statement.rowId, origin: origin, edit: edit, scope: scope, body)
        if saved {
            await reload()
            await property.reload()
        }
        return saved
    }
}
