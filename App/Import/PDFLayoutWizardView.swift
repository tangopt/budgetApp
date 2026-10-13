// App/Import/PDFLayoutWizardView.swift
import SwiftUI
import BudgetCore

struct PDFLayoutWizardView: View {
    let account: Account
    let sampleLines: [String]
    let onSave: (ImportProfile) -> Void

    @State private var regexPattern = #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?$"#
    @State private var dateFormat = "dd MMM yy"
    @Environment(\.dismiss) private var dismiss

    private var previewResult: PDFParseResult {
        PDFLineParser.parse(lines: Array(sampleLines.prefix(10)), config: PDFLayoutConfig(regexPattern: regexPattern, dateFormat: dateFormat))
    }

    var body: some View {
        SheetScaffold(title: "PDF layout — \(account.displayName)",
                      subtitle: "Paste the sample lines below into a regex with 3 capture groups: date, description, amount. Lines ending 'CR' are treated as credits, everything else as a debit.",
                      width: 520, onCancel: { dismiss() },
                      primary: SheetAction("Save layout") {
                          guard let config = try? PDFLayoutConfig(regexPattern: regexPattern, dateFormat: dateFormat).encoded() else { return }
                          let profile = ImportProfile(accountId: account.id!, format: .pdf, pdfLayoutConfig: config)
                          onSave(profile)
                      }) {
            SheetForm {
                LabeledContent("Regex pattern") { TextField("Regex pattern", text: $regexPattern) }
                LabeledContent("Date format") { TextField("Date format", text: $dateFormat) }
            }
            List(sampleLines.prefix(10), id: \.self) { line in Text(line).font(.system(.body, design: .monospaced)) }
                .frame(height: 200)
            Text("Preview: \(previewResult.transactions.count) matched, \(previewResult.unparsedLines.count) unmatched")
                .font(.callout)
        }
    }
}
