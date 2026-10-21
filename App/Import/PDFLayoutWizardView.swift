// App/Import/PDFLayoutWizardView.swift
import SwiftUI
import BudgetCore

struct PDFLayoutWizardView: View {
    let account: Account
    let sampleLines: [String]
    let onSave: (ImportProfile) -> Void

    @State private var regexPattern: String
    @State private var dateFormat: String
    @Environment(\.dismiss) private var dismiss

    static let defaultRegexPattern = #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?$"#
    static let defaultDateFormat = "dd MMM yy"

    /// Opens prefilled from `existingProfile`'s layout when editing (one that can't be read
    /// starts from the default).
    init(account: Account, sampleLines: [String], existingProfile: ImportProfile? = nil, onSave: @escaping (ImportProfile) -> Void) {
        self.account = account
        self.sampleLines = sampleLines
        self.onSave = onSave
        let existing = existingProfile?.pdfLayoutConfig.flatMap { try? PDFLayoutConfig.decode($0) }
        _regexPattern = State(initialValue: existing?.regexPattern ?? Self.defaultRegexPattern)
        _dateFormat = State(initialValue: existing?.dateFormat ?? Self.defaultDateFormat)
    }

    private var previewResult: PDFParseResult {
        PDFLineParser.parse(lines: Array(sampleLines.prefix(10)), config: PDFLayoutConfig(regexPattern: regexPattern, dateFormat: dateFormat))
    }

    var body: some View {
        SheetScaffold(title: "PDF layout — \(account.displayName)",
                      subtitle: "Paste the sample lines below into a regex with 3 capture groups: date, description, amount. Lines ending 'CR' are treated as credits, everything else as a debit.",
                      width: 520, onCancel: { dismiss() },
                      primary: SheetAction("Save layout", isDefault: false) {
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
                .figureText()
        }
    }
}
