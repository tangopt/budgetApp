// App/Settings/APIKeySettingsView.swift
import SwiftUI
import BudgetCore

struct APIKeySettingsView: View {
    private let store: APIKeyStoring = KeychainAPIKeyStore()
    @State private var apiKey: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            SecureField("Anthropic API key", text: $apiKey)
            Button("Save") {
                try? store.setAPIKey(apiKey)
                saved = true
            }
            if saved { Text("Saved.").foregroundStyle(.secondary) }
            Text("Used only as a fallback when a transaction doesn't match any existing rule. If left blank, unmatched transactions are simply left uncategorized for manual review.")
                .font(.caption)
        }
        .padding()
        .onAppear { apiKey = store.getAPIKey() ?? "" }
    }
}
