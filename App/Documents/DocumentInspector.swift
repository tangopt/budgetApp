// App/Documents/DocumentInspector.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// The selected document's side: its name and origin, Open / Show in Finder / Link to
/// transaction… / Remove…, its editable details (Save writes them), what it's linked to
/// (show, change role, unlink) and the transactions it may be evidence for (Link).
struct DocumentInspector: View {
    @ObservedObject var viewModel: DocumentsViewModel
    let document: EvidenceDocument
    let openTransaction: (Transaction) -> Void
    @Environment(\.theme) private var theme

    @State private var draft: DocumentDetailsDraft
    @State private var linking = false
    @State private var confirmingRemove = false
    @State private var customRoleRow: DocumentsViewModel.LinkRow?
    @State private var customRole = ""

    init(viewModel: DocumentsViewModel, document: EvidenceDocument, openTransaction: @escaping (Transaction) -> Void) {
        self.viewModel = viewModel
        self.document = document
        self.openTransaction = openTransaction
        _draft = State(initialValue: DocumentDetailsDraft(document))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                detailsBox
                linksBox
                suggestionsBox
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.windowFill)
        .sheet(isPresented: $linking) {
            LinkTransactionSheet(documentName: document.displayName, viewModel: viewModel)
        }
        .confirmationDialog("Remove “\(document.displayName)” from the library?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { if let id = document.id { viewModel.remove(id) } }
        } message: {
            Text(viewModel.links.isEmpty
                 ? "Budget deletes its copy. The original file, if you still have it, isn't touched."
                 : "Budget deletes its copy and its \(viewModel.links.count) link\(viewModel.links.count == 1 ? "" : "s"). The original file, if you still have it, isn't touched.")
        }
        .alert("Role", isPresented: Binding(get: { customRoleRow != nil }, set: { if !$0 { customRoleRow = nil } })) {
            TextField("Role", text: $customRole)
            Button("Set") {
                if let row = customRoleRow { viewModel.setRole(customRole, for: row) }
                customRoleRow = nil
            }
            Button("Cancel", role: .cancel) { customRoleRow = nil }
        } message: {
            Text("What this document is for the record, e.g. “Notice” or “Payment proof”.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.displayName)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if document.canonicalName != nil, document.canonicalName != document.originalFileName {
                Text(document.originalFileName)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let origin {
                Text(origin)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(origin)
            }
            Text(textStatusNote)
                .font(.caption)
                .foregroundStyle(document.textStatus == .image ? theme.pending : .secondary)
        }
    }

    /// "From Lisboa · BBVA/2024/notice.pdf · added 16 Oct 2026".
    private var origin: String? {
        var parts: [String] = []
        if let folder = viewModel.sourceFolder(document.sourceFolderId) { parts.append("From \(folder.name)") }
        if let path = document.sourceRelativePath { parts.append(path) }
        parts.append("added \(document.addedAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }

    private var textStatusNote: String {
        let size = ByteCountFormatter.string(fromByteCount: document.byteCount, countStyle: .file)
        switch document.textStatus {
        case .text: return "\(size) · Text read"
        case .glyph: return "\(size) · Text decoded"
        case .image: return "\(size) · Image only: no text to search or match — check the details by eye"
        case .noText: return "\(size) · No text"
        case .unknown: return "\(size) · Not analysed"
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Open") { viewModel.open(document) }
                .help("Open in its default app")
            Button("Link to transaction…") { linking = true }
            Spacer(minLength: 0)
            Menu {
                Button("Show in Finder") { viewModel.showInFinder(document) }
                Divider()
                Button("Remove from Library…", role: .destructive) { confirmingRemove = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .controlSize(.small)
    }

    // MARK: Details

    private var detailsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                SheetForm {
                    LabeledContent("Kind") {
                        Picker("Kind", selection: $draft.kind) {
                            ForEach(DocumentKind.byDisplayName, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                    }
                    LabeledContent("Name") {
                        TextField("Name", text: $draft.canonicalName, prompt: Text(document.originalFileName))
                    }
                    LabeledContent("Date") {
                        optionalDay($draft.hasDate, $draft.date, add: "Add date")
                    }
                    LabeledContent("Period") {
                        if draft.hasPeriod {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    DatePicker("From", selection: $draft.periodStart, displayedComponents: .date)
                                    Text("to").foregroundStyle(.secondary)
                                }
                                HStack(spacing: 4) {
                                    DatePicker("To", selection: $draft.periodEnd, displayedComponents: .date)
                                    clearButton("Remove period") { draft.hasPeriod = false }
                                }
                            }
                        } else {
                            Button("Add period") {
                                draft.periodStart = draft.hasDate ? draft.date : Calendar.current.startOfDay(for: Date())
                                draft.periodEnd = draft.periodStart
                                draft.hasPeriod = true
                            }
                            .controlSize(.small)
                        }
                    }
                    LabeledContent("Amount") {
                        HStack(spacing: 6) {
                            MoneyField("Amount", text: $draft.amountText, currency: draft.currency, width: 110)
                            Picker("Currency", selection: $draft.currency) {
                                ForEach(Currency.allCases, id: \.self) { currency in
                                    Text(currency.rawValue.uppercased()).tag(currency)
                                }
                            }
                            .fixedSize()
                        }
                    }
                    LabeledContent("Persons") {
                        TextField("Persons", text: $draft.personsText, prompt: Text("Names, separated by commas"))
                    }
                    LabeledContent("Note") {
                        TextField("Note", text: $draft.note, prompt: Text("Optional"), axis: .vertical)
                            .lineLimit(1...4)
                    }
                    if let problem = draft.problem {
                        SheetFormNote(problem, isError: true)
                    }
                }
                HStack {
                    Spacer()
                    Button("Revert") { draft = DocumentDetailsDraft(document) }
                        .disabled(!isDirty)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty || draft.details == nil)
                }
                .controlSize(.small)
            }
            .padding(6)
        } label: {
            Text("Details").font(.headline)
        }
    }

    private var isDirty: Bool { draft != DocumentDetailsDraft(document) }

    private func save() {
        guard let details = draft.details else { return }
        if viewModel.saveDetails(details), let saved = viewModel.selected {
            draft = DocumentDetailsDraft(saved)
        }
    }

    private func optionalDay(_ isOn: Binding<Bool>, _ day: Binding<Date>, add title: String) -> some View {
        Group {
            if isOn.wrappedValue {
                HStack(spacing: 4) {
                    DatePicker(title, selection: day, displayedComponents: .date)
                    clearButton("Remove date") { isOn.wrappedValue = false }
                }
            } else {
                Button(title) {
                    day.wrappedValue = Calendar.current.startOfDay(for: Date())
                    isOn.wrappedValue = true
                }
                .controlSize(.small)
            }
        }
    }

    private func clearButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Links

    private var linksBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.links.isEmpty {
                    Text("Not linked to anything yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.links) { row in
                    linkRow(row)
                    if row.id != viewModel.links.last?.id { Divider() }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Linked to").font(.headline)
        }
    }

    private func linkRow(_ row: DocumentsViewModel.LinkRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).lineLimit(2)
                    if let subtitle = row.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let info = row.transaction {
                    MoneyText(minorUnits: info.transaction.amountMinorUnits, currency: info.currency).fixedSize()
                }
            }
            HStack(spacing: 8) {
                roleMenu(row)
                Spacer(minLength: 0)
                if let info = row.transaction {
                    Button("Show") { openTransaction(info.transaction) }
                        .help(info.transaction.categoryId == nil ? "Show on the Uncategorized screen (or in Search)" : "Show in its Budget cell")
                }
                Button("Unlink") { viewModel.unlink(row) }
                    .help("Remove this link (the document stays in the library)")
            }
            .controlSize(.small)
        }
    }

    private func roleMenu(_ row: DocumentsViewModel.LinkRow) -> some View {
        Menu(row.link.role ?? "No role") {
            ForEach(EvidenceRoles.presets, id: \.self) { role in
                Button(role) { viewModel.setRole(role, for: row) }
            }
            Divider()
            Button("Other…") {
                customRole = row.link.role ?? ""
                customRoleRow = row
            }
            if row.link.role != nil {
                Button("No role") { viewModel.setRole(nil, for: row) }
            }
        }
        .fixedSize()
        .help("What this document is for the record")
        .accessibilityLabel("Role: \(row.link.role ?? "none")")
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestionsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.catalog == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking for transactions…").foregroundStyle(.secondary)
                    }
                } else if viewModel.suggestions.isEmpty {
                    Text(document.amountMinorUnits == nil && document.docDate == nil
                         ? "Add the document's date and amount to find its transactions."
                         : "No matching transactions. Use Link to transaction… to search.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let confident = EvidenceMatcher.confidentMatch(viewModel.suggestions)?.transactionId
                ForEach(viewModel.suggestions, id: \.transactionId) { suggestion in
                    if let info = viewModel.catalog?.info(suggestion.transactionId) {
                        HStack(alignment: .center, spacing: 8) {
                            EvidenceTransactionRow(info: info, reasons: suggestion.reasons)
                            Button("Link") { viewModel.link(transactionId: suggestion.transactionId, role: nil) }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .tint(suggestion.transactionId == confident ? theme.accent : .secondary)
                                .help(suggestion.transactionId == confident ? "The clear best match" : "Link to this transaction")
                                .accessibilityLabel("Link to \(info.transaction.rawDescription)")
                        }
                        if suggestion.transactionId != viewModel.suggestions.last?.transactionId { Divider() }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Suggested transactions").font(.headline)
        }
    }
}

/// The inspector's editable fields; days as the date pickers hold them (local midnight).
struct DocumentDetailsDraft: Equatable {
    var kind: DocumentKind
    var canonicalName: String
    var hasDate: Bool
    var date: Date
    var hasPeriod: Bool
    var periodStart: Date
    var periodEnd: Date
    var amountText: String
    var currency: Currency
    var personsText: String
    var note: String

    init(_ document: EvidenceDocument) {
        let today = Calendar.current.startOfDay(for: Date())
        func local(_ date: Date?) -> Date? { date.map { PayCalendar.localDay(sameDayAs: $0, in: .current) } }
        kind = document.kind
        canonicalName = document.canonicalName ?? ""
        hasDate = document.docDate != nil
        date = local(document.docDate) ?? today
        hasPeriod = document.periodStart != nil || document.periodEnd != nil
        periodStart = local(document.periodStart ?? document.periodEnd) ?? today
        periodEnd = local(document.periodEnd ?? document.periodStart) ?? today
        amountText = document.amountMinorUnits.map(Money.formatInput) ?? ""
        currency = document.currency ?? .eur
        personsText = document.persons.joined(separator: ", ")
        note = document.note ?? ""
    }

    private var amountIsEmpty: Bool { amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Why the entry can't be saved, if it can't.
    var problem: String? {
        if !amountIsEmpty, Money.parseMinorUnits(amountText) == nil { return MoneyField.invalidAmountMessage(amountText) }
        if hasPeriod, periodEnd < periodStart { return EvidenceDetailsError.periodEndsBeforeStart.localizedDescription }
        return nil
    }

    /// What Save writes; nil while `problem` stands.
    var details: EvidenceDocumentDetails? {
        guard problem == nil else { return nil }
        func utc(_ day: Date) -> Date { PayCalendar.utcDay(sameDayAs: day, in: .current) }
        let amount = amountIsEmpty ? nil : Money.parseMinorUnits(amountText).map(abs)
        return EvidenceDocumentDetails(
            kind: kind, docDate: hasDate ? utc(date) : nil,
            periodStart: hasPeriod ? utc(periodStart) : nil, periodEnd: hasPeriod ? utc(periodEnd) : nil,
            amountMinorUnits: amount, currency: amount == nil ? nil : currency,
            persons: EvidenceDocumentDetails.persons(from: personsText), note: note, canonicalName: canonicalName)
    }
}
