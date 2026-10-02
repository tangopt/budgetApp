// App/Import/CSVMappingWizardView.swift
import SwiftUI
import BudgetCore

struct CSVMappingWizardView: View {
    let account: Account
    let sampleHeaderRow: [String]
    let onSave: (ImportProfile) -> Void

    @State private var dateColumn: Int
    @State private var descriptionColumn: Int
    @State private var amountColumn: Int
    @State private var hasSeparateCreditColumn: Bool
    @State private var creditColumn: Int
    @State private var balanceColumn: Int?
    @State private var dateFormat = "dd/MM/yyyy"

    /// Pre-selects columns from the header names (`CSVColumnSuggester`); anything it
    /// can't recognise falls back to the old positional defaults (0, 1, 2, 3), clamped to
    /// the header's width.
    init(account: Account, sampleHeaderRow: [String], onSave: @escaping (ImportProfile) -> Void) {
        self.account = account
        self.sampleHeaderRow = sampleHeaderRow
        self.onSave = onSave
        let suggestion = CSVColumnSuggester.suggest(header: sampleHeaderRow)
        let lastIndex = max(sampleHeaderRow.count - 1, 0)
        _dateColumn = State(initialValue: suggestion.dateColumn ?? min(0, lastIndex))
        _descriptionColumn = State(initialValue: suggestion.descriptionColumn ?? min(1, lastIndex))
        _amountColumn = State(initialValue: suggestion.amountColumn ?? min(2, lastIndex))
        _hasSeparateCreditColumn = State(initialValue: suggestion.hasSeparateDebitCredit)
        _creditColumn = State(initialValue: suggestion.creditColumn ?? min(3, lastIndex))
        _balanceColumn = State(initialValue: suggestion.balanceColumn)
    }

    var body: some View {
        Form {
            Picker("Date column", selection: $dateColumn) {
                ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
            }
            Picker("Description column", selection: $descriptionColumn) {
                ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
            }
            Toggle("This statement splits amounts into separate debit/credit columns", isOn: $hasSeparateCreditColumn)
            Picker(hasSeparateCreditColumn ? "Debit column" : "Amount column", selection: $amountColumn) {
                ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
            }
            if hasSeparateCreditColumn {
                Picker("Credit column", selection: $creditColumn) {
                    ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
                }
            }
            if account.kind != .credit {
                Picker("Balance column", selection: $balanceColumn) {
                    Text("None").tag(Int?.none)
                    ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(Int?.some(i)) }
                }
                Text("With a Balance column the importer can record this account's balance from the statement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Date format (e.g. dd/MM/yyyy)", text: $dateFormat)
            Button("Save mapping") {
                let profile = ImportProfile(
                    accountId: account.id!, format: .csv, csvDelimiter: ",",
                    csvDateColumnIndex: dateColumn, csvDescriptionColumnIndex: descriptionColumn,
                    csvAmountColumnIndex: amountColumn,
                    csvCreditAmountColumnIndex: hasSeparateCreditColumn ? creditColumn : nil,
                    csvBalanceColumnIndex: account.kind == .credit ? nil : balanceColumn,
                    csvDateFormat: dateFormat
                )
                onSave(profile)
            }
        }
        .padding()
        .frame(width: 440)
    }
}
