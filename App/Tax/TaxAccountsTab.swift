// App/Tax/TaxAccountsTab.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// The year's rental accounts: rent and expense lines in the property's currency, pound items
/// and GBP at the HMRC rate; finance costs and the FTCR input apart; warnings; each line opens
/// its sources (transactions, receipts, manual items) with the rule and share explained.
struct TaxAccountsTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    let openTransaction: (Transaction) -> Void
    @State private var drillDown: RentalAccounts.Line?

    var body: some View {
        if let accounts = page.accounts {
            VStack(alignment: .leading, spacing: 12) {
                if !accounts.warnings.isEmpty {
                    PropertySection("To look at") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(accounts.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                PropertySection("Rental accounts") {
                    linesGrid(accounts, lines: [accounts.income] + accounts.expenses, totals: true)
                }
                PropertySection("Reported apart") {
                    linesGrid(accounts, lines: [accounts.financeCosts, accounts.foreignTax, accounts.notDeductible], totals: false)
                    Text("Finance costs get relief at the basic rate; the PT tax (calendar year \(String(accounts.taxYear.startYear))) is the foreign tax credit relief input; not-deductible items are listed for information.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !accounts.rentMonths.isEmpty {
                    PropertySection("Rent by month") {
                        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                            GridRow {
                                Text("Month").gridColumnAlignment(.leading)
                                Text("Property")
                                Text(page.row.person.name).lineLimit(1)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            ForEach(accounts.rentMonths, id: \.start) { month in
                                GridRow {
                                    Text(month.start.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).year()))
                                        .lineLimit(1).fixedSize()
                                    PropertyMoney(minorUnits: month.whole, currency: accounts.currency, neutral: true)
                                    PropertyMoney(minorUnits: month.amount, currency: accounts.currency)
                                }
                            }
                        }
                    }
                }
                Text(rateCaption(accounts)).font(.caption).foregroundStyle(.secondary)
            }
            .sheet(item: $drillDown) { line in
                TaxLineSourcesSheet(viewModel: viewModel, line: line, currency: accounts.currency, openTransaction: openTransaction)
            }
        } else {
            Text("\(page.row.person.name) owns no property in \(page.row.year.label).").foregroundStyle(.secondary)
        }
    }

    private func rateCaption(_ accounts: RentalAccounts.Result) -> String {
        guard accounts.currency != .gbp else { return "Amounts in GBP." }
        guard let rate = accounts.rate else { return "No HMRC average rate for \(accounts.taxYear.label): set or fetch it in Settings." }
        return "GBP at HMRC's average rate: \(TaxFormat.rate(rate)), \(TaxFormat.source(rate.source))."
    }

    private func linesGrid(_ accounts: RentalAccounts.Result, lines: [RentalAccounts.Line], totals: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("")
                Text(accounts.currency.rawValue.uppercased()).gridColumnAlignment(.trailing)
                Text("Pound items").gridColumnAlignment(.trailing)
                Text("GBP").gridColumnAlignment(.trailing)
                Text("")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(lines, id: \.expenseType) { line in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.label).lineLimit(1)
                        Text("\(line.rule.displayName) · \(line.shareExplanation)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(line.ruleExplanation)
                    PropertyMoney(minorUnits: line.amount.native, currency: accounts.currency, neutral: true)
                    PropertyMoney(minorUnits: line.amount.gbpNative, currency: .gbp, neutral: true)
                    gbp(line.amount)
                    Button(line.sources.isEmpty ? "No sources" : "\(line.sources.count) source\(line.sources.count == 1 ? "" : "s")…") {
                        drillDown = line
                    }
                    .buttonStyle(.borderless)
                    .disabled(line.sources.isEmpty)
                    .accessibilityLabel("Sources of \(line.label)")
                }
            }
            if totals {
                Divider().gridCellUnsizedAxes(.horizontal)
                totalRow("Total expenses", accounts.totals.expenses, accounts.currency)
                totalRow("Profit before finance costs", accounts.totals.profit, accounts.currency)
            }
        }
    }

    private func totalRow(_ title: String, _ amount: RentalAccounts.Amount, _ currency: Currency) -> some View {
        GridRow {
            Text(title).fontWeight(.semibold)
            PropertyMoney(minorUnits: amount.native, currency: currency, font: .body.monospacedDigit().weight(.semibold))
            PropertyMoney(minorUnits: amount.gbpNative, currency: .gbp, neutral: true)
            gbp(amount).fontWeight(.semibold)
            Text("")
        }
    }

    @ViewBuilder
    private func gbp(_ amount: RentalAccounts.Amount) -> some View {
        if let value = amount.gbp {
            PropertyMoney(minorUnits: value, currency: .gbp)
        } else {
            Text("—").foregroundStyle(.secondary).help("No HMRC rate for the year").accessibilityLabel("No GBP figure")
        }
    }
}

extension RentalAccounts.Line: @retroactive Identifiable {
    public var id: TaxExpenseType { expenseType }
}

/// A line's sources: each transaction, receipt or manual item with the part attributed, why,
/// its share, and its documents; Show opens a transaction where it lives.
struct TaxLineSourcesSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let line: RentalAccounts.Line
    let currency: Currency
    let openTransaction: (Transaction) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The sources' documents, read once when the sheet opens.
    @State private var documents: [Int64: EvidenceDocument] = [:]

    var body: some View {
        SheetScaffold(title: line.label, subtitle: "\(line.ruleExplanation) Share: \(line.shareExplanation).", width: 720,
                      cancelTitle: "Done", onCancel: { dismiss() }) {
            List(Array(line.sources.enumerated()), id: \.offset) { _, source in
                row(source)
            }
            .frame(minHeight: 360)
        }
        .onAppear {
            let ids = Array(Set(line.sources.flatMap(\.documentIds)))
            documents = Dictionary(uniqueKeysWithValues: viewModel.documents(ids).compactMap { d in d.id.map { ($0, d) } })
        }
    }

    private func row(_ source: RentalAccounts.Source) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(source.date.map(DocumentFormat.day) ?? "—").monospacedDigit().lineLimit(1).fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text(source.description).lineLimit(1)
                Text(source.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if source.shareBasisPoints != line.share.shareBasisPoints {
                    Text("Share \(PropertyFormat.percent(source.shareBasisPoints))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(source.documentIds.compactMap { documents[$0] }) { document in
                    Button {
                        viewModel.open(document)
                    } label: {
                        Label(document.displayName, systemImage: "paperclip").lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Open in its default app")
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                PropertyMoney(minorUnits: source.attributedMinorUnits, currency: source.currency)
                if source.attributedMinorUnits != source.amountMinorUnits {
                    HStack(spacing: 2) {
                        Text("of").font(.caption).foregroundStyle(.secondary)
                        PropertyMoney(minorUnits: source.amountMinorUnits, currency: source.currency, font: .caption.monospacedDigit(), neutral: true)
                    }
                }
            }
            if case let .transaction(id) = source.reference {
                Button("Show") {
                    guard let info = viewModel.transaction(id) else { return }
                    dismiss()
                    openTransaction(info.transaction)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show \(source.description)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}
