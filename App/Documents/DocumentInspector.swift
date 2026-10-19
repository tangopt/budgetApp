// App/Documents/DocumentInspector.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// The selected document's side (UI polish §4.2): its name with its kind and link state as
/// pills and where it came from; Open / Link to transaction… / ••• (Show in Finder, Remove…);
/// then panels — its first page (click for Quick Look), what it's linked to (show, change
/// role, unlink), the transactions it may be evidence for (link), and its editable details
/// (Save writes them).
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
            VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                header
                actions
                Panel(padding: 12) {
                    DocumentThumbnail(url: viewModel.fileURL(document))
                }
                linksPanel
                suggestionsPanel
                detailsPanel
            }
            // The overview's padding, so the column doesn't shift as a document is selected.
            .padding(ScreenMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.windowFill)
        .sheet(isPresented: $linking) {
            LinkTransactionSheet(documentName: document.displayName, viewModel: viewModel)
        }
        .confirmationDialog("Remove “\(document.displayName)” from the library?", isPresented: $confirmingRemove) {
            Button("Remove from library", role: .destructive) { if let id = document.id { viewModel.remove(id) } }
        } message: {
            Text(viewModel.links.isEmpty
                 ? "Budget deletes its copy. The original file, if you still have it, isn't touched. This can't be undone."
                 : "Budget deletes its copy and its \(viewModel.links.count) link\(viewModel.links.count == 1 ? "" : "s"). The original file, if you still have it, isn't touched. This can't be undone.")
        }
        .alert("Custom role", isPresented: Binding(get: { customRoleRow != nil }, set: { if !$0 { customRoleRow = nil } })) {
            TextField("Role", text: $customRole)
            Button("Set role") {
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
        VStack(alignment: .leading, spacing: 8) {
            Text(document.displayName)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                StatusPill(document.kind.displayName)
                if viewModel.links.isEmpty {
                    StatusPill("Not linked", tone: .warning, systemImage: "circle.dashed")
                } else {
                    StatusPill(viewModel.links.count == 1 ? "1 link" : "\(viewModel.links.count) links", tone: .positive, systemImage: "link")
                }
                if document.textStatus == .image {
                    StatusPill("Image only", tone: .warning, systemImage: "photo")
                        .help("No text to search or match — check the details by eye")
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                if document.canonicalName != nil, document.canonicalName != document.originalFileName {
                    metaRow("File", document.originalFileName)
                }
                if let source {
                    metaRow("From", source)
                }
                // When it was added, on this Mac's calendar (a moment, not a stored day).
                metaRow("Added", document.addedAt.formatted(date: .abbreviated, time: .omitted), isFigure: true)
                metaRow("Size", size, isFigure: true)
            }
            .font(.caption)
        }
    }

    /// A label and its value; a figure (a day, a size) on one line, a name in up to two.
    private func metaRow(_ label: String, _ value: String, isFigure: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            if isFigure {
                Text(value).textSelection(.enabled).figureText()
            } else {
                Text(value)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(value)
            }
        }
    }

    /// "Property A · Bank/2024/notice.pdf": the evidence folder it was found in, and where.
    private var source: String? {
        var parts: [String] = []
        if let folder = viewModel.sourceFolder(document.sourceFolderId) { parts.append(folder.name) }
        if let path = document.sourceRelativePath { parts.append(path) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2 KB · Text read".
    private var size: String {
        let size = ByteCountFormatter.string(fromByteCount: document.byteCount, countStyle: .file)
        switch document.textStatus {
        case .text: return "\(size) · Text read"
        case .glyph: return "\(size) · Text decoded"
        case .image: return "\(size) · Image only, no text"
        case .noText: return "\(size) · No text"
        case .unknown: return "\(size) · Not analysed"
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Open") { viewModel.open(document) }
                .help("Open in its default app")
            Button("Link to transaction…") { linking = true }
                .buttonStyle(.borderedProminent).prominentTint()
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

    // MARK: Links

    private var linksPanel: some View {
        Panel("Linked to", padding: 12) {
            if viewModel.links.isEmpty {
                Text("Not linked to anything yet. Link it to the transaction it's for, or to a record from that record's screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.links.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        linkRow(row)
                            .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    /// A linked record on two lines: its name and amount, then what it is with the link's role
    /// (a menu) and the actions as icons.
    private func linkRow(_ row: DocumentsViewModel.LinkRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title).lineLimit(1).truncationMode(.tail).help(row.title)
                Spacer(minLength: 6)
                if let info = row.transaction {
                    MoneyText(minorUnits: info.transaction.amountMinorUnits, currency: info.currency)
                }
            }
            HStack(spacing: 6) {
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                roleMenu(row)
                Spacer(minLength: 0)
                if let info = row.transaction {
                    Button { openTransaction(info.transaction) } label: { Image(systemName: "arrow.right.circle") }
                        .help(info.transaction.categoryId == nil ? "Show on the Uncategorized screen (or in Search)" : "Show in its Budget cell")
                        .accessibilityLabel("Show \(row.title)")
                }
                Button { viewModel.unlink(row) } label: { Image(systemName: "xmark.circle") }
                    .help("Unlink: remove this link (the document stays in the library)")
                    .accessibilityLabel("Unlink \(row.title)")
            }
            .buttonStyle(.borderless)
        }
    }

    private func roleMenu(_ row: DocumentsViewModel.LinkRow) -> some View {
        Menu {
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
        } label: {
            // One Text, so the menu keeps the chevron after the role.
            Text("\(row.link.role ?? "No role") \(Image(systemName: "chevron.down"))")
                .font(.caption)
                .foregroundStyle(row.link.role == nil ? Color.secondary : theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What this document is for the record")
        .accessibilityLabel("Role: \(row.link.role ?? "none")")
    }

    // MARK: Suggestions

    /// A suggested transaction as a table row.
    private struct SuggestionRow: Identifiable {
        let info: EvidenceTransactionInfo
        let reasons: [String]
        let isConfident: Bool
        var id: Int64 { info.id }
    }

    private var suggestionRows: [SuggestionRow] {
        let confident = EvidenceMatcher.confidentMatch(viewModel.suggestions)?.transactionId
        return viewModel.suggestions.compactMap { suggestion in
            viewModel.catalog?.info(suggestion.transactionId).map {
                SuggestionRow(info: $0, reasons: suggestion.reasons, isConfident: suggestion.transactionId == confident)
            }
        }
    }

    private var suggestionsPanel: some View {
        Panel("Suggested transactions", padding: 12) {
            if viewModel.catalog == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for transactions…").foregroundStyle(.secondary)
                }
                .font(.callout)
            } else if suggestionRows.isEmpty {
                Text(document.amountMinorUnits == nil && document.docDate == nil
                     ? "Add the document's date and amount to find its transactions."
                     : "No matching transactions: search with Link to transaction….")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DataTable(columns: suggestionColumns, rows: suggestionRows)
            }
        }
    }

    private var suggestionColumns: [DataTableColumn<SuggestionRow>] {
        [
            DataTableColumn("Transaction", width: .fill(min: 120),
                            accessibilityValue: { row in
                                ((row.isConfident ? ["Best match"] : []) + [row.info.transaction.rawDescription,
                                  DocumentFormat.day(row.info.transaction.date), row.info.accountName] + row.reasons).joined(separator: ", ")
                            }) { row, _ in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        // The clear best match: a star before its description (it never costs the
                        // caption its room, as words would).
                        if row.isConfident {
                            Image(systemName: "star.fill")
                                .font(.caption2).foregroundStyle(theme.accent)
                                .help("Best match")
                                .accessibilityLabel("Best match")
                        }
                        Text(row.info.transaction.rawDescription).lineLimit(1)
                    }
                    // The day, then why it's suggested — its first two reasons, or as many as fit
                    // (the account is one when it counted; all of them in the tooltip) — else the account.
                    ViewThatFits(in: .horizontal) {
                        ForEach([2, 1, 0], id: \.self) { count in
                            let why = row.reasons.isEmpty ? [row.info.accountName] : Array(row.reasons.prefix(count))
                            Text(([DocumentFormat.day(row.info.transaction.date)] + why).filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .lineLimit(1)
                .help(([row.info.transaction.rawDescription, [DocumentFormat.day(row.info.transaction.date), row.info.accountName, row.info.categoryName]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")] + row.reasons).joined(separator: "\n"))
            },
            .money("Amount", minWidth: 84, currency: { $0.info.currency }) { $0.info.transaction.amountMinorUnits },
            DataTableColumn("", alignment: .trailing) { row, _ in
                HStack(spacing: 6) {
                    // Why it's suggested: the amount, the days apart, a reference…
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("Why: " + (row.reasons.isEmpty ? "near the document's date" : row.reasons.joined(separator: " · ")))
                        .accessibilityLabel("Why: " + (row.reasons.isEmpty ? "near the document's date" : row.reasons.joined(separator: ", ")))
                    Button { viewModel.link(transactionId: row.info.id, role: nil) } label: {
                        Image(systemName: "link.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(row.isConfident ? theme.accent : Color.secondary)
                    .help(row.isConfident ? "Link: the clear best match" : "Link to this transaction")
                    .accessibilityLabel("Link to \(row.info.transaction.rawDescription)")
                }
            }
        ]
    }

    // MARK: Details

    private var detailsPanel: some View {
        Panel("Details", padding: 12) {
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
                                draft.periodStart = draft.hasDate ? draft.date : Calendar.current.startOfDay(for: AppClock.now)
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
                        .buttonStyle(.borderedProminent).prominentTint()
                        .disabled(!isDirty || draft.details == nil)
                }
                .controlSize(.small)
            }
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
                    day.wrappedValue = Calendar.current.startOfDay(for: AppClock.now)
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
        let today = Calendar.current.startOfDay(for: AppClock.now)
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
