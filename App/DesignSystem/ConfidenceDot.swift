// App/DesignSystem/ConfidenceDot.swift
import SwiftUI
import BudgetCore

/// Green = a rule matched (deterministic). Orange = the on-device model suggested
/// something above `ReviewPartitioning.highConfidenceThreshold`. Gray = a weak or absent
/// suggestion — this row needs a look.
struct ConfidenceDot: View {
    let source: CategorizedBy
    let confidence: Double

    private var color: Color {
        switch source {
        case .rule: return .green
        case .llm: return confidence >= ReviewPartitioning.highConfidenceThreshold ? .orange : .gray
        case .manual, .none: return .gray
        }
    }

    private var label: String {
        switch source {
        case .rule: return "Matched rule"
        case .llm: return confidence >= ReviewPartitioning.highConfidenceThreshold
            ? "Suggested by on-device model"
            : "Weak suggestion from on-device model"
        case .manual: return "Manually set"
        case .none: return "No suggestion"
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).help(label)
    }
}
