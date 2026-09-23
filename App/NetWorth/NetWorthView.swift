// App/NetWorth/NetWorthView.swift
import SwiftUI
import BudgetCore

struct NetWorthView: View {
    @ObservedObject var viewModel: NetWorthViewModel
    @State private var showAddSnapshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Net Worth: \(Money.format(viewModel.netWorthGBP, currency: .gbp))")
                .font(.largeTitle).bold()

            if let warning = viewModel.reconciliationWarning {
                Text(warning)
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            ForEach(groupedByKind(), id: \.0) { kind, balancesInKind in
                VStack(alignment: .leading) {
                    Text(kind.rawValue.capitalized).font(.headline)
                    ForEach(balancesInKind, id: \.account.id) { balance in
                        HStack {
                            Text(balance.account.name)
                            Spacer()
                            if balance.account.kind == .credit {
                                // Stored signed (negative = owed); shown as the amount owed.
                                Text("\(Money.format(NetWorthCalculator.enteredBalance(signedMinorUnits: balance.nativeBalanceMinorUnits, accountKind: .credit), currency: balance.account.currency)) owed")
                            } else {
                                Text(Money.format(balance.nativeBalanceMinorUnits, currency: balance.account.currency))
                            }
                            if balance.account.currency != .gbp {
                                Text("(\(Money.format(balance.gbpBalanceMinorUnits, currency: .gbp)))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Button("Update a balance…") { showAddSnapshot = true }

            if !viewModel.history.isEmpty {
                Text("History").font(.headline)
                ForEach(viewModel.history, id: \.date) { point in
                    HStack {
                        Text(point.date.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Text(Money.format(point.netWorthGBP, currency: .gbp))
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $showAddSnapshot) {
            AddSnapshotView(accounts: viewModel.accounts) { accountId, enteredMinorUnits, note in
                do {
                    try viewModel.addSnapshot(accountId: accountId, enteredMinorUnits: enteredMinorUnits, note: note)
                } catch {
                    viewModel.errorMessage = "Couldn't save the balance: \(error.localizedDescription)"
                }
                showAddSnapshot = false
            }
        }
    }

    private func groupedByKind() -> [(AccountKind, [AccountBalance])] {
        Dictionary(grouping: viewModel.balances, by: { $0.account.kind })
            .sorted { $0.key.rawValue < $1.key.rawValue }
    }
}
