import Combine
import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Category
import struct BudgetCore.Property
import struct BudgetCore.Transaction

/// Everything the iPad's Money screen offers (step 10, Task 15), each one answering something the Mac's Money tab shows. The
/// edits (Link document, Unlink) go through the device writer in Documents; the rest only reads.
public enum PadMoneyAction: String, CaseIterable, Sendable {
    /// Calendar year, tax year or a custom range.
    case period
    /// By month or the list of transactions behind a figure.
    case view
    /// Every figure in GBP (the Mac's GBP column).
    case showInGBP
    /// The headline tiles: income, costs, capital repaid, net cash flow and the yields.
    case headline
    /// Costs by category, each a chip that lists its transactions.
    case categoryChips
    /// A month that expands to its transactions (the Cash flow chart's month panel).
    case monthList
    /// The cash flow and mortgage charts and the full figures table.
    case chartsAndFigures
    /// A figure's transactions (a row of the figures table).
    case figureTransactions
    /// A transaction opened in the document panel.
    case openTransaction
    /// The transaction's document in the panel.
    case viewDocument
    /// A library document linked to the transaction.
    case linkDocument
    /// A document taken off the transaction.
    case unlinkDocument
    /// The document selected on the Documents screen.
    case showInDocuments
    /// The transaction's details and its Edit.
    case transactionDetails

    public var title: String {
        switch self {
        case .period: "Period"
        case .view: "View"
        case .showInGBP: "Show in GBP"
        case .headline: "Summary"
        case .categoryChips: "Costs by category"
        case .monthList: "Months"
        case .chartsAndFigures: "Charts and figures"
        case .figureTransactions: "Figure's transactions"
        case .openTransaction: "Transaction"
        case .viewDocument: "View"
        case .linkDocument: "Link document"
        case .unlinkDocument: "Unlink"
        case .showInDocuments: "Show in Documents"
        case .transactionDetails: "Details"
        }
    }

    /// The icon button the action is drawn as in a row (the shared vocabulary); nil for the ones drawn as text or controls.
    var rowAction: RowAction? {
        switch self {
        case .linkDocument: .linkDocument
        case .unlinkDocument: .unlink
        case .viewDocument: .view
        default: nil
        }
    }

    /// Whether the action writes (hidden, not disabled, without Edit on Documents).
    public var edits: Bool { self == .linkDocument || self == .unlinkDocument }

    /// What the Mac's Money tab shows and does, by the words it uses, and the action that answers each here.
    /// `testEveryMacMoneyAndCalendarCapabilityListed` keeps the list whole.
    static let macActions: [(mac: String, pad: PadMoneyAction)] = [
        ("Calendar year, tax year and custom range", .period),
        ("Summary · period", .headline),
        ("Rate note: GBP at the Settings rate", .showInGBP),
        ("GBP column", .showInGBP),
        ("Figures table", .chartsAndFigures),
        ("Select a figure to list its transactions", .figureTransactions),
        ("Costs by category", .categoryChips),
        ("A chevron for each category", .categoryChips),
        ("Mortgage interest and capital", .chartsAndFigures),
        ("Cash flow by month", .chartsAndFigures),
        ("Click a month for its transactions", .monthList),
        ("Monthly figures table", .chartsAndFigures),
        ("Up and Down through the rows", .openTransaction),
        ("Documents of a transaction", .viewDocument),
        ("Link document", .linkDocument),
        ("Unlink document", .unlinkDocument),
        ("Edit transaction", .transactionDetails),
        ("Show in Search", .transactionDetails),
        ("Show in Documents", .showInDocuments),
    ]
}

/// The property's money for the iPad: a period's summary, its months (each expanding to the transactions behind its cash
/// flow, counted as the Mac counts them), any figure's transactions, and the transaction open in the document panel with
/// its documents. It reads the Mac's read models (`PropertyFinance`, `PropertyPage`, `TransactionDocuments`) and computes
/// no figure; the only writes are a document linked to or taken off a transaction.
@MainActor
public final class PadMoneyModel: ObservableObject {
    public enum PeriodChoice: Hashable, Sendable {
        case calendarYear(Int)
        case taxYear(Int)
        case custom
    }

    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case months = "By month"
        case transactions = "Transactions"
        public var id: String { rawValue }
    }

    /// A figure (or cost category) whose transactions are listed.
    public struct Drill: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var kind: PropertyDrillDown

        public init(id: String, title: String, kind: PropertyDrillDown) {
            self.id = id
            self.title = title
            self.kind = kind
        }
    }

    /// A transaction as a row: the month list's (with what it counts in the month) or a figure's.
    public struct Line: Identifiable, Equatable, Sendable {
        public var id: String
        public var transaction: Transaction
        public var categoryName: String?
        public var accountName: String
        /// The currency of the transaction's account (its own amount is in it).
        public var currency: Currency
        /// What the line adds to the month's net cash flow; nil in a figure's list.
        public var counted: PropertyAmount?
        /// Why `counted` isn't the transaction's own amount, when it isn't.
        public var note: String?
        public var documentCount: Int

        public var transactionId: Int64 { transaction.id ?? 0 }

        /// "Category · Account".
        public var detail: String { [categoryName, accountName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
    }

    public struct AccountInfo: Equatable, Sendable {
        public var name: String
        public var currency: Currency
    }

    public struct Snapshot: Equatable, Sendable {
        public var property: Property?
        public var summary: PropertySummary?
        public var categoryNames: [Int64: String]
        public var accounts: [Int64: AccountInfo]
        /// How many documents each transaction has.
        public var documentCounts: [Int64: Int]
        /// The years the period menu offers, latest first.
        public var years: [Int]

        public static let empty = Snapshot(property: nil, summary: nil, categoryNames: [:], accounts: [:], documentCounts: [:], years: [])
    }

    /// The transaction open in the panel: its line, its documents, and the month it was opened from.
    public struct Panel: Equatable, Sendable {
        public var line: Line
        public var documents: [TransactionDocument]
        public var month: Date?
    }

    @Published public private(set) var snapshot: Snapshot = .empty
    @Published public var periodChoice: PeriodChoice
    /// The custom range's first and last days (UTC midnights).
    @Published public var customFirstDay: Date
    @Published public var customLastDay: Date
    @Published public var showsGBP = false
    @Published public var mode: Mode = .months
    @Published public private(set) var drill: Drill?
    @Published public private(set) var drillLines: [Line] = []
    /// The month expanded in the list (its first day, as the summary has it).
    @Published public private(set) var expandedMonth: Date?
    @Published public private(set) var breakdowns: [Date: PropertyMonthBreakdown] = [:]
    @Published public private(set) var panel: Panel?
    /// The document the panel shows when it isn't the transaction's first.
    @Published public var shownDocumentId: Int64?

    public let property: PadPropertyModel
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private var generation = 0
    private var isPreloaded = false
    private var forwarding: AnyCancellable?

    /// Where a refusal of a document edit shows: under the transaction's panel.
    public nonisolated static func transactionRow(_ id: Int64) -> String { "money-transaction-\(id)" }

    /// `write`: the device writer in Documents (a document link is Documents' edit, as the Mac's is).
    public init(property: PadPropertyModel, write: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.property = property
        self.write = write
        self.dbQueue = dbQueue
        self.today = today
        let day = MonthRange.calendar.startOfDay(for: today())
        let year = MonthRange.components(of: day).year
        periodChoice = .calendarYear(year)
        customFirstDay = MonthRange.of(year: year, month: 1).start
        customLastDay = day
        forwarding = property.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Reading

    public func preload(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        isPreloaded = true
    }

    /// Already read, with a month expanded and a transaction open (the snapshot routes' first frame).
    public func preload(_ snapshot: Snapshot, expanded month: Date? = nil, breakdown: PropertyMonthBreakdown? = nil, panel: Panel? = nil,
                        drill: Drill? = nil, drillLines: [Line] = []) {
        preload(snapshot)
        expandedMonth = month
        breakdowns = month.flatMap { start in breakdown.map { [start: $0] } } ?? [:]
        self.panel = panel
        self.drill = drill
        self.drillLines = drillLines
        if drill != nil { mode = .transactions }
    }

    /// `line` opened as the panel shows it, read now.
    public nonisolated static func panelNow(_ dbQueue: any DatabaseReader, line: Line, month: Date?) -> Panel {
        let documents = (try? dbQueue.read { db in
            try TransactionDocuments.documents(db: db, transactionId: line.transactionId, catalog: try DocumentKindCatalog.load(db: db))
        }) ?? []
        return Panel(line: line, documents: documents, month: month)
    }

    /// The month's breakdown, read now.
    public nonisolated static func breakdownNow(_ dbQueue: any DatabaseReader, propertyId: Int64, month: PropertyMonthFigures) -> PropertyMonthBreakdown? {
        try? dbQueue.read { db in
            try PropertyFinance.monthBreakdown(db: db, propertyId: propertyId, interval: DateInterval(start: month.start, end: month.end))
        }
    }

    public func reload() async {
        guard !isPreloaded else { return }
        await read()
    }

    private func read() async {
        generation += 1
        let mine = generation
        guard let propertyId = property.property?.id else {
            snapshot = .empty
            return
        }
        let period = period
        let day = MonthRange.calendar.startOfDay(for: today())
        let reader = dbQueue
        guard let read = try? await reader.read({ db in try Self.read(db, propertyId: propertyId, period: period, today: day) }),
              mine == generation else { return }
        snapshot = read
        breakdowns = [:]
        if let start = expandedMonth { await loadBreakdown(start) }
        if let drill { await loadDrill(drill) }
        if let open = panel { await reloadPanel(open.line, month: open.month) }
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, propertyId: Int64?, period: PropertyPeriod?, today: Date) -> Snapshot {
        guard let propertyId else { return .empty }
        return (try? dbQueue.read { db in try read(db, propertyId: propertyId, period: period, today: MonthRange.calendar.startOfDay(for: today)) })
            ?? .empty
    }

    nonisolated static func read(_ db: Database, propertyId: Int64, period: PropertyPeriod?, today: Date) throws -> Snapshot {
        guard let property = try Property.fetchOne(db, key: propertyId) else { return .empty }
        let summary = try period.map { try PropertyFinance.summary(db: db, propertyId: propertyId, period: $0, today: today) }
        let tenancyStarts = try Tenancies.all(db: db, propertyId: propertyId).map(\.startDate)
        let current = MonthRange.components(of: today).year
        let first = ([tenancyStarts.min(), property.purchaseDate].compactMap { $0 }.map { MonthRange.components(of: $0).year }.min() ?? current)
        return Snapshot(
            property: property, summary: summary,
            categoryNames: Dictionary(uniqueKeysWithValues: try Category.fetchAll(db).compactMap { c in c.id.map { ($0, c.name) } }),
            accounts: Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in
                a.id.map { ($0, AccountInfo(name: a.displayName, currency: a.currency)) }
            }),
            documentCounts: try TransactionDocuments.allCounts(db: db),
            years: Array(min(first, current)...(current + 1)).reversed())
    }

    // MARK: Period and display

    /// The period the summary covers; nil for a custom range that ends before it starts.
    public var period: PropertyPeriod? {
        switch periodChoice {
        case let .calendarYear(year): return .calendarYear(year)
        case let .taxYear(year): return .ukTaxYear(UKTaxYear(startYear: year))
        case .custom:
            guard customFirstDay <= customLastDay else { return nil }
            return .custom(DateInterval(start: customFirstDay, end: MonthRange.calendar.date(byAdding: .day, value: 1, to: customLastDay)!))
        }
    }

    /// Chooses a period and reads it; the month list and a figure's list start over.
    public func choose(_ choice: PeriodChoice) async {
        periodChoice = choice
        closeMonth()
        drill = nil
        drillLines = []
        panel = nil
        mode = .months
        isPreloaded = false
        await read()
    }

    /// The period menu's label: "2026", "Tax year 2026/27", or the custom range.
    public var periodTitle: String {
        switch periodChoice {
        case let .calendarYear(year): String(year)
        case let .taxYear(year): "Tax \(UKTaxYear(startYear: year).label)"
        case .custom: period?.label ?? "Custom range"
        }
    }

    public var currency: Currency { snapshot.property?.currency ?? property.property?.currency ?? .eur }

    /// The currency figures are shown in: the property's, or GBP when asked and it differs.
    public var displayCurrency: Currency { showsGBP && currency != .gbp ? .gbp : currency }

    /// An amount in the property's currency or in GBP, as chosen.
    public func shown(_ amount: PropertyAmount) -> Int { displayCurrency == .gbp && currency != .gbp ? amount.gbp : amount.native }

    /// Whether the GBP toggle does anything (the property is not already in pounds).
    public var offersGBP: Bool { currency != .gbp }

    public var summary: PropertySummary? { snapshot.summary }

    /// "GBP at 0.8650 per euro (the rate in Settings)" while GBP is shown for a euro property.
    public var rateNote: String? {
        guard let summary, showsGBP, offersGBP else { return nil }
        return "GBP at \(String(format: "%.4f", summary.eurToGbpRate)) per euro (the rate in Settings)"
    }

    /// The summary's months, latest first.
    public var months: [PropertyMonthFigures] { (summary?.months ?? []).reversed() }

    /// The cost categories as chips, largest first.
    public var categoryChips: [Drill] {
        (summary?.costsByCategory ?? []).map {
            Drill(id: Self.categoryPrefix + String($0.categoryId), title: $0.name, kind: .costs(categoryId: $0.categoryId))
        }
    }

    public static let categoryPrefix = "category."

    /// Every costs transaction: the chip that clears a category.
    public static let allCosts = Drill(id: "costs", title: "All costs", kind: .costs(categoryId: nil))

    // MARK: Headline and figures

    /// A headline tile: a money figure (in the property's currency and GBP) or a yield.
    public struct Tile: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var amount: PropertyAmount?
        public var text: String?
        public var role: MoneyRole
        public var caption: String?
    }

    /// The summary's six headline figures, as the Mac's strip has them.
    public var tiles: [Tile] {
        guard let summary else { return [] }
        let t = summary.totals
        let priceHint = summary.purchasePrice == nil
        return [
            Tile(id: "income", title: "Income", amount: t.income, text: nil, role: .income, caption: nil),
            Tile(id: "costs", title: "Costs", amount: t.costs, text: nil, role: .expense, caption: nil),
            Tile(id: "capital", title: "Capital repaid", amount: t.mortgageCapital, text: nil, role: .expense, caption: nil),
            Tile(id: "net", title: "Net cash flow", amount: t.netCashFlow, text: nil, role: .income, caption: nil),
            Tile(id: "gross", title: "Gross yield", amount: nil, text: Self.yield(summary.grossYield), role: .neutral,
                 caption: priceHint ? "Set a price in Profile" : "Rent on receipts, annualised"),
            Tile(id: "netYield", title: "Net yield", amount: nil, text: Self.yield(summary.netYield), role: .neutral,
                 caption: priceHint ? nil : "Income − costs, annualised"),
        ]
    }

    public nonisolated static func yield(_ value: Double?) -> String {
        value.map { String(format: "%.2f%%", $0 * 100) } ?? "—"
    }

    /// A row of the figures table.
    public struct Figure: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// What it is.
        public var detail: String?
        public var amount: PropertyAmount
        public var role: MoneyRole
        public var drillDown: PropertyDrillDown?
        public var isTotal = false
    }

    public struct FigureSection: Identifiable, Equatable, Sendable {
        public var title: String
        public var rows: [Figure]
        public var id: String { title }
    }

    /// The Mac's figures table in its groups (Rent, Income, Costs, Mortgage, Cash flow, Balances at the end).
    public var figureSections: [FigureSection] {
        guard let summary else { return [] }
        let t = summary.totals
        return [
            FigureSection(title: "Rent", rows: [
                Figure(id: "perReceipts", title: "Rent per receipts", detail: "The receipts' rent, spread over their rent periods",
                       amount: t.rentPerReceipts, role: .neutral),
                Figure(id: "credits", title: "Rent credits", detail: "Credits in the rent categories on the current account",
                       amount: t.rentCredits, role: .income, drillDown: .rentCredits),
                Figure(id: "recharges", title: "Recharges and other", detail: "The part of those credits that isn't rent",
                       amount: t.recharges, role: .income, drillDown: .rentCredits),
                Figure(id: "received", title: "Rent received", detail: "Rent credits − recharges and other",
                       amount: t.rentReceived, role: .income, drillDown: .rentCredits),
            ]),
            FigureSection(title: "Income", rows: [
                Figure(id: "income", title: "Income", detail: "Every transaction in the property's income categories",
                       amount: t.income, role: .income, drillDown: .income),
            ]),
            FigureSection(title: "Costs", rows: [
                Figure(id: "costs", title: "Costs", detail: "Every transaction in the property's expense categories, mortgage interest included",
                       amount: t.costs, role: .expense, drillDown: .costs(categoryId: nil)),
                Figure(id: "utilities", title: "Utilities paid", detail: "Costs in the utility categories (electricity, gas, water)",
                       amount: t.utilities, role: .expense),
                Figure(id: "utilityRecharges", title: "Utilities recharged",
                       detail: "Recharge statements paid by the tenant: the statement-linked parts of credits",
                       amount: t.utilityRecharges, role: .income),
                Figure(id: "netUtilities", title: "Net utilities", detail: "Utilities paid − recharged, never below zero: what they cost the landlord",
                       amount: t.netUtilities, role: .expense),
            ]),
            FigureSection(title: "Mortgage", rows: [
                Figure(id: "interest", title: "Mortgage interest", detail: "Interest, fees and taxes charged on the mortgage accounts",
                       amount: t.mortgageInterest, role: .expense, drillDown: .mortgageInterest),
                Figure(id: "capital", title: "Mortgage capital repaid", detail: "Instalments less interest",
                       amount: t.mortgageCapital, role: .expense, drillDown: .mortgage),
                Figure(id: "outside", title: "Interest outside the property's categories",
                       detail: "Mortgage interest filed under a category that isn't one of the property's",
                       amount: t.interestOutsideCosts, role: .expense, drillDown: .mortgageInterestOutsideCosts),
            ]),
            FigureSection(title: "Cash flow", rows: [
                Figure(id: "net", title: "Net cash flow", detail: "Income − costs − capital repaid (and any interest filed elsewhere)",
                       amount: t.netCashFlow, role: .income, isTotal: true),
            ]),
            FigureSection(title: "Balances at the end", rows: [
                Figure(id: "loan", title: "Outstanding loan", amount: summary.outstandingLoan, role: .neutral),
                Figure(id: "deposit", title: "Deposit held", amount: summary.depositHeld, role: .neutral),
            ]),
        ]
    }

    /// Opens a figure's transactions (a row of the figures table).
    public func show(_ figure: Figure) async {
        guard let kind = figure.drillDown else { return }
        await show(Drill(id: figure.id, title: figure.title, kind: kind))
    }

    // MARK: Months

    private nonisolated static let utc = TimeZone(identifier: "UTC")!

    /// "March 2026", or "6 – 30 Apr 2025" for a month the period cuts.
    public nonisolated static func monthTitle(_ month: PropertyMonthFigures) -> String {
        let (year, number) = MonthRange.components(of: month.start)
        let whole = MonthRange.of(year: year, month: number)
        if whole.start == month.start && whole.end.addingTimeInterval(1) == month.end {
            return month.start.formatted(Date.FormatStyle(timeZone: utc).month(.wide).year())
        }
        return "\(PhoneDateFormat.day(month.start)) – \(PhoneDateFormat.day(month.end.addingTimeInterval(-1)))"
    }

    public func breakdown(_ month: PropertyMonthFigures) -> PropertyMonthBreakdown? { breakdowns[month.start] }

    /// Expands `month` (and loads its transactions), or folds it when it is the one open.
    public func toggle(_ month: PropertyMonthFigures) async {
        if expandedMonth == month.start {
            closeMonth()
            return
        }
        expandedMonth = month.start
        await loadBreakdown(month.start)
    }

    public func closeMonth() { expandedMonth = nil }

    private func loadBreakdown(_ start: Date) async {
        guard breakdowns[start] == nil, let propertyId = property.property?.id,
              let month = summary?.months.first(where: { $0.start == start }) else { return }
        let interval = DateInterval(start: month.start, end: month.end)
        let reader = dbQueue
        if let breakdown = try? await reader.read({ db in try PropertyFinance.monthBreakdown(db: db, propertyId: propertyId, interval: interval) }) {
            breakdowns[start] = breakdown
        }
    }

    /// The lines of a month's group, as rows.
    public func lines(_ group: PropertyFlowGroup) -> [Line] {
        group.lines.map { flow in
            let account = snapshot.accounts[flow.transaction.accountId]
            return Line(id: flow.id, transaction: flow.transaction, categoryName: flow.categoryName, accountName: account?.name ?? "",
                        currency: flow.accountCurrency, counted: flow.counted, note: flow.note,
                        documentCount: snapshot.documentCounts[flow.transaction.id ?? 0] ?? 0)
        }
    }

    // MARK: A figure's transactions

    /// Lists a figure's (or category's) transactions for the period, oldest first.
    public func show(_ drill: Drill) async {
        self.drill = drill
        mode = .transactions
        await loadDrill(drill)
    }

    private func loadDrill(_ drill: Drill) async {
        guard let propertyId = property.property?.id, let interval = period?.interval else {
            drillLines = []
            return
        }
        let reader = dbQueue
        let kind = drill.kind
        guard let rows = try? await reader.read({ db in try PropertyDrillTransactions.transactions(db: db, propertyId: propertyId, period: interval, drillDown: kind) })
        else { return }
        guard self.drill == drill else { return }
        drillLines = rows.map { transaction in
            let account = snapshot.accounts[transaction.accountId]
            return Line(id: "drill/\(transaction.id ?? 0)", transaction: transaction,
                        categoryName: transaction.categoryId.flatMap { snapshot.categoryNames[$0] }, accountName: account?.name ?? "",
                        currency: account?.currency ?? .gbp, counted: nil, note: nil,
                        documentCount: snapshot.documentCounts[transaction.id ?? 0] ?? 0)
        }
    }

    /// Back to the month list.
    public func showMonths() {
        mode = .months
    }

    // MARK: The transaction panel

    /// Opens `line` in the panel with its documents; `month`: the month it was opened from, for the panel's figures.
    public func select(_ line: Line, month: Date? = nil) async {
        shownDocumentId = nil
        await reloadPanel(line, month: month)
    }

    private func reloadPanel(_ line: Line, month: Date?) async {
        let id = line.transactionId
        let reader = dbQueue
        let documents = (try? await reader.read { db in
            try TransactionDocuments.documents(db: db, transactionId: id, catalog: try DocumentKindCatalog.load(db: db))
        }) ?? []
        var fresh = line
        fresh.documentCount = documents.count
        panel = Panel(line: fresh, documents: documents, month: month)
        if let shown = shownDocumentId, !documents.contains(where: { $0.id == shown }) { shownDocumentId = nil }
    }

    public func closePanel() {
        panel = nil
        shownDocumentId = nil
    }

    /// The document the panel shows: the one chosen, else the transaction's first.
    public var panelDocumentId: Int64? { shownDocumentId ?? panel?.documents.first?.id }

    /// The panel's month figures (Rent received, Costs, Net cash flow), when it was opened from a month.
    public var panelMonth: PropertyMonthBreakdown? { panel?.month.flatMap { breakdowns[$0] } }

    /// What the panel offers for the open transaction: view for each other document, the paperclip, the edits only with Edit
    /// on Documents.
    public func actions() -> [PadMoneyAction] {
        guard let panel else { return [] }
        var actions: [PadMoneyAction] = [.transactionDetails]
        if !panel.documents.isEmpty { actions.append(.showInDocuments) }
        if write.canEdit {
            actions.append(.linkDocument)
            if !panel.documents.isEmpty { actions.append(.unlinkDocument) }
        }
        return actions
    }

    // MARK: Writes: documents

    /// The library documents that could be `transactionId`'s: those the matcher would propose first, then the library's
    /// latest, none already linked to it.
    func documentChoices(for transactionId: Int64) async -> [PadChoice] {
        let reader = dbQueue
        return (try? await reader.read { db -> [PadChoice] in
            let linked = Set(try TransactionDocuments.documents(db: db, transactionId: transactionId, catalog: try DocumentKindCatalog.load(db: db)).map(\.id))
            let documents = try EvidenceDocument.fetchAll(db)
            let index = EvidenceMatcher.Index(transactions: try Transaction.fetchAll(db), accounts: try Account.fetchAll(db),
                                              categories: try Category.fetchAll(db))
            let suggested = EvidenceMatcher.documentSuggestions(for: transactionId, documents: documents, index: index, excluding: linked,
                                                                linkedDebits: try EvidenceMatcher.linkedDebits(db: db), limit: 8).map(\.documentId)
            let byId = Dictionary(documents.compactMap { d in d.id.map { ($0, d) } }, uniquingKeysWith: { a, _ in a })
            let rest = documents.sorted { ($0.docDate ?? $0.addedAt) > ($1.docDate ?? $1.addedAt) }.compactMap(\.id)
                .filter { !linked.contains($0) && !suggested.contains($0) }.prefix(12)
            return (suggested + rest).compactMap { byId[$0] }.map {
                PadChoice(id: $0.id ?? 0, title: $0.displayName, date: $0.docDate, amountMinorUnits: $0.amountMinorUnits)
            }
        }) ?? []
    }

    /// Links library document `documentId` to the open transaction.
    @discardableResult
    public func link(documentId: Int64) async -> Bool {
        guard let transactionId = panel?.line.transactionId else { return false }
        let entity = EvidenceEntity.transaction(transactionId)
        let saved = await write.perform(rowId: Self.transactionRow(transactionId), origin: .documentLink, edit: "Link document",
                                        scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            try EvidenceLinkGuard.checked(db: db) { _ = try EvidenceLinks.link(db: db, documentId: documentId, to: entity) }
        }
        if saved {
            shownDocumentId = documentId
            await refresh()
        }
        return saved
    }

    /// Takes `documentId` off the open transaction (the document stays in the library).
    @discardableResult
    public func unlink(documentId: Int64) async -> Bool {
        guard let transactionId = panel?.line.transactionId else { return false }
        let entity = EvidenceEntity.transaction(transactionId)
        let saved = await write.perform(rowId: Self.transactionRow(transactionId), origin: .documentLink, edit: "Unlink document",
                                        scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            _ = try EvidenceLinkGuard.checked(db: db) { try EvidenceLinks.unlink(db: db, documentId: documentId, from: entity) }
        }
        if saved {
            if shownDocumentId == documentId { shownDocumentId = nil }
            await refresh()
        }
        return saved
    }

    private func refresh() async {
        isPreloaded = false
        await read()
    }

    /// A transaction as a search row, for its detail sheet (and the Edit it offers).
    public func detailRow(transactionId: Int64) async -> TransactionSearch.Row? {
        try? await dbQueue.read { db in
            guard let transaction = try Transaction.fetchOne(db, key: transactionId) else { return nil }
            let account = try Account.fetchOne(db, key: transaction.accountId)
            let category = try transaction.categoryId.flatMap { try Category.fetchOne(db, key: $0) }
            return TransactionSearch.Row(transaction: transaction, category: category, categoryName: category?.name ?? "",
                                         accountName: account?.displayName ?? "", currency: account?.currency ?? .gbp,
                                         isLinkedTransfer: false, outgoingTransactionId: nil)
        }
    }
}
