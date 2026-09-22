// App/Import/PDFLayoutWizardView.swift
import SwiftUI
import BudgetCore

struct PDFLayoutWizardView: View {
    let account: Account
    let sampleLines: [String]
    let onSave: (ImportProfile) -> Void

    @State private var regexPattern = #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?$"#
    @State private var dateFormat = "dd MMM yy"

    private var previewResult: PDFParseResult {
        PDFLineParser.parse(lines: Array(sampleLines.prefix(10)), config: PDFLayoutConfig(regexPattern: regexPattern, dateFormat: dateFormat))
    }

    var body: some View {
        Form {
            Text("Paste the sample lines below into a regex with 3 capture groups: date, description, amount. Lines ending 'CR' are treated as credits, everything else as a debit.")
                .font(.caption)
            TextField("Regex pattern", text: $regexPattern)
            TextField("Date format", text: $dateFormat)
            List(sampleLines.prefix(10), id: \.self) { line in Text(line).font(.system(.body, design: .monospaced)) }
            Text("Preview: \(previewResult.transactions.count) matched, \(previewResult.unparsedLines.count) unmatched")
            Button("Save layout") {
                guard let config = try? PDFLayoutConfig(regexPattern: regexPattern, dateFormat: dateFormat).encoded() else { return }
                let profile = ImportProfile(accountId: account.id!, format: .pdf, pdfLayoutConfig: config)
                onSave(profile)
            }
        }
        .padding()
        .frame(width: 520)
    }
}
