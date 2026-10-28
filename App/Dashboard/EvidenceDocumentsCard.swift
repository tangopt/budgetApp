// App/Dashboard/EvidenceDocumentsCard.swift
import SwiftUI
import BudgetCore

/// The tax year's missing evidence and the documents waiting for their payment.
struct EvidenceDocumentsCard: View {
    let evidence: DashboardReview.EvidenceSummary
    let navigate: (AppScreen) -> Void

    var body: some View {
        DashboardCard(title: "Evidence and documents") {
            row("\(evidence.missingCount) missing", warning: evidence.missingCount > 0, link: "Missing evidence") { navigate(.missingEvidence) }
            row("\(evidence.waitingForPayment) waiting for their payment", warning: false, link: "Documents") { navigate(.documents) }
            if let linked = evidence.linkedSinceLastVisit {
                row("\(linked) linked since your last visit", warning: false, link: nil) {}
            }
        }
    }

    private func row(_ text: String, warning: Bool, link: String?, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(warning ? Color.orange : Color.secondary)
            Text(text).lineLimit(1).figureText()
            Spacer()
            if let link { PanelLink(title: link, action: action) }
        }
        .font(.callout)
    }
}
