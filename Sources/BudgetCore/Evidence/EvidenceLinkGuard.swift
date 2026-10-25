import Foundation
import GRDB

/// Filed returns never change (spec 2026-10-24 §4c, as `CustomDocumentKinds.save`): a document linked
/// by hand to a transaction — the rest of a part-paid bill, a second instalment — can move an expense
/// into another tax year (an invoice dates the payments it is linked to, `RentalAccounts.invoiceKinds`).
/// Unlinking moves it back the same way. A link change — a link, an unlink, links moved to a new version,
/// a linked document deleted — that would move a figure on a filed or paid return (`FiledYearSyncCheck`'s
/// protected years) is refused whole, writing nothing. A change that moves nothing (unlinking and linking
/// again the same document) is never refused: the check compares with the figures as they are now.
public enum EvidenceLinkGuard {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The years ("2024/25") whose returns the link change would move.
        case changesFiledYear(years: [String])
        /// A linked document's details (kind, date, period, persons) would move these years' returns.
        case detailsChangeFiledYear(years: [String])

        public var errorDescription: String? {
            switch self {
            case .changesFiledYear(let years): return "Links not changed: this would change \(Self.returns(years))."
            case .detailsChangeFiledYear(let years): return "Details not saved: this would change \(Self.returns(years))."
            }
        }

        private static func returns(_ years: [String]) -> String {
            years.count == 1 ? "the filed \(years[0]) return" : "the filed \(years.joined(separator: ", ")) returns"
        }
    }

    /// Whether `documentId` is linked to any transaction (only then can removing it, or moving its
    /// links, change a return).
    static func hasTransactionLinks(db: Database, documentId: Int64) throws -> Bool {
        try DocumentLink.filter(Column("documentId") == documentId && Column("entityType") == EvidenceEntityType.transaction.rawValue)
            .fetchCount(db) > 0
    }

    /// Runs `apply` (link changes, in the caller's write) in a savepoint: kept when no protected
    /// return figure moves, else rolled back and `refusal` (default `Failure.changesFiledYear`) thrown.
    public static func checked<T>(db: Database, refusal: ([String]) -> Failure = Failure.changesFiledYear,
                                  _ apply: () throws -> T) throws -> T {
        let baseline = try FiledYearSyncCheck.baseline(db: db)
        var result: T?
        var impacts: [FiledYearImpact] = []
        try db.inSavepoint {
            impacts = try FiledYearSyncCheck.impacts(db: db, baseline: baseline) { result = try apply() }
            return impacts.isEmpty ? .commit : .rollback
        }
        guard impacts.isEmpty, let result else {
            throw refusal(Set(impacts.map(\.startYear)).sorted().map { UKTaxYear(startYear: $0).label })
        }
        return result
    }
}
