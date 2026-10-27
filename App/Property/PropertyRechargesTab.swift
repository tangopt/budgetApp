// App/Property/PropertyRechargesTab.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction
import GRDB

/// One tenancy's utility recharges (plan phase 5 Task 3): the monthly statements with their
/// status and what's still owed, the next month to prepare, and the tenant credits that may
/// pay sent statements (exact ones linked by Match payments, others suggested for the user to
/// accept). Statements are built and emailed in `RechargeStatementSheet`. For the tab's
/// figures and chart it also reads the tenancy's invoices — those on its statements and those
/// waiting for the next one — with the day each was paid (`Charge`).
@MainActor
final class RechargesModel: ObservableObject {
    /// One of the tenancy's invoices, as the figures and the chart read it: the day it was paid
    /// (its debit, else its issue date: `Recharges.rechargeDate`), the tenancy's share of it
    /// (the statement line's amount, or what the next statement would take), and its utility.
    struct Charge: Equatable {
        let date: Date
        let amountMinorUnits: Int
        let kind: UtilityKind
    }

    /// A year's recharges at a glance.
    struct YearFigures: Equatable {
        /// The totals of the statements sent (or paid) for the year's months, and how many.
        var recharged = 0
        var statements = 0
        /// What tenant credits paid of those statements.
        var received = 0
        /// The tenancy's share of the invoices paid in the year, and how many.
        var paid = 0
        var invoices = 0
        /// Recharged less paid: below zero while invoices wait for a statement (or a draft).
        var net: Int { recharged - paid }
    }

    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary
    let propertyId: Int64
    let tenancyId: Int64
    let currency: Currency
    @Published private(set) var rows: [Recharges.MonthRow] = []
    @Published private(set) var suggestions: [Recharges.PaymentSuggestion] = []
    @Published private(set) var transactions: [Int64: Transaction] = [:]
    @Published private(set) var nextMonth = AppClock.now
    @Published private(set) var providerCount = 0
    @Published private(set) var charges: [Charge] = []
    /// Per statement: what its lines are for ("Electricity · Water").
    @Published private(set) var lineSummaries: [Int64: String] = [:]
    @Published var errorMessage: String?

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, propertyId: Int64, tenancyId: Int64, currency: Currency) {
        self.dbQueue = dbQueue
        self.library = library
        self.propertyId = propertyId
        self.tenancyId = tenancyId
        self.currency = currency
    }

    private struct Loaded {
        var rows: [Recharges.MonthRow]
        var suggestions: [Recharges.PaymentSuggestion]
        var next: Date
        var providerCount: Int
        var charges: [Charge]
        var summaries: [Int64: String]
    }

    func load() {
        do {
            let today = PropertyDays.utcToday(AppClock.now)
            let loaded = try dbQueue.read { [propertyId, tenancyId] db -> Loaded in
                let rows = try Recharges.overview(db: db, tenancyId: tenancyId)
                let providers = try Recharges.providers(db: db, propertyId: propertyId)
                let kinds = Dictionary(uniqueKeysWithValues: providers.compactMap { provider in provider.id.map { ($0, provider.kind) } })
                var charges: [Charge] = []
                var summaries: [Int64: String] = [:]
                for row in rows {
                    let details = try Recharges.lineDetails(db: db, statementId: row.id)
                    for detail in details {
                        guard let invoice = detail.invoice else { continue }
                        charges.append(Charge(date: try Recharges.rechargeDate(db: db, invoice), amountMinorUnits: detail.line.amountMinorUnits,
                                              kind: detail.provider?.kind ?? .other))
                    }
                    summaries[row.id] = Self.summary(details)
                }
                for line in try Recharges.pendingLines(db: db, tenancyId: tenancyId, through: today) {
                    charges.append(Charge(date: line.rechargeDate, amountMinorUnits: line.amountMinorUnits,
                                          kind: kinds[line.invoice.providerId] ?? .other))
                }
                return Loaded(rows: rows,
                              suggestions: try Recharges.paymentSuggestions(db: db, propertyId: propertyId).filter { $0.statement.tenancyId == tenancyId },
                              next: try Recharges.nextMonth(db: db, tenancyId: tenancyId, today: today),
                              providerCount: providers.count, charges: charges, summaries: summaries)
            }
            let ids = Set(loaded.rows.flatMap { $0.payments.map(\.transactionId) })
            transactions = (try? dbQueue.read { db in
                Dictionary(uniqueKeysWithValues: try Transaction.filter(keys: Array(ids)).fetchAll(db).map { ($0.id!, $0) })
            }) ?? [:]
            rows = loaded.rows
            suggestions = loaded.suggestions
            nextMonth = loaded.next
            providerCount = loaded.providerCount
            charges = loaded.charges
            lineSummaries = loaded.summaries
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// What a statement's lines are for: its utilities (in `UtilityKind` order), then its
    /// one-off lines' descriptions.
    nonisolated static func summary(_ details: [Recharges.LineDetail]) -> String {
        let kinds = Set(details.compactMap(\.provider?.kind))
        let manual = details.filter { $0.invoice == nil }.compactMap(\.line.lineDescription).filter { !$0.isEmpty }
        return (UtilityKind.allCases.filter(kinds.contains).map(\.displayName) + manual).joined(separator: " · ")
    }

    /// The tab's matching and links through the filed-year check (plan Task 14): rent and recharges
    /// received feed the rental accounts. Its question shows on the tab.
    let filedYearGate = FiledYearGate()

    /// `body` through the filed-year check, off the main thread, then reloads.
    private func write(_ edit: String, _ body: @escaping (Database) throws -> Void) {
        filedYearGate.run(dbQueue, area: .property, origin: .propertyMatching, edit: edit, scope: .everyYear, body) { [weak self] result in
            self?.errorMessage = result.failure.map(RechargeMessages.text(for:))
            self?.load()
        }
    }

    /// Rent matching, then exact recharge payments.
    func matchPayments() {
        write("Rent and recharge payments matched") { [propertyId] db in
            _ = try RentReceiptMatching.match(db: db, propertyId: propertyId)
            _ = try Recharges.matchPayments(db: db, propertyId: propertyId)
        }
    }

    func accept(_ suggestion: Recharges.PaymentSuggestion) {
        write("Recharge payment linked") { db in
            try Recharges.linkPayment(db: db, statementId: suggestion.statement.id!, transactionId: suggestion.transaction.id!,
                                      amountMinorUnits: suggestion.amountMinorUnits)
        }
    }

    func unlink(_ payment: RechargePayment) {
        write("Recharge payment unlinked") { db in _ = try Recharges.unlinkPayment(db: db, statementId: payment.statementId, transactionId: payment.transactionId) }
    }

    /// Back to draft (sent, nothing paying it).
    func reopen(_ statement: RechargeStatement) {
        write("Recharge statement reopened") { db in _ = try Recharges.reopen(db: db, statementId: statement.id!) }
    }

    func delete(_ statement: RechargeStatement) {
        write("Recharge statement deleted") { db in _ = try Recharges.deleteStatement(db: db, id: statement.id!) }
    }

    // MARK: Presentation

    /// The sent statements still waiting for their payment, oldest first.
    var awaiting: [Recharges.MonthRow] {
        rows.filter { $0.statement.status == .sent }.sorted { $0.statement.month < $1.statement.month }
    }

    /// What the tenant still owes on sent statements.
    var outstanding: Int { awaiting.reduce(0) { $0 + $1.outstandingMinorUnits } }

    /// Overdue as its pill says (`RechargeFormat.statusPill`): sent, nothing received yet, past
    /// the payment window. A statement part paid shows as Part paid instead.
    func isOverdue(_ row: Recharges.MonthRow, today: Date) -> Bool {
        !RechargeFormat.isPartPaid(receivedMinorUnits: row.payments.reduce(0) { $0 + $1.amountMinorUnits })
            && row.outstandingMinorUnits > 0 && RechargeFormat.isOverdue(row.statement, today: today)
    }

    /// The years with statements or invoices, latest first (this year when there are none).
    func years(today: Date) -> [Int] {
        let found = Set(rows.map { MonthRange.components(of: $0.statement.month).year }
                        + charges.map { MonthRange.components(of: $0.date).year })
        return found.isEmpty ? [MonthRange.components(of: today).year] : found.sorted(by: >)
    }

    /// The year the tab opens on: this year, else the latest before it with anything.
    func defaultYear(today: Date) -> Int {
        let current = MonthRange.components(of: today).year
        return years(today: today).first { $0 <= current } ?? current
    }

    private func isIn(_ date: Date, year: Int, month: Int? = nil) -> Bool {
        let parts = MonthRange.components(of: date)
        return parts.year == year && (month == nil || parts.month == month)
    }

    func figures(_ year: Int) -> YearFigures {
        var figures = YearFigures()
        for row in rows where row.statement.status != .draft && isIn(row.statement.month, year: year) {
            figures.recharged += row.statement.totalMinorUnits
            figures.statements += 1
            figures.received += row.payments.reduce(0) { $0 + $1.amountMinorUnits }
        }
        for charge in charges where isIn(charge.date, year: year) {
            figures.paid += charge.amountMinorUnits
            figures.invoices += 1
        }
        return figures
    }

    /// The year's months: recharged (statements sent for the month) above the line, utilities
    /// paid in the month below, the difference as the line — only while the tenancy ran.
    func flowMonths(_ year: Int, tenancy: Tenancy) -> [FlowMonth] {
        (1...12).map { month in
            let range = MonthRange.of(year: year, month: month)
            let recharged = rows.filter { $0.statement.status != .draft && isIn($0.statement.month, year: year, month: month) }
                .reduce(0) { $0 + $1.statement.totalMinorUnits }
            let paid = charges.filter { isIn($0.date, year: year, month: month) }.reduce(0) { $0 + $1.amountMinorUnits }
            let running = range.end >= tenancy.startDate && (tenancy.endDate.map { range.start <= $0 } ?? true)
            return FlowMonth(start: range.start, inflowMinorUnits: recharged, outflowMinorUnits: paid,
                             netMinorUnits: running ? recharged - paid : nil)
        }
    }

    /// The year's invoices by utility (the tenancy's share).
    func byUtility(_ year: Int) -> [BreakdownItem] {
        UtilityKind.allCases.compactMap { kind in
            let amount = charges.filter { $0.kind == kind && isIn($0.date, year: year) }.reduce(0) { $0 + $1.amountMinorUnits }
            return amount == 0 ? nil : BreakdownItem(kind.displayName, minorUnits: amount, id: kind.rawValue)
        }
    }

    /// The month of the year with the most paid, and that amount.
    func busiestMonth(_ year: Int) -> (month: Date, minorUnits: Int)? {
        let byMonth = Dictionary(grouping: charges.filter { isIn($0.date, year: year) }) { MonthRange.components(of: $0.date).month }
            .mapValues { $0.reduce(0) { $0 + $1.amountMinorUnits } }
        guard let best = byMonth.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        return (MonthRange.of(year: year, month: best.key).start, best.value)
    }

    /// The months of the year with an invoice paid.
    func monthsWithInvoices(_ year: Int) -> Int {
        Set(charges.filter { isIn($0.date, year: year) }.map { MonthRange.components(of: $0.date).month }).count
    }
}

/// What the statement sheet opens on.
struct RechargeStatementTarget: Identifiable {
    let id = UUID()
    /// The first day of the month.
    let month: Date
    let statementId: Int64?
}

/// The Recharges tab (UI polish §4.2): the tenancy picker with Utility invoices…, More
/// (Providers…, Match payments) and Prepare <month>… prominent; then for the tenancy its
/// banners, the suggested payments to accept, the year's figures (outstanding, recharged,
/// utilities paid, the difference), paid and recharged by month beside the utilities' shares,
/// and the statements as a table by year with totals.
struct PropertyRechargesTab: View {
    @ObservedObject var viewModel: PropertyViewModel
    @State private var editingProviders = false
    /// Bumped when a sheet that changes providers closes, so the months reload.
    @State private var refreshToken = 0

    var body: some View {
        Group {
            if let tenancy = viewModel.selectedTenancy, let propertyId = viewModel.propertyId {
                // A view per tenancy: its model is made once (not on every update of the page).
                RechargesTenancyView(viewModel: viewModel, tenancy: tenancy, propertyId: propertyId, refreshToken: refreshToken,
                                     openProviders: { editingProviders = true })
                    .id(tenancy.id)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $editingProviders, onDismiss: { refreshToken += 1 }) {
            if let propertyId = viewModel.propertyId {
                UtilityProvidersSheet(dbQueue: viewModel.dbQueue, propertyId: propertyId)
            }
        }
    }

    private var emptyState: some View {
        Panel {
            EmptyState(systemImage: "bolt.horizontal", title: "No tenancies yet",
                       message: "Utilities are recharged to a tenancy's tenant: add the tenancy on Tenancies first. Providers and invoices can be set up now.") {
                Button("Providers…") { editingProviders = true }
                if let propertyId = viewModel.propertyId {
                    ImportShortcutButton("Utility invoices…", shortcut: .utilityInvoices(propertyId: propertyId))
                }
            }
            .inPanel()
        }
    }
}

struct RechargesTenancyView: View {
    @ObservedObject var viewModel: PropertyViewModel
    @StateObject private var model: RechargesModel
    let tenancy: Tenancy
    let refreshToken: Int
    let openProviders: () -> Void
    /// The window's importer: Utility invoices… is a shortcut into it (handed explicitly to the More menu).
    @Environment(\.documentImport) private var documentImport
    @State private var opened: RechargeStatementTarget?
    /// The year the figures and the chart cover (`nil`: `RechargesModel.defaultYear`).
    @State private var chosenYear: Int?

    init(viewModel: PropertyViewModel, tenancy: Tenancy, propertyId: Int64, refreshToken: Int,
         openProviders: @escaping () -> Void) {
        self.viewModel = viewModel
        // `StateObject(wrappedValue:)` takes an autoclosure: the model is made once per view.
        _model = StateObject(wrappedValue: RechargesModel(dbQueue: viewModel.dbQueue, library: viewModel.library, propertyId: propertyId,
                                                          tenancyId: tenancy.id!, currency: viewModel.currency))
        self.tenancy = tenancy
        self.refreshToken = refreshToken
        self.openProviders = openProviders
    }

    private var today: Date { PropertyDays.utcToday(AppClock.now) }
    private var year: Int { chosenYear ?? model.defaultYear(today: today) }
    private var currency: Currency { model.currency }

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            header
            banners
            if !model.suggestions.isEmpty { suggestionsPanel }
            summaryPanel
            SplitRow(ratio: 0.62) {
                chartPanel
                utilitiesPanel
            }
            BillsSection(viewModel: viewModel, bills: viewModel.bills, tenancy: tenancy, propertyId: model.propertyId)
            statementsPanel
        }
        .onAppear { model.load() }
        .filedYearGate(model.filedYearGate)
        .onChange(of: refreshToken) { _, _ in model.load() }
        // The side panel's statement sheet closed: what it changed shows here too.
        .onChange(of: viewModel.rechargesRevision) { _, _ in model.load() }
        .sheet(item: $opened, onDismiss: { model.load() }) { target in
            RechargeStatementSheet(model: RechargeStatementModel(dbQueue: model.dbQueue, library: model.library, propertyId: model.propertyId,
                                                                 tenancy: tenancy, currency: model.currency, target: target))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Tenancy", selection: Binding(get: { viewModel.selectedTenancy?.id }, set: { viewModel.selectedTenancyId = $0 })) {
                ForEach(viewModel.snapshot.tenancies.reversed()) { tenancy in
                    Text("\(tenancy.referenceLabel) · \(PropertyFormat.period(tenancy.startDate, tenancy.endDate))").tag(tenancy.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Tenancy")
            Spacer(minLength: 8)
            // Utility invoices… as a button when there's room; in More when a side panel narrows the page.
            ViewThatFits(in: .horizontal) {
                headerActions(invoicesInMenu: false)
                headerActions(invoicesInMenu: true)
            }
        }
    }

    private func headerActions(invoicesInMenu: Bool) -> some View {
        HStack(spacing: 8) {
            if !invoicesInMenu {
                ImportShortcutButton("Utility invoices…", shortcut: .utilityInvoices(propertyId: model.propertyId))
                    .help("Add utility invoices (to recharge to the tenant) and match them to their debits")
            }
            Menu {
                if invoicesInMenu {
                    ImportShortcutButton("Utility invoices…", shortcut: .utilityInvoices(propertyId: model.propertyId),
                                         importer: documentImport)
                    Divider()
                }
                Button("Providers…", action: openProviders)
                Divider()
                Button("Match payments") { model.matchPayments() }
            } label: {
                Text("More")
            }
            .fixedSize()
            .help(invoicesInMenu
                  ? "Utility invoices…; Providers…; Match payments: link rent credits to their receipts, then tenant credits whose remainder is what statements still need"
                  : "Providers…; Match payments: link rent credits to their receipts, then tenant credits whose remainder is what statements still need")
            Button("Prepare \(RechargeEmail.monthName(model.nextMonth, language: .english))…") {
                opened = RechargeStatementTarget(month: model.nextMonth, statementId: nil)
            }
            .buttonStyle(.borderedProminent).prominentTint()
            .help("The statement of the invoices since the last one, to email to the tenant")
        }
        .fixedSize()
    }

    @ViewBuilder
    private var banners: some View {
        if let error = model.errorMessage {
            InlineBanner(.error, error) { model.errorMessage = nil }
        }
        if tenancy.tenantEmail == nil {
            InlineBanner(.warning, action: {
                Button("Tenancies ›") { viewModel.tab = .tenancies }.buttonStyle(.link)
            }) {
                Text("Add the tenant's email to the tenancy (Tenancies ▸ Edit) to address the statements.")
            }
        }
        if model.providerCount == 0 {
            InlineBanner(.info, action: {
                Button("Providers…", action: openProviders).controlSize(.small)
            }) {
                Text("No utility providers yet: add them, so their invoices are read and matched to their debits.")
            }
        }
    }

    // MARK: Suggested payments

    private var suggestionsPanel: some View {
        let count = model.suggestions.count
        return Panel("Suggested payments", subtitle: "Tenant credits with something left after their rent that may pay a sent statement") {
            StatusPill(count == 1 ? "1 to review" : "\(count) to review", tone: .warning)
        } content: {
            DataTable(columns: [
                .text("Statement", width: .fit, figure: true) { RechargeEmail.monthName($0.statement.month, language: .english) },
                .date("Credit") { $0.transaction.date },
                // Narrow (a side panel open): the description truncates in less room, and the
                // difference shows as a short pill.
                DataTableColumn<Recharges.PaymentSuggestion>.text("Description", width: .fill(min: 160)) { $0.transaction.rawDescription }
                    .narrowsWhenNarrow(1, to: .fill(min: 80)),
                .money("Would pay", role: .neutral, currency: { _ in currency }) { $0.amountMinorUnits },
                DataTableColumn<Recharges.PaymentSuggestion>.status("") { differencePill($0) }
                    .compactsWhenNarrow(2) { suggestion, _ in differencePill(suggestion, short: true) },
                DataTableColumn("", alignment: .trailing) { suggestion, _ in
                    Button("Accept") { model.accept(suggestion) }
                        .controlSize(.small)
                        .help("Link this credit to the statement")
                        .accessibilityLabel("Accept the \(DocumentFormat.day(suggestion.transaction.date)) credit for \(RechargeEmail.monthName(suggestion.statement.month, language: .english))")
                }
            ], rows: model.suggestions, zebra: false)
        }
    }

    /// How the credit compares with the statement; `short`: the difference alone ("+€1.00").
    private func differencePill(_ suggestion: Recharges.PaymentSuggestion, short: Bool = false) -> StatusPill {
        let difference = suggestion.differenceMinorUnits
        let amount = Money.format(abs(difference), currency: currency)
        if difference == 0 { return StatusPill("Exact", tone: .positive, systemImage: "checkmark") }
        let more = "What's left of the credit after its rent is \(amount) more than the statement needs"
        let partial = "The credit pays part of the statement; \(amount) would stay owed"
        if short {
            return difference > 0 ? StatusPill("+\(amount)", help: more) : StatusPill("−\(amount)", tone: .warning, help: partial)
        }
        return difference > 0
            ? StatusPill("Credit has \(amount) more", help: more)
            : StatusPill("\(amount) short: partial", tone: .warning, help: partial)
    }

    // MARK: Summary

    private var summaryPanel: some View {
        Panel("Summary", subtitle: "Statements by the month they're for; invoices by the day they were paid, at the tenancy's share") {
            let years = model.years(today: today)
            if years.count > 1 {
                Picker("Year", selection: Binding(get: { year }, set: { chosenYear = $0 })) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Year")
            } else {
                Text(String(year)).font(.callout).foregroundStyle(.secondary).figureText()
            }
        } content: {
            FigureStrip(tiles)
        }
    }

    private var tiles: [FigureTile] {
        let figures = model.figures(year)
        let awaiting = model.awaiting
        let overdue = awaiting.filter { model.isOverdue($0, today: today) }.count
        let owedCaption: String = switch awaiting.count {
        case 0: "Nothing owed"
        case 1: "\(RechargeEmail.monthName(awaiting[0].statement.month, language: .english)) awaiting payment"
        default: "\(awaiting.count) statements awaiting payment"
        }
        let net = figures.net
        return [
            FigureTile(title: "Outstanding", value: .money(model.outstanding, currency, .neutral), caption: owedCaption,
                       pill: overdue > 0 ? StatusPill("\(overdue) overdue", tone: .warning, systemImage: "exclamationmark.triangle.fill") : nil),
            FigureTile(title: "Recharged in \(year)", value: .money(figures.recharged, currency, .signed),
                       caption: "\(figures.statements) statement\(figures.statements == 1 ? "" : "s") · \(Money.format(figures.received, currency: currency)) received"),
            FigureTile(title: "Utilities paid in \(year)", value: .money(figures.paid, currency, .cost),
                       caption: "\(figures.invoices) invoice\(figures.invoices == 1 ? "" : "s")"),
            FigureTile(title: "Recharged − paid", value: .money(net, currency, .signed),
                       caption: net < 0 ? "\(Money.format(-net, currency: currency)) still to recharge" : (net == 0 ? "Every invoice recharged" : "One-off lines included"),
                       captionIsWarning: net < 0)
        ]
    }

    // MARK: Charts

    private var chartPanel: some View {
        Panel("Paid and recharged by month · \(String(year))",
              subtitle: "Recharged above the line, utilities paid below, the difference as the line; click a month for its details",
              fillsHeight: true) {
            MonthlyFlowChart(months: model.flowMonths(year, tenancy: tenancy), currency: currency, inflowLabel: "Recharged",
                             outflowLabel: "Utilities paid", netLabel: "Difference", today: AppClock.now, height: 200,
                             openMonth: openMonth,
                             onSelectMonth: { month in viewModel.toggleSidePanel(.rechargeMonth(month, tenancyId: tenancy.id!)) },
                             selectLabel: { "Show the invoices and recharges of \($0)" })
        }
    }

    private var utilitiesPanel: some View {
        let items = model.byUtility(year)
        let figures = model.figures(year)
        let months = model.monthsWithInvoices(year)
        return Panel("By utility · \(String(year))", subtitle: "The tenancy's share of the invoices paid", fillsHeight: true) {
            if items.isEmpty {
                Text("No invoices paid in \(String(year)).").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    BreakdownBars(items: items, currency: currency, role: .neutral)
                    Divider()
                    PropertyFacts {
                        PropertyFact("Invoices") { Text("\(figures.invoices)").monospacedDigit().figureText() }
                        if months > 0 {
                            PropertyFact("A month") {
                                HStack(spacing: 4) {
                                    MoneyText(minorUnits: figures.paid / months, currency: currency, role: .neutral)
                                    Text("on average, over \(months) month\(months == 1 ? "" : "s")").foregroundStyle(.secondary).figureText()
                                }
                            }
                        }
                        if let busiest = model.busiestMonth(year) {
                            PropertyFact("Highest") {
                                HStack(spacing: 4) {
                                    MoneyText(minorUnits: busiest.minorUnits, currency: currency, role: .neutral)
                                    Text("in \(Self.monthName(busiest.month))").foregroundStyle(.secondary).figureText()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The chart month whose panel is open.
    private var openMonth: Date? {
        if case let .rechargeMonth(month, tenancyId) = viewModel.sidePanel, tenancyId == tenancy.id { return month }
        return nil
    }

    /// The statement whose panel is open (its table line's id).
    private var openStatementLineId: String? {
        if case let .rechargeStatement(id, tenancyId) = viewModel.sidePanel, tenancyId == tenancy.id { return "\(id)" }
        return nil
    }

    private func showDetails(_ row: Recharges.MonthRow) {
        viewModel.toggleSidePanel(.rechargeStatement(id: row.id, tenancyId: tenancy.id!))
    }

    // MARK: Statements

    /// A statement (or a year's total) as a table row.
    private struct StatementLine: Identifiable {
        let id: String
        /// Nil for a total.
        let row: Recharges.MonthRow?
        let total: Int
        let received: Int
        /// What a sent statement still needs (nil: nothing, or not sent yet).
        let outstanding: Int?
    }

    private var statementsPanel: some View {
        let rows = model.rows
        let paid = rows.filter { $0.statement.status == .paid }.count
        let drafts = rows.filter { $0.statement.status == .draft }.count
        let awaiting = model.awaiting.count
        return Panel("Statements", subtitle: rows.isEmpty ? nil : "\(rows.count) statement\(rows.count == 1 ? "" : "s") · \(paid) paid · click one for its charges and credits") {
            HStack(spacing: 6) {
                if drafts > 0 { StatusPill(drafts == 1 ? "1 draft" : "\(drafts) drafts") }
                if awaiting > 0 {
                    StatusPill("\(awaiting) awaiting payment", tone: .warning)
                } else if paid > 0 {
                    StatusPill("All sent paid", tone: .positive, systemImage: "checkmark")
                }
            }
        } content: {
            if rows.isEmpty {
                Text("No statements yet: record the month's invoices with Utility invoices…, then Prepare \(RechargeEmail.monthName(model.nextMonth, language: .english))….")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DataTable(columns: statementColumns, sections: statementSections(rows),
                          onSelect: { line in if let row = line.row { showDetails(row) } }, selectedId: openStatementLineId)
            }
        }
    }

    private static let monthFormat = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide)
    private static let monthYearFormat = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()

    private static func monthName(_ date: Date) -> String { date.formatted(monthFormat) }

    private func owed(_ row: Recharges.MonthRow) -> Int? {
        row.statement.status == .sent && row.outstandingMinorUnits != 0 ? row.outstandingMinorUnits : nil
    }

    private func statementSections(_ rows: [Recharges.MonthRow]) -> [DataTableSection<StatementLine>] {
        let byYear = Dictionary(grouping: rows) { MonthRange.components(of: $0.statement.month).year }
        return byYear.keys.sorted(by: >).map { year in
            let lines = byYear[year]!.sorted { $0.statement.month > $1.statement.month }.map { row in
                StatementLine(id: "\(row.id)", row: row, total: row.statement.totalMinorUnits,
                              received: row.payments.reduce(0) { $0 + $1.amountMinorUnits }, outstanding: owed(row))
            }
            // The year's total is what was recharged, as the summary's "Recharged in": drafts
            // (not sent yet) stay out.
            let sent = lines.filter { $0.row?.statement.status != .draft }
            let owing = sent.compactMap(\.outstanding)
            let total = StatementLine(id: "total-\(year)", row: nil, total: sent.reduce(0) { $0 + $1.total },
                                      received: sent.reduce(0) { $0 + $1.received },
                                      outstanding: owing.isEmpty ? nil : owing.reduce(0, +))
            return DataTableSection(String(year), rows: lines, total: total)
        }
    }

    private var statementColumns: [DataTableColumn<StatementLine>] {
        let currency = currency
        func amountFont(_ kind: DataTableRowKind) -> Font {
            kind == .total ? .body.monospacedDigit().weight(.semibold) : .body.monospacedDigit()
        }
        return [
            DataTableColumn("Month", accessibilityValue: { line in line.row.map { $0.statement.month.formatted(Self.monthYearFormat) } }) { line, kind in
                Text(kind == .total ? "Total sent" : line.row.map { Self.monthName($0.statement.month) } ?? "")
                    .fontWeight(kind == .total ? .semibold : .regular)
                    .figureText()
            },
            .status("Status") { line in line.row.map(status) },
            // Hidden when the table is narrow (a side panel open): the panel shows them.
            DataTableColumn<StatementLine>.date("Sent on") { $0.row?.statement.sentAt }.hidesWhenNarrow(2),
            DataTableColumn<StatementLine>.text("Lines", width: .fill(min: 140)) { line in line.row.map { model.lineSummaries[$0.id] ?? "" } ?? "" }
                .hidesWhenNarrow(1),
            .money("Total", role: .neutral, currency: { _ in currency }) { $0.total },
            DataTableColumn("Paid on", accessibilityValue: paidOnDescription) { line, kind in
                if kind == .row, let row = line.row, !row.payments.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(row.payments, id: \.id) { payment in
                            DateText(date: model.transactions[payment.transactionId]?.date)
                        }
                    }
                }
            }
            .hidesWhenNarrow(3),
            DataTableColumn("Received", alignment: .trailing, width: .min(96),
                            accessibilityValue: { $0.received == 0 ? nil : Money.format($0.received, currency: currency) }) { line, kind in
                if kind == .row, let row = line.row, !row.payments.isEmpty {
                    // One amount per credit, beside its day.
                    VStack(alignment: .trailing, spacing: 1) {
                        ForEach(row.payments, id: \.id) { payment in
                            MoneyText(minorUnits: payment.amountMinorUnits, currency: currency, role: .signed)
                        }
                    }
                } else if kind == .total, line.received != 0 {
                    MoneyText(minorUnits: line.received, currency: currency, font: amountFont(kind), role: .signed)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            },
            .money("Outstanding", role: .neutral, currency: { _ in currency }) { $0.outstanding },
            .actions { line in line.row.map(actions) ?? [] }
        ]
    }

    private func status(_ row: Recharges.MonthRow) -> StatusPill {
        RechargeFormat.statusPill(row.statement, receivedMinorUnits: row.payments.reduce(0) { $0 + $1.amountMinorUnits }, today: today)
    }

    private func paidOnDescription(_ line: StatementLine) -> String? {
        guard let row = line.row, !row.payments.isEmpty else { return nil }
        return row.payments.map { payment in
            [model.transactions[payment.transactionId].map { DocumentFormat.day($0.date) }, Money.format(payment.amountMinorUnits, currency: currency)]
                .compactMap { $0 }.joined(separator: " ")
        }.joined(separator: "; ")
    }

    /// Open (or Edit, for a draft) as the row's icon; the rest in its ••• menu.
    private func actions(_ row: Recharges.MonthRow) -> [DataTableAction] {
        let statement = row.statement
        let month = RechargeEmail.monthName(statement.month, language: .english)
        let isDraft = statement.status == .draft
        var actions = [DataTableAction(isDraft ? "Edit \(month)…" : "Open \(month)…", systemImage: isDraft ? "pencil" : "doc.text",
                                       inline: true) {
            opened = RechargeStatementTarget(month: statement.month, statementId: statement.id)
        },
        DataTableAction("Details of \(month): charges and credits", systemImage: "chevron.right", inline: true) { showDetails(row) }]
        if statement.status == .sent && row.payments.isEmpty {
            actions.append(DataTableAction("Reopen as draft, to change its lines", systemImage: "arrow.uturn.backward") { model.reopen(statement) })
        }
        for payment in row.payments {
            let day = model.transactions[payment.transactionId].map { DocumentFormat.day($0.date) } ?? ""
            actions.append(DataTableAction(row.payments.count == 1 ? "Unlink the credit" : "Unlink the credit of \(day)",
                                           systemImage: "xmark.circle") { model.unlink(payment) })
        }
        if isDraft {
            actions.append(DataTableAction("Delete the draft (its invoices wait for the next one)", systemImage: "trash", role: .destructive) {
                model.delete(statement)
            })
        }
        return actions
    }
}
