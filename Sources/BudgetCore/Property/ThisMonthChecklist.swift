import Foundation
import GRDB

/// A tenancy's This-month checklist on the iPad (step 10 Task 9), computed from the Mac's read models and never stored:
/// (1) last month's recharge paid — its statement sent and the tenant's transfer seen; (2) this month's bills — each
/// expected provider's invoice fetched, checked or missing (`UtilityBills`' grid stages, the downloads tray);
/// (3) the charges in the bills grid — automatic once the bills are checked; (4) email the tenant — once 2–3 are done
/// (last month's payment never holds this month's email back), then sent. Beside them: this month's rent receipt and condomínio, the tax year's missing evidence and the
/// downloads waiting.
public struct ThisMonthChecklist: Equatable, Sendable {
    public enum StepID: String, CaseIterable, Sendable {
        case lastRechargePaid, billsIn, chargesInGrid, emailTenant
    }

    public enum StepState: String, Sendable {
        case done
        /// Something for the person to do (the step's actions).
        case needsYou
        /// Nothing to do yet: the tenant, the bank or the Mac comes first.
        case waiting
        /// Doesn't apply this month (a tenancy's first month, nothing recharged, no bills expected).
        case notApplicable
    }

    /// What a step offers. The checklist only reads; each action opens the screen that does it.
    public enum ChecklistAction: Hashable, Sendable {
        /// Fetch a document from a saved site of that kind (the bank's statement, the tax portal's rent receipt).
        case fetchStatement(SavedSiteKind)
        /// Confirm that the tenant credit pays last month's statement (not an exact match).
        case confirmMatch(transactionId: Int64)
        /// Open the provider's site to fetch its invoice.
        case openSite(providerId: Int64)
        /// Check and link a downloaded file (`CheckAndLink`).
        case check(trayItemId: UUID)
        /// Prepare the statement's email to the tenant.
        case prepareEmail(statementId: Int64)
        /// Last month's statement (`lastStatementId`) was paid another way: link the payment by hand.
        case markReceived
    }

    /// One expected provider's bill this month.
    public struct ProviderBill: Equatable, Identifiable, Sendable {
        public enum State: String, Sendable {
            /// Downloaded, waiting in the tray to be checked.
            case fetched
            /// Its invoice is recorded (grid stage invoice in or later).
            case checked
            /// Neither: fetch it from the provider's site.
            case missing
        }

        /// Nil: utility payments no provider explains ("Other utilities").
        public var providerId: Int64?
        public var name: String
        public var kind: UtilityKind
        public var state: State
        /// The bill's grid stage this month (the least advanced), nil when no bill is seen yet.
        public var stage: UtilityBillStage?
        /// The downloads that look like this provider's.
        public var trayItemIds: [UUID]
        public var id: String { UtilityBills.key(providerId) }
    }

    public struct Step: Equatable, Identifiable, Sendable {
        public var id: StepID
        public var state: StepState
        public var headline: String
        public var detail: String?
        public var actions: [ChecklistAction]
        /// Step 2's providers, in the grid's order; empty for the other steps.
        public var providers: [ProviderBill] = []
        /// Step 1 waits on a bank statement sent from the iPad that the Mac hasn't imported yet (its own state:
        /// "Waiting for the Mac to import").
        public var isWaitingForMac = false
    }

    public struct SideItem: Equatable, Identifiable, Sendable {
        public enum Kind: String, Sendable {
            case rentReceipt, condominium
        }

        public var kind: Kind
        public var state: StepState
        public var headline: String
        public var date: Date?
        /// In `currency`, when known (the condomínio's last payment).
        public var amountMinorUnits: Int?
        public var currency: Currency?
        public var actions: [ChecklistAction]
        public var id: String { kind.rawValue }
    }

    public var tenancyId: Int64
    /// The tenancy's name (its reference label), never the tenant's.
    public var tenancyName: String
    /// The first day of this month.
    public var month: Date
    /// The four steps in order; empty when the viewer can't see Property (`isHidden`).
    public var steps: [Step]
    public var side: [SideItem]
    /// The current UK tax year's missing evidence (utilities, kept for the recharges, left out); 0 when the viewer
    /// can't see Documents.
    public var evidenceCount: Int
    /// Files in the downloads tray.
    public var downloadsWaiting: Int
    /// Last month's statement (step 1's), and this month's (step 4's).
    public var lastStatementId: Int64?
    public var statementId: Int64?

    /// The viewer can't see Property: nothing is shown.
    public var isHidden: Bool { steps.isEmpty }

    public func step(_ id: StepID) -> Step? { steps.first { $0.id == id } }
}

extension ThisMonthChecklist {
    /// The checklist for `tenancyId` on `today`. `trayCount` is the downloads tray's size (`DownloadsTray.items().count`);
    /// `trayItems`, when given, lets step 2 tell a provider's downloaded invoice by its file name or site. `viewer`
    /// nil reads everything (the Mac, no sign-in); a member who can't see Property gets a hidden checklist, and the
    /// evidence count needs Documents. Reads only.
    public static func build(db: Database, tenancyId: Int64, today: Date, trayCount: Int, trayItems: [TrayItem] = [],
                             viewer: AccessActor? = nil) throws -> ThisMonthChecklist {
        try build(db: db, tenancyId: tenancyId, today: today, trayCount: trayCount, trayItems: trayItems, viewer: viewer, seesNothing: false)
    }

    /// `build` as a device's screen reads it (`DeviceWriter.readScope`): `.nothing` (her user not known yet, or not
    /// readable) gives a hidden checklist.
    public static func build(db: Database, tenancyId: Int64, today: Date, trayCount: Int, trayItems: [TrayItem] = [],
                             scope: DeviceReadScope) throws -> ThisMonthChecklist {
        try build(db: db, tenancyId: tenancyId, today: today, trayCount: trayCount, trayItems: trayItems, viewer: scope.viewer,
                  seesNothing: scope == .nothing)
    }

    private static func build(db: Database, tenancyId: Int64, today: Date, trayCount: Int, trayItems: [TrayItem],
                              viewer: AccessActor?, seesNothing: Bool) throws -> ThisMonthChecklist {
        guard let tenancy = try Tenancy.fetchOne(db, key: tenancyId) else { throw RechargeError.tenancyNotFound }
        let calendar = MonthRange.calendar
        let day = PropertyDates.day(today)
        let (year, monthNumber) = MonthRange.components(of: day)
        let month = MonthRange.of(year: year, month: monthNumber).start
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: month)!
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: month)!
        var checklist = ThisMonthChecklist(tenancyId: tenancyId, tenancyName: tenancy.referenceLabel, month: month, steps: [], side: [],
                                           evidenceCount: 0, downloadsWaiting: 0)
        func canView(_ area: AccessArea) throws -> Bool {
            guard !seesNothing else { return false }
            guard let viewer else { return true }
            return try AccessPolicy.level(viewer, area, db: db) >= .view
        }
        guard try canView(.property) else { return checklist }
        checklist.downloadsWaiting = trayCount
        if try canView(.documents) {
            checklist.evidenceCount = MissingEvidence.progress(MissingEvidence.affectingTaxFigures(
                try MissingEvidence.items(db: db, taxYear: UKTaxYear.containing(day)))).missing
        }

        let statements = try Recharges.statements(db: db, tenancyId: tenancyId)
        let last = statements.first { $0.month == lastMonth }
        let current = statements.first { $0.month == month }
        checklist.lastStatementId = last?.id
        checklist.statementId = current?.id

        // Not running at all this month: nothing to do but last month's recharge, if any.
        if tenancy.startDate >= nextMonth {
            checklist.steps = StepID.allCases.map { Step(id: $0, state: .notApplicable, headline: headline($0, month: month, tenancy: tenancy),
                                                         detail: ThisMonthCopy.notStarted, actions: []) }
            return checklist
        }
        let step1 = try lastRechargeStep(db: db, tenancy: tenancy, month: month, lastMonth: lastMonth, statement: last, today: day)
        let runsThisMonth = tenancy.endDate.map { $0 >= month } ?? true
        guard runsThisMonth else {
            checklist.steps = [step1] + [StepID.billsIn, .chargesInGrid, .emailTenant].map {
                Step(id: $0, state: .notApplicable, headline: headline($0, month: month, tenancy: tenancy), detail: ThisMonthCopy.ended, actions: [])
            }
            return checklist
        }
        let step2 = try billsStep(db: db, tenancy: tenancy, month: month, trayItems: trayItems)
        let step3 = chargesStep(after: step2, month: month)
        let currency = try Property.fetchOne(db, key: tenancy.propertyId)?.currency ?? .eur
        let step4 = emailStep(tenancy: tenancy, statement: current, currency: currency, before: [step2, step3])
        checklist.steps = [step1, step2, step3, step4]
        checklist.side = try sideItems(db: db, tenancy: tenancy, month: month, nextMonth: nextMonth, today: day)
        return checklist
    }

    static func headline(_ id: StepID, month: Date, tenancy: Tenancy) -> String {
        switch id {
        case .lastRechargePaid: return ThisMonthCopy.rechargePaidTitle(MonthRange.calendar.date(byAdding: .month, value: -1, to: month)!)
        case .billsIn: return ThisMonthCopy.billsTitle(month)
        case .chargesInGrid: return ThisMonthCopy.chargesTitle
        case .emailTenant: return ThisMonthCopy.emailTitle(tenancy.referenceLabel)
        }
    }

    // MARK: Step 1

    /// Last month's statement paid: done once its payment links cover it, or once tenant credits in its payment window
    /// (from the day it was sent, else the month after its month, `Recharges.paymentWindowDays`) leave exactly what it
    /// still needs — one credit or two adding up (`Recharges.matchPayments` links the single ones on the Mac). A credit's
    /// part for the recharge is what its rent links and other recharge links leave; a credit with no rent link yet is
    /// taken to carry the month's rent first. Any other credit with something left is offered to confirm. None: waiting
    /// for the Mac to import a statement sent from the iPad, else for the tenant's transfer (fetch the bank statement
    /// when the bank's movements stop before the window) — or, once the bank's movements pass the window, mark it received.
    static func lastRechargeStep(db: Database, tenancy: Tenancy, month: Date, lastMonth: Date, statement: RechargeStatement?,
                                 today: Date) throws -> Step {
        func step(_ state: StepState, _ detail: String?, _ actions: [ChecklistAction] = []) -> Step {
            Step(id: .lastRechargePaid, state: state, headline: ThisMonthCopy.rechargePaidTitle(lastMonth), detail: detail, actions: actions)
        }
        guard tenancy.startDate < month else { return step(.notApplicable, ThisMonthCopy.firstMonth) }
        guard let statement, let statementId = statement.id, statement.totalMinorUnits > 0 else {
            return step(.notApplicable, ThisMonthCopy.nothingRecharged(lastMonth))
        }
        switch statement.status {
        case .paid: return step(.done, ThisMonthCopy.paid)
        case .draft: return step(.needsYou, ThisMonthCopy.notSentYet(lastMonth), [.prepareEmail(statementId: statementId)])
        case .sent: break
        }
        let currency = try Property.fetchOne(db, key: tenancy.propertyId)?.currency ?? .eur
        func money(_ minorUnits: Int) -> String { Money.format(minorUnits, currency: currency) }
        let needed = try Recharges.outstanding(db: db, statementId: statementId)
        guard needed > 0 else { return step(.done, ThisMonthCopy.paid) }

        let calendar = MonthRange.calendar
        let from = statement.sentAt.map(PropertyDates.day) ?? calendar.date(byAdding: .month, value: 1, to: statement.month)!
        let windowEnd = calendar.date(byAdding: .day, value: Recharges.paymentWindowDays + 1, to: from)!
        let to = min(windowEnd, PropertyDates.nextDay(today))
        let rentLinked = Set(try Int64.fetchAll(db, sql: "SELECT transactionId FROM rentReceiptPayment WHERE isDismissed = 0"))
        var left: [(credit: Transaction, amount: Int)] = []
        for credit in try RentReceiptMatching.candidateCredits(db: db, propertyId: tenancy.propertyId)
        where credit.date >= from && credit.date < to {
            guard try !Recharges.isDismissed(db: db, statementId: statementId, transactionId: credit.id!) else { continue }
            var amount = try Recharges.creditRemainder(db: db, transactionId: credit.id!)
            if !rentLinked.contains(credit.id!), let rent = try Tenancies.rent(db: db, tenancyId: tenancy.id!, at: PropertyDates.day(credit.date)),
               rent > 0, amount >= rent {
                amount -= rent
            }
            if amount > 0 { left.append((credit, amount)) }
        }
        if let exact = left.first(where: { $0.amount == needed }) {
            return step(.done, ThisMonthCopy.paidBy(transfers: [(money(exact.amount), PropertyDates.day(exact.credit.date))]))
        }
        for (i, a) in left.enumerated() {
            if let b = left[(i + 1)...].first(where: { a.amount + $0.amount == needed }) {
                return step(.done, ThisMonthCopy.paidBy(transfers: [(money(a.amount), PropertyDates.day(a.credit.date)),
                                                                     (money(b.amount), PropertyDates.day(b.credit.date))]))
            }
        }
        if let nearest = left.min(by: { (abs($0.amount - needed), $0.credit.date) < (abs($1.amount - needed), $1.credit.date) }) {
            return step(.needsYou, ThisMonthCopy.confirmMatch(transfer: money(nearest.amount), day: PropertyDates.day(nearest.credit.date),
                                                             statement: money(needed)),
                        [.confirmMatch(transactionId: nearest.credit.id!)])
        }

        // No transfer seen: a statement sent from the iPad the Mac hasn't imported yet, else how far the bank's movements go.
        let sentFromPad = try ImportWaitingFile.filter(Column("importedRunId") == nil && Column("reason") == CheckAndLinkCopy.sentReason).fetchCount(db)
        if sentFromPad > 0 {
            var waiting = step(.waiting, ThisMonthCopy.waitingForMac)
            waiting.isWaitingForMac = true
            return waiting
        }
        let accountIds = try Properties.accounts(db: db, propertyId: tenancy.propertyId, role: .current).map(\.accountId)
        let latest = accountIds.isEmpty ? nil : try Transaction.filter(accountIds.contains(Column("accountId")))
            .select(GRDB.max(Column("date")), as: Date.self).fetchOne(db)
        if let latest, PropertyDates.day(latest) >= calendar.date(byAdding: .day, value: -1, to: windowEnd)! {
            return step(.needsYou, ThisMonthCopy.noTransferSeen(money(needed)), [.markReceived])
        }
        if latest.map({ PropertyDates.day($0) < from }) ?? true {
            return step(.waiting, ThisMonthCopy.fetchStatement(from), [.fetchStatement(.bank)])
        }
        return step(.waiting, ThisMonthCopy.waitingForTransfer, [.fetchStatement(.bank)])
    }

    // MARK: Step 2

    /// The providers expected this month: those with a bill in the grid this month, and those whose bills over the
    /// year before come at a steady gap (the median, 1 to 12 months) that falls due by this month — not more than two
    /// gaps after the last (a provider that stopped, or changed). Each is checked when its bills this month are all
    /// at invoice in or later, fetched when a download looks like its invoice, else missing.
    static func billsStep(db: Database, tenancy: Tenancy, month: Date, trayItems: [TrayItem]) throws -> Step {
        let grid = try UtilityBills.read(db: db, propertyId: tenancy.propertyId, tenancyId: tenancy.id!)
        let calendar = MonthRange.calendar
        let yearBefore = calendar.date(byAdding: .month, value: -12, to: month)!
        func monthsBetween(_ a: Date, _ b: Date) -> Int { calendar.dateComponents([.month], from: a, to: b).month ?? 0 }

        var providers: [ProviderBill] = []
        for row in grid.rows {
            let bills = grid.bills.filter { $0.providerId == row.providerId }
            let thisMonth = bills.filter { $0.month == month }
            var expected = !thisMonth.isEmpty
            if !expected, row.providerId != nil {
                let earlier = Array(Set(bills.map(\.month).filter { $0 >= yearBefore && $0 < month })).sorted()
                if earlier.count >= 2, let lastBill = earlier.last {
                    let gaps = zip(earlier.dropFirst(), earlier).map { monthsBetween($1, $0) }.sorted()
                    let gap = gaps[gaps.count / 2]
                    let since = monthsBetween(lastBill, month)
                    expected = (1...12).contains(gap) && since >= gap && since <= 2 * gap
                }
            }
            guard expected else { continue }
            let stage = thisMonth.map(\.stage).min()
            let fetched = row.providerId == nil ? [] : trayItems.filter { looksLike($0, provider: row.name) }.map(\.id)
            let state: ProviderBill.State = stage.map { $0 >= .invoiceIn } ?? false ? .checked : fetched.isEmpty ? .missing : .fetched
            providers.append(ProviderBill(providerId: row.providerId, name: row.name, kind: row.kind, state: state, stage: stage,
                                          trayItemIds: state == .fetched ? fetched : []))
        }
        let headline = ThisMonthCopy.billsTitle(month)
        guard !providers.isEmpty else {
            return Step(id: .billsIn, state: .notApplicable, headline: headline, detail: ThisMonthCopy.noBillsExpected, actions: [])
        }
        let checked = providers.filter { $0.state == .checked }.count
        let fetched = providers.filter { $0.state == .fetched }
        let missing = providers.filter { $0.state == .missing }
        var actions: [ChecklistAction] = fetched.flatMap { $0.trayItemIds.map { ChecklistAction.check(trayItemId: $0) } }
        actions += missing.compactMap { $0.providerId.map { ChecklistAction.openSite(providerId: $0) } }
        let progress = ThisMonthCopy.billsChecked(checked, of: providers.count)
        let detail = [progress, ThisMonthCopy.billsDetail(fetched: fetched.count, missing: missing.count)].compactMap { $0 }.joined(separator: " · ")
        return Step(id: .billsIn, state: checked == providers.count ? .done : .needsYou, headline: headline, detail: detail,
                    actions: actions, providers: providers)
    }

    /// Whether a download's file name or site names the provider: its name with only letters and digits, or one of
    /// its words of three letters or more, as a word of the file name or a label of the site's host.
    static func looksLike(_ item: TrayItem, provider: String) -> Bool {
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        func words(_ text: String) -> [String] { folded(text).split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let names = words(provider)
        guard !names.isEmpty else { return false }
        let whole = names.joined()
        let seen = Set(words(item.fileName) + words(item.sourceHost ?? ""))
        let compact = folded(item.fileName + " " + (item.sourceHost ?? "")).filter { $0.isLetter || $0.isNumber }
        return compact.contains(whole) || names.contains { $0.count >= 3 && seen.contains($0) && !genericWords.contains($0) }
    }

    /// Words too common in providers' names to tell one from another.
    static let genericWords: Set<String> = ["the", "and", "energia", "energy", "power", "water", "agua", "gas", "electricity", "www", "com",
                                            "pdf", "invoice", "fatura", "factura", "example"]

    // MARK: Step 3

    /// Automatic: done once every expected bill is checked (it joins the grid and the statement as it is saved).
    static func chargesStep(after bills: Step, month: Date) -> Step {
        let headline = ThisMonthCopy.chargesTitle
        switch bills.state {
        case .notApplicable: return Step(id: .chargesInGrid, state: .notApplicable, headline: headline, detail: ThisMonthCopy.noBillsExpected, actions: [])
        case .done: return Step(id: .chargesInGrid, state: .done, headline: headline, detail: ThisMonthCopy.chargesIn(bills.providers.count), actions: [])
        case .needsYou, .waiting: return Step(id: .chargesInGrid, state: .waiting, headline: headline, detail: ThisMonthCopy.chargesAutomatic, actions: [])
        }
    }

    // MARK: Step 4

    /// Done once this month's statement is sent (or paid). Before that, waiting until steps 2–3 are each done or not
    /// applicable (step 1, last month's payment, doesn't hold it back); then the draft with charges on it is to email.
    static func emailStep(tenancy: Tenancy, statement: RechargeStatement?, currency: Currency, before: [Step]) -> Step {
        func step(_ state: StepState, _ detail: String?, _ actions: [ChecklistAction] = []) -> Step {
            Step(id: .emailTenant, state: state, headline: ThisMonthCopy.emailTitle(tenancy.referenceLabel), detail: detail, actions: actions)
        }
        if let statement, statement.status != .draft { return step(.done, ThisMonthCopy.sentOn(statement.sentAt)) }
        guard before.allSatisfy({ $0.state == .done || $0.state == .notApplicable }) else { return step(.waiting, ThisMonthCopy.afterSteps) }
        if let statement, let id = statement.id, statement.totalMinorUnits != 0 {
            return step(.needsYou, ThisMonthCopy.readyToSend(Money.format(statement.totalMinorUnits, currency: currency)), [.prepareEmail(statementId: id)])
        }
        let nothingExpected = before.first { $0.id == .billsIn }?.state == .notApplicable
        return nothingExpected ? step(.notApplicable, ThisMonthCopy.nothingToRecharge) : step(.waiting, ThisMonthCopy.noChargesYet)
    }

    // MARK: Side column

    /// This month's rent receipt (issued, else to fetch from the tax portal) and the condomínio (the property's
    /// recurring cost of that name: paid this month, else due this month).
    static func sideItems(db: Database, tenancy: Tenancy, month: Date, nextMonth: Date, today: Date) throws -> [SideItem] {
        var items: [SideItem] = []
        let interval = DateInterval(start: month, end: nextMonth)
        switch try PropertyGlance.receiptStatus(db: db, running: tenancy, thisMonth: interval) {
        case .issued:
            items.append(SideItem(kind: .rentReceipt, state: .done, headline: ThisMonthCopy.rentReceiptIn, actions: []))
        case .pending:
            items.append(SideItem(kind: .rentReceipt, state: .needsYou, headline: ThisMonthCopy.fetchRentReceipt, actions: [.fetchStatement(.tax)]))
        case .none:
            break
        }
        let calendar = MonthRange.calendar
        let patterns = try PropertyCalendar.recurringPatterns(db: db, propertyId: tenancy.propertyId, asOf: today)
        if let condominium = patterns.first(where: { PropertyCalendar.words($0.title).contains { $0.hasPrefix("condom") } }) {
            if interval.contains(condominium.lastDate) {
                items.append(SideItem(kind: .condominium, state: .done, headline: ThisMonthCopy.condominiumPaid(condominium.lastDate),
                                      date: condominium.lastDate, amountMinorUnits: condominium.lastAmountMinorUnits,
                                      currency: condominium.currency, actions: []))
            } else {
                var k = 1
                while let due = calendar.date(byAdding: .month, value: k * condominium.everyMonths, to: condominium.lastDate), due < nextMonth {
                    if due >= month {
                        items.append(SideItem(kind: .condominium, state: due <= today ? .needsYou : .waiting,
                                              headline: ThisMonthCopy.condominiumDue(due), date: due,
                                              amountMinorUnits: condominium.lastAmountMinorUnits, currency: condominium.currency, actions: []))
                        break
                    }
                    k += 1
                }
            }
        }
        return items
    }
}
