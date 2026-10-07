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

    init(viewModel: AccountsViewModel, row: AccountRow) {
        self.viewModel = viewModel
        self.row = row
        _amountText = State(initialValue: AccountsFormat.enteredAmountText(row))
    }

    private var amount: Int? { Money.parseMinorUnits(amountText) }

    var body: some View {
        SheetScaffold(title: "Update balance — \(row.account.name)", saveTitle: "Save", canSave: amount != nil, error: viewModel.errorMessage, onCancel: { dismiss() }, onSave: save) {
            HStack {
                TextField(row.account.kind == .credit ? "Amount owed" : "Balance", text: $amountText)
                Text(row.account.currency.rawValue.uppercased()).foregroundStyle(.secondary)
            }
            if row.account.kind == .credit {
                SheetCaption("Enter what you owe on the card as a positive number.")
            }
            if amount == nil && !amountText.trimmingCharacters(in: .whitespaces).isEmpty {
                SheetCaption(AccountsFormat.invalidAmountMessage(amountText), isError: true)
            }
            DatePicker("As of", selection: $asOf, displayedComponents: .date)
            TextField("Note (optional)", text: $note)
        }
        .onAppear { viewModel.errorMessage = nil }
    }

    private func save() {
        guard let amount else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = BalanceUpdates.Entry(accountId: row.id, enteredMinorUnits: amount, note: trimmedNote.isEmpty ? nil : trimmedNote)
        if viewModel.saveBalances([entry], asOf: AccountsFormat.snapshotDay(asOf)) {
            dismiss()
        }
    }
}

/// "Update balances…": every account, grouped like the list, prefilled with its current
/// entered balance; included rows (default all) are saved as of one day.
struct UpdateBalancesSheet: View {
    @ObservedObject var viewModel: AccountsViewModel
    let groups: [AccountGroup]
    @Environment(\.dismiss) private var dismiss

    @State private var included: [Int64: Bool]
    @State private var texts: [Int64: String]
    @State private var asOf = Date()

    init(viewModel: AccountsViewModel, groups: [AccountGroup]) {
        self.viewModel = viewModel
        self.groups = groups
        let rows = groups.flatMap(\.rows)
        _included = State(initialValue: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, true) }))
        _texts = State(initialValue: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, AccountsFormat.enteredAmountText($0)) }))
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
        SheetScaffold(title: "Update balances", saveTitle: saveTitle, canSave: (entries?.isEmpty == false), error: viewModel.errorMessage, width: 480, wrapsInForm: false, onCancel: { dismiss() }, onSave: save) {
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
            DatePicker("As of", selection: $asOf, displayedComponents: .date)
            SheetCaption("Credit cards: enter the amount owed. Unchanged rows are saved too, confirming the balance as of that day.")
        }
        .onAppear { viewModel.errorMessage = nil }
    }

    private func rowView(_ row: AccountRow) -> some View {
        let isIncluded = included[row.id] ?? false
        let text = texts[row.id] ?? ""
        let invalid = isIncluded && Money.parseMinorUnits(text) == nil
        return HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { included[row.id] ?? false }, set: { included[row.id] = $0 })) {
                Text(row.account.name).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            Spacer()
            TextField(row.account.kind == .credit ? "Amount owed" : "Balance", text: Binding(get: { texts[row.id] ?? "" }, set: { texts[row.id] = $0 }))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 130)
                .disabled(!isIncluded)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(invalid ? Color.red : Color.clear))
                .help(invalid ? AccountsFormat.invalidAmountMessage(text) : "")
            Text(row.account.currency.rawValue.uppercased())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    private func save() {
        guard let entries, !entries.isEmpty else { return }
        if viewModel.saveBalances(entries, asOf: AccountsFormat.snapshotDay(asOf)) {
            dismiss()
        }
    }
}
