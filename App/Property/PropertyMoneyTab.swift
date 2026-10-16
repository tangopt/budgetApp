// App/Property/PropertyMoneyTab.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// The Money tab (spec 2026-10-16 §1): the period's figures in the property's currency and
/// GBP, costs by category, a monthly chart and table; each figure opens its transactions.
struct PropertyMoneyTab: View {
    @ObservedObject var viewModel: PropertyViewModel
    let openTransaction: (Transaction) -> Void

    private struct DrillDown: Identifiable {
        let id = UUID()
        let title: String
        let rows: [EvidenceTransactionInfo]
    }

    @State private var drillDown: DrillDown?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = viewModel.snapshot.summary {
                PropertySection("Figures · \(summary.period.label)") {
                    figures(summary)
                }
                PropertySection("Costs by category") {
                    costs(summary)
                }
                PropertySection("By month") {
                    PropertyMonthlyChart(summary: summary).frame(height: 220)
                    monthly(summary)
                }
                Text("GBP at \(String(format: "%.4f", summary.eurToGbpRate)) per euro (the rate in Settings).")
                    .font(.caption).foregroundStyle(.secondary)
            } else if viewModel.period == nil {
                Text("Pick a range that ends after it starts.").foregroundStyle(.secondary)
            }
        }
        .sheet(item: $drillDown) { item in
            PropertyDrillDownSheet(title: item.title, rows: item.rows, openTransaction: openTransaction)
        }
    }

    private func open(_ title: String, _ kind: PropertyDrillDown) {
        drillDown = DrillDown(title: title, rows: viewModel.transactions(kind))
    }

    private func figures(_ summary: PropertySummary) -> some View {
        let t = summary.totals
        let rows: [(String, PropertyAmount, PropertyDrillDown?, String?)] = [
            ("Rent per receipts", t.rentPerReceipts, nil, "The receipts' rent, spread over their rent periods"),
            ("Rent credits", t.rentCredits, .rentCredits, "Credits in the rent categories on the current account"),
            ("Recharges and other", t.recharges, .rentCredits, "The part of those credits that isn't rent"),
            ("Rent received", t.rentReceived, .rentCredits, nil),
            ("Income", t.income, .income, "Every transaction in the property's income categories"),
            ("Costs", -t.costs, .costs(categoryId: nil), "Every transaction in the property's expense categories, mortgage interest included"),
            ("Mortgage interest", -t.mortgageInterest, .mortgageInterest, nil),
            ("Mortgage capital repaid", -t.mortgageCapital, .mortgage, "Instalments less interest"),
            ("Interest outside the property's categories", -t.interestOutsideCosts, .mortgageInterestOutsideCosts, nil),
            ("Net cash flow", t.netCashFlow, nil, "Income − costs − capital repaid (and any interest filed elsewhere)"),
            ("Outstanding loan at the end", summary.outstandingLoan, nil, nil),
            ("Deposit held at the end", summary.depositHeld, nil, nil)
        ]
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text(summary.currency.rawValue.uppercased()).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text("GBP").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text("")
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).lineLimit(1).help(row.3 ?? "")
                    PropertyMoney(minorUnits: row.1.native, currency: summary.currency, neutral: row.0.hasPrefix("Outstanding") || row.0.hasPrefix("Deposit"))
                    PropertyMoney(minorUnits: row.1.gbp, currency: .gbp, neutral: true)
                    if let kind = row.2 {
                        Button("Transactions…") { open(row.0, kind) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Transactions for \(row.0)")
                    } else {
                        Text("")
                    }
                }
            }
            GridRow {
                Text("Gross / net yield")
                Text("\(PropertyFormat.yield(summary.grossYield)) / \(PropertyFormat.yield(summary.netYield))")
                    .monospacedDigit().lineLimit(1).fixedSize()
                Text("")
                Text("")
            }
        }
    }

    private func costs(_ summary: PropertySummary) -> some View {
        Group {
            if summary.costsByCategory.isEmpty {
                Text("No costs in this period. Link the property's category groups in Profile.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(summary.costsByCategory, id: \.categoryId) { total in
                        GridRow {
                            Text(total.name).lineLimit(1)
                            PropertyMoney(minorUnits: -total.amount.native, currency: summary.currency).gridColumnAlignment(.trailing)
                            PropertyMoney(minorUnits: -total.amount.gbp, currency: .gbp, neutral: true).gridColumnAlignment(.trailing)
                            Button("Transactions…") { open(total.name, .costs(categoryId: total.categoryId)) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Transactions for \(total.name)")
                        }
                    }
                }
            }
        }
    }

    private func monthly(_ summary: PropertySummary) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Month").gridColumnAlignment(.leading)
                Text("Rent per receipts")
                Text("Rent received")
                Text("Recharges")
                Text("Costs")
                Text("Interest")
                Text("Capital")
                Text("Net cash flow")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(summary.months, id: \.start) { month in
                let f = month.figures
                GridRow {
                    Text(month.start.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).year()))
                        .lineLimit(1).fixedSize()
                    PropertyMoney(minorUnits: f.rentPerReceipts.native, currency: summary.currency, neutral: true)
                    PropertyMoney(minorUnits: f.rentReceived.native, currency: summary.currency)
                    PropertyMoney(minorUnits: f.recharges.native, currency: summary.currency, neutral: true)
                    PropertyMoney(minorUnits: -f.costs.native, currency: summary.currency)
                    PropertyMoney(minorUnits: -f.mortgageInterest.native, currency: summary.currency)
                    PropertyMoney(minorUnits: -f.mortgageCapital.native, currency: summary.currency, neutral: true)
                    PropertyMoney(minorUnits: f.netCashFlow.native, currency: summary.currency)
                }
            }
        }
        .font(.callout)
    }
}
