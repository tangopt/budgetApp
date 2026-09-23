// App/NetWorth/AddSnapshotView.swift
import SwiftUI
import BudgetCore

struct AddSnapshotView: View {
    let accounts: [Account]
    /// (accountId, amount in minor units as entered — the amount owed for credit accounts, note)
    let onSave: (Int64, Int, String?) -> Void

    @State private var accountId: Int64?
    @State private var amountText = ""
    @State private var note = ""
    @State private var validationMessage: String?

    private var selectedAccount: Account? {
        accounts.first { $0.id == accountId }
    }

    private var amountLabel: String {
        selectedAccount?.kind == .credit ? "Amount owed" : "Current balance"
    }

    var body: some View {
        Form {
            Picker("Account", selection: $accountId) {
                Text("Select…").tag(Int64?.none)
                ForEach(accounts) { account in Text("\(account.name) (\(account.currency.rawValue.uppercased()))").tag(Int64?.some(account.id!)) }
            }
            TextField(amountLabel, text: $amountText)
            if selectedAccount?.kind == .credit {
                Text("Enter what you currently owe on the card as a positive number.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Note (optional)", text: $note)
            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            Button("Save") {
                guard let accountId else {
                    validationMessage = "Choose an account."
                    return
                }
                guard let minorUnits = Money.parseMinorUnits(amountText) else {
                    validationMessage = "“\(amountText)” isn't a valid amount. Use digits with an optional decimal point, e.g. 1,234.56."
                    return
                }
                validationMessage = nil
                onSave(accountId, minorUnits, note.isEmpty ? nil : note)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
