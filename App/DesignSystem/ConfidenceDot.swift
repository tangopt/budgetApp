// App/DesignSystem/ConfidenceDot.swift
import SwiftUI
import BudgetCore

/// Green = a rule matched or the row is the other leg of a transfer (deterministic). Orange = past transactions of the same merchant
/// agreed (history), or the on-device model suggested something above `ReviewPartitioning.highConfidenceThreshold`. Gray = a weak or absent
/// suggestion — this row needs a look.
struct ConfidenceDot: View {
    let source: CategorizedBy
    let confidence: Double

    private var color: Color {
        switch source {
        case .rule, .transfer: return .green
        case .history: return .orange
        case .llm: return confidence >= ReviewPartitioning.highConfidenceThreshold ? .orange : .gray
        case .manual, .none: return .gray
        }
    }

    private var label: String {
        switch source {
        case .rule: return "Matched rule"
        case .history: return "Suggested from past transactions"
        case .llm: return confidence >= ReviewPartitioning.highConfidenceThreshold
            ? "Suggested by on-device model"
            : "Weak suggestion from on-device model"
        case .transfer: return "The other leg of a transfer between your accounts"
        case .manual: return "Manually set"
        case .none: return "No suggestion"
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).help(label)
    }
}
