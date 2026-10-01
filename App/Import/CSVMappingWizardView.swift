// App/Import/CSVMappingWizardView.swift
import SwiftUI
import BudgetCore

struct CSVMappingWizardView: View {
    let account: Account
    let sampleHeaderRow: [String]
    let onSave: (ImportProfile) -> Void

    @State private var dateColumn = 0
    @State private var descriptionColumn = 1
    @State private var amountColumn = 2
    @State private var hasSeparateCreditColumn = false
    @State private var creditColumn = 3
    @State private var dateFormat = "dd/MM/yyyy"

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
            TextField("Date format (e.g. dd/MM/yyyy)", text: $dateFormat)
            Button("Save mapping") {
                let profile = ImportProfile(
                    accountId: account.id!, format: .csv, csvDelimiter: ",",
                    csvDateColumnIndex: dateColumn, csvDescriptionColumnIndex: descriptionColumn,
                    csvAmountColumnIndex: amountColumn,
                    csvCreditAmountColumnIndex: hasSeparateCreditColumn ? creditColumn : nil,
                    csvDateFormat: dateFormat
                )
                onSave(profile)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
