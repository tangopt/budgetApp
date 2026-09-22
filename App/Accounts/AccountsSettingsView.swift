// App/Accounts/AccountsSettingsView.swift
import SwiftUI
import BudgetCore
import GRDB

@MainActor
final class AccountsSettingsViewModel: ObservableObject {
    @Published var accounts: [Account] = []
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }
    }

    func addAccount(name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode) throws {
        var account = Account(name: name, currency: currency, kind: kind, trackingMode: trackingMode)
        try dbQueue.write { db in try account.insert(db) }
        try load()
    }
}

struct AccountsSettingsView: View {
    @ObservedObject var viewModel: AccountsSettingsViewModel
    @State private var name = ""
    @State private var currency: Currency = .gbp
    @State private var kind: AccountKind = .cash
    @State private var trackingMode: AccountTrackingMode = .manual

    var body: some View {
        VStack(alignment: .leading) {
            List(viewModel.accounts) { account in
                Text("\(account.name) — \(account.currency.rawValue.uppercased()) — \(account.kind.rawValue) — \(account.trackingMode.rawValue)")
            }
            Divider()
            Form {
                TextField("Name", text: $name)
                Picker("Currency", selection: $currency) { ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
                Picker("Kind", selection: $kind) { ForEach(AccountKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Tracking", selection: $trackingMode) { ForEach(AccountTrackingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Button("Add account") {
                    guard !name.isEmpty else { return }
                    try? viewModel.addAccount(name: name, currency: currency, kind: kind, trackingMode: trackingMode)
                    name = ""
                }
            }
        }
        .padding()
        .onAppear { try? viewModel.load() }
    }
}
