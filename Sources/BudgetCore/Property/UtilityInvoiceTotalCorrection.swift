import GRDB
import Foundation

/// One-off correction of the municipal-water (SIMAR) records the first import made from the
/// 2017–2022 invoices: they hold the invoice summary's first line (the water charge) instead of
/// the invoice's total, which is what the account is charged and debited. A record is corrected
/// only when its document's text reads that total with certainty, the record equals the
/// summary's first line, and nothing hangs on its amount (no debit linked, no recharge line).
public enum UtilityInvoiceTotalCorrection {
    public struct Change: Equatable, Sendable {
        public var invoiceId: Int64
        public var issueDate: Date
        public var oldMinorUnits: Int
        public var newMinorUnits: Int

        public init(invoiceId: Int64, issueDate: Date, oldMinorUnits: Int, newMinorUnits: Int) {
            self.invoiceId = invoiceId
            self.issueDate = issueDate
            self.oldMinorUnits = oldMinorUnits
            self.newMinorUnits = newMinorUnits
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// The record changed since planning (amount, debit or recharge line): nothing is written.
        case changedSincePlanning(invoiceId: Int64)

        public var errorDescription: String? {
            switch self {
            case .changedSincePlanning(let id): return "Invoice \(id) changed since the plan was made: nothing was written."
            }
        }
    }

    /// The invoice's total and its summary's first line, when the reader takes the "TOTAL"
    /// figure with certainty (no review note, no separate account total) and a "€" heading
    /// opens the summary block that ends at that "TOTAL"; else nil.
    public static func summary(text: String, rules: UtilityInvoiceRules) -> (total: Int, firstLine: Int)? {
        let reading = UtilityInvoiceReader.read(text: text, fileName: "", rules: rules)
        guard let total = reading.amountMinorUnits, total > 0, reading.amountReviewNote == nil,
              reading.accountTotalMinorUnits == nil else { return nil }
        let body = EvidenceText.normalized(String(text.prefix(UtilityInvoiceReader.maxTextLength)))
        let source = body as NSString
        // The summary's "TOTAL x": the first "TOTAL" whose figure right after it is the total
        // (only that label's few characters looked at).
        guard let totalAt = EvidenceAnalyzer.occurrences(of: "TOTAL", in: source).first(where: { range in
            UtilityInvoiceReader.isWord(range, in: source)
                && UtilityInvoiceReader.rightAfterAmount(["TOTAL"], in: source.substring(
                    with: NSRange(location: range.location, length: min(24, source.length - range.location))) as NSString,
                                                         positiveOnly: true) == total
        })?.location else { return nil }
        // The "€" heading nearest before it, standing alone.
        var euroAt: Int?
        var search = NSRange(location: 0, length: totalAt)
        while euroAt == nil {
            let found = source.range(of: "€", options: .backwards, range: search)
            guard found.location != NSNotFound, totalAt - found.location <= maxSummaryLength else { return nil }
            func isSpace(_ index: Int) -> Bool { index < 0 || index >= source.length || source.character(at: index) == 32 }
            if isSpace(found.location - 1) && isSpace(found.location + found.length) { euroAt = found.location + found.length }
            search = NSRange(location: 0, length: found.location)
        }
        guard let euroAt else { return nil }
        let block = source.substring(with: NSRange(location: euroAt, length: totalAt - euroAt))
        guard let first = EvidenceAmountParser.amounts(in: block).first?.minorUnits, first > 0, first < total else { return nil }
        return (total, first)
    }

    /// How far before its "TOTAL" the summary's "€" heading may be (the line labels and figures).
    static let maxSummaryLength = 1_500

    /// The providers whose rules mark the municipal water's invoices ("SIMAR").
    public static func simarProviderIds(db: Database) throws -> [Int64] {
        try UtilityProvider.order(Column("id")).fetchAll(db).filter { provider in
            provider.effectiveRules.textMarkers.contains { EvidenceText.normalized($0) == "SIMAR" }
        }.compactMap(\.id)
    }

    /// The records to correct, by issue date.
    public static func plan(db: Database, providerId: Int64) throws -> [Change] {
        guard let provider = try UtilityProvider.fetchOne(db, key: providerId) else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT utilityInvoice.id, utilityInvoice.issueDate, utilityInvoice.amountMinorUnits, document.extractedText
            FROM utilityInvoice JOIN document ON document.id = utilityInvoice.documentId
            WHERE utilityInvoice.providerId = ? AND utilityInvoice.transactionId IS NULL AND utilityInvoice.amountMinorUnits > 0
              AND document.extractedText IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM rechargeLine WHERE rechargeLine.invoiceId = utilityInvoice.id)
            ORDER BY utilityInvoice.issueDate, utilityInvoice.id
            """, arguments: [providerId])
        return rows.compactMap { row -> Change? in
            let amount: Int = row["amountMinorUnits"]
            guard let text: String = row["extractedText"],
                  let summary = summary(text: text, rules: provider.effectiveRules), summary.firstLine == amount else { return nil }
            return Change(invoiceId: row["id"], issueDate: row["issueDate"], oldMinorUnits: amount, newMinorUnits: summary.total)
        }
    }

    /// Writes the plan: each record must still be as planned (same amount, no debit, no recharge
    /// line), else nothing is written (the caller's transaction rolls back).
    public static func apply(db: Database, _ changes: [Change]) throws {
        for change in changes {
            try db.execute(sql: """
                UPDATE utilityInvoice SET amountMinorUnits = ?
                WHERE id = ? AND amountMinorUnits = ? AND transactionId IS NULL
                  AND NOT EXISTS (SELECT 1 FROM rechargeLine WHERE rechargeLine.invoiceId = utilityInvoice.id)
                """, arguments: [change.newMinorUnits, change.invoiceId, change.oldMinorUnits])
            guard db.changesCount == 1 else { throw Failure.changedSincePlanning(invoiceId: change.invoiceId) }
        }
    }
}
