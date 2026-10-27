import Combine
import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Property
import struct BudgetCore.Transaction

/// Every action the iPad's Checks screen offers (step 10, Task 16), each one of the Mac Checks tab's.
public enum PadChecksAction: String, CaseIterable, Sendable {
    /// The period the checks cover: a calendar or UK tax year.
    case period
    /// The property's Missing evidence (the Evidence screen).
    case missingEvidence
    /// One PDF per rent receipt and one contract per tenancy asked for in Missing evidence (`PropertyEvidence.seedRules`).
    case addEvidenceRules
    /// Rent credits linked to the receipts they paid (`RentReceiptMatching.match`).
    case matchCredits
    /// A rent credit without a receipt: its details, and the Edit they offer.
    case showCredit
    /// A recurring cost that has stopped (`PropertyCheckDecisions.stopExpecting`).
    case notExpected
    /// The toast's Undo of "Not expected any more" (`PropertyCheckDecisions.expectAgain`).
    case undoNotExpected

    public var title: String {
        switch self {
        case .period: "Period"
        case .missingEvidence: "Missing evidence"
        case .addEvidenceRules: "Add evidence rules"
        case .matchCredits: "Match credits"
        case .showCredit: "Show the transaction"
        case .notExpected: "Not expected any more"
        case .undoNotExpected: "Undo"
        }
    }

    /// Whether the action writes (hidden, not disabled, without Edit on Property).
    public var edits: Bool {
        switch self {
        case .addEvidenceRules, .matchCredits, .notExpected, .undoNotExpected: true
        case .period, .missingEvidence, .showCredit: false
        }
    }

    /// The icon button the action is drawn as in a row (the shared vocabulary); nil for the ones drawn as text.
    var rowAction: RowAction? {
        switch self {
        case .notExpected: .notExpected
        case .showCredit: .view
        case .period, .missingEvidence, .addEvidenceRules, .matchCredits, .undoNotExpected: nil
        }
    }

    /// The Mac's Checks tab actions, by the name the Mac gives them, and the action that answers each here. "Expect again"
    /// (the Mac's list of costs not expected any more) is the toast's Undo: there is no such list on the iPad.
    static let macActions: [(mac: String, pad: PadChecksAction)] = [
        ("Period", .period),
        ("Missing evidence for the property", .missingEvidence),
        ("Add evidence rules", .addEvidenceRules),
        ("Match credits", .matchCredits),
        ("Show the transaction", .showCredit),
        ("Not expected any more", .notExpected),
        ("Expect again", .undoNotExpected),
    ]
}

/// The iPad Checks screen's state (step 10, Task 16): the period's checks as lines (all well, or what's off), the
/// selected check's findings, the deposit against the tenancy's terms, and the recurring costs by provider, each
/// overdue or expected with "Not expected any more" and an Undo toast. It reads the Mac's read models
/// (`PropertyChecks.run`, `PropertyCalendar.recurringPatterns`) and writes through `PadWriteModel`.
@MainActor
public final class PadChecksModel: ObservableObject {
    /// One check of the Mac's summary panel.
    public enum Check: String, CaseIterable, Identifiable, Sendable {
        case months, receipts, credits, deposit, recurring
        public var id: String { rawValue }
    }

    public enum LineState: Equatable, Sendable { case ok, issue, notChecked }

    /// A check as its line: its state and the Mac's words.
    public struct Line: Equatable, Identifiable, Sendable {
        public var check: Check
        public var state: LineState
        public var text: String
        public var id: String { check.rawValue }
    }

    /// A recurring cost of the property by its provider (the payee, or the mortgage account): overdue, or when it is
    /// expected next.
    public struct RecurringCost: Equatable, Identifiable, Sendable {
        public var pattern: PropertyRecurringPattern
        /// Overdue since this day (its expected day); nil when it is only expected.
        public var overdueSince: Date?
        public var id: String { pattern.key }
        var rowId: String { "recurring-\(pattern.key)" }
        public var isOverdue: Bool { overdueSince != nil }
        /// "Overdue · expected around 3 Sep 2026" or "Expected around 3 Nov 2026".
        public var status: String {
            if let overdueSince { return "Overdue · expected around \(PhoneDateFormat.day(overdueSince))" }
            return "Expected around \(PhoneDateFormat.day(pattern.nextDate))"
        }
    }

    /// The toast after "Not expected any more": its words, and the series Undo brings back (nil after Undo).
    public struct Toast: Equatable, Identifiable, Sendable {
        public let id = UUID()
        public var message: String
        public var undo: RecurringCost?
        public var canUndo: Bool { undo != nil }

        public init(message: String, undo: RecurringCost?) {
            self.message = message
            self.undo = undo
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var property: Property?
        public var report: PropertyCheckReport?
        /// Each tenancy's name (its reference), by id.
        public var tenancyNames: [Int64: String]
        /// Each account's name, by id (for a credit's line).
        public var accountNames: [Int64: String]
        /// Expected but not yet overdue recurring costs (the overdue ones are the report's).
        public var expected: [PropertyRecurringPattern]
        public var hasEvidenceRules: Bool
        /// The years the period menu offers, latest first.
        public var years: [Int]

        public static let empty = Snapshot(property: nil, report: nil, tenancyNames: [:], accountNames: [:], expected: [],
                                           hasEvidenceRules: true, years: [])
    }

    @Published public private(set) var snapshot: Snapshot = .empty
    @Published public private(set) var periodChoice: PadMoneyModel.PeriodChoice
    /// The check whose findings show in the side card.
    @Published public var selected: Check?
    @Published public private(set) var toast: Toast?
    /// What the last screen-wide action did ("Linked 2 credits…").
    @Published public private(set) var info: String?

    public let property: PadPropertyModel
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private var generation = 0
    private var isPreloaded = false
    private var forwarding: AnyCancellable?

    /// The row a refusal of a screen-wide action shows under.
    static let screenRow = "checks"

    public init(property: PadPropertyModel, write: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.property = property
        self.write = write
        self.dbQueue = dbQueue
        self.today = today
        periodChoice = .calendarYear(MonthRange.components(of: MonthRange.calendar.startOfDay(for: today())).year)
        forwarding = property.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Reading

    /// Already read, with a check's card open and a toast showing (the snapshot routes' first frame).
    public func preload(_ snapshot: Snapshot, selected: Check? = nil, toast: Toast? = nil) {
        self.snapshot = snapshot
        self.selected = selected
        self.toast = toast
        isPreloaded = true
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
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, propertyId: Int64?, period: PropertyPeriod, today: Date) -> Snapshot {
        guard let propertyId else { return .empty }
        return (try? dbQueue.read { db in try read(db, propertyId: propertyId, period: period, today: MonthRange.calendar.startOfDay(for: today)) })
            ?? .empty
    }

    nonisolated static func read(_ db: Database, propertyId: Int64, period: PropertyPeriod, today: Date) throws -> Snapshot {
        guard let property = try Property.fetchOne(db, key: propertyId) else { return .empty }
        let report = try PropertyChecks.run(db: db, propertyId: propertyId, period: period.interval, today: today)
        let tenancies = try Tenancies.all(db: db, propertyId: propertyId)
        let overdue = Set(report.missingRecurringCosts.map(\.pattern.key))
        let notExpected = Set(report.notExpectedRecurringCosts.map(\.pattern.key))
        let expected = try PropertyCalendar.recurringPatterns(db: db, propertyId: propertyId, asOf: today)
            .filter { !overdue.contains($0.key) && !notExpected.contains($0.key) }
            .sorted { $0.nextDate < $1.nextDate }
        let current = MonthRange.components(of: today).year
        let first = ([tenancies.map(\.startDate).min(), property.purchaseDate].compactMap { $0 }.map { MonthRange.components(of: $0).year }.min()
            ?? current)
        return Snapshot(
            property: property, report: report,
            tenancyNames: Dictionary(uniqueKeysWithValues: tenancies.compactMap { t in t.id.map { ($0, t.referenceLabel) } }),
            accountNames: Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a.displayName) } }),
            expected: expected,
            hasEvidenceRules: try PropertyEvidence.defaultRules(db: db, propertyId: propertyId).isEmpty,
            years: Array(min(first, current)...current).reversed())
    }

    // MARK: Period

    public var period: PropertyPeriod {
        switch periodChoice {
        case let .taxYear(year): .ukTaxYear(UKTaxYear(startYear: year))
        case let .calendarYear(year): .calendarYear(year)
        case .custom: .calendarYear(MonthRange.components(of: today()).year)
        }
    }

    /// "2026" or "Tax 2026/27".
    public var periodTitle: String {
        switch periodChoice {
        case let .taxYear(year): "Tax \(UKTaxYear(startYear: year).label)"
        case let .calendarYear(year): String(year)
        case .custom: period.label
        }
    }

    public func choose(_ choice: PadMoneyModel.PeriodChoice) async {
        periodChoice = choice
        selected = nil
        isPreloaded = false
        await read()
    }

    public var currency: Currency { snapshot.property?.currency ?? property.property?.currency ?? .eur }

    // MARK: Lines

    /// "Nothing to look at" or "3 things to look at".
    public var headline: String {
        let count = snapshot.report?.issueCount ?? 0
        return count == 0 ? "Nothing to look at" : "\(count) thing\(count == 1 ? "" : "s") to look at"
    }

    /// The checks as the Mac's summary panel words them.
    public var lines: [Line] {
        guard let report = snapshot.report else { return [] }
        func line(_ check: Check, _ count: Int, ok: String, one: String, many: String) -> Line {
            Line(check: check, state: count == 0 ? .ok : .issue, text: count == 0 ? ok : (count == 1 ? one : "\(count) \(many)"))
        }
        var lines = [
            line(.months, report.monthsWithoutReceipt.count, ok: "Every month the tenancy ran has a receipt",
                 one: "1 month without a receipt", many: "months without a receipt"),
            line(.receipts, report.receiptsWithoutCredit.count, ok: "Every receipt has its credit",
                 one: "1 receipt without a matched credit", many: "receipts without a matched credit"),
            line(.credits, report.creditsWithoutReceipt.count, ok: "Every rent credit has its receipt",
                 one: "1 rent credit without a receipt", many: "rent credits without a receipt"),
        ]
        if let deposit = report.deposit {
            lines.append(Line(check: .deposit, state: deposit.matches ? .ok : .issue,
                              text: deposit.matches ? "The deposit account matches the terms"
                                : "The deposit account is \(Self.depositOff(deposit, currency: currency))"))
        } else {
            lines.append(Line(check: .deposit, state: .notChecked, text: "Deposit not checked: no deposit account linked"))
        }
        lines.append(line(.recurring, report.missingRecurringCosts.count, ok: "No recurring cost is overdue",
                          one: "1 recurring cost overdue", many: "recurring costs overdue"))
        return lines
    }

    public func select(_ check: Check) { selected = selected == check ? nil : check }
    public func closeCard() { selected = nil }

    /// The selected check's card title and what it lists.
    public static func cardTitle(_ check: Check) -> String {
        switch check {
        case .months: "Months without a receipt"
        case .receipts: "Receipts without a matched credit"
        case .credits: "Rent credits without a receipt"
        case .deposit: "Deposit"
        case .recurring: "Recurring costs overdue"
        }
    }

    public static func cardSubtitle(_ check: Check) -> String {
        switch check {
        case .months: "Months a tenancy ran with no issued receipt covering them"
        case .receipts: "Issued receipts the linked credits don't fully pay"
        case .credits: "Credits in the rent categories not linked to any receipt"
        case .deposit: "The deposit account against the tenancy's terms"
        case .recurring: "Costs that repeat in the history whose next one hasn't come"
        }
    }

    /// A month without a receipt and its tenancy's name (never the tenant's).
    public func monthLine(_ item: PropertyCheckReport.MissingReceiptMonth) -> (month: String, tenancy: String) {
        let format = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()
        return (item.month.start.formatted(format), snapshot.tenancyNames[item.tenancyId] ?? "")
    }

    /// A rent credit's line: "Rent credit · <account>" (its bank description may name the tenant).
    public func creditTitle(_ credit: Transaction) -> String {
        let account = snapshot.accountNames[credit.accountId] ?? ""
        return account.isEmpty ? "Rent credit" : "Rent credit · \(account)"
    }

    // MARK: Deposit

    /// One line of the deposit card.
    public struct DepositLine: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var amountMinorUnits: Int
        public var matches: Bool
    }

    /// In the account, the deposit months × rent, with advance rent; then how far off when neither matches.
    public static func depositLines(_ deposit: PropertyCheckReport.DepositCheck) -> [DepositLine] {
        var lines = [
            DepositLine(id: "held", title: "In the deposit account", amountMinorUnits: deposit.heldMinorUnits, matches: false),
            DepositLine(id: "deposit", title: "Deposit months × rent", amountMinorUnits: deposit.expectedDepositMinorUnits,
                        matches: deposit.matchedInterpretation == .depositOnly),
            DepositLine(id: "advance", title: "With advance rent", amountMinorUnits: deposit.expectedWithAdvanceMinorUnits,
                        matches: deposit.matchedInterpretation == .depositAndAdvanceRent),
        ]
        if !deposit.matches {
            lines.append(DepositLine(id: "difference", title: deposit.differenceMinorUnits < 0 ? "Short by" : "Over by",
                                     amountMinorUnits: abs(deposit.differenceMinorUnits), matches: false))
        }
        return lines
    }

    /// The deposit's pill: which reading it matches, or how far off ("€100.00 short").
    public static func depositPill(_ deposit: PropertyCheckReport.DepositCheck, currency: Currency) -> String {
        switch deposit.matchedInterpretation {
        case .depositAndAdvanceRent: return "Matches with advance rent"
        case .depositOnly: return "Matches the deposit"
        case nil:
            let difference = deposit.differenceMinorUnits
            return "\(Money.format(abs(difference), currency: currency)) \(difference < 0 ? "short" : "over")"
        }
    }

    /// "€100.00 short of the deposit and advance rent" (the Mac's `PropertyCheckSummary.depositOff`).
    public static func depositOff(_ deposit: PropertyCheckReport.DepositCheck, currency: Currency) -> String {
        let difference = deposit.differenceMinorUnits
        let withAdvance = deposit.expectedWithAdvanceMinorUnits != deposit.expectedDepositMinorUnits
            && difference == deposit.heldMinorUnits - deposit.expectedWithAdvanceMinorUnits
        return "\(Money.format(abs(difference), currency: currency)) \(difference < 0 ? "short of" : "over") "
            + (withAdvance ? "the deposit and advance rent" : "the deposit")
    }

    // MARK: Recurring costs

    /// Every recurring cost still expected, overdue ones first; those not expected any more are left out.
    public var recurringCosts: [RecurringCost] {
        let overdue = (snapshot.report?.missingRecurringCosts ?? []).map { RecurringCost(pattern: $0.pattern, overdueSince: $0.expectedDate) }
        return overdue + snapshot.expected.map { RecurringCost(pattern: $0, overdueSince: nil) }
    }

    /// The overdue ones (the recurring check's card).
    public var overdueCosts: [RecurringCost] { recurringCosts.filter(\.isOverdue) }

    /// What a recurring cost offers: "Not expected any more", with Edit on Property.
    public func actions(for cost: RecurringCost) -> [PadChecksAction] {
        write.canEdit ? [.notExpected] : []
    }

    /// The screen's own actions: Missing evidence always; evidence rules and matching with Edit.
    public func screenActions() -> [PadChecksAction] {
        var actions: [PadChecksAction] = [.missingEvidence]
        if write.canEdit, !snapshot.hasEvidenceRules { actions.append(.addEvidenceRules) }
        return actions
    }

    /// The receipts check's action, with Edit.
    public var offersMatchCredits: Bool { write.canEdit }

    /// What a decision on `pattern` reaches: its category on its last payment's day (a filed year's figures when it is
    /// within the rental accounts' reach).
    nonisolated static func scope(_ pattern: PropertyRecurringPattern) -> FiledYearEditCheck.Scope {
        FiledYearEditCheck.Scope(dates: [pattern.lastDate], categoryIds: [pattern.categoryId])
    }

    /// "Not expected any more": the series leaves the checks and the calendar; a toast offers Undo.
    @discardableResult
    public func stopExpecting(_ cost: RecurringCost) async -> Bool {
        guard let propertyId = property.property?.id else { return false }
        let pattern = cost.pattern
        let saved = await write.perform(rowId: cost.rowId, origin: .edit, edit: "\(pattern.title) not expected any more",
                                        scope: Self.scope(pattern)) { db in
            try PropertyCheckDecisions.stopExpecting(db: db, propertyId: propertyId, pattern: pattern)
        }
        if saved {
            toast = Toast(message: "\(pattern.title) is no longer expected.", undo: cost)
            await refresh()
        }
        return saved
    }

    /// The toast's Undo: the series is expected again.
    @discardableResult
    public func undo() async -> Bool {
        guard let cost = toast?.undo, let propertyId = property.property?.id else { return false }
        let series = cost.pattern.series
        let saved = await write.perform(rowId: cost.rowId, origin: .edit, edit: "\(cost.pattern.title) expected again",
                                        scope: Self.scope(cost.pattern)) { db in
            try PropertyCheckDecisions.expectAgain(db: db, propertyId: propertyId, series: series)
        }
        if saved {
            toast = Toast(message: "\(cost.pattern.title) is expected again.", undo: nil)
            await refresh()
        }
        return saved
    }

    public func dismissToast() { toast = nil }

    /// The toast goes by itself after `QuickEditModel.toastSeconds`, unless another took its place.
    func expireToast(_ id: UUID) {
        if toast?.id == id { toast = nil }
    }

    // MARK: Screen actions

    /// Links the property's rent credits to the receipts they paid and says what it did.
    @discardableResult
    public func matchCredits() async -> Bool {
        guard let propertyId = property.property?.id else { return false }
        let result = await write.saving(rowId: Self.screenRow, origin: .propertyMatching, edit: "Rent credits matched to receipts",
                                        scope: .everyYear) { db in
            let result = try RentReceiptMatching.match(db: db, propertyId: propertyId)
            return (result.created.count, result.unmatchedReceipts.count, result.unmatchedCredits.count)
        }
        guard let (created, receipts, credits) = result else { return false }
        info = "Linked \(created) credit\(created == 1 ? "" : "s"). \(receipts) receipt\(receipts == 1 ? "" : "s") and "
            + "\(credits) credit\(credits == 1 ? "" : "s") remain unmatched."
        await refresh()
        return true
    }

    /// Asks for a PDF per rent receipt and a contract per tenancy in Missing evidence.
    @discardableResult
    public func addEvidenceRules() async -> Bool {
        guard let propertyId = property.property?.id else { return false }
        let added = await write.saving(rowId: Self.screenRow, origin: .edit, edit: "Evidence rules added", scope: FiledYearEditCheck.Scope()) { db in
            try PropertyEvidence.seedRules(db: db, propertyId: propertyId).count
        }
        guard let added else { return false }
        info = added == 0 ? "The property's evidence rules are already there."
            : "Added \(added) evidence rule\(added == 1 ? "" : "s"): one PDF per rent receipt, one contract per tenancy."
        await refresh()
        return true
    }

    /// A credit as a search row, for its detail sheet (and the Edit it offers).
    public func creditRow(transactionId: Int64) async -> TransactionSearch.Row? {
        try? await dbQueue.read { db in
            guard let transaction = try Transaction.fetchOne(db, key: transactionId) else { return nil }
            let account = try Account.fetchOne(db, key: transaction.accountId)
            let category = try transaction.categoryId.flatMap { try Category.fetchOne(db, key: $0) }
            return TransactionSearch.Row(transaction: transaction, category: category, categoryName: category?.name ?? "",
                                         accountName: account?.displayName ?? "", currency: account?.currency ?? .gbp,
                                         isLinkedTransfer: false, outgoingTransactionId: nil)
        }
    }

    private func refresh() async {
        isPreloaded = false
        await read()
    }
}
