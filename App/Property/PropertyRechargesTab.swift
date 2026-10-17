// App/Property/PropertyRechargesTab.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction
import GRDB

/// One tenancy's utility recharges (plan phase 5 Task 3): the monthly statements with their
/// status and what's still owed, the next month to prepare, and the tenant credits that may
/// pay sent statements (exact ones linked by Match payments, others suggested for the user to
/// accept). Statements are built and emailed in `RechargeStatementSheet`.
@MainActor
final class RechargesModel: ObservableObject {
    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary
    let propertyId: Int64
    let tenancyId: Int64
    let currency: Currency
    @Published private(set) var rows: [Recharges.MonthRow] = []
    @Published private(set) var suggestions: [Recharges.PaymentSuggestion] = []
    @Published private(set) var transactions: [Int64: Transaction] = [:]
    @Published private(set) var nextMonth = Date()
    @Published private(set) var providerCount = 0
    @Published var errorMessage: String?

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, propertyId: Int64, tenancyId: Int64, currency: Currency) {
        self.dbQueue = dbQueue
        self.library = library
        self.propertyId = propertyId
        self.tenancyId = tenancyId
        self.currency = currency
    }

    func load() {
        do {
            let (rows, suggestions, next, providers) = try dbQueue.read { [propertyId, tenancyId] db in
                (try Recharges.overview(db: db, tenancyId: tenancyId),
                 try Recharges.paymentSuggestions(db: db, propertyId: propertyId).filter { $0.statement.tenancyId == tenancyId },
                 try Recharges.nextMonth(db: db, tenancyId: tenancyId, today: PropertyDays.utcToday(Date())),
                 try Recharges.providers(db: db, propertyId: propertyId).count)
            }
            let ids = Set(rows.flatMap { $0.payments.map(\.transactionId) })
            transactions = (try? dbQueue.read { db in
                Dictionary(uniqueKeysWithValues: try Transaction.filter(keys: Array(ids)).fetchAll(db).map { ($0.id!, $0) })
            }) ?? [:]
            self.rows = rows
            self.suggestions = suggestions
            nextMonth = next
            providerCount = providers
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func write(_ body: (Database) throws -> Void) {
        do {
            try dbQueue.write(body)
            errorMessage = nil
        } catch {
            errorMessage = RechargeMessages.text(for: error)
        }
        load()
    }

    /// Rent matching, then exact recharge payments.
    func matchPayments() {
        write { [propertyId] db in
            _ = try RentReceiptMatching.match(db: db, propertyId: propertyId)
            _ = try Recharges.matchPayments(db: db, propertyId: propertyId)
        }
    }

    func accept(_ suggestion: Recharges.PaymentSuggestion) {
        write { db in
            try Recharges.linkPayment(db: db, statementId: suggestion.statement.id!, transactionId: suggestion.transaction.id!,
                                      amountMinorUnits: suggestion.amountMinorUnits)
        }
    }

    func unlink(_ payment: RechargePayment) {
        write { db in _ = try Recharges.unlinkPayment(db: db, statementId: payment.statementId, transactionId: payment.transactionId) }
    }

    /// Back to draft (sent, nothing paying it).
    func reopen(_ statement: RechargeStatement) {
        write { db in _ = try Recharges.reopen(db: db, statementId: statement.id!) }
    }

    func delete(_ statement: RechargeStatement) {
        write { db in _ = try Recharges.deleteStatement(db: db, id: statement.id!) }
    }
}

/// What the statement sheet opens on.
struct RechargeStatementTarget: Identifiable {
    let id = UUID()
    /// The first day of the month.
    let month: Date
    let statementId: Int64?
}

struct PropertyRechargesTab: View {
    @ObservedObject var viewModel: PropertyViewModel
    @Environment(\.theme) private var theme
    @State private var intaking = false
    @State private var editingProviders = false
    /// Bumped when a sheet that changes invoices or providers closes, so the months reload.
    @State private var refreshToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if !viewModel.snapshot.tenancies.isEmpty {
                    Picker("Tenancy", selection: Binding(get: { viewModel.selectedTenancy?.id }, set: { viewModel.selectedTenancyId = $0 })) {
                        ForEach(viewModel.snapshot.tenancies.reversed()) { tenancy in
                            Text("\(tenancy.referenceLabel) · \(PropertyFormat.period(tenancy.startDate, tenancy.endDate))").tag(tenancy.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Tenancy")
                }
                Spacer()
                Button("Providers…") { editingProviders = true }
                Button("Utility invoices…") { intaking = true }
            }
            if let tenancy = viewModel.selectedTenancy, let propertyId = viewModel.propertyId {
                RechargesTenancyView(model: RechargesModel(dbQueue: viewModel.dbQueue, library: viewModel.library, propertyId: propertyId,
                                                           tenancyId: tenancy.id!, currency: viewModel.currency),
                                     tenancy: tenancy, refreshToken: refreshToken)
                    .id(tenancy.id)
            } else {
                Text("No tenancies yet.").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $intaking, onDismiss: { refreshToken += 1 }) {
            if let propertyId = viewModel.propertyId {
                UtilityInvoiceIntakeSheet(dbQueue: viewModel.dbQueue, library: viewModel.library, propertyId: propertyId, currency: viewModel.currency)
            }
        }
        .sheet(isPresented: $editingProviders, onDismiss: { refreshToken += 1 }) {
            if let propertyId = viewModel.propertyId {
                UtilityProvidersSheet(dbQueue: viewModel.dbQueue, propertyId: propertyId)
            }
        }
    }
}

struct RechargesTenancyView: View {
    @StateObject var model: RechargesModel
    let tenancy: Tenancy
    let refreshToken: Int
    @Environment(\.theme) private var theme
    @State private var opened: RechargeStatementTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tenancy.tenantEmail == nil {
                Text("Add the tenant's email to the tenancy (Tenancies ▸ Edit…) to address the statements.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.providerCount == 0 {
                Text("No utility providers yet: add them with Providers… (or from the Utility invoices sheet).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Prepare \(RechargeEmail.monthName(model.nextMonth, language: .english))…") {
                    opened = RechargeStatementTarget(month: model.nextMonth, statementId: nil)
                }
                .buttonStyle(.borderedProminent)
                Button("Match payments") { model.matchPayments() }
                    .help("Link rent credits to their receipts, then tenant credits whose remainder equals what statements still need")
                Spacer()
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(theme.expense)
            }
            if !model.suggestions.isEmpty {
                PropertySection("Suggested payments") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.suggestions) { suggestion in
                            HStack(spacing: 8) {
                                Text(RechargeEmail.monthName(suggestion.statement.month, language: .english)).frame(width: 120, alignment: .leading)
                                Text("\(DocumentFormat.day(suggestion.transaction.date)) · \(suggestion.transaction.rawDescription)").lineLimit(1)
                                Spacer()
                                PropertyMoney(minorUnits: suggestion.amountMinorUnits, currency: model.currency)
                                Text(differenceText(suggestion)).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                                Button("Accept") { model.accept(suggestion) }
                                    .accessibilityLabel("Accept the \(DocumentFormat.day(suggestion.transaction.date)) credit for \(RechargeEmail.monthName(suggestion.statement.month, language: .english))")
                            }
                        }
                    }
                }
            }
            PropertySection("Statements") {
                if model.rows.isEmpty {
                    Text("No statements yet.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Month"); Text("Status"); Text("Total").gridColumnAlignment(.trailing)
                            Text("Outstanding").gridColumnAlignment(.trailing); Text("Paid by"); Text("")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.rows) { row in
                            GridRow {
                                Text(RechargeEmail.monthName(row.statement.month, language: .english))
                                Text(statusText(row.statement))
                                PropertyMoney(minorUnits: row.statement.totalMinorUnits, currency: model.currency, neutral: true)
                                PropertyMoney(minorUnits: row.outstandingMinorUnits, currency: model.currency, neutral: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(row.payments, id: \.id) { payment in
                                        HStack(spacing: 4) {
                                            Text(model.transactions[payment.transactionId].map { DocumentFormat.day($0.date) } ?? "—")
                                            PropertyMoney(minorUnits: payment.amountMinorUnits, currency: model.currency, font: .callout.monospacedDigit(), neutral: true)
                                            Button("Unlink") { model.unlink(payment) }.buttonStyle(.borderless).font(.callout)
                                                .accessibilityLabel("Unlink the \(model.transactions[payment.transactionId].map { DocumentFormat.day($0.date) } ?? "") credit from \(RechargeEmail.monthName(row.statement.month, language: .english))")
                                        }
                                    }
                                }
                                HStack(spacing: 8) {
                                    Button(row.statement.status == .draft ? "Edit…" : "Open…") {
                                        opened = RechargeStatementTarget(month: row.statement.month, statementId: row.statement.id)
                                    }
                                    if row.statement.status == .sent && row.payments.isEmpty {
                                        Button("Reopen") { model.reopen(row.statement) }
                                            .help("Back to draft, to change its lines")
                                    }
                                    if row.statement.status == .draft {
                                        Button("Delete", role: .destructive) { model.delete(row.statement) }
                                            .help("Deletes the draft; its invoices become pending again")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(RechargeEmail.monthName(row.statement.month, language: .english))
                            }
                        }
                    }
                }
            }
        }
        .onAppear { model.load() }
        .onChange(of: refreshToken) { _, _ in model.load() }
        .sheet(item: $opened, onDismiss: { model.load() }) { target in
            RechargeStatementSheet(model: RechargeStatementModel(dbQueue: model.dbQueue, library: model.library, propertyId: model.propertyId,
                                                                 tenancy: tenancy, currency: model.currency, target: target))
        }
    }

    private func statusText(_ statement: RechargeStatement) -> String {
        switch statement.status {
        case .draft: return "Draft"
        case .sent: return "Sent \(statement.sentAt.map(DocumentFormat.day) ?? "")"
        case .paid: return "Paid"
        }
    }

    private func differenceText(_ suggestion: Recharges.PaymentSuggestion) -> String {
        let difference = suggestion.differenceMinorUnits
        if difference == 0 { return "exact" }
        let amount = Money.format(abs(difference), currency: model.currency)
        return difference > 0 ? "credit has \(amount) more" : "\(amount) short (partial)"
    }
}
