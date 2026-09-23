import Foundation

/// Splits staged transactions into "ready to confirm" (a rule match, or an on-device
/// suggestion confident enough to trust without a second look) and "needs your
/// attention" (a weak suggestion or none at all) — drives the Review screen's two
/// sections and its "Confirm N ready" bulk action.
public enum ReviewPartitioning {
    public static let highConfidenceThreshold: Double = 0.6

    public static func partition(_ staged: [StagedTransaction]) -> (ready: [StagedTransaction], needsAttention: [StagedTransaction]) {
        var ready: [StagedTransaction] = []
        var needsAttention: [StagedTransaction] = []
        for transaction in staged {
            if transaction.suggestedCategoryId != nil && transaction.confidence >= highConfidenceThreshold {
                ready.append(transaction)
            } else {
                needsAttention.append(transaction)
            }
        }
        return (ready, needsAttention)
    }
}
