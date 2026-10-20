import GRDB
import Foundation

/// The one-off history backfill of utility recharges (plan phase 5 Task 4): providers from
/// presets, every past invoice read into the evidence library and matched to its debit, and
/// the past monthly statements rebuilt from the tenant's transfers — one per month whose
/// following rent transfer carried a recharge, its lines the invoices pending at that time —
/// sent, and paid by that transfer. The plan (property, tenancy, folders, providers) is a
/// personal data file kept outside the repository.
public enum RechargeBackfill {
    public struct ProviderPlan: Codable, Equatable, Sendable {
        /// A `UtilityInvoiceRules.presets` name.
        public var preset: String
        /// Defaults to the preset's name.
        public var name: String?
        public var accountReference: String?
        /// Defaults to the preset's.
        public var bankDescriptionPattern: String?
    }

    public struct Plan: Codable, Equatable, Sendable {
        /// The property's name.
        public var property: String
        /// The tenancy whose statements are rebuilt: its contract number, else its reference.
        public var tenancyContract: String?
        public var tenancyReference: String?
        /// The first day statements are rebuilt from (`yyyy-MM-dd`).
        public var since: String
        /// Folders searched (recursively) for utility invoices; `~` expands.
        public var invoiceFolders: [String]
        public var providers: [ProviderPlan]
        /// The tracker's recharged totals per calendar year, in minor units, to compare with.
        public var trackerTotals: [String: Int]?
        /// UK tax years (start years) already filed: marked filed for every owner, so automatic
        /// netting leaves them as filed.
        public var filedTaxYears: [Int]?

        public init(property: String, tenancyContract: String?, tenancyReference: String?, since: String, invoiceFolders: [String],
                    providers: [ProviderPlan], trackerTotals: [String: Int]?, filedTaxYears: [Int]? = nil) {
            self.property = property
            self.tenancyContract = tenancyContract
            self.tenancyReference = tenancyReference
            self.since = since
            self.invoiceFolders = invoiceFolders
            self.providers = providers
            self.trackerTotals = trackerTotals
            self.filedTaxYears = filedTaxYears
        }
    }

    public enum BackfillError: Error, Equatable {
        case unknownKeys([String])
        case badDate(String)
        case unknownPreset(String)
        case propertyNotFound(String)
        case tenancyNotFound
    }

    public static func decodePlan(_ data: Data) throws -> Plan {
        let json = try JSONSerialization.jsonObject(with: data)
        var unknown: [String] = []
        let root = json as? [String: Any] ?? [:]
        for key in root.keys.sorted() where !["property", "tenancyContract", "tenancyReference", "since", "invoiceFolders", "providers",
                                              "trackerTotals", "filedTaxYears"].contains(key) {
            unknown.append(key)
        }
        for (index, item) in ((root["providers"] as? [Any]) ?? []).enumerated() {
            for key in ((item as? [String: Any]) ?? [:]).keys.sorted()
            where !["preset", "name", "accountReference", "bankDescriptionPattern"].contains(key) {
                unknown.append("providers[\(index)].\(key)")
            }
        }
        guard unknown.isEmpty else { throw BackfillError.unknownKeys(unknown) }
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        _ = try day(plan.since)
        return plan
    }

    public static func day(_ text: String) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = EvidenceDateParser.makeDate(year: parts[0], month: parts[1], day: parts[2]) else {
            throw BackfillError.badDate(text)
        }
        return date
    }

    // MARK: Providers

    /// The plan's providers, created from their presets when missing (by name).
    @discardableResult
    public static func ensureProviders(db: Database, propertyId: Int64, plan: Plan) throws -> [UtilityProvider] {
        for entry in plan.providers {
            guard let preset = UtilityInvoiceRules.presets.first(where: { $0.name == entry.preset }) else {
                throw BackfillError.unknownPreset(entry.preset)
            }
            let name = entry.name ?? preset.name
            if try UtilityProvider.filter(sql: "propertyId = ? AND name = ? COLLATE NOCASE", arguments: [propertyId, name]).fetchCount(db) > 0 {
                continue
            }
            var provider = UtilityProvider(propertyId: propertyId, name: name, kind: preset.kind, accountReference: entry.accountReference,
                                           bankDescriptionPattern: entry.bankDescriptionPattern ?? preset.bankDescriptionPattern,
                                           invoiceRules: preset.rules)
            try Recharges.saveProvider(db: db, &provider)
        }
        return try Recharges.providers(db: db, propertyId: propertyId)
    }

    // MARK: Filed years

    public struct FiledYear: Equatable, Sendable {
        public var taxYear: UKTaxYear
        public var person: String
        /// The status before (`nil`: no record).
        public var previous: TaxYearStatus?
        public var status: TaxYearStatus
    }

    /// Marks each of `years` filed for every owner of the property: a missing record is
    /// created filed, preparing/ready become filed, filed and paid stay. Idempotent.
    @discardableResult
    public static func markFiledYears(db: Database, propertyId: Int64, years: [Int]) throws -> [FiledYear] {
        var result: [FiledYear] = []
        for startYear in years.sorted() {
            for person in try owners(db: db, propertyId: propertyId, in: UKTaxYear(startYear: startYear)) {
                let previous = try TaxYears.year(db: db, startYear: startYear, personId: person.id!)?.status
                var record = try TaxYears.ensure(db: db, startYear: startYear, personId: person.id!)
                if record.status != .filed && record.status != .paid {
                    record.status = .filed
                    try TaxYears.save(db: db, &record)
                }
                result.append(FiledYear(taxYear: UKTaxYear(startYear: startYear), person: person.name, previous: previous, status: record.status))
            }
        }
        return result
    }

    /// The people owning a share of the property at some point of the tax year, by name.
    static func owners(db: Database, propertyId: Int64, in year: UKTaxYear) throws -> [Person] {
        let ids = try Properties.owners(db: db, propertyId: propertyId).filter { owner in
            (owner.fromDate.map { $0 <= year.lastDay } ?? true) && (owner.toDate.map { $0 >= year.start } ?? true)
        }.map(\.personId)
        return try Person.filter(keys: Array(Set(ids))).order(Column("name")).fetchAll(db)
    }

    // MARK: Invoices

    static let invoiceExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic"]

    /// The files under `folders` (recursively, hidden ones skipped) a provider recognises: by
    /// their text layer, else (image-only or unreadable) by a file-name word — leaving out
    /// documents classified as something else (bank statements name the providers too). By path.
    public static func candidateFiles(in folders: [URL], providers: [UtilityProvider]) -> [URL] {
        var found: [URL] = []
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where invoiceExtensions.contains(url.pathExtension.lowercased()) {
                let name = url.lastPathComponent
                let text = autoreleasepool { EvidenceTextExtractor.extract(from: url).text }
                let kind = DocumentClassifier.classify(text: text, fileName: name)
                guard kind == .utilityInvoice || kind == .other else { continue }
                if UtilityInvoiceReader.provider(text: text, fileName: name, providers: providers) != nil { found.append(url) }
            }
        }
        return Array(Set(found)).sorted { $0.path < $1.path }
    }

    public enum InvoiceStatus: Equatable, Sendable {
        /// Recorded; `matched` when its payment was found.
        case recorded(matched: Bool)
        /// Already recorded (same content or same invoice).
        case duplicate
        /// Not recorded: what's missing or why.
        case skipped
    }

    public struct InvoiceOutcome: Equatable, Sendable {
        public var file: String
        public var status: InvoiceStatus
        public var reading: UtilityInvoiceReading
        public var usedOCR: Bool
        public var invoiceId: Int64?
        public var transactionId: Int64?
        /// Why it's skipped, a duplicate, or unmatched.
        public var reason: String?
    }

    /// Adds each file to the library, reads it, records it with its payment when found; a
    /// file that doesn't become an invoice and wasn't in the library before is removed from it
    /// again. Returns one outcome per file, in order.
    public static func intake(files: [URL], library: EvidenceLibrary, propertyId: Int64) throws -> [InvoiceOutcome] {
        let firstMovement = try library.database.read { db -> Date? in
            let accounts = try Properties.accounts(db: db, propertyId: propertyId, role: .current).map(\.accountId)
            guard !accounts.isEmpty else { return nil }
            return try Date.fetchOne(db, Transaction.filter(accounts.contains(Column("accountId"))).select(min(Column("date"))))
        }
        var outcomes: [InvoiceOutcome] = []
        func discard(_ added: EvidenceLibrary.AddResult) throws {
            guard added.isNew, let id = added.document.id else { return }
            let used = try library.database.read { db in
                try UtilityInvoice.filter(Column("documentId") == id).fetchCount(db) > 0
                    || DocumentLink.filter(Column("documentId") == id).fetchCount(db) > 0
            }
            if !used { try library.remove(id) }
        }
        for url in files {
            let added = try library.addAnalyzing(url)
            let document = added.document
            let proposal = try UtilityInvoiceIntake.propose(document: document, library: library, propertyId: propertyId)
            var outcome = InvoiceOutcome(file: url.lastPathComponent, status: .skipped, reading: proposal.reading, usedOCR: proposal.usedOCR,
                                         invoiceId: nil, transactionId: nil, reason: nil)
            let existing = try library.database.read { db in
                try UtilityInvoice.filter(Column("documentId") == document.id!).fetchOne(db)
            }
            if let existing {
                outcome.status = .duplicate
                outcome.invoiceId = existing.id
                outcome.reason = "same content as an invoice already recorded"
                outcomes.append(outcome)
                continue
            }
            guard var invoice = proposal.invoice else {
                outcome.reason = "missing " + proposal.missing.joined(separator: ", ")
                try discard(added)
                outcomes.append(outcome)
                continue
            }
            do {
                try library.database.write { db in try UtilityInvoiceIntake.record(db: db, &invoice) }
            } catch RechargeError.duplicateInvoiceNumber {
                outcome.status = .duplicate
                outcome.reason = "invoice number \(invoice.invoiceNumber ?? "") already recorded (another copy)"
                try discard(added)
                outcomes.append(outcome)
                continue
            } catch RechargeError.duplicateInvoice {
                outcome.status = .duplicate
                outcome.invoiceId = proposal.duplicateOf
                outcome.reason = "a copy of an invoice already recorded (same text, ATCUD, or date, period and amount)"
                try discard(added)
                outcomes.append(outcome)
                continue
            }
            // Paid: its debit, or the debits its document is linked to (paid in parts).
            let payments = try library.database.read { db in try Recharges.payments(db: db, invoice) }
            outcome.status = .recorded(matched: !payments.isEmpty)
            outcome.invoiceId = invoice.id
            outcome.transactionId = invoice.transactionId ?? payments.first?.id
            if payments.isEmpty {
                if let firstMovement, invoice.issueDate < firstMovement {
                    outcome.reason = "issued before the bank history starts"
                } else if invoice.amountMinorUnits < 0 {
                    outcome.reason = "refund: no credit of that amount from 5 days before to 60 after"
                } else {
                    outcome.reason = "no debit of that amount from 5 days before to 60 after the issue date"
                }
                if let warning = proposal.warnings.first { outcome.reason! += "; " + warning }
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    // MARK: Statements

    /// How far a transfer may be from its invoices and still be taken as paying them.
    public static let roundingTolerance = 100

    public struct StatementOutcome: Equatable, Sendable {
        /// The month the statement is for (the one before the transfer's).
        public var month: Date
        public var statementId: Int64?
        public var creditId: Int64
        public var creditDate: Date
        /// The transfer's part beyond its rent.
        public var rechargePartMinorUnits: Int
        public var totalMinorUnits: Int
        public var linkedMinorUnits: Int
        public var lineCount: Int
        /// How the lines were chosen and any difference.
        public var explanation: String
    }

    /// Rebuilds the tenancy's statements from its rent credits dated from `since` (run after
    /// rent matching) — and the tenant's transfers that pay no rent receipt (a recharge sent on
    /// its own): for each credit with a part beyond its rent, oldest first, the month
    /// before the rent it pays (its earliest linked receipt's period) gets a statement of the invoices pending then — or, when a few
    /// invoices more (issued up to the day before the credit) or fewer make the credit's part
    /// exactly, those — marked sent and paid by the credit. A transfer within €1 of the lines
    /// gets a rounding line for the difference (either way), so it settles the statement.
    /// Credits whose month already has a statement pay what it still needs. Statements already
    /// made are left alone.
    public static func rebuildStatements(db: Database, tenancyId: Int64, since: Date) throws -> [StatementOutcome] {
        guard let tenancy = try Tenancy.fetchOne(db, key: tenancyId) else { throw BackfillError.tenancyNotFound }
        let rentCredits = try Transaction.fetchAll(db, sql: """
            SELECT DISTINCT t.* FROM transaction_ t JOIN rentReceiptPayment p ON p.transactionId = t.id
            JOIN rentReceipt r ON r.id = p.rentReceiptId
            WHERE r.tenancyId = ? AND p.isDismissed = 0 AND t.date >= ? ORDER BY t.date, t.id
            """, arguments: [tenancyId, since])
        let withoutReceipt = try tenantCreditsWithoutReceipt(db: db, tenancy: tenancy, since: since)
        let unlinked = Set(withoutReceipt.map(\.id!))
        let credits = (rentCredits + withoutReceipt).sorted { ($0.date, $0.id!) < ($1.date, $1.id!) }
        let calendar = MonthRange.calendar
        var outcomes: [StatementOutcome] = []
        for credit in credits {
            let part = try Recharges.creditRemainder(db: db, transactionId: credit.id!)
            guard part > 0 else { continue }
            let creditDay = PropertyDates.day(credit.date)
            let rentStart = try Date.fetchOne(db, sql: """
                SELECT MIN(r.periodStart) FROM rentReceipt r JOIN rentReceiptPayment p ON p.rentReceiptId = r.id
                WHERE p.transactionId = ? AND p.isDismissed = 0
                """, arguments: [credit.id!]) ?? creditDay
            let (year, monthNumber) = MonthRange.components(of: min(rentStart, calendar.date(byAdding: .month, value: 1, to: creditDay)!))
            let month = calendar.date(byAdding: .month, value: -1, to: MonthRange.of(year: year, month: monthNumber).start)!
            let lastDay = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: month)!
            var outcome = StatementOutcome(month: month, statementId: nil, creditId: credit.id!, creditDate: creditDay, rechargePartMinorUnits: part,
                                           totalMinorUnits: 0, linkedMinorUnits: 0, lineCount: 0, explanation: "")

            if let existing = try RechargeStatement.filter(Column("tenancyId") == tenancyId && Column("month") == month).fetchOne(db) {
                outcome.statementId = existing.id
                outcome.totalMinorUnits = existing.totalMinorUnits
                let needed = try Recharges.outstanding(db: db, statementId: existing.id!)
                if unlinked.contains(credit.id!), part != needed {
                    outcome.explanation = "a transfer without a rent receipt that isn't what the month's statement needs: not taken"
                } else if existing.status != .draft, needed > 0 {
                    let link = try Recharges.linkPayment(db: db, statementId: existing.id!, transactionId: credit.id!,
                                                         amountMinorUnits: min(part, needed), origin: .auto)
                    outcome.linkedMinorUnits = link.amountMinorUnits
                    outcome.explanation = "second transfer for an existing statement"
                } else {
                    outcome.explanation = "the month's statement is already settled: this part stays unexplained"
                }
                outcomes.append(outcome)
                continue
            }
            if try RechargeStatement.filter(Column("tenancyId") == tenancyId && Column("month") > month).fetchCount(db) > 0 {
                outcome.explanation = "a later month already has a statement: left for review"
                outcomes.append(outcome)
                continue
            }

            // The invoices pending up to the day before the credit, by recharge date; the
            // month's are the default; the prefix whose sum is the part, if any, nearest it.
            let dayBefore = calendar.date(byAdding: .day, value: -1, to: creditDay)!
            let pending = try Recharges.pendingLines(db: db, tenancyId: tenancyId, through: max(dayBefore, lastDay))
            let base = pending.filter { $0.rechargeDate <= lastDay }.count
            var sums = [0]
            for line in pending { sums.append(sums.last! + line.amountMinorUnits) }
            let exact = sums.indices.filter { sums[$0] == part && ($0 <= base || pending[$0 - 1].rechargeDate <= dayBefore) }
            // Else a prefix within €1 of it (the transfer rounded), nearest the part.
            let near = sums.indices.filter { $0 > 0 && abs(sums[$0] - part) <= roundingTolerance }
                .min { (abs(sums[$0] - part), abs($0 - base)) < (abs(sums[$1] - part), abs($1 - base)) }
            let chosen = exact.min { abs($0 - base) < abs($1 - base) } ?? near ?? base
            if exact.isEmpty, let near, chosen == near {
                outcome.explanation = "within \(Money.format(abs(part - sums[near]), currency: .eur)) (transfer rounded): \(near) invoice\(near == 1 ? "" : "s")"
            } else if exact.isEmpty {
                outcome.explanation = sums[base] == 0 ? "no invoices pending: the transfer's part isn't explained by invoices"
                    : "differs by \(Money.format(part - sums[base], currency: .eur)) (transfer − invoices pending at month end)"
            } else if chosen == base {
                outcome.explanation = "exact: the invoices pending at month end"
            } else if chosen > base {
                outcome.explanation = "exact with \(chosen - base) invoice\(chosen - base == 1 ? "" : "s") issued after month end (before the transfer)"
            } else {
                outcome.explanation = "exact without the last \(base - chosen) invoice\(base - chosen == 1 ? "" : "s") of the month (left for the next)"
            }
            guard chosen > 0 else {
                outcomes.append(outcome)
                continue
            }
            // A transfer without a rent receipt may be anything (a late rent, a deposit): it's a
            // recharge only when invoices make it (within rounding).
            if unlinked.contains(credit.id!), exact.isEmpty, near != chosen {
                outcome.explanation = "a transfer without a rent receipt that the invoices don't make: not taken"
                outcomes.append(outcome)
                continue
            }

            var statement = try Recharges.draftStatement(db: db, tenancyId: tenancyId, month: month)
            for line in pending.prefix(base).dropFirst(chosen) {
                try Recharges.removeLine(db: db, statementId: statement.id!, invoiceId: line.invoice.id!)
            }
            for line in pending.prefix(chosen).dropFirst(base) {
                try Recharges.setLine(db: db, statementId: statement.id!, invoiceId: line.invoice.id!, amountMinorUnits: line.amountMinorUnits,
                                      note: line.note)
            }
            let included = Array(pending.prefix(chosen))
            // A transfer rounded: the cents it's short are written off on the statement, and
            // the cents it's over added to it, so it's settled and the credit fully allocated.
            let sum = sums[chosen]
            if !exact.contains(chosen), sum != part, abs(sum - part) <= roundingTolerance {
                let description = sum > part ? "Rounding: the transfer was \(Money.format(sum - part, currency: .eur)) less"
                                             : "Rounding: the transfer was \(Money.format(part - sum, currency: .eur)) more"
                try Recharges.saveManualLine(db: db, statementId: statement.id!, description: description, amountMinorUnits: part - sum,
                                             isRounding: true)
            }
            let sentAt = min(max(lastDay, included.map(\.rechargeDate).max() ?? lastDay), creditDay)
            statement = try Recharges.markSent(db: db, statementId: statement.id!, at: sentAt)
            outcome.statementId = statement.id
            outcome.totalMinorUnits = statement.totalMinorUnits
            outcome.lineCount = included.count
            let needed = try Recharges.outstanding(db: db, statementId: statement.id!)
            if needed > 0 {
                let link = try Recharges.linkPayment(db: db, statementId: statement.id!, transactionId: credit.id!,
                                                     amountMinorUnits: min(part, needed), origin: .auto)
                outcome.linkedMinorUnits = link.amountMinorUnits
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    /// The tenant's credits linked to no rent receipt (a recharge sent on its own transfer):
    /// the property's rent credits dated in the tenancy from `since` with no active receipt
    /// link and something left after their recharge links, that are the tenant's — the only
    /// tenancy of the property on that day, or a payer word (a name in the description) shared
    /// with the tenancy's own rent credits (words of other tenancies' rent credits don't count).
    public static func tenantCreditsWithoutReceipt(db: Database, tenancy: Tenancy, since: Date) throws -> [Transaction] {
        let linked = Set(try Int64.fetchAll(db, sql: "SELECT transactionId FROM rentReceiptPayment WHERE isDismissed = 0"))
        let tenancies = try Tenancies.all(db: db, propertyId: tenancy.propertyId)
        let ownWords = Set(try Transaction.fetchAll(db, sql: """
            SELECT DISTINCT t.* FROM transaction_ t JOIN rentReceiptPayment p ON p.transactionId = t.id
            JOIN rentReceipt r ON r.id = p.rentReceiptId WHERE r.tenancyId = ? AND p.isDismissed = 0
            """, arguments: [tenancy.id!]).flatMap { payerWords($0.rawDescription) })
            .subtracting(try Transaction.fetchAll(db, sql: """
                SELECT DISTINCT t.* FROM transaction_ t JOIN rentReceiptPayment p ON p.transactionId = t.id
                JOIN rentReceipt r ON r.id = p.rentReceiptId WHERE r.tenancyId != ? AND p.isDismissed = 0
                """, arguments: [tenancy.id!]).flatMap { payerWords($0.rawDescription) })
        return try RentReceiptMatching.candidateCredits(db: db, propertyId: tenancy.propertyId).filter { credit in
            guard credit.date >= since, !linked.contains(credit.id!), tenancy.covers(PropertyDates.day(credit.date)),
                  try Recharges.creditRemainder(db: db, transactionId: credit.id!) > 0 else { return false }
            let alone = tenancies.filter { $0.covers(PropertyDates.day(credit.date)) }.count == 1
            return alone || !ownWords.isDisjoint(with: payerWords(credit.rawDescription))
        }
    }

    /// The words of a bank description that can name a payer: letters only, 4 or more, not a
    /// banking word or a bank's name.
    static func payerWords(_ description: String) -> Set<String> {
        let ignored: Set<String> = ["TRANSF", "TRANSFER", "TRANSFERENCIA", "SEPA", "CREDIT", "CREDITO", "PAGAMENTO", "RENDA", "ALUGUER",
                                    "IMEDIATA", "RECEBIDA", "RECEBIDO", "MBWAY", "PAYMENT", "INSTANT", "BBVA", "CAIXA", "MILLENNIUM",
                                    "NOVO", "BANCO", "SANTANDER", "MONTEPIO", "ACTIVOBANK", "BANKINTER", "REVOLUT", "WISE", "MONZO",
                                    "BARCLAYS", "HSBC", "LLOYDS", "NATWEST"]
        return Set(EvidenceText.normalized(description).split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.count >= 4 && !ignored.contains($0) })
    }

    // MARK: Netting impact

    public struct YearImpact: Equatable, Sendable {
        public var taxYear: UKTaxYear
        public var person: String
        public var status: TaxYearStatus?
        /// What the year gets with no stored mode (filed years: none).
        public var automaticMode: RechargeNettingMode?
        /// Whole property, in the property's currency, as before phase 5 (each utility category
        /// on its own line, recharges not netted).
        public var automaticUtilities: Int
        public var automaticNotDeductible: Int
        public var automaticIncome: Int
        public var nettedUtilities: Int
        public var nettedNotDeductible: Int
        public var nettedIncome: Int
        public var utilitiesPaid: Int
        public var rechargesReceived: Int
        /// The person's profit change if netted against before phase 5 (share applied), in the
        /// property's currency.
        public var profitChange: Int
        /// The change the automatic mode makes against before phase 5 (none for filed years).
        public var automaticChange: Int
    }

    /// For each UK tax year and owner: the rental accounts as before phase 5 (computed as a
    /// filed year with no stored mode) and with netting forced, and the mode the year gets
    /// automatically — computed inside rolled-back savepoints, so nothing is stored.
    public static func nettingImpact(db: Database, propertyId: Int64, years: [UKTaxYear]) throws -> [YearImpact] {
        var impacts: [YearImpact] = []
        for year in years {
            for person in try owners(db: db, propertyId: propertyId, in: year) {
                let current = try RentalAccounts.compute(db: db, taxYear: year, personId: person.id!, propertyId: propertyId)
                var automatic = current
                try db.inSavepoint {
                    try RechargeNetting.set(db: db, startYear: year.startYear, mode: nil)
                    try RechargeNetting.set(db: db, startYear: nil, mode: nil)
                    var record = try TaxYears.ensure(db: db, startYear: year.startYear, personId: person.id!)
                    record.status = .filed
                    try TaxYears.save(db: db, &record)
                    automatic = try RentalAccounts.compute(db: db, taxYear: year, personId: person.id!, propertyId: propertyId)
                    return .rollback
                }
                var netted = current
                try db.inSavepoint {
                    try RechargeNetting.set(db: db, startYear: year.startYear, mode: .netOfRecharges)
                    netted = try RentalAccounts.compute(db: db, taxYear: year, personId: person.id!, propertyId: propertyId)
                    return .rollback
                }
                impacts.append(YearImpact(
                    taxYear: year, person: person.name,
                    status: try TaxYears.year(db: db, startYear: year.startYear, personId: person.id!)?.status,
                    automaticMode: current.utilityNetting.mode,
                    automaticUtilities: automatic.line(.utilities)?.whole.native ?? 0,
                    automaticNotDeductible: automatic.notDeductible.whole.native, automaticIncome: automatic.income.whole.native,
                    nettedUtilities: netted.line(.utilities)?.whole.native ?? 0, nettedNotDeductible: netted.notDeductible.whole.native,
                    nettedIncome: netted.income.whole.native, utilitiesPaid: netted.utilityNetting.utilitiesPaid,
                    rechargesReceived: netted.utilityNetting.rechargesReceived,
                    profitChange: netted.totals.profit.native - automatic.totals.profit.native,
                    automaticChange: current.totals.profit.native - automatic.totals.profit.native))
            }
        }
        return impacts
    }
}
