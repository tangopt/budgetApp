// App/Property/PropertyTenanciesTab.swift
import SwiftUI
import QuickLook
import BudgetCore
import struct BudgetCore.Transaction

/// The Tenancies tab (spec 2026-10-16 §1, §2, UI polish §4.2): the tenancy picker with
/// Import receipts… (the main action) and More (New tenancy…, Match credits, Utility
/// invoices…); the tenancy's panel — tenant, dates, rent, what's held (and whether the
/// deposit account matches), its rent history and contract; then its receipts as a table by
/// year with totals — period, amounts, status, the credits that paid them, the PDF (click its
/// paperclip to preview it), and one actions menu per row. Clicking a receipt opens its panel.
struct PropertyTenanciesTab: View {
    @ObservedObject var viewModel: PropertyViewModel
    let openTransaction: (Transaction) -> Void
    /// Shows a library document selected on the Documents screen.
    let showDocument: (Int64) -> Void
    @Environment(\.theme) private var theme

    /// The window's importer: Import receipts…, Add contract…, Utility invoices… and the
    /// receipts' Add/Replace PDF… are shortcuts into it (handed explicitly to menu content).
    @Environment(\.documentImport) private var documentImport

    @State private var editing: TenancyDraft?
    @State private var deleting: Tenancy?
    /// The receipt PDF shown in Quick Look.
    @State private var quickLook: URL?
    @State private var documentsOf: DocumentsTarget?

    struct DocumentsTarget: Identifiable {
        let entity: EvidenceEntity
        let title: String
        var id: String { "\(entity.type.rawValue)/\(entity.id)" }
    }

    var body: some View {
        let tenancies = viewModel.snapshot.tenancies
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            HStack(spacing: 8) {
                if !tenancies.isEmpty {
                    Picker("Tenancy", selection: Binding(get: { viewModel.selectedTenancy?.id }, set: { viewModel.selectedTenancyId = $0 })) {
                        ForEach(tenancies.reversed()) { tenancy in
                            Text("\(tenancy.referenceLabel) · \(PropertyFormat.period(tenancy.startDate, tenancy.endDate))").tag(tenancy.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Tenancy")
                }
                Spacer(minLength: 8)
                Menu {
                    Button("New tenancy…") { editing = TenancyDraft(nil, rents: [], propertyId: viewModel.propertyId ?? 0) }
                    Divider()
                    Button("Match credits") { viewModel.matchCredits() }
                        .help("Link rent credits on the current account to the receipts they paid")
                    if let propertyId = viewModel.propertyId {
                        ImportShortcutButton("Utility invoices…", shortcut: .utilityInvoices(propertyId: propertyId), importer: documentImport)
                            .help("Add utility invoices (to recharge to the tenant) and match them to their debits")
                    }
                } label: {
                    Text("More")
                }
                .fixedSize()
                .help("New tenancy…, Match credits, Utility invoices…")
                importReceiptsButton
                    .help("Import the Portal das Finanças receipts export (ListaRecibos .xlsx); credits are matched after")
            }
            if let tenancy = viewModel.selectedTenancy {
                // Each built again only when what it shows changes, not whenever the page's
                // model does (a receipt's panel opening, another receipt chosen).
                EquatableContent(tenancyPanelKey(tenancy)) { tenancyPanel(tenancy) }.equatable()
                EquatableContent(receiptsPanelKey(tenancy)) { receiptsPanel(tenancy) }.equatable()
            } else {
                Panel {
                    EmptyState(systemImage: "person.2", title: "No tenancies yet",
                               message: "Import the portal's receipts export to create them, or add one by hand.") {
                        Button("New tenancy…") { editing = TenancyDraft(nil, rents: [], propertyId: viewModel.propertyId ?? 0) }
                        importReceiptsButton
                    }
                    .inPanel()
                }
            }
        }
        .sheet(item: $editing) { draft in
            TenancyFormSheet(viewModel: viewModel, draft: draft)
        }
        .sheet(item: $documentsOf) { target in
            PropertyDocumentsSheet(viewModel: viewModel, entity: target.entity, title: target.title)
        }
        .confirmationDialog(deleting.map { "Delete “\($0.referenceLabel)”?" } ?? "Delete this tenancy?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { tenancy in
            Button("Delete tenancy and its receipts", role: .destructive) {
                viewModel.errorMessage = viewModel.deleteTenancy(tenancy.id!)
            }
        } message: { _ in
            Text("Its rent history, receipts and their credit links go too. Linked documents stay in the library. This can't be undone.")
        }
        .quickLookPreview($quickLook)
    }

    /// Import receipts…: the receipts export, into the importer (its review shows what the file
    /// creates and updates; credits are matched on Confirm import).
    @ViewBuilder
    private var importReceiptsButton: some View {
        if let propertyId = viewModel.propertyId {
            ImportShortcutButton("Import receipts…", shortcut: .rentReceiptsExport(propertyId: propertyId), prominent: true)
        }
    }

    /// A receipt's Add the receipt PDF… / Add another PDF… (`replacing` empty) or Replace PDF…
    /// (the documents linked now), from a table cell or a row's actions menu.
    private func pickReceiptPDF(_ receiptId: Int64, replacing: [Int64] = []) {
        documentImport?.pickShortcut(.receiptPDF(receiptId: receiptId, replacing: replacing))
    }

    /// A receipt's linked documents, read when acted on.
    private func receiptDocuments(_ row: TenancyReceiptRow) -> [EvidenceDocument] {
        viewModel.documents(for: .rentReceipt(row.receipt.id!))
    }

    private func preview(_ document: EvidenceDocument) {
        quickLook = viewModel.fileURL(for: document)
    }

    // MARK: Tenancy

    /// What the tenancy's panel shows.
    private struct TenancyPanelKey: Equatable {
        let tenancy: Tenancy
        let rents: [TenancyRent]
        let contracts: Int
        let currency: Currency
        let inForce: TenancyRent?
        let deposit: PropertyCheckReport.DepositCheck?
        let theme: Theme
    }

    private func tenancyPanelKey(_ tenancy: Tenancy) -> TenancyPanelKey {
        let id = tenancy.id!
        return TenancyPanelKey(tenancy: tenancy, rents: viewModel.snapshot.rents[id] ?? [], contracts: viewModel.snapshot.tenancyDocumentCounts[id] ?? 0,
                               currency: viewModel.currency, inForce: viewModel.rentInForce(tenancy),
                               deposit: viewModel.currentTenancy?.id == id ? viewModel.snapshot.checks?.deposit : nil, theme: theme)
    }

    private func tenancyPanel(_ tenancy: Tenancy) -> some View {
        let id = tenancy.id!
        let rents = viewModel.snapshot.rents[id] ?? []
        let contracts = viewModel.snapshot.tenancyDocumentCounts[id] ?? 0
        let currency = viewModel.currency
        let inForce = viewModel.rentInForce(tenancy)
        // The deposit check is for the tenancies running on its day: shown on the current one.
        let deposit = viewModel.currentTenancy?.id == id ? viewModel.snapshot.checks?.deposit : nil
        return Panel(tenancy.referenceLabel, subtitle: tenancy.contractNumber.map { "Contract \($0)" }) {
            HStack(spacing: 10) {
                Button { editing = TenancyDraft(tenancy, rents: rents, propertyId: tenancy.propertyId) } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit the tenancy: terms and rent history")
                .accessibilityLabel("Edit \(tenancy.referenceLabel)")
                Menu {
                    Button("Edit…") { editing = TenancyDraft(tenancy, rents: rents, propertyId: tenancy.propertyId) }
                    ImportShortcutButton("Add contract…", shortcut: .tenancyContract(tenancyId: id), importer: documentImport)
                    if contracts > 0 {
                        Button("Contract documents…") {
                            documentsOf = DocumentsTarget(entity: .tenancy(id), title: "\(tenancy.referenceLabel): documents")
                        }
                    }
                    Divider()
                    Button("Delete tenancy…", role: .destructive) { deleting = tenancy }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions for \(tenancy.referenceLabel)")
            }
            .buttonStyle(.borderless)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                FigureStrip([
                    FigureTile(title: "Tenant", value: .text(tenancy.tenantName ?? "—"),
                               caption: tenancy.tenantEmail.flatMap { $0.isEmpty ? nil : $0 }),
                    FigureTile(title: "From", value: .text(DocumentFormat.day(tenancy.startDate)),
                               caption: tenancy.endDate.map { "Until \(DocumentFormat.day($0))" } ?? "Ongoing"),
                    inForce.map {
                        FigureTile(title: "Rent", value: .money($0.monthlyAmountMinorUnits, currency, .neutral),
                                   caption: "A month, since \(DocumentFormat.day($0.fromDate))")
                    } ?? FigureTile(title: "Rent", value: .text("—"), caption: "No rent history"),
                    FigureTile(title: "Deposit", value: .text(PropertyFormat.months(tenancy.depositMonths)),
                               caption: "+ \(PropertyFormat.months(tenancy.advanceRentMonths)) advance rent",
                               pill: deposit.map { PropertyCheckSummary.depositPill($0, currency: currency) })
                ])
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rent history").font(.subheadline.bold())
                        if rents.isEmpty {
                            Text("No rent history yet: add it with Edit.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            DataTable(columns: [
                                .date("From") { $0.fromDate },
                                .money("Monthly rent", role: .neutral, currency: { _ in currency }) { $0.monthlyAmountMinorUnits },
                                .status("") { $0.id == inForce?.id ? StatusPill("In force", tone: .accent) : nil }
                            ], rows: rents, zebra: false)
                        }
                    }
                    // Narrower (down to its table's width) while a side panel is open beside the page.
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 340, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Contract").font(.subheadline.bold())
                        PropertyFacts {
                            PropertyFact("Number") { Text(tenancy.contractNumber ?? "—") }
                            PropertyFact("Document") {
                                HStack(spacing: 8) {
                                    if contracts == 0 {
                                        StatusPill("None yet", tone: .warning, systemImage: "circle.dashed")
                                        ImportShortcutButton("Add contract…", shortcut: .tenancyContract(tenancyId: id))
                                            .controlSize(.small)
                                    } else {
                                        Button {
                                            documentsOf = DocumentsTarget(entity: .tenancy(id), title: "\(tenancy.referenceLabel): documents")
                                        } label: {
                                            Label(contracts == 1 ? "1 document" : "\(contracts) documents", systemImage: "paperclip")
                                        }
                                        .buttonStyle(.link)
                                        .help("The contract's documents: open or unlink")
                                    }
                                }
                            }
                            if let notes = tenancy.notes, !notes.isEmpty {
                                PropertyFact("Notes") { Text(notes).lineLimit(2).help(notes) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Receipts

    /// What the receipts' panel shows besides the open receipt (and, without the rows, what the
    /// table's cells show besides their rows).
    private struct ReceiptsKey: Equatable {
        let tenancyId: Int64?
        let rows: [TenancyReceiptRow]
        let currency: Currency
        let currentAccountName: String?
        let currentAccountLastDay: Date?
        let theme: Theme
    }

    /// What the receipts' cells show besides their row.
    private struct ReceiptsCellsKey: Equatable {
        let currency: Currency
        let currentAccountName: String?
        let currentAccountLastDay: Date?
        let theme: Theme
    }

    /// What the receipts' panel shows.
    private struct ReceiptsPanelKey: Equatable {
        let receipts: ReceiptsKey
        let openLineId: String?
    }

    private func receiptsKey(_ tenancy: Tenancy) -> ReceiptsKey {
        ReceiptsKey(tenancyId: tenancy.id, rows: viewModel.snapshot.receipts[tenancy.id!] ?? [], currency: viewModel.currency,
                    currentAccountName: viewModel.snapshot.currentAccountName,
                    currentAccountLastDay: viewModel.snapshot.currentAccountLastDay, theme: theme)
    }

    private func receiptsPanelKey(_ tenancy: Tenancy) -> ReceiptsPanelKey {
        ReceiptsPanelKey(receipts: receiptsKey(tenancy), openLineId: openReceiptLineId(tenancy))
    }

    /// A receipt (or a year's total) as a table row.
    private struct ReceiptLine: Identifiable, Equatable {
        let id: String
        /// Nil for a total.
        let row: TenancyReceiptRow?
        let rent: Int
        let withheld: Int
        let received: Int

        var isCancelled: Bool { row?.receipt.status == .cancelled }
    }

    private func receiptSections(_ rows: [TenancyReceiptRow]) -> [DataTableSection<ReceiptLine>] {
        let byYear = Dictionary(grouping: rows) { MonthRange.components(of: $0.receipt.periodStart).year }
        return byYear.keys.sorted(by: >).map { year in
            let receipts = byYear[year]!.sorted { $0.receipt.periodStart > $1.receipt.periodStart }
            let lines = receipts.map { row in
                ReceiptLine(id: "\(row.id)", row: row, rent: row.receipt.amountMinorUnits, withheld: row.receipt.withholdingMinorUnits,
                            received: row.receipt.amountReceivedMinorUnits)
            }
            // Issued receipts only: a cancelled one charged nothing.
            let issued = lines.filter { !$0.isCancelled }
            let total = ReceiptLine(id: "total-\(year)", row: nil, rent: issued.reduce(0) { $0 + $1.rent },
                                    withheld: issued.reduce(0) { $0 + $1.withheld }, received: issued.reduce(0) { $0 + $1.received })
            return DataTableSection(String(year), rows: lines, total: total)
        }
    }

    private func receiptsPanel(_ tenancy: Tenancy) -> some View {
        let rows = viewModel.snapshot.receipts[tenancy.id!] ?? []
        let paid = rows.filter(\.isPaid).count, issued = rows.filter { $0.receipt.status == .issued }.count
        return Panel("Receipts", subtitle: rows.isEmpty ? nil
                     : "\(rows.count) receipt\(rows.count == 1 ? "" : "s") · \(paid) of \(issued) issued paid by their credits") {
            if issued > 0 {
                if paid == issued {
                    StatusPill("All paid", tone: .positive, systemImage: "checkmark",
                               help: "Every issued receipt is paid: the rent credits linked to it cover what it says was received.")
                } else {
                    StatusPill("\(issued - paid) not matched", tone: .warning,
                               help: "\(issued - paid) issued receipt\(issued - paid == 1 ? " isn't" : "s aren't") fully paid by linked rent credits yet. "
                                   + ReceiptStatusHelp.whyNotMatched(viewModel.snapshot))
                }
            }
        } content: {
            if rows.isEmpty {
                Text("No receipts yet: import the portal's export with Import receipts….").font(.callout).foregroundStyle(.secondary)
            } else {
                DataTable(columns: receiptColumns(withholding: rows.contains { $0.receipt.withholdingMinorUnits != 0 }),
                          sections: receiptSections(rows),
                          onSelect: { line in
                              if let id = line.row?.receipt.id { viewModel.toggleSidePanel(.receipt(id: id, tenancyId: tenancy.id!)) }
                          },
                          selectedId: openReceiptLineId(tenancy))
                // Choosing another receipt redraws the rows' backgrounds, not their cells.
                .cellsRebuilt(when: ReceiptsCellsKey(currency: viewModel.currency, currentAccountName: viewModel.snapshot.currentAccountName,
                                                     currentAccountLastDay: viewModel.snapshot.currentAccountLastDay, theme: theme))
            }
        }
    }

    private func receiptColumns(withholding: Bool) -> [DataTableColumn<ReceiptLine>] {
        var columns: [DataTableColumn<ReceiptLine>] = [
            DataTableColumn("No.", accessibilityValue: { $0.row?.receipt.receiptNumber }) { line, kind in
                Text(kind == .total ? "Total" : line.row?.receipt.receiptNumber ?? "")
                    .monospacedDigit()
                    .fontWeight(kind == .total ? .semibold : .regular)
                    .foregroundStyle(line.isCancelled ? Color.secondary : Color.primary)
                    .figureText()
            },
            PropertyReceiptColumns.period(compactAt: 3) { $0.row.map { ($0.receipt.periodStart, $0.receipt.periodEnd) } },
            // Hidden first when the table is narrow (the receipt's panel shows it).
            DataTableColumn<ReceiptLine>.date("Received on") { $0.row?.receipt.receiptDate }.hidesWhenNarrow(1),
            amountColumn("Rent") { $0.rent }
        ]
        if withholding {
            columns.append(amountColumn("Withheld") { $0.withheld })
            columns.append(amountColumn("Received") { $0.received })
        }
        columns += [
            .status("Status") { line in line.row.map(status) }
                .headerHelp("Paid: linked credits cover the receipt. Part paid: they cover part of it. Not matched: no credit linked yet. Cancelled: charged nothing. Hover a status for its details."),
            DataTableColumn("Paid by", width: .fill(min: 170), accessibilityValue: paidByDescription) { line, _ in
                if let row = line.row { paidBy(row) }
            }
            // Narrow: the credits' amounts only (their days and the part that isn't rent on hover).
            .compactsWhenNarrow(2) { line, _ in
                if let row = line.row { paidBy(row, compact: true) }
            },
            // The PDF: its paperclip (previews it; a menu when there are several), or a dashed
            // to-do circle that adds it (none for a cancelled receipt). No accessibility value:
            // the button stays reachable.
            DataTableColumn("PDF", alignment: .center, width: .fixed(40)) { line, kind in
                if kind == .row, let row = line.row {
                    if row.documentCount > 0 {
                        ReceiptPDFButton(receiptNumber: row.receipt.receiptNumber, count: row.documentCount,
                                         documents: { receiptDocuments(row) }, preview: preview,
                                         openInPreview: viewModel.openInPreview, show: { $0.id.map(showDocument) })
                    } else if row.receipt.status != .cancelled {
                        Button { pickReceiptPDF(row.receipt.id!) } label: {
                            Image(systemName: "circle.dashed").foregroundStyle(theme.pending)
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        .help(ReceiptStatusHelp.noPDF)
                        .accessibilityLabel("No receipt PDF yet for receipt \(row.receipt.receiptNumber): add it")
                        .accessibilityHint("Download it from Portal das Finanças, then choose the file")
                    }
                }
            }
            .headerHelp("The receipt's PDF: a paperclip when it's in the library — click it to preview the PDF (right-click for Open in Preview and Show in Documents); a dashed circle when it's missing — click it to add the PDF (download it from Portal das Finanças)."),
            .actions { line in line.row.map(actions) ?? [] }
        ]
        return columns
    }

    /// A receipt's amount (as on the receipt: neutral), muted when it's cancelled.
    private func amountColumn(_ title: String, _ value: @escaping (ReceiptLine) -> Int) -> DataTableColumn<ReceiptLine> {
        let currency = viewModel.currency
        return DataTableColumn(title, alignment: .trailing, width: .min(96),
                               accessibilityValue: { Money.format(value($0), currency: currency) }) { line, kind in
            MoneyText(minorUnits: value(line), currency: currency,
                      font: kind == .total ? .body.monospacedDigit().weight(.semibold) : .body.monospacedDigit(),
                      role: .neutral, tint: line.isCancelled ? .secondary : nil)
        }
    }

    private func status(_ row: TenancyReceiptRow) -> StatusPill {
        ReceiptStatusHelp.pill(row, currency: viewModel.currency, snapshot: viewModel.snapshot)
    }

    /// The credits that paid it: the day and the credit, the part that isn't rent beneath.
    @ViewBuilder
    private func paidBy(_ row: TenancyReceiptRow, compact: Bool = false) -> some View {
        if row.payments.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else if compact {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(row.payments, id: \.payment.id) { info in
                    MoneyText(minorUnits: info.transaction.amountMinorUnits, currency: viewModel.currency)
                }
            }
            .help(paidByDescription(ReceiptLine(id: "", row: row, rent: 0, withheld: 0, received: 0)) ?? "")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(row.payments, id: \.payment.id) { info in
                    HStack(spacing: 8) {
                        DateText(date: info.transaction.date)
                        MoneyText(minorUnits: info.transaction.amountMinorUnits, currency: viewModel.currency)
                    }
                    if info.payment.otherMinorUnits > 0 {
                        Text("incl. \(Money.format(info.payment.otherMinorUnits, currency: viewModel.currency)) other")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .figureText()
                            .help("The part of the credit that isn't rent (utility recharges and the like)")
                    }
                }
            }
        }
    }

    private func paidByDescription(_ line: ReceiptLine) -> String? {
        guard let row = line.row, !row.payments.isEmpty else { return nil }
        return row.payments.map { info in
            var text = "\(DocumentFormat.day(info.transaction.date)) \(Money.format(info.transaction.amountMinorUnits, currency: viewModel.currency))"
            if info.payment.otherMinorUnits > 0 {
                text += " including \(Money.format(info.payment.otherMinorUnits, currency: viewModel.currency)) other"
            }
            return text
        }.joined(separator: "; ")
    }

    /// The receipt whose panel is open (its table line's id).
    private func openReceiptLineId(_ tenancy: Tenancy) -> String? {
        if case let .receipt(id, tenancyId) = viewModel.sidePanel, tenancyId == tenancy.id { return "\(id)" }
        return nil
    }

    /// One ••• menu per receipt: its details, its PDF (view, open in Preview, show in
    /// Documents, replace or add another, documents), its credits (show, unlink).
    private func actions(_ row: TenancyReceiptRow) -> [DataTableAction] {
        let receipt = row.receipt
        var actions: [DataTableAction] = [
            DataTableAction("Receipt details", systemImage: "sidebar.right") {
                viewModel.sidePanel = .receipt(id: receipt.id!, tenancyId: receipt.tenancyId)
            }
        ]
        if row.documentCount > 0 {
            actions.append(DataTableAction(row.documentCount == 1 ? "View receipt PDF" : "View the first receipt PDF", systemImage: "eye") {
                if let document = receiptDocuments(row).first { preview(document) }
            })
            actions.append(DataTableAction("Open in Preview", systemImage: "arrow.up.forward.square") {
                if let document = receiptDocuments(row).first { viewModel.openInPreview(document) }
            })
            actions.append(DataTableAction("Show in Documents", systemImage: "doc.text.magnifyingglass") {
                if let id = receiptDocuments(row).first?.id { showDocument(id) }
            })
        }
        let single = row.payments.count == 1
        for info in row.payments {
            let day = DocumentFormat.day(info.transaction.date)
            actions.append(DataTableAction(single ? "Show the credit" : "Show the credit of \(day)", systemImage: "arrow.right.circle") {
                openTransaction(info.transaction)
            })
            actions.append(DataTableAction(single ? "Unlink the credit" : "Unlink the credit of \(day)", systemImage: "xmark.circle") {
                viewModel.unlinkPayment(info.payment)
            })
        }
        if row.documentCount == 1 {
            actions.append(DataTableAction("Replace PDF…", systemImage: "arrow.triangle.2.circlepath") {
                pickReceiptPDF(receipt.id!, replacing: receiptDocuments(row).compactMap(\.id))
            })
        }
        actions.append(DataTableAction(row.documentCount == 0 ? "Add the receipt PDF…" : "Add another PDF…", systemImage: "paperclip") {
            pickReceiptPDF(receipt.id!)
        })
        if row.documentCount > 0 {
            actions.append(DataTableAction("Documents…", systemImage: "doc.on.doc") {
                documentsOf = DocumentsTarget(entity: .rentReceipt(receipt.id!), title: "Receipt \(receipt.receiptNumber): documents")
            })
        }
        return actions
    }
}

/// A rent period as two aligned days, "1 Aug 2025 – 31 Aug 2025" (`DateText`); in a narrow
/// table, from give-way step `compactAt` (nil: never), "1–31 Aug 2025" when it is within one month.
enum PropertyReceiptColumns {
    static func period<Row>(_ title: String = "Rent period", compactAt step: Int? = nil,
                            _ value: @escaping (Row) -> (Date, Date)?) -> DataTableColumn<Row> {
        let column = DataTableColumn<Row>(title, accessibilityValue: { row in
            value(row).map { "\(DocumentFormat.day($0.0)) to \(DocumentFormat.day($0.1))" }
        }) { row, _ in
            if let period = value(row) {
                HStack(spacing: 4) {
                    DateText(date: period.0, alignment: .trailing)
                    Text("–").foregroundStyle(.secondary)
                    DateText(date: period.1)
                }
            }
        }
        guard let step else { return column }
        return column.compactsWhenNarrow(step) { row, _ in
            if let period = value(row) {
                Text(compact(period.0, period.1)).monospacedDigit().figureText()
            }
        }
    }

    /// "1–31 Aug 2025" within one month; both days otherwise.
    static func compact(_ start: Date, _ end: Date) -> String {
        let calendar = MonthRange.calendar
        let a = calendar.dateComponents([.year, .month, .day], from: start), b = calendar.dateComponents([.year, .month], from: end)
        guard a.year == b.year, a.month == b.month, let day = a.day else {
            return "\(DocumentFormat.day(start)) – \(DocumentFormat.day(end))"
        }
        return "\(day)–\(DocumentFormat.day(end))"
    }
}

/// The documents linked to a property record as a table (name over kind, day, amount), with
/// open and unlink as icons.
struct PropertyDocumentsSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    let entity: EvidenceEntity
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.documentKinds) private var kinds
    @State private var documents: [EvidenceDocument] = []

    var body: some View {
        SheetScaffold(title: title, subtitle: documents.isEmpty ? nil : "\(documents.count) document\(documents.count == 1 ? "" : "s")",
                      width: SheetMetrics.listWidth, cancelTitle: "Done", onCancel: { dismiss() }) {
            if documents.isEmpty {
                SheetEmptyState(systemImage: "doc", title: "No documents",
                                message: "Nothing is linked to this record yet. Unlinked documents stay in the library.", minHeight: 130)
            } else {
                ScrollView {
                    DataTable(columns: columns, rows: documents)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .sheetListFrame()
            }
        }
        .onAppear { documents = viewModel.documents(for: entity) }
    }

    private var columns: [DataTableColumn<EvidenceDocument>] {
        [
            DataTableColumn("Document", width: .fill(min: 200),
                            accessibilityValue: { [$0.displayName, kinds.displayName(of: $0)].joined(separator: ", ") }) { document, _ in
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(document.displayName).lineLimit(1).help(document.displayName)
                        Text(kinds.displayName(of: document)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            },
            .date("Date") { $0.docDate },
            .money("Amount", role: .neutral, currency: { $0.currency ?? .eur }) { $0.currency == nil ? nil : $0.amountMinorUnits },
            .actions { document in
                [DataTableAction("Open \(document.displayName) in its default app", systemImage: "arrow.up.forward.square", inline: true) {
                    viewModel.open(document)
                 },
                 DataTableAction("Unlink \(document.displayName): it stays in the library", systemImage: "xmark.circle", inline: true) {
                    viewModel.unlinkDocument(document, from: entity)
                    documents = viewModel.documents(for: entity)
                 }]
            }
        ]
    }
}

/// What the receipts' status pills and PDF marks explain on hover.
enum ReceiptStatusHelp {
    static let noPDF = "No receipt PDF yet — click to add it (download it from Portal das Finanças)."

    /// A receipt's status pill, its hover explaining it (the table's Status column, the receipt panel).
    static func pill(_ row: TenancyReceiptRow, currency: Currency, snapshot: PropertyViewModel.Snapshot) -> StatusPill {
        if row.receipt.status == .cancelled {
            return StatusPill("Cancelled", help: "Cancelled on Portal das Finanças: it charged nothing, so no credit is expected and it isn't counted in the rent.")
        }
        let received = Money.format(row.receipt.amountReceivedMinorUnits, currency: currency).unbroken
        let linked = Money.format(row.paidMinorUnits, currency: currency).unbroken
        let credits = row.payments.map { DocumentFormat.day($0.transaction.date).unbroken }.joined(separator: ", ")
        if row.isPaid {
            return StatusPill("Paid", tone: .positive, systemImage: "checkmark",
                              help: "Paid: the credit\(row.payments.count == 1 ? "" : "s") of \(credits) linked to it cover\(row.payments.count == 1 ? "s" : "") the \(received) it says was received.")
        }
        if row.payments.isEmpty {
            return StatusPill("Not matched", tone: .warning,
                              help: "No rent credit on the current account has been linked to this receipt yet. " + whyNotMatched(snapshot))
        }
        let left = Money.format(row.receipt.amountReceivedMinorUnits - row.paidMinorUnits, currency: currency).unbroken
        return StatusPill("Part paid", tone: .warning,
                          help: "Part paid: the credit\(row.payments.count == 1 ? "" : "s") of \(credits) linked to it cover\(row.payments.count == 1 ? "s" : "") \(linked) of the \(received) received; \(left) is still to link. Another credit may pay the rest once it's imported: use Match credits.")
    }

    /// Why a receipt may have no credit yet, with how far the current account's imports run.
    static func whyNotMatched(_ snapshot: PropertyViewModel.Snapshot) -> String {
        let imports: String
        if let day = snapshot.currentAccountLastDay {
            let name = snapshot.currentAccountName ?? "the current account"
            imports = " (\(name)'s transactions run to \(DocumentFormat.day(day).unbroken))"
        } else {
            imports = ""
        }
        return "Usually the tenant's transfer isn't imported yet\(imports), or it arrived under a different amount or name, "
            + "so it wasn't matched: import the statement, then use Match credits (in More). Checks lists the credits without a receipt."
    }
}
