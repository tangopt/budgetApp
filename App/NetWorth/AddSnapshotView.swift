// App/NetWorth/AddSnapshotView.swift
import SwiftUI
import BudgetCore

struct AddSnapshotView: View {
    let accounts: [Account]
    let onSave: (Int64, Int, String?) -> Void

    @State private var accountId: Int64?
    @State private var amountText = ""
    @State private var note = ""

    var body: some View {
        Form {
            Picker("Account", selection: $accountId) {
                Text("Select…").tag(Int64?.none)
                ForEach(accounts) { account in Text("\(account.name) (\(account.currency.rawValue.uppercased()))").tag(Int64?.some(account.id!)) }
            }
            TextField("Current balance", text: $amountText)
            TextField("Note (optional)", text: $note)
            Button("Save") {
                guard let accountId, let value = Double(amountText) else { return }
                onSave(accountId, Int((value * 100).rounded()), note.isEmpty ? nil : note)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
