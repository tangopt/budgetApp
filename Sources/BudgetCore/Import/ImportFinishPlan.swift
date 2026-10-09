import Foundation

/// What "Finish import" does with the rows the user didn't confirm.
public enum UnconfirmedRowsChoice {
    /// Saved alongside the confirmed rows: as Uncategorized, or with the category already
    /// chosen for them (the old "Save remaining as Uncategorized").
    case saveAsUncategorized
    /// Not saved at all; the next import of the same statement stages them again.
    case leaveOut
}

/// The rows and decisions a review's single `ImportCoordinator.commit` saves. Confirming on
/// the Review screen only marks rows in memory; this builds the one commit from the
/// confirmed rows plus, by the user's choice, the unconfirmed ones.
public struct ImportFinishPlan {
    /// A review row: what was staged and the user's current decision for it.
    public struct Row {
        public let staged: StagedTransaction
        public let decision: ImportDecision

        public init(staged: StagedTransaction, decision: ImportDecision) {
            self.staged = staged
            self.decision = decision
        }
    }

    public let staged: [StagedTransaction]
    public let decisions: [ImportDecision]

    public var isEmpty: Bool { staged.isEmpty }

    /// Keeps the review's row order. `confirmedIds` naming no row in `rows` are ignored.
    public static func make(rows: [Row], confirmedIds: Set<UUID>, unconfirmed: UnconfirmedRowsChoice) -> ImportFinishPlan {
        let included = rows.filter { confirmedIds.contains($0.staged.id) || unconfirmed == .saveAsUncategorized }
        return ImportFinishPlan(staged: included.map(\.staged), decisions: included.map(\.decision))
    }
}
