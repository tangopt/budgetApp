// App/Property/RechargeSheets.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BudgetCore
import GRDB

// MARK: - Statement

/// One month's statement (plan phase 5 Task 3): its invoice lines (the invoices since the
/// last statement) and manual lines, staged until Save; the email (template per language,
/// editable) opened as a draft in Mail with the invoices attached — the user sends it; and
/// Mark sent. Prepare email and Mark sent save the staged lines first.
@MainActor
final class RechargeStatementModel: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        var lineId: Int64?
        var invoiceId: Int64?
        var label: String
        var detail: String
        var note: String?
        var amountMinorUnits: Int
        var manualText: String
        var manualAmountText: String
        var isNew: Bool
        var removed = false
        var isManual: Bool { invoiceId == nil }
        var currentAmount: Int? { isManual ? Money.parseMinorUnits(manualAmountText) : amountMinorUnits }
    }

    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary
    let propertyId: Int64
    let tenancy: Tenancy
    let currency: Currency
    let month: Date
    @Published private(set) var statement: RechargeStatement?
    @Published var lines: [Line] = []
    @Published var language: RechargeEmailLanguage = .portuguese { didSet { if language != oldValue { loadTemplate() } } }
    @Published var subject = ""
    @Published var bodyText = ""
    @Published var sentDate = PropertyDays.utcToday(Date())
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// The last prepared message's attachment copies (removed at the next one).
    private static var attachmentFolder: URL?

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, propertyId: Int64, tenancy: Tenancy, currency: Currency,
         target: RechargeStatementTarget) {
        self.dbQueue = dbQueue
        self.library = library
        self.propertyId = propertyId
        self.tenancy = tenancy
        self.currency = currency
        self.month = target.month
        load(statementId: target.statementId)
        loadTemplate()
    }

    var isEditable: Bool { statement.map { $0.status == .draft } ?? true }
    var total: Int { lines.filter { !$0.removed }.reduce(0) { $0 + ($1.currentAmount ?? 0) } }
    var isValid: Bool { lines.filter { !$0.removed && $0.isManual }.allSatisfy { !$0.manualText.trimmingCharacters(in: .whitespaces).isEmpty && $0.currentAmount != nil } }
    var hasLines: Bool { lines.contains { !$0.removed } }
    /// A sent date before the statement's month is probably a slip.
    var sentDateWarning: String? {
        sentDate < month ? "The sent date is before \(RechargeEmail.monthName(month, language: .english))." : nil
    }
    /// Recipients as they'll be addressed.
    var recipients: [String] { Tenancies.emailAddresses(tenancy) }
    var title: String { "Utilities · \(RechargeEmail.monthName(month, language: .english))" }

    private func load(statementId: Int64?) {
        do {
            let (statement, details, pending) = try dbQueue.read { [tenancy, month] db in
                let statement = try statementId.flatMap { try RechargeStatement.fetchOne(db, key: $0) }
                let details = try statement.map { try Recharges.lineDetails(db: db, statementId: $0.id!) } ?? []
                var pending: [(Recharges.PendingLine, UtilityProvider?)] = []
                if statement?.status ?? .draft == .draft {
                    let lastDay = MonthRange.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: month)!
                    pending = try Recharges.pendingLines(db: db, tenancyId: tenancy.id!, through: lastDay).map {
                        ($0, try UtilityProvider.fetchOne(db, key: $0.invoice.providerId))
                    }
                }
                return (statement, details, pending)
            }
            self.statement = statement
            if let sentAt = statement?.sentAt { sentDate = sentAt }
            lines = details.map { detail in
                Line(lineId: detail.line.id, invoiceId: detail.line.invoiceId, label: label(detail.invoice, detail.provider, manual: detail.line.lineDescription),
                     detail: detail.invoice.map(invoiceDetail) ?? "", note: detail.line.note, amountMinorUnits: detail.line.amountMinorUnits,
                     manualText: detail.line.lineDescription ?? "", manualAmountText: Money.formatInput(detail.line.amountMinorUnits), isNew: false)
            } + pending.map { pending, provider in
                // On an existing draft, invoices that arrived since are offered unticked.
                Line(lineId: nil, invoiceId: pending.invoice.id, label: label(pending.invoice, provider, manual: nil),
                     detail: invoiceDetail(pending.invoice), note: pending.note, amountMinorUnits: pending.amountMinorUnits,
                     manualText: "", manualAmountText: "", isNew: true, removed: statement != nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func label(_ invoice: UtilityInvoice?, _ provider: UtilityProvider?, manual: String?) -> String {
        guard let invoice else { return manual ?? "" }
        return [provider.map { "\($0.kind.displayName) · \($0.name)" }, invoice.invoiceNumber].compactMap { $0 }.joined(separator: " · ")
    }

    private func invoiceDetail(_ invoice: UtilityInvoice) -> String {
        var text = "Issued \(DocumentFormat.day(invoice.issueDate))"
        if let start = invoice.periodStart, let end = invoice.periodEnd { text += " · \(DocumentFormat.day(start)) – \(DocumentFormat.day(end))" }
        return text
    }

    func loadTemplate() {
        let template = (try? dbQueue.read { [propertyId, language] db in
            try RechargeEmail.template(db: db, propertyId: propertyId, language: language)
        }) ?? RechargeEmail.defaultTemplate(propertyId: propertyId, language: language)
        subject = template.subject
        bodyText = template.body
    }

    func addManualLine() {
        lines.append(Line(lineId: nil, invoiceId: nil, label: "", detail: "", note: nil, amountMinorUnits: 0, manualText: "",
                          manualAmountText: "", isNew: true))
    }

    /// Applies the staged lines: the statement (created empty), the ticked new invoice lines
    /// added at the amounts shown, lines left out removed, manual lines added or changed.
    /// Returns its id.
    @discardableResult
    func apply() throws -> Int64 {
        if let statement, statement.status != .draft { return statement.id! }
        let lines = lines
        let id = try dbQueue.write { [tenancy, month] db -> Int64 in
            let statement = try Recharges.draftStatement(db: db, tenancyId: tenancy.id!, month: month, addPending: false)
            let id = statement.id!
            for line in lines {
                if line.isManual {
                    if line.removed {
                        if let lineId = line.lineId { try Recharges.removeLine(db: db, lineId: lineId) }
                    } else if let amount = line.currentAmount {
                        try Recharges.saveManualLine(db: db, statementId: id, lineId: line.lineId, description: line.manualText, amountMinorUnits: amount)
                    }
                } else if let invoiceId = line.invoiceId {
                    if line.removed {
                        if line.lineId != nil { try Recharges.removeLine(db: db, statementId: id, invoiceId: invoiceId) }
                    } else if line.lineId == nil {
                        try Recharges.setLine(db: db, statementId: id, invoiceId: invoiceId, amountMinorUnits: line.amountMinorUnits, note: line.note)
                    }
                }
            }
            return id
        }
        load(statementId: id)
        return id
    }

    func save() -> Bool {
        do {
            try apply()
            return true
        } catch {
            errorMessage = RechargeMessages.text(for: error)
            return false
        }
    }

    func saveTemplate() {
        do {
            try dbQueue.write { [propertyId, language, subject, bodyText] db in
                var template = try RechargeEmail.template(db: db, propertyId: propertyId, language: language)
                template.subject = subject
                template.body = bodyText
                try RechargeEmail.saveTemplate(db: db, &template)
            }
            infoMessage = "Saved as the \(language.displayName) template."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetTemplate() {
        try? dbQueue.write { [propertyId, language] db in try RechargeEmail.resetTemplate(db: db, propertyId: propertyId, language: language) }
        loadTemplate()
    }

    /// Saves the lines, then opens a new message in Mail (recipients, subject, body, the
    /// invoices attached under their own names). Nothing is sent: the user reviews and sends.
    func prepareEmail() {
        do {
            let id = try apply()
            let template = RechargeEmailTemplate(propertyId: propertyId, language: language, subject: subject, body: bodyText)
            let (draft, documents) = try dbQueue.read { [language] db in
                let draft = try RechargeEmail.draft(db: db, statementId: id, language: language, template: template)
                return (draft, try EvidenceDocument.filter(keys: draft.attachmentDocumentIds).fetchAll(db))
            }
            // The previous draft's copies go (Mail has them by now).
            if let previous = Self.attachmentFolder { try? FileManager.default.removeItem(at: previous) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Recharges-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.attachmentFolder = folder
            var attachments: [URL] = []
            for documentId in draft.attachmentDocumentIds {
                guard let document = documents.first(where: { $0.id == documentId }) else { continue }
                let name = (document.canonicalName ?? document.originalFileName).replacingOccurrences(of: "/", with: "-")
                var base = (name as NSString).deletingPathExtension
                var ext = (name as NSString).pathExtension
                if ext.isEmpty { ext = (document.storedRelativePath as NSString).pathExtension }
                if base.isEmpty { base = "Invoice" }
                // Two documents with the same name: "name (2).pdf".
                var target = folder.appendingPathComponent(base).appendingPathExtension(ext)
                var copy = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent("\(base) (\(copy))").appendingPathExtension(ext)
                    copy += 1
                }
                try FileManager.default.copyItem(at: library.fileURL(for: document), to: target)
                attachments.append(target)
            }
            let items: [Any] = [draft.body as NSString] + attachments.map { $0 as NSURL }
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) else {
                errorMessage = "No email app is set up to compose a message: set one in Mail ▸ Settings."
                return
            }
            service.recipients = draft.recipients
            service.subject = draft.subject
            service.perform(withItems: items)
            infoMessage = draft.recipients.isEmpty
                ? "Message prepared with no recipient: add the tenant's email to the tenancy."
                : "Message prepared for \(draft.recipients.joined(separator: ", ")). Check and send it from your email app, then Mark sent."
        } catch {
            errorMessage = RechargeMessages.text(for: error)
        }
    }

    func markSent() -> Bool {
        do {
            let id = try apply()
            try dbQueue.write { [sentDate] db in _ = try Recharges.markSent(db: db, statementId: id, at: sentDate) }
            return true
        } catch {
            errorMessage = RechargeMessages.text(for: error)
            return false
        }
    }
}

struct RechargeStatementSheet: View {
    @StateObject var model: RechargeStatementModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        SheetScaffold(title: model.title,
                      subtitle: model.isEditable
                          ? "The invoices issued (or debited) since the last statement, prorated to the tenancy's days where needed. Leave lines out or add one-off lines; nothing is saved until Save, Prepare email or Mark sent."
                          : "Sent \(model.statement?.sentAt.map(DocumentFormat.day) ?? ""): its lines are fixed.",
                      error: model.errorMessage, width: 760, cancelTitle: model.isEditable ? "Cancel" : "Close", onCancel: { dismiss() },
                      primary: model.isEditable ? SheetAction("Save", isEnabled: model.isValid) { if model.save() { dismiss() } } : nil) {
            VStack(alignment: .leading, spacing: 12) {
                linesView
                Divider()
                emailView
                if let info = model.infoMessage {
                    Text(info).font(.callout).foregroundStyle(.secondary)
                }
                if model.isEditable {
                    HStack {
                        Spacer()
                        if let warning = model.sentDateWarning { Text(warning).font(.callout).foregroundStyle(theme.expense) }
                        DatePicker("Sent on", selection: utcDay($model.sentDate), displayedComponents: .date).fixedSize()
                        Button("Mark sent") { if model.markSent() { dismiss() } }
                            .disabled(!model.isValid || !model.hasLines)
                            .help("Saves the statement and fixes its lines; the next tenant credit can then pay it")
                    }
                }
            }
        }
    }

    private var linesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach($model.lines) { $line in
                        GridRow {
                            if line.isManual && model.isEditable {
                                TextField("Description", text: $line.manualText).gridCellColumns(1)
                                Text("Manual line").font(.caption).foregroundStyle(.secondary)
                                MoneyField("Amount", text: $line.manualAmountText, currency: model.currency, width: 90)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.isManual ? line.manualText : line.label).lineLimit(1)
                                    if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(line.detail + (line.isNew ? " · new" : "")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                PropertyMoney(minorUnits: line.currentAmount ?? 0, currency: model.currency).gridColumnAlignment(.trailing)
                            }
                            if model.isEditable {
                                Toggle("Include", isOn: Binding(get: { !line.removed }, set: { line.removed = !$0 }))
                                    .toggleStyle(.checkbox).labelsHidden()
                                    .accessibilityLabel("Include \(line.isManual ? line.manualText : line.label)")
                            }
                        }
                        .opacity(line.removed ? 0.45 : 1)
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 240)
            HStack {
                if model.isEditable { Button("Add line") { model.addManualLine() }.help("A one-off charge, or a refund (negative)") }
                Spacer()
                Text("Total").foregroundStyle(.secondary)
                PropertyMoney(minorUnits: model.total, currency: model.currency, font: .headline.monospacedDigit())
            }
        }
    }

    private var emailView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.recipients.isEmpty ? "No email on the tenancy" : "To: \(model.recipients.joined(separator: ", "))").font(.callout)
                Spacer()
                Picker("Language", selection: $model.language) {
                    ForEach(RechargeEmailLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
            }
            TextField("Subject", text: $model.subject)
            TextEditor(text: $model.bodyText)
                .font(.callout)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Text("Placeholders: {tenant} {month} {property} {table} {total}").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset text") { model.resetTemplate() }.buttonStyle(.borderless)
                Button("Save text as template") { model.saveTemplate() }
                Button("Prepare email…") { model.prepareEmail() }
                    .disabled(!model.isValid || !model.hasLines)
                    .help("Saves the statement and opens a new message in Mail with the invoices attached; you send it")
            }
        }
    }
}

// MARK: - Providers

/// The property's utility providers and how their invoices are read (stored as data), with
/// "Test against a document…" to check the rules on a real invoice before saving.
struct UtilityProvidersSheet: View {
    let dbQueue: DatabaseQueue
    let propertyId: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [UtilityProvider] = []
    @State private var editing: UtilityProvider?
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: "Utility providers", subtitle: "Each provider's bank description and how its invoices are read.",
                      error: error, width: 520, cancelTitle: "Done", onCancel: { dismiss() }) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(providers) { provider in
                    HStack {
                        Text(provider.name)
                        Text(provider.kind.displayName).foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit…") { editing = provider }.buttonStyle(.borderless)
                        Button("Delete", role: .destructive) { delete(provider) }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Menu("Add provider") {
                        ForEach(UtilityInvoiceRules.presets) { preset in
                            Button("\(preset.name) (\(preset.kind.displayName.lowercased()))") {
                                editing = UtilityProvider(propertyId: propertyId, name: preset.name, kind: preset.kind,
                                                          bankDescriptionPattern: preset.bankDescriptionPattern, invoiceRules: preset.rules)
                            }
                        }
                        Divider()
                        Button("Blank") { editing = UtilityProvider(propertyId: propertyId, name: "", kind: .other, invoiceRules: .generic) }
                    }
                    .fixedSize()
                    Spacer()
                }
            }
        }
        .onAppear(perform: load)
        .sheet(item: $editing, onDismiss: load) { provider in
            UtilityProviderFormSheet(dbQueue: dbQueue, provider: provider)
        }
    }

    private func load() {
        providers = (try? dbQueue.read { db in try Recharges.providers(db: db, propertyId: propertyId) }) ?? []
    }

    private func delete(_ provider: UtilityProvider) {
        do {
            _ = try dbQueue.write { db in try Recharges.deleteProvider(db: db, id: provider.id!) }
            error = nil
            load()
        } catch {
            self.error = error as? RechargeError == .invoiceOnStatement
                ? "\(provider.name) has invoices on statements: it can't be deleted."
                : error.localizedDescription
        }
    }
}

struct UtilityProviderFormSheet: View {
    let dbQueue: DatabaseQueue
    @State var provider: UtilityProvider
    @Environment(\.dismiss) private var dismiss
    @State private var markers = ""
    @State private var fileNameMarkers = ""
    @State private var numberPatterns = ""
    @State private var issueLabels = ""
    @State private var periodLabels = ""
    @State private var amountLabels = ""
    @State private var refundLabels = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var error: String?

    init(dbQueue: DatabaseQueue, provider: UtilityProvider) {
        self.dbQueue = dbQueue
        _provider = State(initialValue: provider)
        let rules = provider.effectiveRules
        _markers = State(initialValue: rules.textMarkers.joined(separator: ", "))
        _fileNameMarkers = State(initialValue: rules.fileNameMarkers.joined(separator: ", "))
        _numberPatterns = State(initialValue: rules.invoiceNumberPatterns.joined(separator: "\n"))
        _issueLabels = State(initialValue: rules.issueDateLabels.joined(separator: ", "))
        _periodLabels = State(initialValue: rules.periodLabels.joined(separator: ", "))
        _amountLabels = State(initialValue: rules.amountLabels.joined(separator: ", "))
        _refundLabels = State(initialValue: rules.refundLabels.joined(separator: ", "))
    }

    private var rules: UtilityInvoiceRules {
        func list(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return UtilityInvoiceRules(textMarkers: list(markers), fileNameMarkers: list(fileNameMarkers),
                                   invoiceNumberPatterns: numberPatterns.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                   issueDateLabels: list(issueLabels), periodLabels: list(periodLabels),
                                   amountLabels: list(amountLabels), refundLabels: list(refundLabels))
    }

    var body: some View {
        SheetScaffold(title: provider.id == nil ? "New provider" : "Edit provider", error: error, width: 600, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: !provider.name.trimmingCharacters(in: .whitespaces).isEmpty, action: save)) {
            SheetForm {
                LabeledContent("Name") { TextField("Name", text: $provider.name) }
                LabeledContent("Kind") {
                    Picker("Kind", selection: $provider.kind) { ForEach(UtilityKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                        .labelsHidden().fixedSize()
                }
                LabeledContent("Account / contract") { TextField("Account", text: Binding(get: { provider.accountReference ?? "" }, set: { provider.accountReference = $0 })) }
                LabeledContent("Bank description") {
                    TextField("Bank description", text: Binding(get: { provider.bankDescriptionPattern ?? "" }, set: { provider.bankDescriptionPattern = $0 }),
                              prompt: Text("Text its debits contain; alternatives separated by |"))
                }
                LabeledContent("Identifying words") { TextField("Words", text: $markers, prompt: Text("In the invoice text, comma-separated")) }
                LabeledContent("File name words") { TextField("Words", text: $fileNameMarkers, prompt: Text("e.g. LUZ, AGUA")) }
                LabeledContent("Number patterns") {
                    TextField("Patterns", text: $numberPatterns, prompt: Text("Regular expressions, one per line; group 1 is the number"), axis: .vertical)
                        .lineLimit(2...4).font(.callout.monospaced())
                }
                LabeledContent("Issue date after") { TextField("Labels", text: $issueLabels, prompt: Text("Labels; none: the first date")) }
                LabeledContent("Period after") { TextField("Labels", text: $periodLabels) }
                LabeledContent("Total after") { TextField("Labels", text: $amountLabels) }
                LabeledContent("Refund after") { TextField("Labels", text: $refundLabels) }
                LabeledContent("Test") {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Test against a document…") { testing = true }
                        if let testResult { Text(testResult).font(.callout.monospaced()).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
        .fileImporter(isPresented: $testing, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            test(url)
        }
    }

    private func test(_ url: URL) {
        let rules = rules
        testResult = "Reading…"
        Task {
            let reading = await Task.detached(priority: .userInitiated) { () -> (UtilityInvoiceReading, Bool) in
                let text = EvidenceFiles.withAccess(url) { UtilityInvoiceIntake.text(of: url) }
                return (UtilityInvoiceReader.read(text: text.text, fileName: url.lastPathComponent, rules: rules), text.usedOCR)
            }.value
            let r = reading.0
            func day(_ date: Date?) -> String { date.map(DocumentFormat.day) ?? "—" }
            testResult = """
            Number   \(r.invoiceNumber ?? "—")
            Issued   \(day(r.issueDate))
            Period   \(day(r.periodStart)) – \(day(r.periodEnd))
            Amount   \(r.amountMinorUnits.map { Money.formatInput($0) } ?? "—")\(reading.1 ? "\n(read with OCR)" : "")
            """
        }
    }

    private func save() {
        do {
            var provider = provider
            provider.invoiceRules = rules
            try dbQueue.write { db in try Recharges.saveProvider(db: db, &provider) }
            dismiss()
        } catch {
            self.error = RechargeMessages.text(for: error)
        }
    }
}
