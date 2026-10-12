// App/Budget/AccountFilterPanel.swift
import SwiftUI
import BudgetCore

/// The Budget grid's account filter (spec §7): a slim, collapsible column to the left of the
/// grid — "All accounts" then each account with its transaction count, ticked to show only
/// those accounts' actuals. The selection and the open/closed state live in the view model,
/// so they're kept while the app runs.
struct AccountFilterPanel: View {
    @ObservedObject var viewModel: BudgetGridViewModel

    var body: some View {
        if viewModel.isAccountPanelOpen {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("ACCOUNTS")
                        .font(.caption).bold()
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        viewModel.isAccountPanelOpen = false
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Hide accounts")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        row("All accounts", count: viewModel.transactions.count, ticked: !viewModel.isAccountFiltered) {
                            viewModel.showAllAccounts()
                        }
                        ForEach(viewModel.accounts) { account in
                            if let id = account.id {
                                row(account.name, count: viewModel.transactionCountByAccount[id] ?? 0, ticked: viewModel.accountFilter.contains(id)) {
                                    viewModel.toggleAccountFilter(id)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(width: 190, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 8) {
                Button {
                    viewModel.isAccountPanelOpen = true
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("Show accounts")
                if viewModel.isAccountFiltered {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .help("Filtered to some accounts")
                }
            }
            .padding(.vertical, 6)
            .frame(width: 28)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// A tickable line: the name, then its transaction count.
    private func row(_ name: String, count: Int, ticked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ticked ? Color.accentColor : Color.secondary)
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(count.formatted())
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(ticked ? Color.accentColor.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }
}
