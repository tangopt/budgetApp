import SwiftUI
import BudgetCore

/// Update balance for a manual account (step 7b): the balance as of a day (today unless changed) and a note. The
/// difference becomes a Balance adjustment on the Mac's rules (`BalanceUpdates.save`). Nothing is written until Save.
public struct UpdateBalanceSheet: View {
    let accountId: Int64
    let accountName: String
    let currency: Currency
    let today: Date
    @ObservedObject var model: QuickEditModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var amountText = ""
    @State private var asOf: Date
    @State private var note = ""
    @State private var saving = false

    public init(accountId: Int64, accountName: String, currency: Currency, today: Date, model: QuickEditModel) {
        self.accountId = accountId
        self.accountName = accountName
        self.currency = currency
        self.today = today
        self.model = model
        _asOf = State(initialValue: today)
    }

    private var amount: Int? { Money.parseMinorUnits(amountText) }

    public var body: some View {
        NavigationStack {
            Form {
                if let refusal = model.refusal {
                    Section { PadRefusalBanner(message: refusal) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    Text(accountName)
                        .mangoFont(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Section("Balance") {
                    TextField("Balance", text: $amountText, prompt: Text(MoneyPresentation.format(0, currency: currency)))
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("balance-field")
                    DatePicker("As of", selection: $asOf, in: ...today, displayedComponents: .date)
                        .frame(minHeight: 44)
                }
                Section("Note") {
                    TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(1...4)
                        .frame(minHeight: 44)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Update balance")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(amount == nil || saving)
                }
            }
        }
        .presentationDetents([.large])
        .onDisappear { model.refusal = nil }
    }

    private func save() {
        guard let amount else { return }
        saving = true
        Task {
            let saved = await model.updateBalance(accountId: accountId, enteredMinorUnits: amount, asOf: QuickEditModel.snapshotDay(asOf), note: note)
            saving = false
            if saved { dismiss() }
        }
    }
}
