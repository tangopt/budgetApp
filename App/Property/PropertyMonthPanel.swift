// App/Property/PropertyMonthPanel.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// A month of the Cash flow by month chart, opened by clicking it (Overview, Money): the
/// month's three figures as the chart shows them, then its transactions grouped Rent / Other
/// income / Costs / Mortgage (`PropertyFinance.monthBreakdown`), each with what it counts,
/// its day, category and account, documents, Edit transaction and Show where it lives.
/// The groups add up to the bars and the line exactly.
struct PropertyMonthPanel: View {
    @ObservedObject var viewModel: PropertyViewModel
    let interval: DateInterval
    let openTransaction: (Transaction) -> Void
    @State private var editing: Transaction?

    private static let utc = TimeZone(identifier: "UTC")!

    /// "March 2026", or "6 – 30 Apr 2025" for a month the period cuts.
    private var title: String {
        let (year, month) = MonthRange.components(of: interval.start)
        let whole = MonthRange.of(year: year, month: month)
        if whole.start == interval.start && whole.end.addingTimeInterval(1) == interval.end {
            return interval.start.formatted(Date.FormatStyle(timeZone: Self.utc).month(.wide).year())
        }
        let lastDay = interval.end.addingTimeInterval(-1)
        return "\(DocumentFormat.day(interval.start)) – \(DocumentFormat.day(lastDay))"
    }

    var body: some View {
        let currency = viewModel.currency
        PropertySidePanel(title: title, subtitle: "Cash flow: the transactions behind the month's bars and line",
                          onClose: { viewModel.sidePanel = nil }) {
            if let breakdown = viewModel.monthBreakdown(interval) {
                VStack(alignment: .leading, spacing: 4) {
                    PropertyPanelFigure(title: "Rent received", minorUnits: breakdown.rentReceived.native, currency: currency)
                    PropertyPanelFigure(title: "Costs", minorUnits: breakdown.costs.native, currency: currency, role: .cost)
                    PropertyPanelFigure(title: "Net cash flow", minorUnits: breakdown.netCashFlow.native, currency: currency, isTotal: true)
                }
                .padding(.bottom, 2)
                if breakdown.groups.isEmpty {
                    Text("No transactions in this month.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(breakdown.groups) { group in
                            Section {
                                ForEach(group.lines) { line in
                                    PropertyPanelTransactionRow(
                                        transaction: line.transaction, minorUnits: line.counted.native, currency: currency,
                                        detail: [line.categoryName, viewModel.accountName(line.transaction.accountId)].compactMap { $0 }
                                            .joined(separator: " · "),
                                        note: line.note,
                                        onEdit: { editing = $0 },
                                        onShow: openTransaction)
                                }
                            } header: {
                                PropertyPanelSectionHeader(title: group.kind.title, minorUnits: group.total.native, currency: currency)
                                    .help(Self.help(group.kind))
                            }
                        }
                    }
                    .wrapProbeClips()
                }
            } else {
                Text("Couldn't read the month's transactions.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .sheet(item: $editing) { transaction in
            PropertyEditTransactionSheet(transaction: transaction, dbQueue: viewModel.dbQueue)
        }
    }

    private static func help(_ kind: PropertyFlowGroupKind) -> String {
        switch kind {
        case .rent: return "The rent credits' rent part: the bar above the line"
        case .otherIncome: return "The rest of the income: recharges and other credits (in the net cash flow, not in the bar)"
        case .costs: return "Every transaction in the property's expense categories, the mortgage interest included: the bar below the line"
        case .mortgage: return "The instalments paid into the loan less the interest already in Costs"
        }
    }
}
