// App/Property/PropertyBillsTab.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction
import GRDB

/// The utility bills data (Recharges tab, first section): one tenancy's `UtilityBills` grid, read off the main
/// thread. Held by `PropertyViewModel`, so the tab and its side panel read the same grid.
@MainActor
final class BillsModel: ObservableObject {
    @Published private(set) var grid = UtilityBillsGrid(bills: [], rows: [])
    /// The month "Add to a recharge…" prepares (`RechargeEmail.nextMonth`).
    @Published private(set) var nextMonth = AppClock.now
    @Published private(set) var isLoaded = false
    @Published var errorMessage: String?
    private var token = 0

    func load(dbQueue: DatabaseQueue, propertyId: Int64, tenancyId: Int64) {
        token += 1
        let mine = token
        let today = PropertyDays.utcToday(AppClock.now)
        Task { [weak self] in
            do {
                let (grid, next) = try await dbQueue.read { db in
                    (try UtilityBills.read(db: db, propertyId: propertyId, tenancyId: tenancyId),
                     try Recharges.nextMonth(db: db, tenancyId: tenancyId, today: today))
                }
                guard let self, mine == self.token else { return }
                self.grid = grid
                self.nextMonth = next
                self.isLoaded = true
                self.errorMessage = nil
            } catch {
                guard let self, mine == self.token else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func clear() {
        token += 1
        grid = UtilityBillsGrid(bills: [], rows: [])
        isLoaded = false
    }
}

extension UtilityBillStage {
    var icon: String {
        switch self {
        case .missingInvoice: return "exclamationmark"
        case .invoiceIn: return "doc.text"
        case .linkedToPayment: return "link"
        case .inRecharge: return "list.bullet.rectangle"
        case .sentToTenant: return "paperplane"
        case .paidByTenant: return "checkmark"
        }
    }

    var tone: StatusPill.Tone {
        switch self {
        case .missingInvoice: return .warning
        case .invoiceIn, .linkedToPayment: return .neutral
        case .inRecharge, .sentToTenant: return .accent
        case .paidByTenant: return .positive
        }
    }

    /// What the stage means and what comes next, for the legend's tooltip and the panel.
    var explanation: String {
        switch self {
        case .missingInvoice: return "A utility payment with no invoice recorded for it"
        case .invoiceIn: return "The invoice is recorded; no payment is linked to it yet"
        case .linkedToPayment: return "Invoice and payment linked: next, add it to a recharge statement"
        case .inRecharge: return "On the tenant's draft statement: prepared, ready to send"
        case .sentToTenant: return "On a statement emailed to the tenant, who hasn't paid it all"
        case .paidByTenant: return "The statement is covered by the tenant's payments"
        }
    }
}

/// A stage as a small icon capsule (the grid's cell) or with its name (the legend, the panel).
struct BillStagePill: View {
    let stage: UtilityBillStage
    var partial = false
    var showsName = false
    @Environment(\.theme) private var theme

    private var color: Color {
        switch stage.tone {
        case .neutral: return theme.neutralMoney
        case .accent: return theme.accent
        case .positive: return theme.income
        case .warning: return theme.pending
        case .negative: return theme.expense
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: partial ? "paperplane.fill" : stage.icon).imageScale(.small).accessibilityHidden(true)
            if showsName { Text(partial ? "Part paid" : stage.displayName).lineLimit(1) }
        }
        .font(.caption.weight(.medium))
        .fixedSize()
        .padding(.horizontal, showsName ? 6 : 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(stage.tone == .neutral ? Color.secondary : color)
        .help(partial ? "Sent; the tenant has paid part of it" : stage.explanation)
    }
}

/// The tenancy's utility bills as a provider × month grid, each cell the stage of its bill(s) on
/// the way from the landlord's payment to the tenant's: the first section of the Recharges tab.
/// Clicking a cell opens the bill beside the page (`UtilityBillPanel`). Nothing is edited here.
struct BillsSection: View {
    @ObservedObject var viewModel: PropertyViewModel
    @ObservedObject var bills: BillsModel
    let tenancy: Tenancy
    let propertyId: Int64
    @State private var chosenYear: Int?
    @Environment(\.theme) private var theme

    private var grid: UtilityBillsGrid { bills.grid }
    private var year: Int {
        chosenYear ?? (grid.years.contains(MonthRange.components(of: AppClock.now).year)
                       ? MonthRange.components(of: AppClock.now).year : grid.years.first ?? MonthRange.components(of: AppClock.now).year)
    }

    private var openCell: (String, Date)? {
        if case let .utilityBill(key, month, _) = viewModel.sidePanel { return (key, month) }
        return nil
    }

    private static let monthName = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated)

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if let message = bills.errorMessage { InlineBanner(.error, message) { bills.errorMessage = nil } }
            Panel("Utility bills", subtitle: grid.summaryText) {
                if grid.years.count > 1 {
                    Picker("Year", selection: Binding(get: { year }, set: { chosenYear = $0 })) {
                        ForEach(grid.years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Year")
                }
            } content: {
                if !bills.isLoaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                } else if grid.rows.isEmpty {
                    EmptyState(systemImage: "bolt.horizontal", title: "No utility bills in this tenancy",
                               message: "Utility payments and invoices show here once they are recorded.") {
                        ImportShortcutButton("Utility invoices…", shortcut: .utilityInvoices(propertyId: propertyId))
                    }
                    .inPanel()
                } else {
                    gridView
                    legend
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: viewModel.rechargesRevision) { _, _ in reload() }
        .onChange(of: viewModel.snapshot) { _, _ in reload() }
    }

    private func reload() {
        bills.load(dbQueue: viewModel.dbQueue, propertyId: propertyId, tenancyId: tenancy.id!)
    }

    private var months: [Date] { (1...12).map { MonthRange.of(year: year, month: $0).start } }

    private var gridView: some View {
        Grid(alignment: .center, horizontalSpacing: 4, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: 1, height: 1).gridColumnAlignment(.leading)
                ForEach(months, id: \.self) { month in
                    Text(month.formatted(Self.monthName)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .figureText()
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(grid.rows) { row in
                GridRow {
                    HStack(spacing: 4) {
                        UtilityKindIcon(kind: row.kind)
                        Text(row.name).lineLimit(1).truncationMode(.tail).help(row.name)
                    }
                    .frame(width: 130, alignment: .leading)
                    ForEach(months, id: \.self) { month in
                        cellView(row: row, month: month)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(row: UtilityBillRow, month: Date) -> some View {
        if let cell = grid.cell(row: row, month: month) {
            let selected = openCell.map { $0.0 == row.id && $0.1 == month } ?? false
            let partial = cell.bills.count == 1 && cell.bills[0].isPartiallyPaid
            Button {
                viewModel.sidePanel = selected ? nil : .utilityBill(providerKey: row.id, month: month, tenancyId: tenancy.id!)
            } label: {
                BillStagePill(stage: cell.stage, partial: partial)
                    .overlay(alignment: .topTrailing) {
                        if cell.bills.count > 1 {
                            Text("\(cell.bills.count)").font(.system(size: 9, weight: .bold)).padding(2)
                                .background(Circle().fill(theme.windowFill)).offset(x: 5, y: -5)
                        }
                    }
                    .padding(2)
                    .overlay(Capsule().strokeBorder(selected ? theme.accent : .clear, lineWidth: 1.5))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.name), \(month.formatted(Self.monthName)) \(year): \(partial ? "Part paid" : cell.stage.displayName)")
        } else {
            Text("·").foregroundStyle(.quaternary).frame(maxWidth: .infinity).accessibilityHidden(true)
        }
    }

    private var legend: some View {
        ChipFlow(spacing: 8) {
            ForEach(UtilityBillStage.allCases, id: \.self) { stage in
                HStack(spacing: 4) {
                    BillStagePill(stage: stage)
                    Text(stage.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .fixedSize()
            }
        }
        .padding(.top, 4)
    }
}

/// One bill beside the Recharges tab: its stage and figures, the invoice (page 1, Quick Look), the
/// payment that settled it, and the actions the Recharges tab already has: add the invoice, add
/// to a recharge, open the statement (mark sent, there), or go to Recharges for the tenant's payment.
struct UtilityBillPanel: View {
    @ObservedObject var viewModel: PropertyViewModel
    @ObservedObject var bills: BillsModel
    let providerKey: String
    let month: Date
    let tenancyId: Int64
    let openTransaction: (Transaction) -> Void
    let showDocument: (Int64) -> Void
    @State private var editing: Transaction?
    @State private var opened: RechargeStatementTarget?
    @State private var documents: [Int64: EvidenceDocument] = [:]

    private static let title = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()

    private var cell: UtilityBillCell? {
        let row = bills.grid.rows.first { $0.id == providerKey }
        return row.flatMap { bills.grid.cell(row: $0, month: month) }
    }

    var body: some View {
        let currency = viewModel.currency
        PropertySidePanel(title: cell?.bills.first?.providerName ?? "Bill", subtitle: month.formatted(Self.title), titleIsName: true,
                          onClose: { viewModel.sidePanel = nil }) {
            if let cell {
                List {
                    ForEach(cell.bills) { bill in
                        Section {
                            // One row: its parts stay together and keep their width.
                            VStack(alignment: .leading, spacing: 8) { billContent(bill, currency: currency) }
                                .padding(.vertical, 4)
                        } header: {
                            PropertyPanelSectionHeader(title: bill.invoice.map { $0.invoiceNumber.map { "No. \($0)" } ?? "Invoice" } ?? "Payment, no invoice",
                                                       minorUnits: bill.amountMinorUnits, currency: currency, role: .neutral)
                        }
                    }
                }
                .wrapProbeClips()
            } else {
                Text("This bill is no longer here.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .task(id: cell?.bills.compactMap { $0.invoice?.documentId }) { await loadDocuments() }
        .sheet(item: $editing) { PropertyEditTransactionSheet(transaction: $0, dbQueue: viewModel.dbQueue) }
        .sheet(item: $opened, onDismiss: { viewModel.rechargesRevision += 1 }) { target in
            if let tenancy = viewModel.snapshot.tenancies.first(where: { $0.id == tenancyId }), let propertyId = viewModel.propertyId {
                RechargeStatementSheet(model: RechargeStatementModel(dbQueue: viewModel.dbQueue, library: viewModel.library, propertyId: propertyId,
                                                                     tenancy: tenancy, currency: currency, target: target))
            }
        }
    }

    private func loadDocuments() async {
        let ids = cell?.bills.compactMap { $0.invoice?.documentId } ?? []
        guard !ids.isEmpty else { documents = [:]; return }
        let found = (try? await viewModel.library.database.read { db in try EvidenceDocument.fetchAll(db, keys: ids) }) ?? []
        documents = Dictionary(uniqueKeysWithValues: found.compactMap { document in document.id.map { ($0, document) } })
    }

    @ViewBuilder
    private func billContent(_ bill: UtilityBill, currency: Currency) -> some View {
        HStack(spacing: 6) {
            BillStagePill(stage: bill.stage, partial: bill.isPartiallyPaid, showsName: true)
            if let sent = bill.statement?.sentAt, bill.stage >= .sentToTenant {
                HStack(spacing: 3) {
                    Text("Sent").foregroundStyle(.secondary)
                    DateText(date: sent, font: .caption).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        Text(bill.stage.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let statement = bill.statement {
            VStack(alignment: .leading, spacing: 4) {
                PropertyPanelFigure(title: "Statement total", minorUnits: bill.statementTotalMinorUnits, currency: currency, role: .neutral)
                if statement.status != .draft {
                    PropertyPanelFigure(title: "Paid by the tenant", minorUnits: bill.tenantPaidMinorUnits, currency: currency, role: .neutral)
                }
            }
        }
        invoiceSection(bill, currency: currency)
        if bill.payments.isEmpty, bill.invoice != nil {
            Text("No payment linked yet").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(bill.payments, id: \.id) { debit in
            PropertyPanelTransactionRow(transaction: debit, minorUnits: debit.amountMinorUnits,
                                        currency: viewModel.account(debit.accountId)?.currency ?? currency,
                                        detail: "Payment", onEdit: { editing = $0 }, onShow: openTransaction)
        }
        actions(bill)
    }

    @ViewBuilder
    private func invoiceSection(_ bill: UtilityBill, currency: Currency) -> some View {
        if let invoice = bill.invoice {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Issued").foregroundStyle(.secondary)
                    DateText(date: invoice.issueDate, font: .caption)
                }
                .font(.caption)
                if let start = invoice.periodStart, let end = invoice.periodEnd {
                    HStack(spacing: 4) {
                        Text("For").foregroundStyle(.secondary)
                        DateText(date: start, font: .caption)
                        Text("–")
                        DateText(date: end, font: .caption)
                    }
                    .font(.caption)
                }
                if invoice.amountMinorUnits != bill.amountMinorUnits {
                    Text("The tenancy's share of \(Money.format(invoice.amountMinorUnits, currency: currency).unbroken)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let documentId = invoice.documentId {
                    if let document = documents[documentId] {
                        DocumentThumbnail(url: viewModel.fileURL(for: document), height: 150)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("The invoice: Quick Look")
                        Text(document.displayName).font(.caption).lineLimit(1).truncationMode(.middle).help(document.displayName)
                        HStack(spacing: 8) {
                            Button("Open in Preview") { viewModel.openInPreview(document) }
                            Button("Show in Documents") { showDocument(documentId) }
                        }
                        .controlSize(.small).fixedSize()
                    } else {
                        ProgressView().frame(maxWidth: .infinity).frame(height: 60)
                    }
                } else {
                    Text("Recorded without a document").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No invoice recorded for this payment").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The next step, with the buttons the Recharges tab and the statement sheet already have.
    @ViewBuilder
    private func actions(_ bill: UtilityBill) -> some View {
        HStack(spacing: 8) {
            switch bill.stage {
            case .missingInvoice:
                if let propertyId = viewModel.propertyId {
                    ImportShortcutButton("Add the invoice…", shortcut: .utilityInvoices(propertyId: propertyId))
                        .help("Choose the invoice: it is read and matched to its debit")
                }
            case .invoiceIn:
                if let propertyId = viewModel.propertyId {
                    ImportShortcutButton("Match to a payment…", shortcut: .utilityInvoices(propertyId: propertyId))
                        .help("Add the invoices again to match them to their debits")
                }
            case .linkedToPayment:
                Button("Add to a recharge…") { opened = RechargeStatementTarget(month: bills.nextMonth, statementId: nil) }
                    .buttonStyle(.borderedProminent).prominentTint()
                    .help("The statement sheet: tick this bill and the others waiting")
            case .inRecharge:
                Button("Open statement… to send") { opened = RechargeStatementTarget(month: bill.statement?.month ?? bills.nextMonth, statementId: bill.statement?.id) }
                    .buttonStyle(.borderedProminent).prominentTint()
                    .help("The statement sheet: its lines, the email to the tenant and Mark sent")
            case .sentToTenant:
                Button("Record tenant payment ›") {
                    if let id = bill.statement?.id { viewModel.sidePanel = nil; viewModel.tab = .recharges; viewModel.sidePanel = .rechargeStatement(id: id, tenancyId: tenancyId) }
                }
                .help("The Recharges tab: Match payments, or accept the suggested credit")
                Button("Open statement…") { opened = RechargeStatementTarget(month: bill.statement?.month ?? bills.nextMonth, statementId: bill.statement?.id) }
            case .paidByTenant:
                Button("Open statement…") { opened = RechargeStatementTarget(month: bill.statement?.month ?? bills.nextMonth, statementId: bill.statement?.id) }
            }
        }
        .controlSize(.small)
        .fixedSize()
    }
}
