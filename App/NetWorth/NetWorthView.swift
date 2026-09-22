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

            ForEach(groupedByKind(), id: \.0) { kind, balancesInKind in
                VStack(alignment: .leading) {
                    Text(kind.rawValue.capitalized).font(.headline)
                    ForEach(balancesInKind, id: \.account.id) { balance in
                        HStack {
                            Text(balance.account.name)
                            Spacer()
                            Text(Money.format(balance.nativeBalanceMinorUnits, currency: balance.account.currency))
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
            AddSnapshotView(accounts: viewModel.accounts) { accountId, minorUnits, note in
                try? viewModel.addSnapshot(accountId: accountId, balanceMinorUnits: minorUnits, note: note)
                showAddSnapshot = false
            }
        }
    }

    private func groupedByKind() -> [(AccountKind, [AccountBalance])] {
        Dictionary(grouping: viewModel.balances, by: { $0.account.kind })
            .sorted { $0.key.rawValue < $1.key.rawValue }
    }
}
