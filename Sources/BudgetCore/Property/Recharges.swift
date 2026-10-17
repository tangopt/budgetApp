import GRDB
import Foundation

public enum RechargeError: Error, Equatable {
    case propertyNotFound
    case tenancyNotFound
    case providerNotFound
    case invoiceNotFound
    case statementNotFound
    case transactionNotFound
    case blankName
    case duplicateName
    case duplicateInvoiceNumber
    /// A period with only one end, or ending before it starts.
    case invalidPeriod
    /// Lines can only change while the statement is a draft.
    case statementNotDraft
    /// Only a sent (or paid) statement takes payments.
    case statementNotSent
    /// The statement has payments: unlink them first.
    case statementHasPayments
    /// The invoice is on a statement: remove the line first.
    case invoiceOnStatement
    /// The invoice is on a sent or paid statement: its provider, amount and period are fixed.
    case invoiceOnSentStatement
    /// A later month's statement exists: statements are drafted in month order.
    case laterStatementExists
    /// The bank movement already settles another invoice.
    case transactionOnAnotherInvoice
    /// A provider's invoice-number pattern isn't a valid regular expression.
    case invalidPattern(String)
    /// The invoice belongs to another property's provider.
    case invoiceNotForTenancy
    /// The lines of an invoice would recharge more than it charges.
    case overRecharged
    /// A manual line needs a description.
    case blankDescription
    case lineNotFound
    case documentNotFound
    /// Only credits (positive amounts) pay statements.
    case notACredit
    case nothingAllocated
    /// The credit's rent and recharge parts would exceed its amount.
    case overAllocated
    /// The payment would exceed what the statement still needs.
    case exceedsStatement
}

/// Tenant utility recharges (plan phase 5 Task 1): providers and invoices, the monthly
/// statement, and the split of each tenant credit into rent + recharge.
///
/// Rules (mirroring the user's tracker: every invoice is recharged in full at its invoice
/// amount, refunds included as negatives, the first invoice of a tenancy pro rata to its days):
/// - An invoice belongs to a tenancy when its period overlaps the tenancy (no period: its
///   recharge date falls in the tenancy). The tenancy's share is the whole invoice, or the
///   tenancy's days of the period when the period runs past the tenancy's start or end.
/// - Its recharge date is its bank debit's date (the tracker lists invoices by the day they're
///   debited), else — not matched to a debit yet — its issue date.
/// - A month's statement takes every invoice of the tenancy with a recharge date up to the
///   month's last day that isn't on one of the tenancy's statements yet: "issued (or debited)
///   since the last statement", late arrivals included.
/// - The tenant pays it with the next transfer: the credit's rent part is its rent receipt
///   links, the rest (up to the statement's outstanding amount) its recharge part.
public enum Recharges {
    // MARK: Providers

    /// Inserts or updates the provider (trimmed name, unique per property; blank optionals cleared).
    public static func saveProvider(db: Database, _ provider: inout UtilityProvider) throws {
        provider.name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.name.isEmpty else { throw RechargeError.blankName }
        guard try Property.exists(db, key: provider.propertyId) else { throw RechargeError.propertyNotFound }
        provider.accountReference = Transaction.normalizedNote(provider.accountReference)
        provider.bankDescriptionPattern = Transaction.normalizedNote(provider.bankDescriptionPattern)
        provider.notes = Transaction.normalizedNote(provider.notes)
        for pattern in provider.invoiceRules?.invoiceNumberPatterns ?? [] where (try? NSRegularExpression(pattern: pattern)) == nil {
            throw RechargeError.invalidPattern(pattern)
        }
        var clash = UtilityProvider.filter(sql: "propertyId = ? AND name = ? COLLATE NOCASE", arguments: [provider.propertyId, provider.name])
        if let id = provider.id { clash = clash.filter(Column("id") != id) }
        guard try clash.fetchCount(db) == 0 else { throw RechargeError.duplicateName }
        try provider.save(db)
    }

    /// The property's providers, by kind then name.
    public static func providers(db: Database, propertyId: Int64) throws -> [UtilityProvider] {
        try UtilityProvider.filter(Column("propertyId") == propertyId).fetchAll(db)
            .sorted { (UtilityKind.allCases.firstIndex(of: $0.kind)!, $0.name.lowercased()) < (UtilityKind.allCases.firstIndex(of: $1.kind)!, $1.name.lowercased()) }
    }

    /// Deletes the provider and its invoices; refused while one of them is on a statement.
    @discardableResult
    public static func deleteProvider(db: Database, id: Int64) throws -> Bool {
        let onStatements = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM rechargeLine JOIN utilityInvoice ON utilityInvoice.id = rechargeLine.invoiceId
            WHERE utilityInvoice.providerId = ?
            """, arguments: [id]) ?? 0
        guard onStatements == 0 else { throw RechargeError.invoiceOnStatement }
        return try UtilityProvider.deleteOne(db, key: id)
    }

    // MARK: Invoices

    /// Inserts or updates the invoice: days normalised, period both-or-neither and in order,
    /// invoice number trimmed and unique per provider.
    public static func saveInvoice(db: Database, _ invoice: inout UtilityInvoice) throws {
        guard try UtilityProvider.exists(db, key: invoice.providerId) else { throw RechargeError.providerNotFound }
        invoice.invoiceNumber = Transaction.normalizedNote(invoice.invoiceNumber)
        invoice.notes = Transaction.normalizedNote(invoice.notes)
        invoice.issueDate = PropertyDates.day(invoice.issueDate)
        invoice.periodStart = invoice.periodStart.map(PropertyDates.day)
        invoice.periodEnd = invoice.periodEnd.map(PropertyDates.day)
        switch (invoice.periodStart, invoice.periodEnd) {
        case (nil, nil): break
        case let (start?, end?) where start <= end: break
        default: throw RechargeError.invalidPeriod
        }
        if let number = invoice.invoiceNumber {
            var clash = UtilityInvoice.filter(Column("providerId") == invoice.providerId && Column("invoiceNumber") == number)
            if let id = invoice.id { clash = clash.filter(Column("id") != id) }
            guard try clash.fetchCount(db) == 0 else { throw RechargeError.duplicateInvoiceNumber }
        }
        if let transactionId = invoice.transactionId {
            guard try Transaction.exists(db, key: transactionId) else { throw RechargeError.transactionNotFound }
            var other = UtilityInvoice.filter(Column("transactionId") == transactionId)
            if let id = invoice.id { other = other.filter(Column("id") != id) }
            guard try other.fetchCount(db) == 0 else { throw RechargeError.transactionOnAnotherInvoice }
        }
        let before = try invoice.id.flatMap { try UtilityInvoice.fetchOne(db, key: $0) }
        let recharged = before.map { $0.providerId != invoice.providerId || $0.amountMinorUnits != invoice.amountMinorUnits
            || $0.periodStart != invoice.periodStart || $0.periodEnd != invoice.periodEnd || $0.issueDate != invoice.issueDate
            || $0.transactionId != invoice.transactionId } ?? false
        if recharged, let id = invoice.id {
            let fixed = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM rechargeLine JOIN rechargeStatement ON rechargeStatement.id = rechargeLine.statementId
                WHERE rechargeLine.invoiceId = ? AND rechargeStatement.status != ?
                """, arguments: [id, RechargeStatementStatus.draft.rawValue]) ?? 0
            let changesCharge = before.map { $0.providerId != invoice.providerId || $0.amountMinorUnits != invoice.amountMinorUnits
                || $0.periodStart != invoice.periodStart || $0.periodEnd != invoice.periodEnd } ?? false
            guard fixed == 0 || !changesCharge else { throw RechargeError.invoiceOnSentStatement }
        }
        try invoice.save(db)
        // Draft lines follow the invoice: its tenancy share again (or off the draft when it no
        // longer belongs to the tenancy).
        if recharged, let id = invoice.id {
            let drafts = try RechargeLine.fetchAll(db, sql: """
                SELECT rechargeLine.* FROM rechargeLine JOIN rechargeStatement ON rechargeStatement.id = rechargeLine.statementId
                WHERE rechargeLine.invoiceId = ? AND rechargeStatement.status = ?
                """, arguments: [id, RechargeStatementStatus.draft.rawValue])
            let providerProperty = try UtilityProvider.fetchOne(db, key: invoice.providerId)?.propertyId
            for var line in drafts {
                guard let statement = try RechargeStatement.fetchOne(db, key: line.statementId),
                      let tenancy = try Tenancy.fetchOne(db, key: statement.tenancyId) else { continue }
                // Off the draft when it's now another property's invoice, or not the tenancy's.
                if providerProperty == tenancy.propertyId,
                   let share = share(of: invoice, rechargeDate: try rechargeDate(db: db, invoice), tenancy: tenancy) {
                    // Never more than other statements leave of it.
                    let left = invoice.amountMinorUnits - (try Self.recharged(db: db, invoiceId: id, excludingStatement: line.statementId))
                    line.amountMinorUnits = invoice.amountMinorUnits >= 0 ? min(share.amount, max(0, left)) : max(share.amount, min(0, left))
                    line.daysInTenancy = share.days?.inside
                    line.daysInPeriod = share.days?.total
                    line.note = share.note
                    try line.update(db)
                } else {
                    try line.delete(db)
                }
                try refreshTotal(db: db, statementId: line.statementId)
            }
        }
    }

    /// Deletes the invoice; refused while it's on a statement.
    @discardableResult
    public static func deleteInvoice(db: Database, id: Int64) throws -> Bool {
        guard try RechargeLine.filter(Column("invoiceId") == id).fetchCount(db) == 0 else { throw RechargeError.invoiceOnStatement }
        return try UtilityInvoice.deleteOne(db, key: id)
    }

    /// The property's invoices, by issue date.
    public static func invoices(db: Database, propertyId: Int64) throws -> [UtilityInvoice] {
        try UtilityInvoice.fetchAll(db, sql: """
            SELECT utilityInvoice.* FROM utilityInvoice JOIN utilityProvider ON utilityProvider.id = utilityInvoice.providerId
            WHERE utilityProvider.propertyId = ? ORDER BY utilityInvoice.issueDate, utilityInvoice.id
            """, arguments: [propertyId])
    }

    /// The debit's day, else the issue date.
    public static func rechargeDate(db: Database, _ invoice: UtilityInvoice) throws -> Date {
        guard let id = invoice.transactionId, let debit = try Transaction.fetchOne(db, key: id) else { return invoice.issueDate }
        return PropertyDates.day(debit.date)
    }

    /// The tenancy's part of an invoice and why, `nil` when the invoice isn't the tenancy's.
    struct Share {
        var amount: Int
        var note: String?
        var days: (inside: Int, total: Int)?
    }

    static func share(of invoice: UtilityInvoice, rechargeDate: Date, tenancy: Tenancy) -> Share? {
        guard let start = invoice.periodStart, let end = invoice.periodEnd else {
            return tenancy.covers(rechargeDate) ? Share(amount: invoice.amountMinorUnits) : nil
        }
        let from = max(start, tenancy.startDate)
        let to = min(end, tenancy.endDate ?? end)
        guard from <= to else { return nil }
        if from == start && to == end { return Share(amount: invoice.amountMinorUnits) }
        let total = PropertyFinance.days(start, PropertyDates.nextDay(end))
        let inside = PropertyFinance.days(from, PropertyDates.nextDay(to))
        // Rounded cumulatively from the period's start, so the tenancies' shares add up exactly.
        func upTo(_ day: Date) -> Int {
            Int((Double(invoice.amountMinorUnits) * Double(PropertyFinance.days(start, day)) / Double(total)).rounded())
        }
        let amount = upTo(PropertyDates.nextDay(to)) - upTo(from)
        return Share(amount: amount, note: "\(inside) of \(total) days in the tenancy", days: (inside, total))
    }

    /// An invoice the tenancy's next statement would take.
    public struct PendingLine: Equatable, Sendable {
        public var invoice: UtilityInvoice
        public var rechargeDate: Date
        public var amountMinorUnits: Int
        public var note: String?
        public var daysInTenancy: Int?
        public var daysInPeriod: Int?
    }

    /// The tenancy's invoices with a recharge date up to `through` (a day, inclusive) that
    /// aren't on any of its statements, by recharge date, each at the tenancy's share capped
    /// by what other statements (another tenancy's) leave of it; nothing left: left out.
    public static func pendingLines(db: Database, tenancyId: Int64, through: Date) throws -> [PendingLine] {
        guard let tenancy = try Tenancy.fetchOne(db, key: tenancyId) else { throw RechargeError.tenancyNotFound }
        let taken = Set(try Int64.fetchAll(db, sql: """
            SELECT rechargeLine.invoiceId FROM rechargeLine JOIN rechargeStatement ON rechargeStatement.id = rechargeLine.statementId
            WHERE rechargeStatement.tenancyId = ? AND rechargeLine.invoiceId IS NOT NULL
            """, arguments: [tenancyId]))
        let cutoff = PropertyDates.day(through)
        var lines: [PendingLine] = []
        for invoice in try invoices(db: db, propertyId: tenancy.propertyId) where !taken.contains(invoice.id!) {
            let date = try rechargeDate(db: db, invoice)
            guard date <= cutoff, let share = share(of: invoice, rechargeDate: date, tenancy: tenancy) else { continue }
            let left = invoice.amountMinorUnits - (try recharged(db: db, invoiceId: invoice.id!, excludingStatement: -1))
            let amount = invoice.amountMinorUnits >= 0 ? min(share.amount, max(0, left)) : max(share.amount, min(0, left))
            guard amount != 0 || invoice.amountMinorUnits == 0 else { continue }
            lines.append(PendingLine(invoice: invoice, rechargeDate: date, amountMinorUnits: amount, note: share.note,
                                     daysInTenancy: share.days?.inside, daysInPeriod: share.days?.total))
        }
        return lines.sorted { ($0.rechargeDate, $0.invoice.id!) < ($1.rechargeDate, $1.invoice.id!) }
    }

    // MARK: Statements

    /// The tenancy's statement for the month of `month`, created when there is none, with every
    /// pending invoice up to the month's last day added (unless `addPending` is false: the
    /// statement sheet adds the lines the user ticked). A sent or paid statement is returned
    /// unchanged.
    @discardableResult
    public static func draftStatement(db: Database, tenancyId: Int64, month: Date, addPending: Bool = true) throws -> RechargeStatement {
        guard try Tenancy.exists(db, key: tenancyId) else { throw RechargeError.tenancyNotFound }
        let (year, monthNumber) = MonthRange.components(of: month)
        let first = MonthRange.of(year: year, month: monthNumber).start
        var statement = try RechargeStatement.filter(Column("tenancyId") == tenancyId && Column("month") == first).fetchOne(db)
            ?? RechargeStatement(tenancyId: tenancyId, month: first)
        guard statement.status == .draft else { return statement }
        if statement.id == nil {
            // A new month before an existing one would take invoices the later one should have.
            guard try RechargeStatement.filter(Column("tenancyId") == tenancyId && Column("month") > first).fetchCount(db) == 0 else {
                throw RechargeError.laterStatementExists
            }
            try statement.insert(db)
        }
        let lastDay = MonthRange.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: first)!
        for pending in addPending ? try pendingLines(db: db, tenancyId: tenancyId, through: lastDay) : [] {
            var line = RechargeLine(statementId: statement.id!, invoiceId: pending.invoice.id!, amountMinorUnits: pending.amountMinorUnits,
                                    note: pending.note)
            line.daysInTenancy = pending.daysInTenancy
            line.daysInPeriod = pending.daysInPeriod
            try line.insert(db)
        }
        return try refreshTotal(db: db, statementId: statement.id!)
    }

    /// Adds (or changes) a line of a draft statement: the invoice must be the tenancy's
    /// property's and its lines on all statements can't recharge more than it charges.
    @discardableResult
    public static func setLine(db: Database, statementId: Int64, invoiceId: Int64, amountMinorUnits: Int? = nil,
                               note: String? = nil) throws -> RechargeLine {
        let statement = try draft(db: db, statementId)
        guard let invoice = try UtilityInvoice.fetchOne(db, key: invoiceId) else { throw RechargeError.invoiceNotFound }
        guard let tenancy = try Tenancy.fetchOne(db, key: statement.tenancyId),
              let provider = try UtilityProvider.fetchOne(db, key: invoice.providerId),
              provider.propertyId == tenancy.propertyId else { throw RechargeError.invoiceNotForTenancy }
        let elsewhere = try recharged(db: db, invoiceId: invoiceId, excludingStatement: statementId)
        // Default: the tenancy's share (else what's left of the invoice), within what's left.
        let left = invoice.amountMinorUnits - elsewhere
        let tenancyShare = share(of: invoice, rechargeDate: try rechargeDate(db: db, invoice), tenancy: tenancy)
        let shareAmount = tenancyShare?.amount ?? left
        let amount = amountMinorUnits ?? (invoice.amountMinorUnits >= 0 ? min(shareAmount, left) : max(shareAmount, left))
        let total = elsewhere + amount
        let fits = invoice.amountMinorUnits >= 0 ? (amount >= 0 && total <= invoice.amountMinorUnits)
                                                 : (amount <= 0 && total >= invoice.amountMinorUnits)
        guard fits else { throw RechargeError.overRecharged }
        var line = try RechargeLine.filter(Column("statementId") == statementId && Column("invoiceId") == invoiceId).fetchOne(db)
            ?? RechargeLine(statementId: statementId, invoiceId: invoiceId, amountMinorUnits: amount)
        line.amountMinorUnits = amount
        line.note = Transaction.normalizedNote(note)
        // The proration days when the line is the tenancy's prorated share.
        let prorated = tenancyShare?.days != nil && amount == tenancyShare?.amount
        line.daysInTenancy = prorated ? tenancyShare?.days?.inside : nil
        line.daysInPeriod = prorated ? tenancyShare?.days?.total : nil
        try line.save(db)
        try refreshTotal(db: db, statementId: statementId)
        return line
    }

    /// Adds a manual line (a one-off charge, or a refund with a negative amount) to a draft
    /// statement, or changes it when `lineId` is given.
    @discardableResult
    public static func saveManualLine(db: Database, statementId: Int64, lineId: Int64? = nil, description: String, amountMinorUnits: Int,
                                      documentId: Int64? = nil, note: String? = nil) throws -> RechargeLine {
        _ = try draft(db: db, statementId)
        guard let text = Transaction.normalizedNote(description) else { throw RechargeError.blankDescription }
        if let documentId, try !EvidenceDocument.exists(db, key: documentId) { throw RechargeError.documentNotFound }
        var line: RechargeLine
        if let lineId {
            guard let existing = try RechargeLine.fetchOne(db, key: lineId), existing.statementId == statementId, existing.isManual else {
                throw RechargeError.lineNotFound
            }
            line = existing
        } else {
            line = RechargeLine(statementId: statementId, invoiceId: nil, amountMinorUnits: amountMinorUnits)
        }
        line.lineDescription = text
        line.amountMinorUnits = amountMinorUnits
        line.documentId = documentId
        line.note = Transaction.normalizedNote(note)
        try line.save(db)
        try refreshTotal(db: db, statementId: statementId)
        return line
    }

    /// Removes any line (invoice or manual) of a draft statement; `false` when there was none.
    @discardableResult
    public static func removeLine(db: Database, lineId: Int64) throws -> Bool {
        guard let line = try RechargeLine.fetchOne(db, key: lineId) else { return false }
        _ = try draft(db: db, line.statementId)
        try line.delete(db)
        try refreshTotal(db: db, statementId: line.statementId)
        return true
    }

    /// Removes an invoice from a draft statement; `false` when it wasn't on it.
    @discardableResult
    public static func removeLine(db: Database, statementId: Int64, invoiceId: Int64) throws -> Bool {
        _ = try draft(db: db, statementId)
        let removed = try RechargeLine.filter(Column("statementId") == statementId && Column("invoiceId") == invoiceId).deleteAll(db) > 0
        try refreshTotal(db: db, statementId: statementId)
        return removed
    }

    /// Marks a draft statement sent (its lines are then fixed). One with nothing to pay (a zero
    /// or negative total: refunds owed to the tenant) is settled at once (paid).
    @discardableResult
    public static func markSent(db: Database, statementId: Int64, at date: Date) throws -> RechargeStatement {
        var statement = try draft(db: db, statementId)
        statement.status = .sent
        statement.sentAt = date
        try statement.update(db)
        try refreshStatus(db: db, statementId: statementId)
        return try RechargeStatement.fetchOne(db, key: statementId)!
    }

    /// Back to draft, while no credit pays it.
    @discardableResult
    public static func reopen(db: Database, statementId: Int64) throws -> RechargeStatement {
        guard var statement = try RechargeStatement.fetchOne(db, key: statementId) else { throw RechargeError.statementNotFound }
        guard try RechargePayment.filter(Column("statementId") == statementId && Column("isDismissed") == false).fetchCount(db) == 0 else {
            throw RechargeError.statementHasPayments
        }
        statement.status = .draft
        statement.sentAt = nil
        try statement.update(db)
        return statement
    }

    /// Deletes a draft statement (its invoices become pending again).
    @discardableResult
    public static func deleteStatement(db: Database, id: Int64) throws -> Bool {
        _ = try draft(db: db, id)
        return try RechargeStatement.deleteOne(db, key: id)
    }

    /// The tenancy's statements, latest month first.
    public static func statements(db: Database, tenancyId: Int64) throws -> [RechargeStatement] {
        try RechargeStatement.filter(Column("tenancyId") == tenancyId).order(Column("month").desc).fetchAll(db)
    }

    /// The statement's lines: invoices by issue date, then manual lines.
    public static func lines(db: Database, statementId: Int64) throws -> [RechargeLine] {
        try RechargeLine.fetchAll(db, sql: """
            SELECT rechargeLine.* FROM rechargeLine LEFT JOIN utilityInvoice ON utilityInvoice.id = rechargeLine.invoiceId
            WHERE rechargeLine.statementId = ? ORDER BY utilityInvoice.issueDate IS NULL, utilityInvoice.issueDate, rechargeLine.id
            """, arguments: [statementId])
    }

    /// What the invoice's lines on other statements recharge.
    static func recharged(db: Database, invoiceId: Int64, excludingStatement: Int64) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargeLine WHERE invoiceId = ? AND statementId != ?
            """, arguments: [invoiceId, excludingStatement]) ?? 0
    }

    private static func draft(db: Database, _ statementId: Int64) throws -> RechargeStatement {
        guard let statement = try RechargeStatement.fetchOne(db, key: statementId) else { throw RechargeError.statementNotFound }
        guard statement.status == .draft else { throw RechargeError.statementNotDraft }
        return statement
    }

    @discardableResult
    private static func refreshTotal(db: Database, statementId: Int64) throws -> RechargeStatement {
        guard var statement = try RechargeStatement.fetchOne(db, key: statementId) else { throw RechargeError.statementNotFound }
        statement.totalMinorUnits = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargeLine WHERE statementId = ?",
                                                     arguments: [statementId]) ?? 0
        try statement.update(db)
        return statement
    }

    // MARK: Payments

    /// What the statement still needs: its total less the credits linked.
    public static func outstanding(db: Database, statementId: Int64) throws -> Int {
        guard let statement = try RechargeStatement.fetchOne(db, key: statementId) else { throw RechargeError.statementNotFound }
        let paid = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargePayment WHERE statementId = ? AND isDismissed = 0",
                                    arguments: [statementId]) ?? 0
        return statement.totalMinorUnits - paid
    }

    /// What's left of a credit after its rent (active rent receipt links' rent parts) and its
    /// other recharge links (except `excludingStatement`'s).
    public static func creditRemainder(db: Database, transactionId: Int64, excludingStatement: Int64? = nil) throws -> Int {
        guard let credit = try Transaction.fetchOne(db, key: transactionId) else { throw RechargeError.transactionNotFound }
        let rent = try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(rentMinorUnits), 0) FROM rentReceiptPayment WHERE transactionId = ? AND isDismissed = 0
            """, arguments: [transactionId]) ?? 0
        let recharged = try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargePayment WHERE transactionId = ? AND statementId != ? AND isDismissed = 0
            """, arguments: [transactionId, excludingStatement ?? -1]) ?? 0
        return credit.amountMinorUnits - rent - recharged
    }

    /// Links (part of) a credit to a sent statement, or changes the amount of the link.
    /// `amount` defaults to the statement's outstanding amount, capped by what's left of the
    /// credit. The statement becomes paid when covered.
    @discardableResult
    public static func linkPayment(db: Database, statementId: Int64, transactionId: Int64, amountMinorUnits: Int? = nil,
                                   origin: RentPaymentOrigin = .manual) throws -> RechargePayment {
        guard let statement = try RechargeStatement.fetchOne(db, key: statementId) else { throw RechargeError.statementNotFound }
        guard statement.status != .draft else { throw RechargeError.statementNotSent }
        guard let credit = try Transaction.fetchOne(db, key: transactionId) else { throw RechargeError.transactionNotFound }
        guard credit.amountMinorUnits > 0 else { throw RechargeError.notACredit }
        let existing = try RechargePayment.filter(Column("statementId") == statementId && Column("transactionId") == transactionId).fetchOne(db)
        let needed = try outstanding(db: db, statementId: statementId) + (existing.map { $0.isDismissed ? 0 : $0.amountMinorUnits } ?? 0)
        let left = try creditRemainder(db: db, transactionId: transactionId, excludingStatement: statementId)
        let amount = amountMinorUnits ?? min(needed, left)
        guard amount > 0 else { throw RechargeError.nothingAllocated }
        guard amount <= left else { throw RechargeError.overAllocated }
        guard amount <= needed else { throw RechargeError.exceedsStatement }
        var payment = existing ?? RechargePayment(statementId: statementId, transactionId: transactionId, amountMinorUnits: amount, origin: origin)
        payment.amountMinorUnits = amount
        payment.origin = origin
        payment.isDismissed = false
        try payment.save(db)
        try refreshStatus(db: db, statementId: statementId)
        return payment
    }

    /// Removes a payment link (the statement goes back to sent); an auto link is kept
    /// dismissed so matching doesn't make it again. `false` when there was no active link.
    @discardableResult
    public static func unlinkPayment(db: Database, statementId: Int64, transactionId: Int64) throws -> Bool {
        guard var payment = try RechargePayment.filter(Column("statementId") == statementId && Column("transactionId") == transactionId
                                                       && Column("isDismissed") == false).fetchOne(db) else { return false }
        if payment.origin == .auto {
            payment.isDismissed = true
            try payment.update(db)
        } else {
            try payment.delete(db)
        }
        try refreshStatus(db: db, statementId: statementId)
        return true
    }

    /// Whether an auto link of the credit to the statement was dismissed.
    static func isDismissed(db: Database, statementId: Int64, transactionId: Int64) throws -> Bool {
        try RechargePayment.filter(Column("statementId") == statementId && Column("transactionId") == transactionId
                                   && Column("isDismissed") == true).fetchCount(db) > 0
    }

    private static func refreshStatus(db: Database, statementId: Int64) throws {
        guard var statement = try RechargeStatement.fetchOne(db, key: statementId), statement.status != .draft else { return }
        let status: RechargeStatementStatus = try outstanding(db: db, statementId: statementId) <= 0 ? .paid : .sent
        if statement.status != status {
            statement.status = status
            try statement.update(db)
        }
    }

    /// Links sent statements of the property to tenant credits (the property's rent credits),
    /// per tenancy, oldest first: a credit whose non-rent remainder equals exactly what one
    /// statement — or a run of consecutive outstanding sent statements — still needs, dated on
    /// or after the day the (last) statement was sent (else the month after its month) and
    /// within `windowDays`. The shortest run wins; rounded amounts are left for review. Run
    /// after rent matching (the remainder is what the rent links leave). Idempotent; returns
    /// the links made.
    @discardableResult
    public static func matchPayments(db: Database, propertyId: Int64, windowDays: Int = 45) throws -> [RechargePayment] {
        let statements = try RechargeStatement.fetchAll(db, sql: """
            SELECT rechargeStatement.* FROM rechargeStatement JOIN tenancy ON tenancy.id = rechargeStatement.tenancyId
            WHERE tenancy.propertyId = ? AND rechargeStatement.status = ? ORDER BY rechargeStatement.month, rechargeStatement.id
            """, arguments: [propertyId, RechargeStatementStatus.sent.rawValue])
        guard !statements.isEmpty else { return [] }
        let allCredits = try RentReceiptMatching.candidateCredits(db: db, propertyId: propertyId)
        var made: [RechargePayment] = []
        let calendar = MonthRange.calendar
        for tenancyId in Set(statements.map(\.tenancyId)).sorted() {
            // The tenancy's own rent credits (linked to its receipts) first, then by date.
            let own = Set(try Int64.fetchAll(db, sql: """
                SELECT p.transactionId FROM rentReceiptPayment p JOIN rentReceipt r ON r.id = p.rentReceiptId
                WHERE r.tenancyId = ? AND p.isDismissed = 0
                """, arguments: [tenancyId]))
            let credits = allCredits.sorted { (own.contains($0.id!) ? 0 : 1, $0.date, $0.id!) < (own.contains($1.id!) ? 0 : 1, $1.date, $1.id!) }
            let open = try statements.filter { $0.tenancyId == tenancyId }
                .map { (statement: $0, needed: try outstanding(db: db, statementId: $0.id!)) }
                .filter { $0.needed > 0 }
            var start = 0
            while start < open.count {
                var total = 0
                var matched: (end: Int, credit: Transaction)?
                for end in start..<open.count where matched == nil {
                    total += open[end].needed
                    let last = open[end].statement
                    let from = last.sentAt.map(PropertyDates.day) ?? calendar.date(byAdding: .month, value: 1, to: last.month)!
                    let to = calendar.date(byAdding: .day, value: windowDays + 1, to: from)!
                    for credit in credits where credit.date >= from && credit.date < to {
                        let dismissed = try open[start...end].contains { try isDismissed(db: db, statementId: $0.statement.id!, transactionId: credit.id!) }
                        if !dismissed, try creditRemainder(db: db, transactionId: credit.id!) == total {
                            matched = (end, credit)
                            break
                        }
                    }
                }
                guard let matched else {
                    start += 1
                    continue
                }
                for entry in open[start...matched.end] {
                    made.append(try linkPayment(db: db, statementId: entry.statement.id!, transactionId: matched.credit.id!,
                                                amountMinorUnits: entry.needed, origin: .auto))
                }
                start = matched.end + 1
            }
        }
        return made
    }

    /// A recharge received: the statement-linked part of a tenant credit.
    public struct Received: Equatable, Sendable {
        public var payment: RechargePayment
        public var transaction: Transaction
        public var statement: RechargeStatement
    }

    /// The property's recharges received on credits dated in `interval` (`[start, end)`), by date.
    public static func received(db: Database, propertyId: Int64, in interval: DateInterval? = nil) throws -> [Received] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT rechargePayment.id AS paymentId FROM rechargePayment
            JOIN rechargeStatement ON rechargeStatement.id = rechargePayment.statementId
            JOIN tenancy ON tenancy.id = rechargeStatement.tenancyId
            WHERE tenancy.propertyId = ? AND rechargePayment.isDismissed = 0
            """, arguments: [propertyId])
        var result: [Received] = []
        for row in rows {
            let id: Int64 = row["paymentId"]
            guard let payment = try RechargePayment.fetchOne(db, key: id),
                  let transaction = try Transaction.fetchOne(db, key: payment.transactionId),
                  let statement = try RechargeStatement.fetchOne(db, key: payment.statementId) else { continue }
            if let interval, !(transaction.date >= interval.start && transaction.date < interval.end) { continue }
            result.append(Received(payment: payment, transaction: transaction, statement: statement))
        }
        return result.sorted { ($0.transaction.date, $0.payment.id!) < ($1.transaction.date, $1.payment.id!) }
    }
}
