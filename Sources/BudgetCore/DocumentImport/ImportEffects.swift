import Foundation
import GRDB

public enum ImportEffectsError: Error, Equatable {
    /// A linking effect (rent receipt PDF, transfer advice) was performed without its document.
    case documentRequired
    /// The effect names a record it doesn't carry (a rent receipt PDF without its receipt).
    case incompleteEffect(String)
}

/// The one place an item's effect is applied, inside the caller's write transaction, through the
/// existing guarded write paths. The importer applies Ready items with it, and the filed-year
/// guard performs it in a rolled-back savepoint (`documentId: nil`) to see what it would change.
public enum ImportEffects {
    /// What confirming the item writes besides filing its document, in the order the importer
    /// applies it: the effect (`perform`), then the item's certain proposed links the effect
    /// doesn't make itself, then the documents those certain links replace unlinked from their
    /// record once the item's document is linked there (never the item's own document; never deleted). The importer calls it after filing the document (`documentId`); the
    /// filed-year guard calls it with a placeholder document, so it checks exactly what apply
    /// does. The batch's follow-on matching runs after all items (`followOns`).
    public static func applyRecords(db: Database, item: ImportItem, documentId: Int64?, importRunId: Int64?) throws {
        try perform(db: db, item.effect, documentId: documentId, importRunId: importRunId)
        for link in item.links where link.confidence == .certain && !link.madeByEffect {
            guard let documentId else { throw ImportEffectsError.documentRequired }
            try EvidenceLinks.link(db: db, documentId: documentId, to: link.entity, role: link.role)
        }
        for link in item.links where link.confidence == .certain && !link.replacing.isEmpty {
            // Only once the new document is linked there (by the effect or the link above).
            guard let documentId, try EvidenceLinks.links(db: db, for: documentId).contains(where: { $0.entity == link.entity }) else { continue }
            for replaced in link.replacing where replaced != documentId {
                _ = try EvidenceLinks.unlink(db: db, documentId: replaced, from: link.entity)
            }
        }
    }

    /// The properties whose matching follows the item (nil: all of them, e.g. after a statement
    /// or a link to a transaction).
    public static func touchedPropertyIds(db: Database, item: ImportItem) throws -> Set<Int64>? {
        if item.links.contains(where: { $0.entity.type == .transaction }) { return nil }
        switch item.effect {
        case .file:
            // A rent receipt or contract filed on a receipt or tenancy: its property's matching
            // (the receipt's document goes on the credits that paid it).
            var ids: Set<Int64> = []
            for link in item.links where link.confidence == .certain {
                switch link.entity.type {
                case .rentReceipt:
                    if let receipt = try RentReceipt.fetchOne(db, key: link.entity.id),
                       let tenancy = try Tenancy.fetchOne(db, key: receipt.tenancyId) { ids.insert(tenancy.propertyId) }
                case .tenancy:
                    if let tenancy = try Tenancy.fetchOne(db, key: link.entity.id) { ids.insert(tenancy.propertyId) }
                default: break
                }
            }
            return ids
        case .none, .payrollForm: return []
        case .ukStatement, .bbvaStatement, .transferAdvice: return nil
        case .rentReceiptsExport(let propertyId, _): return [propertyId]
        case .rentReceiptPDF(let planned): return planned.tenancy.map { [$0.propertyId] } ?? nil
        case .utilityInvoice(let invoice):
            return try UtilityProvider.fetchOne(db, key: invoice.providerId).map { [$0.propertyId] } ?? nil
        }
    }

    /// The matching that follows applied items: transfers (when `propertyIds` is nil), then for
    /// each property rent receipts to credits and utility recharges to payments, then receipt
    /// PDFs to the credits paying them, then the received-transfer advices already in the
    /// library to their credits (`.link` outcomes only, each property in turn, as
    /// `RentCreditEvidence.run` does). `propertyIds` nil means every property; empty, nothing.
    /// The importer runs it once after the batch's items; the filed-year guard runs the same.
    public static func followOns(db: Database, propertyIds: Set<Int64>?,
                                 adviceCache: RentCreditEvidence.AdviceCache = RentCreditEvidence.AdviceCache()) throws {
        if propertyIds == nil { _ = try TransferMatcher.match(db: db) }
        let ids = try propertyIds ?? Set(Property.fetchAll(db).compactMap(\.id))
        guard !ids.isEmpty else { return }
        for propertyId in ids.sorted() {
            try RentReceiptMatching.match(db: db, propertyId: propertyId)
            _ = try Recharges.matchPayments(db: db, propertyId: propertyId)
        }
        _ = try RentCreditEvidence.linkReceiptDocuments(db: db)
        var pending = try RentCreditEvidence.libraryAdvices(db: db, cache: adviceCache)
        for propertyId in ids.sorted() where !pending.isEmpty {
            let plan = try RentCreditEvidence.planAdvices(db: db, propertyId: propertyId, inputs: pending)
            _ = try RentCreditEvidence.linkLibraryAdvices(db: db, plan: plan)
            let done = Set(plan.filter { $0.outcome == .link || $0.outcome == .alreadyLinked }.map(\.input.sha256))
            pending.removeAll { done.contains($0.sha256) }
        }
    }

    /// Performs `effect`. `documentId` is the item's document in the library (nil when only
    /// looking at the effect's figures); `importRunId` stamps a statement's import batch.
    ///
    /// - `.rentReceiptsExport`: `RentReceiptImport.run` (which reruns the property's matching).
    /// - `.rentReceiptPDF`: links the document to its receipt (role "Receipt"); no matching.
    /// - `.transferAdvice`: links the document to each credit (`RentCreditEvidence.adviceRole`)
    ///   and gives it the credit's amount when it has none, as `RentCreditEvidence.applyAdvices` does.
    /// - `.utilityInvoice`: `UtilityInvoiceIntake.record` with the document (proposed without one).
    /// - `.payrollForm`: `PayrollFormImport.apply` with the document.
    /// - `.ukStatement`: the account's empty details filled, then the rows committed (a row an
    ///   earlier statement of the import holds is that one's; one left out, the pipeline stages
    ///   the later ones again so they hold its rows); with no
    ///   rows (all duplicates) only the closing balance is checked — never an empty batch. A
    ///   balance adjustment added then isn't stamped with `importRunId` (it has no batch of its
    ///   own); the run's change log records it. A layout mapped in the review is saved first
    ///   (`ImportProfileStore.save(db:)`); after the rows, the account chosen in the review is
    ///   learnt for files like it and a remembered rule marked used — all inside the run, so
    ///   Undo removes them and the filed-year guard simulates them.
    /// - `.bbvaStatement`: `performBBVA` — the current account's rows, the mortgage legs and
    ///   interest, the fund legs and value, the mortgage balance checked, the chosen accounts learnt.
    /// - `.file`, `.none`: nothing.
    /// A BBVA statement confirmed: its new rows committed on the current account (batch
    /// `"BBVA extrato <yyyy-MM>"`, categories as staged, no rule learning, no transfer matching —
    /// the follow-ons match after the legs are in; with none, the closing balance only checked), then each instalment's loan leg and interest row
    /// (`BBVAStatementLegs.addInstalment`) on its saved row (found by fingerprint), the estimates
    /// replaced by their receipts' splits, each subscription's fund leg and the fund's Market
    /// movement to the statement's value. The loan must then owe what the last receipt leaves
    /// (`StatementCheck.compare`), else `ImportApplyError.planOutdated("BBVA mortgage balance …")`.
    /// Last, the accounts chosen in the review are learnt (`ImportRuleStore.learn`, inside the run)
    /// and the learnt rules that named its accounts marked used.
    static func performBBVA(db: Database, _ statement: BBVAStatementEffect, importRunId: Int64?) throws {
        let sourceFileName = "BBVA extrato \(statement.statement.label)"
        let finish = StatementFinish(closing: statement.closing, addAdjustment: false)
        if statement.staged.isEmpty {
            _ = try ImportCoordinator.finishStatementOnly(db: db, accountId: statement.currentAccountId, sourceFileName: sourceFileName, statement: finish)
        } else {
            try ImportCoordinator.commit(db: db, accountId: statement.currentAccountId, sourceFileName: sourceFileName, staged: statement.staged,
                                         decisions: UKStatementEffect.decisions(for: statement.staged), statement: finish, importRunId: importRunId,
                                         matchTransfers: false)
        }
        func savedRow(_ index: Int) throws -> Int64 {
            guard statement.staged.indices.contains(index),
                  let id = try Int64.fetchOne(db, sql: "SELECT id FROM transaction_ WHERE accountId = ? AND fingerprint = ?",
                                              arguments: [statement.currentAccountId, statement.staged[index].fingerprint]) else {
                throw ImportApplyError.planOutdated("BBVA statement \(statement.statement.label): a row it adds wasn't saved")
            }
            return id
        }

        if !statement.instalments.isEmpty || !statement.estimates.isEmpty {
            guard let loanId = statement.loanAccountId else {
                throw ImportApplyError.planOutdated("BBVA statement \(statement.statement.label): no mortgage account for its instalments")
            }
            let needsInterest = statement.instalments.contains { BBVAStatementLegs.charges($0.receipt) != 0 }
            let interestId = try BBVAStatementLegs.interestCategoryId(db: db)
            if needsInterest, interestId == nil {
                throw ImportApplyError.planOutdated("BBVA statement \(statement.statement.label): no “\(BBVAFundMortgageImport.interestCategoryName)” category")
            }
            for match in statement.instalments {
                try BBVAStatementLegs.addInstalment(db: db, instalmentRowId: try savedRow(match.movementIndex), receipt: match.receipt,
                                                    loanAccountId: loanId, interestCategoryId: interestId ?? 0)
            }
            for estimate in statement.estimates {
                guard let row = try Transaction.fetchOne(db, key: estimate.transactionId), row.accountId == loanId,
                      row.rawDescription == BBVAStatementReader.derivedInterestDescription else {
                    throw ImportApplyError.planOutdated("BBVA statement \(statement.statement.label): the estimated interest it replaces changed")
                }
                try BBVAStatementLegs.replaceEstimate(db: db, transactionId: estimate.transactionId, receipt: estimate.receipt)
            }
            try checkMortgage(db: db, statement)
        }

        if let fundId = statement.fundAccountId {
            for pair in statement.fundPairs {
                try BBVAStatementLegs.addFundSubscription(db: db, subscriptionRowId: try savedRow(pair.movementIndex), fundAccountId: fundId)
            }
            _ = try BBVAStatementLegs.marketMovement(db: db, fundAccountId: fundId, statement: statement.statement, since: nil, openingMinorUnits: nil)
        } else if !statement.fundPairs.isEmpty {
            throw ImportApplyError.planOutdated("BBVA statement \(statement.statement.label): no fund account for its subscriptions")
        }

        let accounts = try Account.fetchAll(db)
        for role in statement.learnAccounts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let accountId = statement.learnAccounts[role], let (key, label) = BBVAStatementReader.ruleKey(role, statement.statement) else { continue }
            let name = accounts.first { $0.id == accountId }?.displayName ?? "Account #\(accountId)"
            try ImportRuleStore.learn(db: db, kind: .statementAccount, key: key, matchLabel: label, action: StatementAccountAction(accountId: accountId),
                                      actionLabel: "Account: \(name)", now: Date())
        }
        if !statement.rememberedRuleIds.isEmpty {
            try ImportRuleStore.markUsed(db: db, ids: statement.rememberedRuleIds, now: Date())
        }
    }

    /// The loan owes what the last receipt leaves outstanding (`BBVAStatementReader.mortgageMismatch`,
    /// counting the earlier statements of the import not saved yet).
    private static func checkMortgage(db: Database, _ statement: BBVAStatementEffect) throws {
        guard let found = try BBVAStatementReader.mortgageMismatch(db: db, statement, ownWritten: true) else { return }
        let currency = found.loan?.currency ?? .eur
        throw ImportApplyError.planOutdated("BBVA mortgage balance after \(BBVAStatementReader.title(statement.statement)) on "
                                            + "\(BBVAStatementReader.dayText(found.receipt.operationDate)): receipt \(found.receipt.number) leaves "
                                            + "\(Money.format(found.receipt.outstandingAfterMinorUnits, currency: currency)) owing, but "
                                            + "\(found.loan?.displayName ?? "the mortgage") would owe \(Money.format(-found.mismatch.computedMinorUnits, currency: currency))")
    }

    public static func perform(db: Database, _ effect: ImportEffect, documentId: Int64?, importRunId: Int64?) throws {
        switch effect {
        case .file, .none:
            return
        case .bbvaStatement(let statement):
            try performBBVA(db: db, statement, importRunId: importRunId)
        case .rentReceiptsExport(let propertyId, let rows):
            try RentReceiptImport.run(db: db, propertyId: propertyId, rows: rows)
        case .rentReceiptPDF(let planned):
            guard planned.outcome == .link else { throw ImportEffectsError.incompleteEffect("Rent receipt PDF not planned to link") }
            guard let documentId else { throw ImportEffectsError.documentRequired }
            guard let receiptId = planned.receipt?.id else { throw ImportEffectsError.incompleteEffect("Rent receipt PDF without its receipt") }
            try EvidenceLinks.link(db: db, documentId: documentId, to: .rentReceipt(receiptId), role: "Receipt")
        case .transferAdvice(let planned):
            guard planned.outcome == .link else { throw ImportEffectsError.incompleteEffect("Transfer advice not planned to link") }
            guard let documentId else { throw ImportEffectsError.documentRequired }
            guard !planned.credits.isEmpty else { throw ImportEffectsError.incompleteEffect("Transfer advice without its credit") }
            _ = try RentCreditEvidence.linkAdvice(db: db, documentId: documentId, credits: planned.credits)
        case .utilityInvoice(var invoice):
            if let documentId { invoice.documentId = documentId }
            try UtilityInvoiceIntake.record(db: db, &invoice)
        case .payrollForm(let confirmed):
            try PayrollFormImport.apply(db: db, confirmed, documentId: documentId)
        case .ukStatement(let statement):
            if var profile = statement.profileToSave {
                profile.id = nil
                try ImportProfileStore.save(db: db, profile)
            }
            if let fill = statement.accountFill {
                try StatementAccountCheck.fill(db: db, accountId: statement.accountId, with: fill)
            }
            let rows = statement.staged
            if rows.isEmpty {
                if let finish = statement.statement {
                    _ = try ImportCoordinator.finishStatementOnly(db: db, accountId: statement.accountId,
                                                                  sourceFileName: statement.sourceFileName, statement: finish)
                }
            } else {
                try ImportCoordinator.commit(db: db, accountId: statement.accountId, sourceFileName: statement.sourceFileName,
                                             staged: rows, decisions: UKStatementEffect.decisions(for: rows), statement: statement.statement,
                                             importRunId: importRunId)
            }
            if let learn = statement.learnAccount {
                let name = try Account.fetchOne(db, key: learn.accountId)?.displayName ?? "Account #\(learn.accountId)"
                try ImportRuleStore.learn(db: db, kind: .statementAccount, key: learn.key, matchLabel: learn.label,
                                          action: StatementAccountAction(accountId: learn.accountId), actionLabel: "Account: \(name)", now: Date())
            }
            if let ruleId = statement.rememberedRuleId {
                try ImportRuleStore.markUsed(db: db, ids: [ruleId], now: Date())
            }
        }
    }
}
