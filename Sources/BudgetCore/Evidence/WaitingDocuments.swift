import Foundation
import GRDB

/// Documents first, statements later (step 9): a bill, invoice or receipt filed before the statement
/// that pays it is "waiting for its payment" — derived, never stored: a kind paid by debits
/// (`EvidenceMatcher.isPaidByDebits`, not the bank's own debit advice, which `BBVADebitAdvice` links),
/// an amount stated, no linked transaction, and no bills-tracker payment of its utility invoice. Its date
/// is `docDate ?? periodEnd ?? addedAt`; more than `expiryDays` after it, it has lapsed into an ordinary
/// unlinked document.
///
/// `run` (after a statement import or a sync, given the transactions it added) links each waiting document to its one confident match
/// (`EvidenceMatcher.confidentMatch`), never a debit another waiting document also claims nor one already
/// carrying a document of its kind, each link in its own `EvidenceLinkGuard.checked` (a filed return that
/// would move refuses it: a suggestion instead). Everything else it found is a suggestion, counted, not
/// stored. `undo` takes one link back and remembers the pair (`AutoLinkDeclined`), so it is never remade.
public enum WaitingDocuments {
    public static let expiryDays = 90

    public enum State: Equatable, Sendable {
        case waiting
        /// Expired: now an ordinary unlinked document.
        case lapsed
        case notApplicable
    }

    public struct Pair: Equatable, Identifiable, Sendable {
        public var documentId: Int64
        public var transactionId: Int64
        public var id: String { "\(documentId)-\(transactionId)" }

        public init(documentId: Int64, transactionId: Int64) {
            self.documentId = documentId
            self.transactionId = transactionId
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// The links made, by document id.
        public var linked: [Pair]
        /// Document id → how many candidates it has (not linked: several, a weak match, a taken or
        /// contested debit, or a link a filed return refused).
        public var suggested: [Int64: Int]

        public init(linked: [Pair] = [], suggested: [Int64: Int] = [:]) {
            self.linked = linked
            self.suggested = suggested
        }
    }

    // MARK: State

    /// The date the 90 days count from: the document's own date, else its period's end, else when it was added.
    static func anchor(_ document: EvidenceDocument) -> Date {
        document.docDate ?? document.periodEnd ?? document.addedAt
    }

    static func isLapsed(_ document: EvidenceDocument, now: Date) -> Bool {
        EvidenceMatcher.days(from: anchor(document), to: now) > expiryDays
    }

    /// Whether the kind waits for a payment: paid by debits, and not the bank's advice of the debit itself.
    static func waits(_ document: EvidenceDocument) -> Bool {
        EvidenceMatcher.isPaidByDebits(document.kindRef) && document.kindRef != .builtIn(.bankDebitAdvice)
    }

    /// The links that settle a document: its debit, or the HMRC payment record it proves (a proof downloaded long
    /// after the payment would otherwise wait for a debit already recorded there).
    static let paymentEntityTypes: [EvidenceEntityType] = [.transaction, .hmrcPayment]

    /// Documents with an amount and no transaction link, nor a link to a record that is itself the payment
    /// (`paymentEntityTypes`: an HMRC payment's proof is paid), nor a utility invoice the bills tracker has
    /// paid, of a kind that waits; by id.
    static func unpaid(db: Database, documentId: Int64? = nil) throws -> [EvidenceDocument] {
        var sql = """
            SELECT d.* FROM document d
            WHERE d.amountMinorUnits IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM documentLink l WHERE l.documentId = d.id AND l.entityType IN (?, ?))
              AND NOT EXISTS (SELECT 1 FROM utilityInvoice u WHERE u.documentId = d.id AND u.transactionId IS NOT NULL)
            """
        var arguments = StatementArguments(paymentEntityTypes.map(\.rawValue))
        if let documentId {
            sql += " AND d.id = ?"
            arguments += [documentId]
        }
        sql += " ORDER BY d.id"
        return try EvidenceDocument.fetchAll(db, sql: sql, arguments: arguments).filter(waits)
    }

    public static func state(db: Database, documentId: Int64, now: Date) throws -> State {
        guard let document = try unpaid(db: db, documentId: documentId).first else { return .notApplicable }
        return isLapsed(document, now: now) ? .lapsed : .waiting
    }

    /// The waiting and lapsed documents (every other document is not applicable), in one pass.
    public static func states(db: Database, now: Date) throws -> [Int64: State] {
        var result: [Int64: State] = [:]
        for document in try unpaid(db: db) {
            guard let id = document.id else { continue }
            result[id] = isLapsed(document, now: now) ? .lapsed : .waiting
        }
        return result
    }

    // MARK: Matching

    /// The day the matcher anchors the document's window on (as `EvidenceMatcher.suggestions` does).
    static func matcherAnchor(_ document: EvidenceDocument) -> Date? {
        switch EvidenceMatcher.expectation(for: document.kindRef).anchor {
        case .docDate: document.docDate
        case .periodStart: document.periodStart ?? document.docDate
        case .periodEnd: document.periodEnd ?? document.docDate
        }
    }

    /// Every transaction: the matcher looks only at a document's window, but a payment reference counts only when
    /// exactly one transaction of all repeats it, so the index is never narrowed (a narrowed one could make a
    /// repeated reference look unique).
    static func index(db: Database) throws -> EvidenceMatcher.Index {
        EvidenceMatcher.Index(transactions: try Transaction.fetchAll(db), accounts: try Account.fetchAll(db), categories: try Category.fetchAll(db))
    }

    /// The transactions linked to `documentId`.
    static func linkedTransactions(db: Database, documentId: Int64) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT entityId FROM documentLink WHERE documentId = ? AND entityType = ?",
                               arguments: [documentId, EvidenceEntityType.transaction.rawValue]))
    }

    /// Whether `transactionId` already carries another document of `document`'s kind (as `BBVADebitAdvice.linkLibraryAdvices`),
    /// or the bills tracker has it paying another invoice than the document's own (`Recharges.paymentsTaken`).
    static func isTaken(db: Database, transactionId: Int64, by document: EvidenceDocument) throws -> Bool {
        let carried = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM documentLink l JOIN document d ON d.id = l.documentId
                           WHERE l.entityType = ? AND l.entityId = ? AND d.id != ? AND d.kind = ? AND d.customKindId IS ?)
            """, arguments: [EvidenceEntityType.transaction.rawValue, transactionId, document.id, document.kind.rawValue,
                             document.customKindId]) ?? false
        if carried { return true }
        let ownInvoices = try Int64.fetchAll(db, sql: "SELECT id FROM utilityInvoice WHERE documentId = ?", arguments: [document.id])
        // With no invoice of its own, every invoice is another's; with one (or more), each must leave the debit to it.
        if ownInvoices.isEmpty { return try Recharges.paymentsTaken(db: db, excludingInvoice: nil).contains(transactionId) }
        for invoice in ownInvoices where try !Recharges.paymentsTaken(db: db, excludingInvoice: invoice).contains(transactionId) {
            return false
        }
        return true
    }

    /// Whether the debit may be linked automatically for its property: a document linked to properties is only
    /// auto-linked to a debit of one of their accounts (`propertyAccount`); one linked to none, to any.
    static func isOfItsProperty(db: Database, transactionId: Int64, document: EvidenceDocument) throws -> Bool {
        let properties = try Int64.fetchAll(db, sql: "SELECT entityId FROM documentLink WHERE documentId = ? AND entityType = ?",
                                            arguments: [document.id, EvidenceEntityType.property.rawValue])
        guard !properties.isEmpty else { return true }
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM \(Transaction.databaseTableName) t JOIN propertyAccount pa ON pa.accountId = t.accountId
                           WHERE t.id = ? AND pa.propertyId IN (\(properties.map { _ in "?" }.joined(separator: ", "))))
            """, arguments: StatementArguments([transactionId] + properties)) ?? false
    }

    /// The matcher's candidates for the document, best first, without the transactions it is linked to
    /// or the pairs the user undid; at most `limit`.
    public static func suggestions(db: Database, documentId: Int64, limit: Int = 8) throws -> [EvidenceMatcher.Suggestion] {
        guard let document = try EvidenceDocument.fetchOne(db, key: documentId) else { return [] }
        let excluded = try linkedTransactions(db: db, documentId: documentId).union(AutoLinkDeclined.transactions(db: db, documentId: documentId))
        let found = EvidenceMatcher.suggestions(document: document, index: try index(db: db), limit: limit + excluded.count)
        return Array(found.filter { !excluded.contains($0.transactionId) }.prefix(limit))
    }

    // MARK: The job

    /// Links the waiting documents to their payments (see the type's comment), only to the transactions in
    /// `newTransactions` (the rows this import or pull added: an old pair unlinked by hand, or undone on another
    /// device, is never made again by a later run); the candidates it counts as suggestions are all of them.
    /// A confident match is linked only when no other waiting document claims it, no document of its kind nor
    /// another bills-tracker invoice has it, and, for a document linked to properties, it is a debit of one of
    /// their accounts. Idempotent: a linked document no longer waits, and an undone pair is never made again.
    /// Runs in the caller's write.
    @discardableResult
    public static func run(db: Database, newTransactions: Set<Int64>, now: Date = Date()) throws -> Outcome {
        var outcome = Outcome()
        let declined = try AutoLinkDeclined.byDocument(db: db)

        func link(_ pair: Pair) throws -> Bool {
            do {
                try EvidenceLinkGuard.checked(db: db) {
                    try EvidenceLinks.link(db: db, documentId: pair.documentId, to: .transaction(pair.transactionId))
                }
                return true
            } catch is EvidenceLinkGuard.Failure {
                return false
            }
        }

        guard !newTransactions.isEmpty else { return outcome }
        // A utility bill the bills tracker has paid with a new debit (its invoice's): the document gains
        // that link, the invoice keeps its debit and stage. The tracker's own pairing is authoritative, so the
        // matcher's checks (contested, taken, the property's account) don't apply here; the filed-year guard does.
        let trackerPairs = try Row.fetchAll(db, sql: """
            SELECT d.id, u.transactionId FROM document d JOIN utilityInvoice u ON u.documentId = d.id
            WHERE u.transactionId IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM documentLink l WHERE l.documentId = d.id AND l.entityType = ?)
            ORDER BY d.id, u.id
            """, arguments: [EvidenceEntityType.transaction.rawValue])
        var trackerDone = Set<Int64>()
        for row in trackerPairs {
            let pair = Pair(documentId: row[0], transactionId: row[1])
            guard trackerDone.insert(pair.documentId).inserted, newTransactions.contains(pair.transactionId),
                  !(declined[pair.documentId]?.contains(pair.transactionId) ?? false),
                  let document = try EvidenceDocument.fetchOne(db, key: pair.documentId), !isLapsed(document, now: now) else { continue }
            if try link(pair) { outcome.linked.append(pair) } else { outcome.suggested[pair.documentId] = 1 }
        }

        let waiting = try unpaid(db: db).filter { !isLapsed($0, now: now) }
        guard !waiting.isEmpty else { return outcome }
        let index = try index(db: db)

        var candidates: [(document: EvidenceDocument, suggestions: [EvidenceMatcher.Suggestion])] = []
        var claims: [Int64: Int] = [:]  // transaction → how many documents' confident match it is
        for document in waiting {
            guard let id = document.id else { continue }
            let refused = declined[id] ?? []
            let found = EvidenceMatcher.suggestions(document: document, index: index, limit: 10 + refused.count)
                .filter { !refused.contains($0.transactionId) }
            guard !found.isEmpty else { continue }
            candidates.append((document, Array(found.prefix(10))))
            if let best = EvidenceMatcher.confidentMatch(found) { claims[best.transactionId, default: 0] += 1 }
        }

        for (document, found) in candidates {
            let id = document.id!
            if let best = EvidenceMatcher.confidentMatch(found), newTransactions.contains(best.transactionId), claims[best.transactionId] == 1,
               try !isTaken(db: db, transactionId: best.transactionId, by: document),
               try isOfItsProperty(db: db, transactionId: best.transactionId, document: document) {
                let pair = Pair(documentId: id, transactionId: best.transactionId)
                if try link(pair) {
                    outcome.linked.append(pair)
                    continue
                }
            }
            outcome.suggested[id] = found.count
        }
        outcome.linked.sort { ($0.documentId, $0.transactionId) < ($1.documentId, $1.transactionId) }
        return outcome
    }

    /// Takes one automatic link back (the import summary's Undo): unlinked through the filed-year guard
    /// (a refusal throws `EvidenceLinkGuard.Failure`, nothing written), then remembered so no later run
    /// makes it again nor suggests it.
    public static func undo(db: Database, _ pair: Pair, now: Date) throws {
        try EvidenceLinkGuard.checked(db: db) {
            _ = try EvidenceLinks.unlink(db: db, documentId: pair.documentId, from: .transaction(pair.transactionId))
        }
        try AutoLinkDeclined.record(db: db, documentId: pair.documentId, transactionId: pair.transactionId, at: now)
        try AutoLinkRecent.remove(db: db, [pair])
    }
}
