// App/DesignSystem/TransferLinkActions.swift
import Foundation
import BudgetCore
import GRDB

/// What Edit transaction needs for a transaction's transfer link (spec §6): its linked legs,
/// what Link to transfer… offers, and the two writes (each reloads the screen afterwards).
struct TransferLinkActions {
    /// The other legs of the transaction's active links (`TransferLinks.counterparts`).
    let counterparts: (_ transactionId: Int64) -> [TransferCounterpart]
    let candidates: (_ transactionId: Int64) throws -> [TransferCandidate]
    /// Unlink (`TransferLinks.unlink`).
    let unlink: (_ linkId: Int64) -> SaveOutcome
    /// Link to transfer… (`TransferLinks.link`).
    let link: (_ transactionId: Int64, _ otherId: Int64) -> SaveOutcome
    /// The accounts Add the other side… offers (the transaction's own is left out), in the
    /// order the app lists them.
    let accounts: [Account]
    /// Add the other side… (`ManualTransactions.addOtherSide`, spec 2026-10-14 §2).
    let addOtherSide: (_ transactionId: Int64, _ accountId: Int64) -> SaveOutcome

    /// Writes through `dbQueue`, then `reload` (false = the re-read failed).
    @MainActor
    static func make(dbQueue: DatabaseQueue, accounts: [Account], counterparts: @escaping (Int64) -> [TransferCounterpart],
                     reload: @escaping () -> Bool) -> TransferLinkActions {
        func perform(_ write: (Database) throws -> Void) -> SaveOutcome {
            do {
                try dbQueue.write { db in try write(db) }
            } catch {
                return .failed(error.localizedDescription)
            }
            return reload() ? .saved : .savedButReloadFailed
        }
        return TransferLinkActions(
            counterparts: counterparts,
            candidates: { id in try dbQueue.read { db in try TransferLinks.candidates(db: db, for: id) } },
            unlink: { linkId in perform { db in try TransferLinks.unlink(db: db, linkId: linkId) } },
            link: { id, otherId in perform { db in _ = try TransferLinks.link(db: db, transactionId: id, with: otherId) } },
            accounts: accounts,
            addOtherSide: { id, accountId in perform { db in _ = try ManualTransactions.addOtherSide(db: db, transactionId: id, accountId: accountId) } }
        )
    }
}

enum TransferFormat {
    /// "↔ Lloyds International · 9 Mar 2026 · £360.00"
    static func line(_ counterpart: TransferCounterpart) -> String {
        "↔ \(counterpart.accountName) · \(counterpart.date.formatted(date: .abbreviated, time: .omitted)) · \(Money.format(counterpart.amountMinorUnits, currency: counterpart.currency))"
    }
}
