import GRDB
import Foundation

/// The language of the recharge email.
public enum RechargeEmailLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case portuguese = "pt"
    case english = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .portuguese: return "Português"
        case .english: return "English"
        }
    }

    var locale: Locale { Locale(identifier: self == .portuguese ? "pt_PT" : "en_GB") }
}

/// A property's editable email text per language (placeholders: `{tenant}`, `{month}`,
/// `{property}`, `{utilities}`, `{table}`, `{total_label}`, `{total}`). Without a stored one, `RechargeEmail.defaultTemplate`.
public struct RechargeEmailTemplate: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var propertyId: Int64
    public var language: RechargeEmailLanguage
    public var subject: String
    public var body: String

    public init(id: Int64? = nil, propertyId: Int64, language: RechargeEmailLanguage, subject: String, body: String) {
        self.id = id
        self.propertyId = propertyId
        self.language = language
        self.subject = subject
        self.body = body
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "rechargeEmailTemplate"
}

/// The monthly recharge email (plan phase 5 Task 3): recipients, subject and body from the
/// template, a summary table of the statement's lines, and its documents to attach. The app
/// opens it as a draft in Mail; the user sends it.
public enum RechargeEmail {
    public struct Draft: Equatable, Sendable {
        public var recipients: [String]
        public var subject: String
        public var body: String
        /// The invoices' (and manual lines') documents, in line order.
        public var attachmentDocumentIds: [Int64]
    }

    public static func defaultTemplate(propertyId: Int64, language: RechargeEmailLanguage) -> RechargeEmailTemplate {
        switch language {
        case .portuguese:
            return RechargeEmailTemplate(propertyId: propertyId, language: language,
                                         subject: "Despesas de {month} — {property}",
                                         body: """
                                         Olá {tenant},

                                         Seguem as despesas de {month} ({utilities}), com as faturas em anexo:

                                         {table}

                                         {total_label}: {total}

                                         Obrigado,
                                         """)
        case .english:
            return RechargeEmailTemplate(propertyId: propertyId, language: language,
                                         subject: "Utilities for {month} — {property}",
                                         body: """
                                         Hi {tenant},

                                         Here are the utility charges for {month} ({utilities}), with the invoices attached:

                                         {table}

                                         {total_label}: {total}

                                         Thank you,
                                         """)
        }
    }

    /// The stored template, else the default.
    public static func template(db: Database, propertyId: Int64, language: RechargeEmailLanguage) throws -> RechargeEmailTemplate {
        try RechargeEmailTemplate.filter(Column("propertyId") == propertyId && Column("language") == language.rawValue).fetchOne(db)
            ?? defaultTemplate(propertyId: propertyId, language: language)
    }

    /// Stores the property's template for its language (replacing the previous one).
    public static func saveTemplate(db: Database, _ template: inout RechargeEmailTemplate) throws {
        if template.id == nil, let existing = try RechargeEmailTemplate
            .filter(Column("propertyId") == template.propertyId && Column("language") == template.language.rawValue).fetchOne(db) {
            template.id = existing.id
        }
        try template.save(db)
    }

    /// Drops the stored template (back to the default).
    public static func resetTemplate(db: Database, propertyId: Int64, language: RechargeEmailLanguage) throws {
        _ = try RechargeEmailTemplate.filter(Column("propertyId") == propertyId && Column("language") == language.rawValue).deleteAll(db)
    }

    /// The email for a statement with `template` (default: the property's for the language).
    public static func draft(db: Database, statementId: Int64, language: RechargeEmailLanguage,
                             template: RechargeEmailTemplate? = nil) throws -> Draft {
        guard let statement = try RechargeStatement.fetchOne(db, key: statementId) else { throw RechargeError.statementNotFound }
        guard let tenancy = try Tenancy.fetchOne(db, key: statement.tenancyId),
              let property = try Property.fetchOne(db, key: tenancy.propertyId) else { throw RechargeError.tenancyNotFound }
        let template = try template ?? self.template(db: db, propertyId: property.id!, language: language)
        return draft(details: try Recharges.lineDetails(db: db, statementId: statementId), totalMinorUnits: statement.totalMinorUnits,
                     month: statement.month, tenancy: tenancy, propertyName: property.name, currency: property.currency,
                     language: language, template: template)
    }

    /// The email for lines not saved yet (the statement sheet's preview): the same text as
    /// `draft(db:…)` gives once they're saved with that total.
    public static func draft(details: [Recharges.LineDetail], totalMinorUnits total: Int, month: Date, tenancy: Tenancy,
                             propertyName: String, currency: Currency, language: RechargeEmailLanguage,
                             template: RechargeEmailTemplate) -> Draft {
        let values = [
            "tenant": tenancy.tenantName ?? "",
            "month": monthName(month, language: language),
            "property": propertyName,
            "utilities": utilities(details, language: language),
            "table": table(details, currency: currency, language: language),
            "total_label": totalLabel(total, language: language),
            "total": money(abs(total), currency: currency, language: language)
        ]
        var ids: [Int64] = []
        for id in details.compactMap(\.documentId) where !ids.contains(id) { ids.append(id) }
        return Draft(recipients: Tenancies.emailAddresses(tenancy), subject: render(template.subject, values),
                     body: render(template.body, values), attachmentDocumentIds: ids)
    }

    /// The prefix of the temporary folders "Prepare email" copies the attachments into (emptied by the browser's purge).
    public static let temporaryFolderPrefix = "Recharges-"

    /// Where an attached document's copy goes in `folder`: under its own name ("/" made "-", leading dots dropped so it
    /// is never hidden nor outside `folder`; the stored file's extension when the name has none; "Invoice" when it has
    /// no name), "name (2).pdf" when two documents share one.
    public static func attachmentTarget(for document: EvidenceDocument, in folder: URL) -> URL {
        var name = (document.canonicalName ?? document.originalFileName).replacingOccurrences(of: "/", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        var base = (name as NSString).deletingPathExtension
        var ext = (name as NSString).pathExtension
        if ext.isEmpty { ext = (document.storedRelativePath as NSString).pathExtension }
        if base.isEmpty { base = "Invoice" }
        var target = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var copy = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) (\(copy))").appendingPathExtension(ext)
            copy += 1
        }
        return target
    }

    /// `text` with each `{name}` replaced; an empty value leaves no stray space before
    /// punctuation ("Olá {tenant}," → "Olá,").
    public static func render(_ text: String, _ values: [String: String]) -> String {
        values.reduce(text) { result, value in
            var result = result
            if value.value.isEmpty {
                for mark in [",", ".", "!", ":"] { result = result.replacingOccurrences(of: " {\(value.key)}\(mark)", with: mark) }
            }
            return result.replacingOccurrences(of: "{\(value.key)}", with: value.value)
        }
    }

    /// The utilities the statement's invoice lines are for, in the language ("água, luz e gás").
    static func utilities(_ details: [Recharges.LineDetail], language: RechargeEmailLanguage) -> String {
        let order: [UtilityKind] = [.water, .electricity, .gas, .other]
        let kinds = Set(details.compactMap(\.provider?.kind))
        let names = order.filter(kinds.contains).map { kindName($0, language: language).lowercased() }
        let and = language == .portuguese ? " e " : " and "
        switch names.count {
        case 0: return language == .portuguese ? "outras despesas" : "other charges"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + and + names.last!
        }
    }

    static func totalLabel(_ total: Int, language: RechargeEmailLanguage) -> String {
        switch (language, total < 0) {
        case (.portuguese, false): return "Total a acrescentar à próxima transferência da renda"
        case (.portuguese, true): return "Valor a devolver (a descontar na próxima transferência da renda)"
        case (.english, false): return "Total to add to the next rent transfer"
        case (.english, true): return "Amount owed back to you (to deduct from the next rent transfer)"
        }
    }

    /// A prorated line's note in the language, else its note.
    static func note(_ line: RechargeLine, language: RechargeEmailLanguage) -> String? {
        if let inside = line.daysInTenancy, let total = line.daysInPeriod {
            return language == .portuguese ? "\(inside) de \(total) dias no contrato" : "\(inside) of \(total) days in the tenancy"
        }
        return line.note
    }

    /// One line per statement line: "• what — invoice date, period (note): amount".
    static func table(_ details: [Recharges.LineDetail], currency: Currency, language: RechargeEmailLanguage) -> String {
        details.map { detail -> String in
            var label: String
            if let provider = detail.provider, let invoice = detail.invoice {
                label = "\(kindName(provider.kind, language: language)) (\(provider.name))"
                label += language == .portuguese ? " — fatura de \(day(invoice.issueDate))" : " — invoice of \(day(invoice.issueDate))"
                if let start = invoice.periodStart, let end = invoice.periodEnd {
                    label += ", \(day(start)) – \(day(end))"
                }
            } else {
                label = detail.line.lineDescription ?? ""
            }
            if let note = note(detail.line, language: language) { label += " (\(note))" }
            return "• \(label): \(money(detail.line.amountMinorUnits, currency: currency, language: language))"
        }.joined(separator: "\n")
    }

    static func kindName(_ kind: UtilityKind, language: RechargeEmailLanguage) -> String {
        guard language == .portuguese else { return kind.displayName }
        switch kind {
        case .electricity: return "Luz"
        case .gas: return "Gás"
        case .water: return "Água"
        case .other: return "Outros"
        }
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }

    public static func monthName(_ date: Date, language: RechargeEmailLanguage) -> String {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = language.locale
        formatter.dateFormat = language == .portuguese ? "MMMM 'de' yyyy" : "MMMM yyyy"
        return formatter.string(from: date)
    }

    public static func money(_ minorUnits: Int, currency: Currency, language: RechargeEmailLanguage) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = language.locale
        formatter.currencyCode = currency.rawValue.uppercased()
        return formatter.string(from: NSNumber(value: Double(minorUnits) / 100)) ?? Money.format(minorUnits, currency: currency)
    }
}

// MARK: - Screens

extension Recharges {
    /// A statement line with its invoice and provider (manual lines: neither) and its document.
    public struct LineDetail: Equatable, Sendable {
        public var line: RechargeLine
        public var invoice: UtilityInvoice?
        public var provider: UtilityProvider?
        public var documentId: Int64? { invoice?.documentId ?? line.documentId }

        public init(line: RechargeLine, invoice: UtilityInvoice? = nil, provider: UtilityProvider? = nil) {
            self.line = line
            self.invoice = invoice
            self.provider = provider
        }
    }

    public static func lineDetails(db: Database, statementId: Int64) throws -> [LineDetail] {
        try lines(db: db, statementId: statementId).map { line in
            let invoice = try line.invoiceId.flatMap { try UtilityInvoice.fetchOne(db, key: $0) }
            let provider = try invoice.flatMap { try UtilityProvider.fetchOne(db, key: $0.providerId) }
            return LineDetail(line: line, invoice: invoice, provider: provider)
        }
    }

    /// A month of a tenancy's recharges.
    public struct MonthRow: Equatable, Sendable, Identifiable {
        public var statement: RechargeStatement
        public var outstandingMinorUnits: Int
        public var payments: [RechargePayment]
        public var id: Int64 { statement.id! }
    }

    /// The tenancy's statements, latest month first, with what each still needs and its payments.
    public static func overview(db: Database, tenancyId: Int64) throws -> [MonthRow] {
        try statements(db: db, tenancyId: tenancyId).map { statement in
            MonthRow(statement: statement, outstandingMinorUnits: try outstanding(db: db, statementId: statement.id!),
                     payments: try RechargePayment.filter(Column("statementId") == statement.id! && Column("isDismissed") == false)
                        .order(Column("id")).fetchAll(db))
        }
    }

    /// The month the tenancy's next statement is for: the month after its latest, else the
    /// month before `today`'s (invoices of the month just ended).
    public static func nextMonth(db: Database, tenancyId: Int64, today: Date) throws -> Date {
        let calendar = MonthRange.calendar
        if let latest = try RechargeStatement.filter(Column("tenancyId") == tenancyId).order(Column("month").desc).fetchOne(db) {
            return calendar.date(byAdding: .month, value: 1, to: latest.month)!
        }
        let (year, month) = MonthRange.components(of: today)
        return calendar.date(byAdding: .month, value: -1, to: MonthRange.of(year: year, month: month).start)!
    }

    /// A tenant credit that might pay a sent statement, for the user to accept.
    public struct PaymentSuggestion: Equatable, Sendable, Identifiable {
        public var statement: RechargeStatement
        public var transaction: Transaction
        /// What linking would take: the smaller of the credit's remainder and the outstanding.
        public var amountMinorUnits: Int
        /// The credit's remainder less the outstanding (0: exact; else rounded or partial).
        public var differenceMinorUnits: Int
        public var id: String { "\(statement.id!)-\(transaction.id!)" }
    }

    /// For each sent statement still owed: the property's rent credits from the day it was sent
    /// (else the month after its month), within `windowDays`, with something left after their
    /// rent and recharge links — the tenancy's own credits first, then the closest remainder,
    /// then the earliest; at most `limit` per statement. Exact ones are what `matchPayments`
    /// links by itself.
    public static func paymentSuggestions(db: Database, propertyId: Int64, windowDays: Int = Recharges.paymentWindowDays, limit: Int = 3) throws -> [PaymentSuggestion] {
        let statements = try RechargeStatement.fetchAll(db, sql: """
            SELECT rechargeStatement.* FROM rechargeStatement JOIN tenancy ON tenancy.id = rechargeStatement.tenancyId
            WHERE tenancy.propertyId = ? AND rechargeStatement.status = ? ORDER BY rechargeStatement.month, rechargeStatement.id
            """, arguments: [propertyId, RechargeStatementStatus.sent.rawValue])
        guard !statements.isEmpty else { return [] }
        let credits = try RentReceiptMatching.candidateCredits(db: db, propertyId: propertyId)
        let calendar = MonthRange.calendar
        var suggestions: [PaymentSuggestion] = []
        for statement in statements {
            let needed = try outstanding(db: db, statementId: statement.id!)
            guard needed > 0 else { continue }
            let own = Set(try Int64.fetchAll(db, sql: """
                SELECT p.transactionId FROM rentReceiptPayment p JOIN rentReceipt r ON r.id = p.rentReceiptId
                WHERE r.tenancyId = ? AND p.isDismissed = 0
                """, arguments: [statement.tenancyId]))
            let from = statement.sentAt.map(PropertyDates.day) ?? calendar.date(byAdding: .month, value: 1, to: statement.month)!
            let to = calendar.date(byAdding: .day, value: windowDays + 1, to: from)!
            var found: [(suggestion: PaymentSuggestion, key: (Int, Int, Date))] = []
            let linked = Set(try Int64.fetchAll(db, sql: "SELECT transactionId FROM rechargePayment WHERE statementId = ?",
                                                arguments: [statement.id!]))
            for credit in credits where credit.date >= from && credit.date < to && !linked.contains(credit.id!) {
                let left = try creditRemainder(db: db, transactionId: credit.id!)
                guard left > 0 else { continue }
                let suggestion = PaymentSuggestion(statement: statement, transaction: credit, amountMinorUnits: min(left, needed),
                                                   differenceMinorUnits: left - needed)
                found.append((suggestion, (own.contains(credit.id!) ? 0 : 1, abs(left - needed), credit.date)))
            }
            found.sort { ($0.key.0, $0.key.1, $0.key.2) < ($1.key.0, $1.key.1, $1.key.2) }
            suggestions += found.prefix(limit).map(\.suggestion)
        }
        return suggestions
    }
}

func registerRechargeEmailMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addRechargeEmail") { db in
        try db.alter(table: "tenancy") { t in
            t.add(column: "tenantEmail", .text)
        }
        try db.create(table: "rechargeEmailTemplate") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().references("property", onDelete: .cascade)
            t.column("language", .text).notNull()
            t.column("subject", .text).notNull()
            t.column("body", .text).notNull()
            t.uniqueKey(["propertyId", "language"])
        }
    }
}
