// App/Property/RechargePanels.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// A recharge statement beside the Recharges tab (clicking its row): its status and figures
/// (charges = the statement's total, paid = the credits' recharge parts, outstanding), its
/// charges — each invoice's provider, number, issue day and period, the debit that paid it,
/// its document — then the tenant credits that paid it with their rent / recharge split.
/// Open statement… opens the statement sheet to edit or send it.
struct RechargeStatementPanel: View {
    @ObservedObject var viewModel: PropertyViewModel
    let statementId: Int64
    let tenancyId: Int64
    let openTransaction: (Transaction) -> Void
    @State private var editing: Transaction?
    @State private var opened: RechargeStatementTarget?

    var body: some View {
        let currency = viewModel.currency
        if let detail = viewModel.rechargeStatementDetail(statementId) {
            let statement = detail.statement
            let month = RechargeEmail.monthName(statement.month, language: .english)
            PropertySidePanel(title: "Statement · \(month)", subtitle: "What the tenant was charged and what paid it",
                              onClose: { viewModel.sidePanel = nil }) {
                HStack(spacing: 8) {
                    RechargeFormat.statusPill(statement, receivedMinorUnits: detail.paid, today: PropertyDays.utcToday(AppClock.now))
                    if statement.sentAt != nil {
                        HStack(spacing: 3) {
                            Text("Sent").foregroundStyle(.secondary)
                            DateText(date: statement.sentAt, font: .caption).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    Spacer(minLength: 4)
                    Button(statement.status == .draft ? "Edit statement…" : "Open statement…") {
                        opened = RechargeStatementTarget(month: statement.month, statementId: statement.id)
                    }
                    .controlSize(.small)
                    .help("The statement sheet: its lines, the email to the tenant")
                }
                VStack(alignment: .leading, spacing: 4) {
                    PropertyPanelFigure(title: "Charges", minorUnits: detail.chargesTotal, currency: currency, role: .neutral)
                    PropertyPanelFigure(title: "Paid", minorUnits: detail.paid, currency: currency)
                    PropertyPanelFigure(title: "Outstanding", minorUnits: detail.outstanding, currency: currency, role: .neutral, isTotal: true)
                }
                List {
                    Section {
                        if detail.charges.isEmpty { Text("No lines yet.").foregroundStyle(.secondary) }
                        ForEach(detail.charges) { charge in
                            RechargeChargeRow(viewModel: viewModel, charge: charge, currency: currency, onEdit: { editing = $0 },
                                              onShow: openTransaction)
                        }
                    } header: {
                        PropertyPanelSectionHeader(title: "Charges", minorUnits: detail.chargesTotal, currency: currency, role: .neutral)
                    }
                    Section {
                        if detail.credits.isEmpty {
                            Text(statement.status == .draft ? "Not sent yet." : "No credit linked yet: Match payments, or accept a suggestion.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(detail.credits) { credit in
                            RechargeCreditRow(credit: credit, currency: currency, onEdit: { editing = $0 }, onShow: openTransaction)
                        }
                    } header: {
                        PropertyPanelSectionHeader(title: "Paid by", minorUnits: detail.paid, currency: currency)
                    }
                }
                .wrapProbeClips()
            }
            .sheet(item: $editing) { PropertyEditTransactionSheet(transaction: $0, dbQueue: viewModel.dbQueue) }
            .sheet(item: $opened, onDismiss: { viewModel.rechargesRevision += 1 }) { target in
                if let tenancy = viewModel.snapshot.tenancies.first(where: { $0.id == tenancyId }), let propertyId = viewModel.propertyId {
                    RechargeStatementSheet(model: RechargeStatementModel(dbQueue: viewModel.dbQueue, library: viewModel.library, propertyId: propertyId,
                                                                         tenancy: tenancy, currency: currency, target: target))
                }
            }
        } else {
            PropertySidePanel(title: "Statement", onClose: { viewModel.sidePanel = nil }) {
                Text("The statement no longer exists.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

/// A month of the "Paid and recharged by month" chart beside the Recharges tab: the
/// statements for the month (the bar above the line), the tenancy's share of the invoices
/// paid in it with their debits (the bar below), and the recharges received on credits dated
/// in it with the statements they paid.
struct RechargeMonthPanel: View {
    @ObservedObject var viewModel: PropertyViewModel
    let month: Date
    let tenancyId: Int64
    let openTransaction: (Transaction) -> Void
    @State private var editing: Transaction?

    private static let title = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()

    var body: some View {
        let currency = viewModel.currency
        PropertySidePanel(title: month.formatted(Self.title), subtitle: "Recharges: the month's bars and what arrived",
                          onClose: { viewModel.sidePanel = nil }) {
            if let detail = viewModel.rechargeMonthDetail(month, tenancyId: tenancyId) {
                VStack(alignment: .leading, spacing: 4) {
                    PropertyPanelFigure(title: "Recharged", minorUnits: detail.recharged, currency: currency)
                    PropertyPanelFigure(title: "Utilities paid", minorUnits: detail.paid, currency: currency, role: .cost)
                    PropertyPanelFigure(title: "Difference", minorUnits: detail.recharged - detail.paid, currency: currency, isTotal: true)
                }
                List {
                    Section {
                        if detail.statements.isEmpty { Text("No statement sent for this month.").foregroundStyle(.secondary) }
                        ForEach(detail.statements, id: \.id) { statement in
                            statementRow(statement, currency: currency)
                        }
                    } header: {
                        PropertyPanelSectionHeader(title: "Statements for the month", minorUnits: detail.recharged, currency: currency)
                    }
                    Section {
                        if detail.charges.isEmpty { Text("No invoices paid this month.").foregroundStyle(.secondary) }
                        ForEach(detail.charges) { charge in
                            RechargeChargeRow(viewModel: viewModel, charge: charge, currency: currency, onEdit: { editing = $0 },
                                              onShow: openTransaction, showsStatement: true)
                        }
                    } header: {
                        PropertyPanelSectionHeader(title: "Invoices paid", minorUnits: detail.paid, currency: currency, role: .neutral)
                    }
                    Section {
                        if detail.credits.isEmpty { Text("No recharges received this month.").foregroundStyle(.secondary) }
                        ForEach(detail.credits) { credit in
                            RechargeCreditRow(credit: credit, currency: currency, onEdit: { editing = $0 }, onShow: openTransaction)
                        }
                    } header: {
                        PropertyPanelSectionHeader(title: "Recharges received", minorUnits: detail.received, currency: currency)
                    }
                }
                .wrapProbeClips()
            } else {
                Text("Couldn't read the month's recharges.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .sheet(item: $editing) { PropertyEditTransactionSheet(transaction: $0, dbQueue: viewModel.dbQueue) }
    }

    private func statementRow(_ statement: RechargeStatement, currency: Currency) -> some View {
        let month = RechargeEmail.monthName(statement.month, language: .english)
        return HStack(spacing: 6) {
            Text(month).lineLimit(1)
            Spacer(minLength: 6)
            MoneyText(minorUnits: statement.totalMinorUnits, currency: currency, role: .neutral).fixedSize()
            Button {
                if let id = statement.id { viewModel.sidePanel = .rechargeStatement(id: id, tenancyId: tenancyId) }
            } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("Show the \(month) statement")
                .accessibilityLabel("Show the \(month) statement")
        }
    }
}

/// A statement line in a recharges panel: the provider (or the one-off line's description)
/// and the amount charged; the invoice's number, issue day and period; its document; the
/// debit that paid it, with Edit transaction and Show where it lives.
struct RechargeChargeRow: View {
    @ObservedObject var viewModel: PropertyViewModel
    let charge: RechargeChargeLine
    let currency: Currency
    let onEdit: (Transaction) -> Void
    let onShow: (Transaction) -> Void
    /// Month panels: which statement the invoice is on (or that it waits for the next).
    var showsStatement = false

    private var title: String {
        charge.detail.provider?.name ?? charge.detail.line.lineDescription ?? "Line"
    }

    var body: some View {
        let invoice = charge.detail.invoice
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).lineLimit(1).help(title)
                Spacer(minLength: 8)
                MoneyText(minorUnits: charge.amountMinorUnits, currency: currency, role: .neutral).fixedSize()
            }
            if let invoice {
                HStack(spacing: 4) {
                    Text(invoice.invoiceNumber.map { "No. \($0)" } ?? "No number").lineLimit(1).layoutPriority(-1)
                    Text("· issued").fixedSize()
                    DateText(date: invoice.issueDate, font: .caption)
                    Spacer(minLength: 4)
                    if let documentId = charge.detail.documentId {
                        Button { viewModel.openDocument(id: documentId) } label: { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(.borderless)
                            .help("Open the invoice")
                            .accessibilityLabel("Open the \(title) invoice")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let start = invoice.periodStart, let end = invoice.periodEnd {
                    HStack(spacing: 4) {
                        Text("For")
                        DateText(date: start, font: .caption)
                        Text("–")
                        DateText(date: end, font: .caption)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if invoice.amountMinorUnits != charge.amountMinorUnits {
                    Text("The tenancy's share of \(Money.format(invoice.amountMinorUnits, currency: currency).unbroken)"
                         + (charge.detail.line.note.map { ": \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            } else if let documentId = charge.detail.documentId {
                HStack {
                    Text("One-off line").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { viewModel.openDocument(id: documentId) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless)
                        .help("Open the line's document")
                        .accessibilityLabel("Open the document of \(title)")
                }
            }
            if let debit = charge.debit {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text("Paid").foregroundStyle(.secondary)
                    DateText(date: debit.date, font: .caption).foregroundStyle(.secondary)
                    MoneyText(minorUnits: debit.amountMinorUnits, currency: viewModel.account(debit.accountId)?.currency ?? currency,
                              font: .caption.monospacedDigit()).fixedSize()
                    Spacer(minLength: 4)
                    Button { onEdit(debit) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Edit the debit: category, note, documents")
                        .accessibilityLabel("Edit the \(title) debit")
                    Button { onShow(debit) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless)
                        .help("Show the debit where it lives")
                        .accessibilityLabel("Show the \(title) debit where it lives")
                }
                .font(.caption)
            } else if invoice != nil {
                Text("No debit matched yet").font(.caption).foregroundStyle(.secondary)
            }
            if showsStatement {
                Text(charge.statementMonth.map { "On the \(RechargeEmail.monthName($0, language: .english)) statement" } ?? "Waiting for the next statement")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A tenant credit in a recharges panel: what it paid of recharges (the row's amount), and
/// the split — rent, each statement it paid.
struct RechargeCreditRow: View {
    let credit: RechargeCreditLine
    let currency: Currency
    let onEdit: (Transaction) -> Void
    let onShow: (Transaction) -> Void

    private static let month = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).year()

    private var split: String {
        var parts = ["\(Money.format(credit.transaction.amountMinorUnits, currency: currency).unbroken) credit"]
        if credit.rentMinorUnits != 0 { parts.append("\(Money.format(credit.rentMinorUnits, currency: currency).unbroken) rent") }
        for paid in credit.statements {
            parts.append("\(Money.format(paid.amountMinorUnits, currency: currency).unbroken) for \(paid.month.formatted(Self.month).unbroken)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        PropertyPanelTransactionRow(transaction: credit.transaction, minorUnits: credit.rechargeMinorUnits, currency: currency,
                                    note: split, onEdit: onEdit, onShow: onShow)
    }
}
