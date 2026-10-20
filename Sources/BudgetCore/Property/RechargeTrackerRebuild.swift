import GRDB
import Foundation

/// Rebuilds a tenancy's recharge history from the landlord's tracker, as a data plan (the
/// recharges audit): misread invoices corrected, duplicates deleted, every statement's lines
/// and its paying transfer exactly as the tracker grouped them, manual and rounding lines
/// included. Nothing is guessed: the plan says every line and payment, and the rebuild
/// refuses anything contradicting the stored data. Idempotent: statements already as planned
/// are left alone. Filed tax years must come out unchanged. The plan is a personal data file
/// kept outside the repository.
public enum RechargeTrackerRebuild {
    // MARK: Plan

    public struct InvoiceCorrection: Codable, Equatable, Sendable {
        public var invoiceId: Int64
        public var newAmountMinorUnits: Int
        /// What the invoice holds before the correction: anything else is refused.
        public var oldAmountMinorUnits: Int
        /// The debit (or refund credit) that settled it.
        public var linkDebitTransactionId: Int64?
        /// `yyyy-MM-dd`.
        public var newIssueDate: String?
        public var evidence: String?
    }

    public struct InvoiceDeletion: Codable, Equatable, Sendable {
        public var invoiceId: Int64
        public var reason: String?
    }

    /// An invoice of the tenancy's period the tracker never charged: kept off the statements
    /// by a zero line on the first statement (so it isn't pending).
    public struct NotRecharged: Codable, Equatable, Sendable {
        public var invoiceId: Int64
        public var reason: String?
    }

    public enum LineKind: String, Codable, Sendable {
        case invoice
        /// A one-off charge or refund (kept by later rebuilds).
        case manual
        /// The cents a transfer differs from the lines by.
        case rounding
    }

    public struct Line: Codable, Equatable, Sendable {
        public var kind: LineKind
        public var invoiceId: Int64?
        public var description: String?
        public var amountMinorUnits: Int
        public var note: String?
        /// A manual line's bank movement.
        public var transactionId: Int64?
        /// The tracker's row and amount (`nil` for rounding lines), for the comparison.
        public var trackerRow: Int?
        public var trackerAmountMinorUnits: Int?
    }

    public struct Payment: Codable, Equatable, Sendable {
        public var transactionId: Int64
        /// `yyyy-MM-dd`: the credit's day, checked.
        public var date: String
        public var amountMinorUnits: Int
        public var note: String?
    }

    public enum Status: String, Codable, Sendable {
        case sent
        case paid
    }

    public struct Statement: Codable, Equatable, Sendable {
        /// `yyyy-MM`.
        public var month: String
        public var status: Status
        /// `yyyy-MM-dd`.
        public var sentAt: String
        public var totalMinorUnits: Int
        public var payments: [Payment]
        public var lines: [Line]
        public var note: String?
    }

    public struct Plan: Codable, Equatable, Sendable {
        public var tenancyId: Int64
        /// Provider name → preset name: the stored rules take the preset's labels they lack.
        public var mergePresetRules: [String: String]?
        public var invoiceCorrections: [InvoiceCorrection]
        public var invoiceDeletions: [InvoiceDeletion]
        public var invoicesNotRecharged: [NotRecharged]
        /// In month order; the whole history of the tenancy up to the last one.
        public var statements: [Statement]
    }

    public enum RebuildError: Error, Equatable {
        case unknownKeys([String])
        case badDate(String)
        case badMonth(String)
        /// The plan contradicts itself (what, where).
        case inconsistentPlan(String)
        case tenancyNotFound
        case providerNotFound(String)
        case unknownPreset(String)
        case invoiceNotFound(Int64)
        /// The invoice holds neither the old nor the new amount.
        case invoiceChanged(Int64, found: Int)
        case invoiceNotTheTenancys(Int64)
        /// An invoice to delete is still on a statement the plan doesn't rebuild.
        case invoiceStillOnStatement(Int64)
        case transactionNotFound(Int64)
        /// The credit isn't dated as the plan says.
        case paymentDateDiffers(Int64, found: String)
        /// A statement of the tenancy before the plan's last month that the plan doesn't have.
        case statementNotInPlan(String)
        /// A one-off manual line of a statement to rebuild that the plan doesn't have (kept by
        /// rebuilds: add it to the plan).
        case oneOffLineNotInPlan(String)
        /// The rebuilt statement isn't what the plan says (month, what).
        case statementDiffers(String, String)
        /// A filed tax year's accounts would change.
        case filedYearChanged(String)
    }

    // Keys the plan may carry: the tool's own, then the audit's information (read, not used).
    private static let rootKeys: Set<String> = ["tenancyId", "mergePresetRules", "invoiceCorrections", "invoiceDeletions", "invoicesNotRecharged",
                                                "statements", "generated", "tenancy", "source", "rule", "newInvoices", "removedLines"]
    private static let correctionKeys: Set<String> = ["invoiceId", "newAmountMinorUnits", "oldAmountMinorUnits", "linkDebitTransactionId",
                                                      "newIssueDate", "evidence"]
    private static let deletionKeys: Set<String> = ["invoiceId", "reason"]
    private static let statementKeys: Set<String> = ["month", "status", "sentAt", "totalMinorUnits", "payments", "lines", "note",
                                                     "appStatementIdsToday", "appTotalsToday"]
    private static let paymentKeys: Set<String> = ["transactionId", "date", "amountMinorUnits", "note"]
    private static let lineKeys: Set<String> = ["kind", "invoiceId", "description", "amountMinorUnits", "note", "transactionId", "trackerRow",
                                                "trackerAmountMinorUnits", "type", "trackerDate", "invoiceNumber", "file", "appAmountMinorUnits",
                                                "appStatement", "changes"]

    /// Decodes and checks the plan: unknown keys, dates and months, each statement's lines
    /// adding up to its total, a paid statement's payments to its total (a sent one's to
    /// less), months in order and once, each invoice on one line at most.
    public static func decodePlan(_ data: Data) throws -> Plan {
        let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var unknown: [String] = []
        func check(_ object: Any?, _ allowed: Set<String>, _ path: String) {
            for key in ((object as? [String: Any]) ?? [:]).keys.sorted() where !allowed.contains(key) {
                unknown.append(path.isEmpty ? key : "\(path).\(key)")
            }
        }
        func each(_ key: String, in object: [String: Any], _ allowed: Set<String>, _ path: String, _ body: (([String: Any], String) -> Void)? = nil) {
            for (index, item) in ((object[key] as? [Any]) ?? []).enumerated() {
                let itemPath = "\(path.isEmpty ? "" : path + ".")\(key)[\(index)]"
                check(item, allowed, itemPath)
                if let item = item as? [String: Any] { body?(item, itemPath) }
            }
        }
        check(root, rootKeys, "")
        each("invoiceCorrections", in: root, correctionKeys, "")
        each("invoiceDeletions", in: root, deletionKeys, "")
        each("invoicesNotRecharged", in: root, deletionKeys, "")
        each("statements", in: root, statementKeys, "") { statement, path in
            each("payments", in: statement, paymentKeys, path)
            each("lines", in: statement, lineKeys, path)
        }
        guard unknown.isEmpty else { throw RebuildError.unknownKeys(unknown) }
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        try validate(plan)
        return plan
    }

    static func validate(_ plan: Plan) throws {
        var previous: Date?
        var invoices = Set<Int64>()
        for statement in plan.statements {
            let month = try self.month(statement.month)
            _ = try day(statement.sentAt)
            if let previous, month <= previous { throw RebuildError.inconsistentPlan("months out of order at \(statement.month)") }
            previous = month
            if statement.lines.reduce(0, { $0 + $1.amountMinorUnits }) != statement.totalMinorUnits {
                throw RebuildError.inconsistentPlan("\(statement.month): lines don't add up to the total")
            }
            let paid = statement.payments.reduce(0) { $0 + $1.amountMinorUnits }
            switch statement.status {
            case .paid where statement.totalMinorUnits > 0 && paid != statement.totalMinorUnits:
                throw RebuildError.inconsistentPlan("\(statement.month): paid, but the payments aren't the total")
            case .sent where statement.totalMinorUnits <= 0 || paid >= statement.totalMinorUnits:
                throw RebuildError.inconsistentPlan("\(statement.month): sent, but nothing is owed")
            default: break
            }
            for payment in statement.payments {
                _ = try day(payment.date)
                if payment.amountMinorUnits <= 0 { throw RebuildError.inconsistentPlan("\(statement.month): a payment of nothing") }
            }
            for line in statement.lines {
                switch line.kind {
                case .invoice:
                    guard let invoiceId = line.invoiceId else { throw RebuildError.inconsistentPlan("\(statement.month): an invoice line without its invoice") }
                    guard invoices.insert(invoiceId).inserted else { throw RebuildError.inconsistentPlan("invoice \(invoiceId) on two lines") }
                case .manual, .rounding:
                    guard line.invoiceId == nil, Transaction.normalizedNote(line.description) != nil else {
                        throw RebuildError.inconsistentPlan("\(statement.month): a manual line needs a description and no invoice")
                    }
                }
            }
        }
        for item in plan.invoicesNotRecharged where invoices.contains(item.invoiceId) {
            throw RebuildError.inconsistentPlan("invoice \(item.invoiceId) is both recharged and not")
        }
        for item in plan.invoiceDeletions where invoices.contains(item.invoiceId) {
            throw RebuildError.inconsistentPlan("invoice \(item.invoiceId) is both deleted and on a statement")
        }
        for correction in plan.invoiceCorrections { _ = try correction.newIssueDate.map(day) }
    }

    public static func day(_ text: String) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = EvidenceDateParser.makeDate(year: parts[0], month: parts[1], day: parts[2]) else {
            throw RebuildError.badDate(text)
        }
        return date
    }

    public static func month(_ text: String) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]), parts[0] > 1900 else { throw RebuildError.badMonth(text) }
        return MonthRange.of(year: parts[0], month: parts[1]).start
    }

    // MARK: Outcome

    public enum Change: String, Equatable, Sendable {
        case added
        case changed
        case unchanged
        case deleted
    }

    public struct Action: Equatable, Sendable {
        public var change: Change
        /// What ("invoice 112", "statement 2023-02", "provider rules EDP").
        public var subject: String
        public var detail: String
    }

    /// One owner's rental accounts for a year, as the app computes them.
    public struct YearFigures: Equatable, Sendable {
        public var taxYear: UKTaxYear
        public var person: String
        public var status: TaxYearStatus?
        public var mode: RechargeNettingMode?
        public var utilitiesPaid: Int
        public var rechargesReceived: Int
        public var utilitiesLine: Int
        public var notDeductible: Int
        public var income: Int
        public var profit: Int

        public var isFiled: Bool { status == .filed || status == .paid }
    }

    public struct Outcome: Equatable, Sendable {
        public var propertyId: Int64
        public var tenancyId: Int64
        public var actions: [Action]
        public var before: [YearFigures]
        public var after: [YearFigures]

        public func count(_ change: Change) -> Int { actions.filter { $0.change == change }.count }
    }

    // MARK: Apply

    /// Applies the plan (inside the caller's transaction: a refusal rolls everything back).
    public static func apply(db: Database, plan: Plan) throws -> Outcome {
        guard let tenancy = try Tenancy.fetchOne(db, key: plan.tenancyId) else { throw RebuildError.tenancyNotFound }
        let propertyId = tenancy.propertyId
        let years = try taxYears(db: db, plan: plan)
        let before = try figures(db: db, propertyId: propertyId, years: years)
        var actions: [Action] = []

        // Provider rules.
        for (name, presetName) in (plan.mergePresetRules ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let preset = UtilityInvoiceRules.presets.first(where: { $0.name == presetName }) else { throw RebuildError.unknownPreset(presetName) }
            guard var provider = try UtilityProvider.filter(sql: "propertyId = ? AND name = ? COLLATE NOCASE", arguments: [propertyId, name]).fetchOne(db) else {
                throw RebuildError.providerNotFound(name)
            }
            let merged = provider.effectiveRules.merging(preset.rules)
            if merged == provider.effectiveRules {
                actions.append(Action(change: .unchanged, subject: "provider rules \(name)", detail: "already has the \(presetName) preset's labels"))
                continue
            }
            let added = labelsAdded(from: provider.effectiveRules, to: merged)
            provider.invoiceRules = merged
            try Recharges.saveProvider(db: db, &provider)
            actions.append(Action(change: .changed, subject: "provider rules \(name)", detail: "added " + added))
        }

        // The statements wanted, and which differ from what's stored.
        let desired = try desiredStatements(db: db, plan: plan, tenancy: tenancy)
        let existing = try RechargeStatement.filter(Column("tenancyId") == tenancy.id!).fetchAll(db)
        let lastMonth = desired.last?.month ?? .distantPast
        for statement in existing where statement.month <= lastMonth && !desired.contains(where: { $0.month == statement.month }) {
            throw RebuildError.statementNotInPlan(monthLabel(statement.month))
        }
        var rebuild: [Date: Int64?] = [:]
        for wanted in desired {
            let current = existing.first { $0.month == wanted.month }
            if let current, try isAsPlanned(db: db, current, wanted) { continue }
            rebuild.updateValue(current?.id, forKey: wanted.month)
        }
        // Back to drafts first: invoices on sent statements can't change. The user's one-off
        // lines are kept, so each must be in the plan (else the plan is refused, not the line lost).
        for (month, entry) in rebuild.sorted(by: { $0.key < $1.key }) {
            guard let id = entry else { continue }
            let planned = desired.first { $0.month == month }?.lines ?? []
            for line in try Recharges.resetStatement(db: db, statementId: id) where line.isOneOff && !planned.contains(where: { $0.matches(line) }) {
                throw RebuildError.oneOffLineNotInPlan("\(monthLabel(month)): \(line.lineDescription ?? "") \(Money.format(line.amountMinorUnits, currency: .eur))")
            }
        }

        // Invoices: duplicates deleted, misreads corrected.
        for deletion in plan.invoiceDeletions {
            guard let invoice = try UtilityInvoice.fetchOne(db, key: deletion.invoiceId) else {
                actions.append(Action(change: .unchanged, subject: "invoice \(deletion.invoiceId)", detail: "already deleted"))
                continue
            }
            try requireTenancys(db: db, invoice, propertyId: propertyId)
            guard try RechargeLine.filter(Column("invoiceId") == invoice.id!).fetchCount(db) == 0 else {
                throw RebuildError.invoiceStillOnStatement(invoice.id!)
            }
            // Its document stays in the library; it stops being its debits' evidence (each
            // part, when it was paid in several).
            if let documentId = invoice.documentId {
                for debit in try Recharges.payments(db: db, invoice) {
                    guard let transactionId = debit.id else { continue }
                    _ = try EvidenceLinks.unlink(db: db, documentId: documentId, from: .transaction(transactionId))
                }
            }
            try Recharges.deleteInvoice(db: db, id: invoice.id!)
            actions.append(Action(change: .deleted, subject: "invoice \(deletion.invoiceId)",
                                  detail: "\(PropertyDates.isoDay(invoice.issueDate)) \(Money.format(invoice.amountMinorUnits, currency: .eur))"
                                    + (deletion.reason.map { ": \($0)" } ?? "")))
        }
        for correction in plan.invoiceCorrections {
            guard var invoice = try UtilityInvoice.fetchOne(db, key: correction.invoiceId) else { throw RebuildError.invoiceNotFound(correction.invoiceId) }
            try requireTenancys(db: db, invoice, propertyId: propertyId)
            guard invoice.amountMinorUnits == correction.oldAmountMinorUnits || invoice.amountMinorUnits == correction.newAmountMinorUnits else {
                throw RebuildError.invoiceChanged(invoice.id!, found: invoice.amountMinorUnits)
            }
            let before = invoice
            invoice.amountMinorUnits = correction.newAmountMinorUnits
            if let transactionId = correction.linkDebitTransactionId {
                guard try Transaction.exists(db, key: transactionId) else { throw RebuildError.transactionNotFound(transactionId) }
                invoice.transactionId = transactionId
            }
            if let issued = correction.newIssueDate { invoice.issueDate = try day(issued) }
            guard invoice != before else {
                actions.append(Action(change: .unchanged, subject: "invoice \(invoice.id!)", detail: "already corrected"))
                continue
            }
            try UtilityInvoiceIntake.record(db: db, &invoice)
            var detail: [String] = []
            if before.amountMinorUnits != invoice.amountMinorUnits {
                detail.append("\(Money.format(before.amountMinorUnits, currency: .eur)) → \(Money.format(invoice.amountMinorUnits, currency: .eur))")
            }
            if before.transactionId != invoice.transactionId { detail.append("paid by tx \(invoice.transactionId!)") }
            if before.issueDate != invoice.issueDate { detail.append("issued \(PropertyDates.isoDay(invoice.issueDate))") }
            actions.append(Action(change: .changed, subject: "invoice \(invoice.id!)", detail: detail.joined(separator: ", ")))
        }

        // The statements, oldest first.
        for wanted in desired {
            guard let entry = rebuild[wanted.month] else {
                actions.append(Action(change: .unchanged, subject: "statement \(monthLabel(wanted.month))", detail: "already as planned"))
                continue
            }
            var statementId = entry
            if statementId == nil {
                var statement = RechargeStatement(tenancyId: tenancy.id!, month: wanted.month)
                try statement.insert(db)
                statementId = statement.id
            }
            try write(db: db, wanted, statementId: statementId!)
            guard try isAsPlanned(db: db, try RechargeStatement.fetchOne(db, key: statementId!)!, wanted) else {
                throw RebuildError.statementDiffers(monthLabel(wanted.month), "not as planned after the rebuild")
            }
            let statement = try RechargeStatement.fetchOne(db, key: statementId!)!
            actions.append(Action(change: entry == nil ? .added : .changed, subject: "statement \(monthLabel(wanted.month))",
                                  detail: "\(wanted.lines.count) line\(wanted.lines.count == 1 ? "" : "s"), "
                                    + "\(Money.format(statement.totalMinorUnits, currency: .eur)), \(statement.status.rawValue)"
                                    + (wanted.payments.isEmpty ? "" : " by tx " + wanted.payments.map { String($0.transactionId) }.joined(separator: ", "))))
        }

        let after = try figures(db: db, propertyId: propertyId, years: years)
        for (old, new) in zip(before, after) where old.isFiled && old != new {
            throw RebuildError.filedYearChanged("\(old.taxYear.label) \(old.person)")
        }
        return Outcome(propertyId: propertyId, tenancyId: tenancy.id!, actions: actions, before: before, after: after)
    }

    /// A planned statement with its month as a day, and the not-recharged invoices' zero lines
    /// on the first one.
    struct Desired {
        var month: Date
        var plan: Statement
        var lines: [Line]
        var payments: [Payment] { plan.payments }
    }

    static func desiredStatements(db: Database, plan: Plan, tenancy: Tenancy) throws -> [Desired] {
        var desired = try plan.statements.map { Desired(month: try month($0.month), plan: $0, lines: $0.lines) }
        guard !desired.isEmpty else { return [] }
        for item in plan.invoicesNotRecharged {
            guard let invoice = try UtilityInvoice.fetchOne(db, key: item.invoiceId) else { throw RebuildError.invoiceNotFound(item.invoiceId) }
            try requireTenancys(db: db, invoice, propertyId: tenancy.propertyId)
            desired[0].lines.append(Line(kind: .invoice, invoiceId: item.invoiceId, description: nil, amountMinorUnits: 0,
                                         note: "Not recharged" + (item.reason.map { ": \($0)" } ?? ""), transactionId: nil, trackerRow: nil,
                                         trackerAmountMinorUnits: nil))
        }
        return desired
    }

    static func requireTenancys(db: Database, _ invoice: UtilityInvoice, propertyId: Int64) throws {
        guard try UtilityProvider.fetchOne(db, key: invoice.providerId)?.propertyId == propertyId else {
            throw RebuildError.invoiceNotTheTenancys(invoice.id!)
        }
    }

    /// Whether the stored statement has exactly the planned lines (invoice, amount; manual
    /// lines by description, amount, kind and movement), active payments, status and sent day.
    static func isAsPlanned(db: Database, _ statement: RechargeStatement, _ wanted: Desired) throws -> Bool {
        guard statement.status.rawValue == wanted.plan.status.rawValue,
              statement.sentAt.map(PropertyDates.day) == (try day(wanted.plan.sentAt)) else { return false }
        let lines = try Recharges.lines(db: db, statementId: statement.id!)
        guard lines.count == wanted.lines.count else { return false }
        var unmatched = lines
        for planned in wanted.lines {
            guard let index = unmatched.firstIndex(where: { planned.matches($0) }) else { return false }
            unmatched.remove(at: index)
        }
        let payments = try RechargePayment.filter(Column("statementId") == statement.id! && Column("isDismissed") == false).fetchAll(db)
        return payments.map { "\($0.transactionId):\($0.amountMinorUnits)" }.sorted()
            == wanted.payments.map { "\($0.transactionId):\($0.amountMinorUnits)" }.sorted()
    }

    /// Writes a draft statement's planned lines (one-off lines already there and planned are
    /// kept), marks it sent and links its payments.
    static func write(db: Database, _ wanted: Desired, statementId: Int64) throws {
        var existing = try Recharges.lines(db: db, statementId: statementId).filter(\.isOneOff)
        for line in wanted.lines {
            switch line.kind {
            case .invoice:
                guard try UtilityInvoice.exists(db, key: line.invoiceId!) else { throw RebuildError.invoiceNotFound(line.invoiceId!) }
                try Recharges.setLine(db: db, statementId: statementId, invoiceId: line.invoiceId!, amountMinorUnits: line.amountMinorUnits,
                                      note: line.note)
            case .manual, .rounding:
                if let transactionId = line.transactionId, try !Transaction.exists(db, key: transactionId) {
                    throw RebuildError.transactionNotFound(transactionId)
                }
                let match = existing.firstIndex { line.matches($0) }
                try Recharges.saveManualLine(db: db, statementId: statementId, lineId: match.map { existing[$0].id! }, description: line.description!,
                                             amountMinorUnits: line.amountMinorUnits, documentId: match.flatMap { existing[$0].documentId },
                                             note: line.note, isRounding: line.kind == .rounding, transactionId: line.transactionId)
                if let match { existing.remove(at: match) }
            }
        }
        try Recharges.markSent(db: db, statementId: statementId, at: try day(wanted.plan.sentAt))
        for payment in wanted.payments {
            guard let credit = try Transaction.fetchOne(db, key: payment.transactionId) else { throw RebuildError.transactionNotFound(payment.transactionId) }
            guard PropertyDates.day(credit.date) == (try day(payment.date)) else {
                throw RebuildError.paymentDateDiffers(payment.transactionId, found: PropertyDates.isoDay(credit.date))
            }
            try Recharges.linkPayment(db: db, statementId: statementId, transactionId: payment.transactionId, amountMinorUnits: payment.amountMinorUnits,
                                      origin: .manual)
        }
    }

    static func labelsAdded(from old: UtilityInvoiceRules, to new: UtilityInvoiceRules) -> String {
        let lists: [(String, [String], [String])] = [
            ("text markers", old.textMarkers, new.textMarkers), ("file-name markers", old.fileNameMarkers, new.fileNameMarkers),
            ("number patterns", old.invoiceNumberPatterns, new.invoiceNumberPatterns), ("issue-date labels", old.issueDateLabels, new.issueDateLabels),
            ("period labels", old.periodLabels, new.periodLabels), ("amount labels", old.amountLabels, new.amountLabels),
            ("refund labels", old.refundLabels, new.refundLabels), ("due-date labels", old.dueDateLabels, new.dueDateLabels)
        ]
        return lists.compactMap { name, before, after -> String? in
            let added = after.filter { !before.contains($0) }
            return added.isEmpty ? nil : "\(name) " + added.map { "\"\($0)\"" }.joined(separator: ", ")
        }.joined(separator: "; ")
    }

    static func monthLabel(_ month: Date) -> String { String(PropertyDates.isoDay(month).prefix(7)) }

    // MARK: Tax years

    /// The UK tax years from the one of the first statement's month to the one of its last
    /// payment (or the last statement's sent day), and every year filed or paid for someone.
    static func taxYears(db: Database, plan: Plan) throws -> [UKTaxYear] {
        guard let first = plan.statements.first, let last = plan.statements.last else { return [] }
        let start = UKTaxYear.containing(try month(first.month)).startYear
        let endDates = try plan.statements.flatMap { statement in try statement.payments.map { try day($0.date) } + [try day(statement.sentAt)] }
        let lastSent = try day(last.sentAt)
        let end = UKTaxYear.containing(endDates.max() ?? lastSent).startYear
        // Every filed (or paid) year too, so none may change unnoticed.
        let filed = try Int.fetchAll(db, sql: "SELECT DISTINCT startYear FROM taxYear WHERE status IN (?, ?)",
                                     arguments: [TaxYearStatus.filed.rawValue, TaxYearStatus.paid.rawValue])
        return Set(Array(start...max(start, end)) + filed).sorted().map(UKTaxYear.init(startYear:))
    }

    /// Each owner's accounts for the years, as the app computes them (its own settings).
    public static func figures(db: Database, propertyId: Int64, years: [UKTaxYear]) throws -> [YearFigures] {
        var result: [YearFigures] = []
        for year in years {
            for person in try RechargeBackfill.owners(db: db, propertyId: propertyId, in: year) {
                let accounts = try RentalAccounts.compute(db: db, taxYear: year, personId: person.id!, propertyId: propertyId)
                result.append(YearFigures(
                    taxYear: year, person: person.name, status: try TaxYears.year(db: db, startYear: year.startYear, personId: person.id!)?.status,
                    mode: accounts.utilityNetting.mode, utilitiesPaid: accounts.utilityNetting.utilitiesPaid,
                    rechargesReceived: accounts.utilityNetting.rechargesReceived, utilitiesLine: accounts.line(.utilities)?.whole.native ?? 0,
                    notDeductible: accounts.notDeductible.whole.native, income: accounts.income.whole.native, profit: accounts.totals.profit.native))
            }
        }
        return result
    }

    // MARK: Comparison

    public struct MonthCheck: Equatable, Sendable {
        public var month: String
        /// The tracker rows' amounts.
        public var trackerMinorUnits: Int
        /// Rounding lines (the cents the transfer differs from the lines by).
        public var roundingMinorUnits: Int
        /// Lines whose amount isn't the tracker row's (an invoice the tracker typed with other
        /// cents, or charged pro rata otherwise): line − tracker, summed.
        public var lineVersusTrackerMinorUnits: Int
        /// The transfers' recharge parts (credit − its rent), `nil` for an unpaid month.
        public var tenantPaidMinorUnits: Int?
        public var appTotalMinorUnits: Int?
        public var linkedMinorUnits: Int
        public var status: RechargeStatementStatus?
        public var plannedStatus: Status
        public var matches: Bool
        public var problem: String?
    }

    /// The tenancy's statements against the plan's tracker rows and the tenant's transfers.
    public static func compare(db: Database, plan: Plan) throws -> [MonthCheck] {
        try plan.statements.map { planned in
            let month = try self.month(planned.month)
            let statement = try RechargeStatement.filter(Column("tenancyId") == plan.tenancyId && Column("month") == month).fetchOne(db)
            let tracker = planned.lines.compactMap(\.trackerAmountMinorUnits).reduce(0, +)
            let lineVersusTracker = planned.lines.compactMap { line in line.trackerAmountMinorUnits.map { line.amountMinorUnits - $0 } }.reduce(0, +)
            let rounding = planned.lines.filter { $0.kind == .rounding }.map(\.amountMinorUnits).reduce(0, +)
            var tenantPaid: Int?
            if !planned.payments.isEmpty {
                tenantPaid = try planned.payments.map { payment -> Int in
                    let amount = try Transaction.fetchOne(db, key: payment.transactionId)?.amountMinorUnits ?? 0
                    let rent = try Int.fetchOne(db, sql: """
                        SELECT COALESCE(SUM(rentMinorUnits), 0) FROM rentReceiptPayment WHERE transactionId = ? AND isDismissed = 0
                        """, arguments: [payment.transactionId]) ?? 0
                    // Other statements' links on the same credit aren't this month's.
                    let elsewhere = try Int.fetchOne(db, sql: """
                        SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargePayment WHERE transactionId = ? AND isDismissed = 0
                        AND statementId != ?
                        """, arguments: [payment.transactionId, statement?.id ?? -1]) ?? 0
                    return amount - rent - elsewhere
                }.reduce(0, +)
            }
            let linked = try statement.map { s in
                try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargePayment WHERE statementId = ? AND isDismissed = 0",
                                 arguments: [s.id!]) ?? 0
            } ?? 0
            var problem: String?
            if let statement {
                let total = statement.totalMinorUnits
                if total != planned.totalMinorUnits { problem = "total \(Money.format(total, currency: .eur)) ≠ the plan's" }
                else if total != tracker + lineVersusTracker + rounding + planned.lines.filter({ $0.trackerAmountMinorUnits == nil && $0.kind != .rounding })
                            .map(\.amountMinorUnits).reduce(0, +) {
                    problem = "the tracker difference isn't explained"
                }
                else if let tenantPaid, tenantPaid != total { problem = "the transfer's part \(Money.format(tenantPaid, currency: .eur)) ≠ total" }
                else if statement.status.rawValue != planned.status.rawValue { problem = "status \(statement.status.rawValue)" }
                else if planned.status == .paid && linked != max(0, total) { problem = "linked \(Money.format(linked, currency: .eur))" }
                else if planned.status == .sent && linked != 0 { problem = "an unpaid month with payments" }
            } else {
                problem = "no statement"
            }
            return MonthCheck(month: planned.month, trackerMinorUnits: tracker, roundingMinorUnits: rounding,
                              lineVersusTrackerMinorUnits: lineVersusTracker, tenantPaidMinorUnits: tenantPaid,
                              appTotalMinorUnits: statement?.totalMinorUnits, linkedMinorUnits: linked, status: statement?.status,
                              plannedStatus: planned.status, matches: problem == nil, problem: problem)
        }
    }

    /// Invoices whose stored text reads (with their provider's rules) as another amount than
    /// recorded: misreadings the plan didn't correct. By issue date.
    public struct Reread: Equatable, Sendable {
        public var invoiceId: Int64
        public var provider: String
        public var issueDate: Date
        public var recordedMinorUnits: Int
        public var readMinorUnits: Int?
        public var onStatement: Bool
    }

    public static func rereads(db: Database, propertyId: Int64, text: (EvidenceDocument) -> String? = { $0.extractedText }) throws -> [Reread] {
        let providers = try Recharges.providers(db: db, propertyId: propertyId)
        var result: [Reread] = []
        for invoice in try Recharges.invoices(db: db, propertyId: propertyId) {
            guard let documentId = invoice.documentId, let document = try EvidenceDocument.fetchOne(db, key: documentId),
                  let body = text(document), let provider = providers.first(where: { $0.id == invoice.providerId }) else { continue }
            let reading = UtilityInvoiceReader.read(text: body, fileName: document.originalFileName, rules: provider.effectiveRules)
            guard reading.amountMinorUnits != invoice.amountMinorUnits else { continue }
            result.append(Reread(invoiceId: invoice.id!, provider: provider.name, issueDate: invoice.issueDate, recordedMinorUnits: invoice.amountMinorUnits,
                                 readMinorUnits: reading.amountMinorUnits,
                                 onStatement: try RechargeLine.filter(Column("invoiceId") == invoice.id!).fetchCount(db) > 0))
        }
        return result
    }
}

extension RechargeTrackerRebuild.Line {
    /// Whether a stored line is this planned one.
    func matches(_ line: RechargeLine) -> Bool {
        switch kind {
        case .invoice:
            return line.invoiceId == invoiceId && line.amountMinorUnits == amountMinorUnits
        case .manual, .rounding:
            return line.isManual && line.isRounding == (kind == .rounding) && line.amountMinorUnits == amountMinorUnits
                && line.lineDescription == Transaction.normalizedNote(description) && line.transactionId == transactionId
        }
    }
}
