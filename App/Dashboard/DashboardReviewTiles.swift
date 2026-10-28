// App/Dashboard/DashboardReviewTiles.swift
import SwiftUI
import BudgetCore

// The Property and Tax & documents sections (the review read model, `DashboardReview`).

// MARK: Property

/// Each running tenancy's month: checklist steps done and whether the rent has come in. Tenancies are named by
/// their reference label, never the tenant.
struct PropertyMonthTile: View {
    let rows: [DashboardReview.PropertyRow]
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme
    private let shown = 3

    var body: some View {
        let done = rows.reduce(0) { $0 + $1.stepsDone }
        let total = rows.reduce(0) { $0 + $1.stepsTotal }
        DashTile("Property month", linkTitle: "Property", onLink: { navigate(.property) }) {
            HStack(alignment: .center, spacing: 12) {
                TileFigure(value: "\(done) of \(total)", caption: "steps done this month")
                Spacer(minLength: 4)
                TileRing(fraction: total > 0 ? Double(done) / Double(total) : 0, label: total > 0 ? "\(Int((Double(done) / Double(total) * 100).rounded()))%" : "–",
                             tint: theme.series(0), size: 48)
            }
            ForEach(rows.prefix(shown)) { row in
                HStack(spacing: 6) {
                    Text(row.tenancyName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(row.stepsDone)/\(row.stepsTotal)").foregroundStyle(.secondary).figureText()
                    if let rent = rentText(row.rent) {
                        Text(rent.text).foregroundStyle(rent.tint).figureText()
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
            if rows.count > shown {
                Text("+ \(rows.count - shown) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rentText(_ rent: DashboardReview.PropertyRow.Rent) -> (text: String, tint: Color)? {
        switch rent {
        case .received: return ("Rent received", theme.income)
        case .late: return ("Rent late", .orange)
        case .notDueYet: return ("Rent due", .secondary)
        case .notApplicable: return nil
        }
    }
}

/// One mortgage: what is owed, the next instalment (a meter of the days to it) and the rate.
struct MortgageTile: View {
    let mortgage: DashboardReview.MortgageSummary
    let today: Date
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    /// Days until the next instalment, when there is one.
    private var daysToDue: Int? {
        mortgage.nextDue.map { max(0, MonthRange.calendar.dateComponents([.day], from: MonthRange.calendar.startOfDay(for: today), to: MonthRange.calendar.startOfDay(for: $0)).day ?? 0) }
    }

    var body: some View {
        DashTile("Mortgage · \(mortgage.propertyName)", linkTitle: "Property", onLink: { navigate(.property) }) {
            TileFigure(value: mortgage.owedMinorUnits.map { Money.format($0, currency: mortgage.currency) } ?? "Not set", caption: "owed")
            if let days = daysToDue, let due = mortgage.nextDue {
                MeterLine(label: "Next instalment \(DashboardFormat.day(due))",
                          figure: mortgage.nextInstalmentMinorUnits.map { Money.format($0, currency: mortgage.currency) } ?? "",
                          fraction: 1 - min(Double(days), 31) / 31, tint: theme.series(1))
                    .help("Due in \(days) day\(days == 1 ? "" : "s")")
            } else {
                Text("Next instalment not set").font(.caption).foregroundStyle(.secondary)
            }
            Text(mortgage.ratePercent.map { String(format: "%.2f%%", $0) + (mortgage.nextReview.map { " · review \(DashboardFormat.day($0))" } ?? "") } ?? "Rate not set")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: Tax & documents

/// The current UK tax year: each person's status and estimated balancing figure, and the next payment on account.
struct TaxYearTile: View {
    let tax: DashboardReview.TaxPosition
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme
    private let shown = 2

    var body: some View {
        let estimates = tax.people.compactMap(\.estimateMinorUnits)
        let total = estimates.reduce(0, +)
        DashTile("Tax year \(tax.year.label)", linkTitle: "Tax years", onLink: { navigate(.taxYears) }) {
            if estimates.isEmpty {
                TileFigure(value: "—", caption: "no estimate available yet")
            } else {
                TileFigure(value: DashboardFormat.pounds(abs(total)), caption: total < 0 ? "estimated refund" : "estimated tax due",
                           tint: total < 0 ? theme.income : .primary)
            }
            ForEach(tax.people.prefix(shown)) { person in
                HStack(spacing: 6) {
                    Text(person.name).lineLimit(1).truncationMode(.middle)
                    Text(person.status.displayName).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let value = person.estimateMinorUnits {
                        Text(DashboardFormat.pounds(abs(value))).foregroundStyle(value < 0 ? theme.income : Color.primary).figureText()
                    } else {
                        Text("—").foregroundStyle(.secondary).help(person.unavailableReason ?? "Not available yet")
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
            if let next = tax.nextPaymentOnAccount {
                Text("\(next.label) · \(DashboardFormat.day(next.date).unbroken) · \(DashboardFormat.pounds(next.amountMinorUnits).unbroken)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// The tax year's missing evidence and the documents waiting for their payment.
struct EvidenceTile: View {
    let evidence: DashboardReview.EvidenceSummary
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let largest = Double(max(1, evidence.missingCount, evidence.waitingForPayment))
        DashTile(title: "Evidence and documents", accessory: {
            HStack(spacing: 6) {
                iconButton("doc.badge.ellipsis", "Missing evidence") { navigate(.missingEvidence) }
                iconButton("doc.text", "Documents") { navigate(.documents) }
            }
        }, content: {
            TileFigure(value: "\(evidence.missingCount)", caption: evidence.missingCount == 1 ? "item of evidence missing" : "items of evidence missing",
                       tint: evidence.missingCount > 0 ? .orange : .primary)
            MeterLine(label: "Missing", figure: "\(evidence.missingCount)", fraction: Double(evidence.missingCount) / largest, tint: .orange)
            MeterLine(label: "Waiting for their payment", figure: "\(evidence.waitingForPayment)", fraction: Double(evidence.waitingForPayment) / largest, tint: theme.series(1))
            if let linked = evidence.linkedSinceLastVisit {
                Text("\(linked) linked since your last visit").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        })
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Files waiting for the Mac to import.
struct ImportsWaitingTile: View {
    let count: Int
    let navigate: (AppScreen) -> Void

    var body: some View {
        DashTile("Imports waiting", linkTitle: "Imports", onLink: { navigate(.imports) }) {
            TileFigure(value: "\(count)", caption: count == 1 ? "file waiting for the Mac to import" : "files waiting for the Mac to import", tint: .orange)
            MeterLine(label: "Waiting", figure: "\(count)", fraction: min(1, Double(count) / 10), tint: .orange)
        }
    }
}

/// Everything that needs the person: uncategorised transactions, stale balances, the review's signals.
struct AttentionTile: View {
    let items: AttentionItems
    /// The review's signals (tax deadline, late rent, evidence, waiting documents and imports, mortgage review).
    var extra: [DashboardReview.AttentionLine] = []
    let navigate: (AppScreen) -> Void
    private let shown = 4

    private struct Row: Identifiable {
        let id: String
        let text: String
        let screen: AppScreen
        let link: String
    }

    private func destination(_ kind: DashboardReview.AttentionLine.Kind) -> (screen: AppScreen, link: String) {
        switch kind {
        case .taxDeadline: return (.taxYears, "Tax years")
        case .rentLate: return (.property, "Property")
        case .evidenceMissing: return (.missingEvidence, "Missing evidence")
        case .documentsWaiting: return (.documents, "Documents")
        case .importsWaiting: return (.imports, "Imports")
        case .mortgageReview: return (.property, "Property")
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if items.uncategorizedCount > 0 {
            rows.append(Row(id: "uncategorized", text: "\(items.uncategorizedCount) transaction\(items.uncategorizedCount == 1 ? "" : "s") need a category", screen: .uncategorized, link: "Review"))
        }
        if items.staleBalanceCount > 0 {
            let since = items.oldestStaleSnapshotDate.map { " since \(DashboardFormat.day($0))" } ?? ""
            rows.append(Row(id: "stale", text: "\(items.staleBalanceCount) balance\(items.staleBalanceCount == 1 ? "" : "s") not updated\(since)", screen: .accounts, link: "Update balances"))
        }
        if items.missingReserveAllowance {
            rows.append(Row(id: "reserve", text: "No reserve for unplanned spending in the budget", screen: .budgetGrid, link: "Budget grid"))
        }
        for line in extra {
            let target = destination(line.kind)
            rows.append(Row(id: line.id, text: line.text, screen: target.screen, link: target.link))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        DashTile("Needs attention") {
            if rows.isEmpty {
                TileFigure(value: "0", caption: "all clear: everything categorised, balances up to date", tint: .green)
            } else {
                TileFigure(value: "\(rows.count)", caption: rows.count == 1 ? "thing needs you" : "things need you", tint: .orange)
                ForEach(rows.prefix(shown)) { row in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(row.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button { navigate(row.screen) } label: { Image(systemName: "chevron.right.circle") }
                            .buttonStyle(.borderless)
                            .help(row.link)
                            .accessibilityLabel(row.link)
                    }
                    .font(.caption)
                }
                if rows.count > shown { Text("+ \(rows.count - shown) more").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
