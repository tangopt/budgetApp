// App/DesignSystem/TransferLinkActions.swift
import Foundation
import BudgetCore
import GRDB

/// What Edit transaction needs for a transaction's transfer link (spec §6): its linked legs,
/// what Link to transfer… offers, and what Add the other side… would add. Nothing here
/// writes — the sheet holds the change until Save (`TransactionEditing.save`).
struct TransferLinkActions {
    /// The other legs of the transaction's active links (`TransferLinks.counterparts`).
    let counterparts: (_ transactionId: Int64) -> [TransferCounterpart]
    let candidates: (_ transactionId: Int64) throws -> [TransferCandidate]
    /// Every account, in the order the app lists them (Add the other side… leaves out the
    /// transaction's own).
    let accounts: [Account]
    /// The stored EUR→GBP rate, for previewing the other side's converted amount.
    let eurToGbpRate: Double

    /// Reads through `dbQueue`.
    @MainActor
    static func make(dbQueue: DatabaseQueue, accounts: [Account], counterparts: @escaping (Int64) -> [TransferCounterpart]) -> TransferLinkActions {
        // A failed read only costs the preview's precision (Save converts at the stored rate).
        let rate = (try? dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate }) ?? 0.87
        return TransferLinkActions(
            counterparts: counterparts,
            candidates: { id in try dbQueue.read { db in try TransferLinks.candidates(db: db, for: id) } },
            accounts: accounts,
            eurToGbpRate: rate
        )
    }
}

enum TransferFormat {
    /// "↔ Lloyds International · 9 Mar 2026 · £360.00"
    static func line(_ counterpart: TransferCounterpart) -> String {
        "↔ " + details(account: counterpart.accountName, date: counterpart.date, amountMinorUnits: counterpart.amountMinorUnits,
                       currency: counterpart.currency)
    }

    /// "Lloyds International · 9 Mar 2026 · £360.00"
    static func details(account: String, date: Date, amountMinorUnits: Int, currency: Currency) -> String {
        "\(account) · \(date.formatted(date: .abbreviated, time: .omitted)) · \(Money.format(amountMinorUnits, currency: currency))"
    }
}
