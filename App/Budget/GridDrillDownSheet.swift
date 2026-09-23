// App/Budget/GridDrillDownSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

enum GridDrillDownTarget: Identifiable {
    case transactions(title: String, transactions: [Transaction])
    case forecastEntries(title: String, entries: [ForecastEntry])

    var id: String {
        switch self {
        case .transactions(let title, let transactions):
            return "txn-\(title)-\(transactions.map { String($0.id ?? -1) }.joined(separator: ","))"
        case .forecastEntries(let title, let entries):
            return "forecast-\(title)-\(entries.map { String($0.id ?? -1) }.joined(separator: ","))"
        }
    }
}

struct GridDrillDownSheet: View {
    let target: GridDrillDownTarget
    let categories: [Category]
    let onRecategorize: (Transaction, Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch target {
            case .transactions(let title, let transactions):
                Text(title).font(.headline)
                if transactions.isEmpty {
                    Text("No transactions in this cell.").foregroundStyle(.secondary)
                } else {
                    List(transactions) { transaction in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transaction.rawDescription)
                                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(minorUnits: transaction.amountMinorUnits)
                            Picker("", selection: Binding<Int64?>(
                                get: { transaction.categoryId },
                                set: { newValue in
                                    guard let newValue else { return }
                                    onRecategorize(transaction, newValue)
                                }
                            )) {
                                ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }
                    }
                }
            case .forecastEntries(let title, let entries):
                Text(title).font(.headline)
                Text("Edit these from the Forecast screen.").font(.caption).foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        MoneyText(minorUnits: entry.amountMinorUnits)
                        Text("\(entry.frequency.rawValue), every \(entry.interval) · \(entry.status.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .padding()
        .frame(width: 420, height: 360)
    }
}
