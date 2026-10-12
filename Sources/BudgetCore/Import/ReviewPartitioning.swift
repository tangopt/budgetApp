import Foundation

/// Splits staged transactions into "ready to confirm" and "needs your attention" — drives
/// the Review screen's lists and its Confirm all action (spec §1). A row is ready only when
/// a rule, the user's own history or a matched transfer's other leg suggested its category; an on-device model suggestion
/// always gets a second look, however confident. Partitioning is by review group: a group
/// is ready only when every row in it is, so one merchant never straddles both lists.
public enum ReviewPartitioning {
    /// Where the confidence dot turns from gray to orange for a model suggestion. It no
    /// longer makes a row ready.
    public static let highConfidenceThreshold: Double = 0.6

    /// Whether this row on its own could be ready: a suggestion from a rule, history
    /// (which already requires ≥ 2 past transactions agreeing ≥ 70%) or a transfer's other leg.
    public static func isSure(_ transaction: StagedTransaction) -> Bool {
        guard transaction.suggestedCategoryId != nil else { return false }
        return transaction.source == .rule || transaction.source == .history || transaction.source == .transfer
    }

    /// `groupKeys` are the rows' review keys (`ReviewKey.groupKeys`), one per row in the same
    /// order; computed from the descriptions when omitted. Both lists keep the input order.
    public static func partition(_ staged: [StagedTransaction], groupKeys: [String]? = nil) -> (ready: [StagedTransaction], needsAttention: [StagedTransaction]) {
        let keys = groupKeys ?? ReviewKey.groupKeys(descriptions: staged.map(\.parsed.rawDescription))
        precondition(keys.count == staged.count, "One group key per staged row")
        var unsureKeys: Set<String> = []
        for (transaction, key) in zip(staged, keys) where !isSure(transaction) {
            unsureKeys.insert(key)
        }
        var ready: [StagedTransaction] = []
        var needsAttention: [StagedTransaction] = []
        for (transaction, key) in zip(staged, keys) {
            if unsureKeys.contains(key) {
                needsAttention.append(transaction)
            } else {
                ready.append(transaction)
            }
        }
        return (ready, needsAttention)
    }
}
