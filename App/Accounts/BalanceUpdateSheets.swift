// App/Accounts/BalanceUpdateSheets.swift
import SwiftUI
import BudgetCore

/// "Update balance…" for one account: amount (amount owed for credit), as-of day, note.
struct UpdateBalanceSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    let row: AccountRow
    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String
    @State private var asOf = Date()
    @State private var note = ""
    @State private var error: String?

    init(viewModel: AccountsViewModel, row: AccountRow) {
        self.viewModel = viewModel
        self.row = row
        _amountText = State(initialValue: AccountsFormat.enteredAmountText(row))
    }

    private var amount: Int? { Money.parseMinorUnits(amountText) }

    var body: some View {
        SheetScaffold(title: "Update balance — \(row.account.name)", saveTitle: "Save", canSave: amount != nil, error: error, onCancel: { dismiss() }, onSave: save) {
            MoneyField(row.account.kind == .credit ? "Amount owed" : "Balance", text: $amountText, currency: row.account.currency)
            if row.account.kind == .credit {
                SheetCaption("Enter what you owe on the card as a positive number.")
            }
            DatePicker("As of", selection: $asOf, in: ...Date(), displayedComponents: .date)
            TextField("Note (optional)", text: $note)
        }
    }

    private func save() {
        guard let amount else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = BalanceUpdates.Entry(accountId: row.id, enteredMinorUnits: amount, note: trimmedNote.isEmpty ? nil : trimmedNote)
        finish(viewModel.saveBalances([entry], asOf: AccountsFormat.snapshotDay(asOf)), error: $error, dismiss: dismiss)
    }
}

/// "Update balances…": every account, grouped like the list, prefilled with its current
/// entered balance; included rows (default: every account that has a balance) are saved as
/// of one day. Accounts with no balance yet start unticked with an empty field.
struct UpdateBalancesSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    let groups: [AccountGroup]
    @Environment(\.dismiss) private var dismiss

    @State private var included: [Int64: Bool]
    @State private var texts: [Int64: String]
    @State private var asOf = Date()
    @State private var error: String?

    init(viewModel: AccountsViewModel, groups: [AccountGroup]) {
        self.viewModel = viewModel
        self.groups = groups
        let rows = groups.flatMap(\.rows)
        _included = State(initialValue: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.lastUpdated != nil) }))
        _texts = State(initialValue: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.lastUpdated == nil ? "" : AccountsFormat.enteredAmountText($0)) }))
    }

    private var includedRows: [AccountRow] {
        groups.flatMap(\.rows).filter { included[$0.id] ?? false }
    }

    /// nil when any included row doesn't parse.
    private var entries: [BalanceUpdates.Entry]? {
        var result: [BalanceUpdates.Entry] = []
        for row in includedRows {
            guard let amount = Money.parseMinorUnits(texts[row.id] ?? "") else { return nil }
            result.append(BalanceUpdates.Entry(accountId: row.id, enteredMinorUnits: amount))
        }
        return result
    }

    private var saveTitle: String {
        let count = includedRows.count
        return "Save \(count) balance\(count == 1 ? "" : "s")"
    }

    var body: some View {
        SheetScaffold(title: "Update balances", saveTitle: saveTitle, canSave: (entries?.isEmpty == false), error: error, width: 480, wrapsInForm: false, onCancel: { dismiss() }, onSave: save) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        Text(AccountsFormat.kind(group.kind)).font(.headline)
                        ForEach(group.rows) { row in
                            rowView(row)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
            DatePicker("As of", selection: $asOf, in: ...Date(), displayedComponents: .date)
            SheetCaption("Credit cards: enter the amount owed. Unchanged rows are saved too, confirming the balance as of that day.")
        }
    }

    private func rowView(_ row: AccountRow) -> some View {
        let isIncluded = included[row.id] ?? false
        return HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { included[row.id] ?? false }, set: { included[row.id] = $0 })) {
                Text(row.account.name).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            Spacer()
            MoneyField(row.account.kind == .credit ? "Amount owed" : "Balance", text: Binding(get: { texts[row.id] ?? "" }, set: { texts[row.id] = $0 }), currency: row.account.currency, width: 130)
                .labelsHidden()
                .disabled(!isIncluded)
        }
    }

    private func save() {
        guard let entries, !entries.isEmpty else { return }
        finish(viewModel.saveBalances(entries, asOf: AccountsFormat.snapshotDay(asOf)), error: $error, dismiss: dismiss)
    }
}
