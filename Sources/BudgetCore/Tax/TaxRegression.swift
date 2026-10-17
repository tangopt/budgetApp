import GRDB
import Foundation

/// The rental-accounts regression (plan phase 3 Task 5): compares what the engine computes
/// from the stored records with the figures filed for past years, line by line, in EUR and
/// GBP. The filed figures come from the history CSV (`country,year,person,field,value,
/// currency,source_file`); the year settings (HMRC rates implied by the returns, splits as
/// filed, GBP-native manual items) from a JSON file. Both are personal data kept outside the
/// repository; this code only knows their shape. Run on a copy of the database: `apply`
/// writes the settings.
public enum TaxRegression {
    // MARK: Inputs

    public struct Settings: Codable, Equatable, Sendable {
        public struct Split: Codable, Equatable, Sendable {
            public var person: String
            /// A `TaxExpenseType` raw value; `nil` = every type.
            public var expenseType: String?
            public var percent: Double
        }

        public struct Item: Codable, Equatable, Sendable {
            public var person: String
            /// A `TaxExpenseType` raw value.
            public var expenseType: String
            public var label: String
            /// Decimal text ("300.00").
            public var amount: String
            /// "GBP" or "EUR".
            public var currency: String
            public var wholeProperty: Bool?
        }

        /// A year's attribution rule override (as the year was filed).
        public struct Rule: Codable, Equatable, Sendable {
            /// A `TaxExpenseType` raw value.
            public var expenseType: String
            /// A `TaxAttributionRuleKind` raw value.
            public var rule: String
            public var coverMonths: Int?
            public var note: String?
        }

        public struct Year: Codable, Equatable, Sendable {
            public var startYear: Int
            /// Pounds per euro implied by the filed return (required by `apply`; a comparison
            /// against the stored settings only doesn't need it).
            public var eurGbpPerUnit: Double?
            public var rateNote: String?
            public var splits: [Split]?
            public var manualItems: [Item]?
            public var rules: [Rule]?
        }

        /// An insurer's receipt (`TaxPolicyReceipt`): linked to the bank debit of its amount
        /// within a week of `debitDate` (else `date`), or kept on its own when there is none.
        public struct PolicyReceipt: Codable, Equatable, Sendable {
            /// A `TaxExpenseType` raw value; `nil` = insurance.
            public var expenseType: String?
            /// "YYYY-MM-DD".
            public var date: String
            public var debitDate: String?
            /// Decimal text.
            public var amount: String
            /// "EUR" (default) or "GBP".
            public var currency: String?
            public var policyYear: Int?
            public var instalment: Int?
            public var of: Int?
            public var coverFrom: String?
            public var coverTo: String?
            public var note: String?
        }

        /// Whose a payment is (`TaxTransactionOwner`): the transaction whose description holds
        /// `reference`, else the one of `amount` within 3 days of `date`.
        public struct Owner: Codable, Equatable, Sendable {
            public var person: String
            public var reference: String?
            public var date: String?
            public var amount: String?
            public var note: String?
        }

        public var property: String
        /// The history's person names → the database's, where they differ.
        public var personAliases: [String: String]?
        public var years: [Year]
        public var policyReceipts: [PolicyReceipt]?
        public var transactionOwners: [Owner]?
        /// Uncategorised debits to file under a property category before the rest applies.
        public var categorize: [Categorize]?

        /// The transaction of `amount` on `date` (± 3 days) whose description contains
        /// `description` (when given) → `category` (a category name).
        public struct Categorize: Codable, Equatable, Sendable {
            public var date: String
            public var amount: String
            public var description: String?
            public var category: String
        }

        public func personName(_ historyName: String) -> String { personAliases?[historyName] ?? historyName }
    }

    public enum RegressionError: Error, Equatable {
        case propertyNotFound(String)
        case personNotFound(String)
        case badExpenseType(String)
        case badAmount(String)
        case badCurrency(String)
        case badRule(String)
        case badDate(String)
        case transactionNotFound(String)
        case categoryNotFound(String)
        /// A year to apply without its `eurGbpPerUnit`.
        case missingRate(Int)
    }

    /// One filed figure.
    public struct FiledFigure: Equatable, Sendable {
        public var startYear: Int
        public var person: String
        public var field: String
        /// "EUR" or "GBP".
        public var currency: String
        public var minorUnits: Int
        public var source: String
    }

    /// The fields compared, and what they are in the engine's terms.
    public static let comparedFields: [String] = [
        "rental_income", "rental_exp_mortgage_interest", "rental_exp_service_charge", "rental_exp_insurance_building_insurance",
        "rental_exp_council_tax_if_paid_by_landlord", "rental_exp_accountancy_fee", "rental_exp_any_other_expense",
        "rental_exp_legal_fees", "rental_exp_letting_fee", "rental_exp_repairs_and_maintenance", "rental_total_expenses", "rental_adjusted_profit",
        "rental_profit_before_finance_addback", "residential_finance_costs", "foreign_tax_paid_confirmed_letter",
        "template_eur_total_rental_receivable_income", "template_eur_mortgage_interest", "template_eur_service_charge",
        "template_eur_insurance_building_insurance", "template_eur_council_tax_if_paid_by_landlord", "template_eur_accountancy_fee",
        "template_eur_letting_fee", "template_eur_legal_fees", "template_eur_repairs_and_maintenance",
        "template_eur_any_other_expense", "template_eur_total_expenses", "template_eur_profit_loss_from_rental_income"
    ]

    /// The UK rows of the history for the compared fields with a numeric EUR or GBP value. Where
    /// a field appears in several documents, the signed approval pack wins, then the first.
    public static func parseHistory(_ text: String) -> [FiledFigure] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else { return [] }
        // A UTF-8 byte-order mark (spreadsheet exports) is not part of the first column's name.
        let header = first.hasPrefix("\u{FEFF}") ? String(first.dropFirst()) : first
        let columns = CSVRowSplitter.split(line: header, delimiter: ",")
        guard let country = columns.firstIndex(of: "country"), let year = columns.firstIndex(of: "year"),
              let person = columns.firstIndex(of: "person"), let field = columns.firstIndex(of: "field"),
              let value = columns.firstIndex(of: "value"), let currency = columns.firstIndex(of: "currency") else { return [] }
        let sourceIndex = columns.firstIndex(of: "source_file")
        let wanted = Set(comparedFields)
        var best: [String: (FiledFigure, rank: Int)] = [:]
        var order: [String] = []
        for line in lines.dropFirst() {
            let fields = CSVRowSplitter.split(line: line, delimiter: ",")
            guard fields.count > max(country, year, person, field, value, currency), fields[country] == "UK",
                  wanted.contains(fields[field]), ["EUR", "GBP"].contains(fields[currency]),
                  let start = Int(fields[year].prefix(4)), fields[year].count == 7,
                  let amount = Money.parseMinorUnits(fields[value]) ?? Double(fields[value]).map({ Int(($0 * 100).rounded()) }) else { continue }
            let source = sourceIndex.flatMap { $0 < fields.count ? fields[$0] : nil } ?? ""
            let figure = FiledFigure(startYear: start, person: fields[person], field: fields[field], currency: fields[currency],
                                     minorUnits: amount, source: source)
            let key = "\(start)|\(figure.person)|\(figure.field)|\(figure.currency)"
            let rank = source.localizedCaseInsensitiveContains("approval") ? 0 : 1
            if let existing = best[key] {
                if rank < existing.rank { best[key] = (figure, rank) }
            } else {
                best[key] = (figure, rank)
                order.append(key)
            }
        }
        return order.compactMap { best[$0]?.0 }
    }

    // MARK: Applying the settings (on a copy)

    /// Writes the years' rates (as filed-return rates), splits and manual items. Manual items
    /// replace those of the same person, year and label. Returns what it did.
    @discardableResult
    public static func apply(db: Database, settings: Settings) throws -> [String] {
        let property = try propertyRecord(db: db, settings.property)
        var log: [String] = []
        if let entries = settings.categorize, !entries.isEmpty {
            log.append("Categorised:")
            let groupIds = try Properties.categoryGroupIds(db: db, propertyId: property.id!)
            for entry in entries {
                guard let category = try Category.filter(groupIds.contains(Column("groupId")))
                    .filter(sql: "name = ? COLLATE NOCASE", arguments: [entry.category]).fetchOne(db) else {
                    throw RegressionError.categoryNotFound(entry.category)
                }
                guard let amount = Money.parseMinorUnits(entry.amount) else { throw RegressionError.badAmount(entry.amount) }
                let date = try day(entry.date)
                var matches = try Transaction.filter(Column("amountMinorUnits") == -amount && Column("date") >= date.addingTimeInterval(-3 * 86_400)
                                                     && Column("date") <= date.addingTimeInterval(3 * 86_400)).fetchAll(db)
                if let text = entry.description { matches = matches.filter { $0.rawDescription.localizedCaseInsensitiveContains(text) } }
                guard matches.count == 1, var transaction = matches.first else { throw RegressionError.transactionNotFound("\(entry.date) \(entry.amount)") }
                transaction.categoryId = category.id
                transaction.categorizedBy = .manual
                try transaction.update(db)
                log.append("  \(entry.date) \(transaction.rawDescription) \(entry.amount) → \(category.name)")
            }
        }
        for year in settings.years {
            guard let rate = year.eurGbpPerUnit else { throw RegressionError.missingRate(year.startYear) }
            try HMRCRates.set(db: db, startYear: year.startYear, currencyCode: "EUR", gbpPerUnit: rate,
                              source: .filedReturn, notes: year.rateNote ?? "Implied by the filed return")
            log.append("\(UKTaxYear(startYear: year.startYear).label): EUR rate £\(rate)")
            for split in year.splits ?? [] {
                let person = try personRecord(db: db, settings.personName(split.person))
                let type = try split.expenseType.map(expenseType)
                try TaxSplits.set(db: db, startYear: year.startYear, personId: person.id!, propertyId: property.id!, expenseType: type,
                                  shareBasisPoints: Int((split.percent * 100).rounded()))
                log.append("  split \(person.name) \(type?.rawValue ?? "all") \(split.percent)%")
            }
            for item in year.manualItems ?? [] {
                let person = try personRecord(db: db, settings.personName(item.person))
                guard let amount = Money.parseMinorUnits(item.amount) else { throw RegressionError.badAmount(item.amount) }
                guard let currency = Currency(rawValue: item.currency.lowercased()) else { throw RegressionError.badCurrency(item.currency) }
                try TaxManualItem.filter(Column("startYear") == year.startYear && Column("personId") == person.id! && Column("label") == item.label)
                    .deleteAll(db)
                var record = TaxManualItem(startYear: year.startYear, personId: person.id!, propertyId: property.id!,
                                           expenseType: try expenseType(item.expenseType), label: item.label, amountMinorUnits: amount,
                                           currency: currency, isWholeProperty: item.wholeProperty ?? false, notes: "Regression setting")
                try TaxManualItems.save(db: db, &record)
                log.append("  manual item \(person.name): \(item.label) \(Money.format(amount, currency: currency))")
            }
            for override in year.rules ?? [] {
                guard let rule = TaxAttributionRuleKind(rawValue: override.rule) else { throw RegressionError.badRule(override.rule) }
                let type = try expenseType(override.expenseType)
                try TaxAttributionRules.set(db: db, expenseType: type, startYear: year.startYear, rule: rule,
                                            defaultCoverMonths: override.coverMonths, notes: override.note ?? "Regression setting (as filed)")
                log.append("  rule \(type.rawValue): \(rule.displayName)" + (override.coverMonths.map { " (\($0) months)" } ?? ""))
            }
        }
        if let receipts = settings.policyReceipts, !receipts.isEmpty {
            log.append("Insurers' receipts:")
            log += try applyPolicyReceipts(db: db, propertyId: property.id!, receipts)
        }
        if let owners = settings.transactionOwners, !owners.isEmpty {
            log.append("Payments assigned to a person:")
            for owner in owners {
                let person = try personRecord(db: db, settings.personName(owner.person))
                let transaction = try ownerTransaction(db: db, owner)
                try TaxTransactionOwners.set(db: db, transactionId: transaction.id!, personId: person.id!, notes: owner.note ?? "Regression setting")
                log.append("  \(MissingEvidence.day(transaction.date)) \(transaction.rawDescription) \(Money.format(-transaction.amountMinorUnits, currency: .eur)) → \(person.name)")
            }
        }
        return log
    }

    /// Replaces the property's insurers' receipts with `receipts`, each linked to its debit
    /// when the bank history has it.
    static func applyPolicyReceipts(db: Database, propertyId: Int64, _ receipts: [Settings.PolicyReceipt]) throws -> [String] {
        try TaxPolicyReceipt.filter(Column("propertyId") == propertyId).deleteAll(db)
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId).map(\.accountId)
        var used: Set<Int64> = []
        var log: [String] = []
        for entry in receipts {
            guard let amount = Money.parseMinorUnits(entry.amount) else { throw RegressionError.badAmount(entry.amount) }
            guard let currency = Currency(rawValue: (entry.currency ?? "EUR").lowercased()) else { throw RegressionError.badCurrency(entry.currency ?? "") }
            let date = try day(entry.date)
            let debit = try entry.debitDate.map(day) ?? date
            let window = 7 * 86_400.0
            let candidates = try Transaction
                .filter(accountIds.contains(Column("accountId")) && Column("amountMinorUnits") == -amount
                        && Column("date") >= debit.addingTimeInterval(-window) && Column("date") <= debit.addingTimeInterval(window))
                .fetchAll(db).filter { !used.contains($0.id!) }
                .sorted { abs($0.date.timeIntervalSince(debit)) < abs($1.date.timeIntervalSince(debit)) }
            let transaction = candidates.first
            if let id = transaction?.id { used.insert(id) }
            var receipt = TaxPolicyReceipt(propertyId: propertyId, expenseType: try entry.expenseType.map(expenseType) ?? .insurance,
                                           transactionId: transaction?.id, date: transaction?.date ?? date, amountMinorUnits: amount,
                                           currency: currency, policyYear: entry.policyYear, instalment: entry.instalment,
                                           instalmentCount: entry.of, coverStart: try entry.coverFrom.map(day),
                                           coverEnd: try entry.coverTo.map(day), notes: entry.note ?? "Regression setting")
            try TaxPolicyReceipts.save(db: db, &receipt)
            log.append("  \(entry.date) \(Money.format(amount, currency: currency)) \(receipt.label)"
                       + (receipt.cover.map { ", cover \(MissingEvidence.day($0.start)) – \(MissingEvidence.day($0.end))" } ?? "")
                       + (transaction.map { " → debit \(MissingEvidence.day($0.date)) \($0.rawDescription)" } ?? " → no debit (receipt kept on its own)"))
        }
        return log
    }

    static func ownerTransaction(db: Database, _ owner: Settings.Owner) throws -> Transaction {
        if let reference = owner.reference {
            let matches = try Transaction.filter(Column("rawDescription").like("%\(reference)%")).fetchAll(db)
            if matches.count == 1 { return matches[0] }
        }
        if let text = owner.amount, let amount = Money.parseMinorUnits(text), let dateText = owner.date {
            let date = try day(dateText)
            let matches = try Transaction.filter(Column("amountMinorUnits") == -amount && Column("date") >= date.addingTimeInterval(-3 * 86_400)
                                                 && Column("date") <= date.addingTimeInterval(3 * 86_400)).fetchAll(db)
            if matches.count == 1 { return matches[0] }
        }
        throw RegressionError.transactionNotFound(owner.reference ?? owner.date ?? owner.person)
    }

    static func day(_ text: String) throws -> Date {
        guard let date = RentReceiptsExport.parseDate(text) else { throw RegressionError.badDate(text) }
        return PropertyDates.day(date)
    }

    // MARK: Comparing

    public struct Comparison: Equatable, Sendable {
        public var figure: FiledFigure
        /// The engine's figure, `nil` when it has none (no rate, an uncompared field).
        public var app: Int?
        /// The line the field maps to (its sources explain the figure).
        public var expenseType: TaxExpenseType?
        public var difference: Int? { app.map { $0 - figure.minorUnits } }
        /// Within a cent: rounding.
        public var matches: Bool { difference.map { abs($0) <= 1 } ?? false }
    }

    /// The engine's value of a filed field: native EUR or GBP (pound items included).
    public static func appValue(field: String, currency: String, accounts: RentalAccounts.Result) -> (Int?, TaxExpenseType?) {
        let gbp = currency == "GBP"
        func value(_ amount: RentalAccounts.Amount) -> Int? { gbp ? amount.gbp : amount.native }
        func line(_ type: TaxExpenseType) -> (Int?, TaxExpenseType?) { (accounts.line(type).flatMap { value($0.amount) }, type) }
        let total = accounts.totals.expenses + accounts.totals.financeCosts
        switch field.replacingOccurrences(of: "template_eur_", with: "rental_exp_") {
        case "rental_income", "rental_exp_total_rental_receivable_income": return line(.rentalIncome)
        case "rental_exp_mortgage_interest": return line(.financeCost)
        case "residential_finance_costs": return (value(accounts.totals.financeCosts), .financeCost)
        case "rental_exp_service_charge": return line(.serviceCharge)
        case "rental_exp_insurance_building_insurance": return line(.insurance)
        case "rental_exp_council_tax_if_paid_by_landlord": return line(.councilTax)
        case "rental_exp_accountancy_fee": return line(.accountancy)
        case "rental_exp_any_other_expense": return line(.otherExpense)
        case "rental_exp_legal_fees": return line(.legalFees)
        case "rental_exp_letting_fee": return line(.lettingFees)
        case "rental_exp_repairs_and_maintenance": return line(.repairs)
        // The filed totals include the mortgage interest; the engine reports it apart.
        case "rental_total_expenses", "rental_exp_total_expenses": return (value(total), nil)
        case "rental_adjusted_profit": return (value(accounts.totals.profit), nil)
        case "rental_profit_before_finance_addback", "rental_exp_profit_loss_from_rental_income":
            return (value(accounts.totals.income - total), nil)
        case "foreign_tax_paid_confirmed_letter": return line(.foreignTax)
        default: return (nil, nil)
        }
    }

    /// The rental accounts of each person and year in `filed`, and the comparisons.
    public static func compare(db: Database, settings: Settings, filed: [FiledFigure]) throws -> (accounts: [String: RentalAccounts.Result], comparisons: [Comparison]) {
        let property = try propertyRecord(db: db, settings.property)
        var accounts: [String: RentalAccounts.Result] = [:]
        var comparisons: [Comparison] = []
        for figure in filed where settings.years.contains(where: { $0.startYear == figure.startYear }) {
            let key = "\(figure.startYear)|\(figure.person)"
            if accounts[key] == nil {
                let person = try personRecord(db: db, settings.personName(figure.person))
                accounts[key] = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: figure.startYear), personId: person.id!,
                                                           propertyId: property.id!)
            }
            let (app, type) = appValue(field: figure.field, currency: figure.currency, accounts: accounts[key]!)
            comparisons.append(Comparison(figure: figure, app: app, expenseType: type))
        }
        return (accounts, comparisons)
    }

    /// The whole property's figure of `type` for the year under each attribution rule (the
    /// stored settings untouched: each is tried in a rolled-back savepoint).
    public static func ruleAlternatives(db: Database, propertyId: Int64, personId: Int64, startYear: Int, type: TaxExpenseType,
                                        coverMonths: [Int] = [6, 12]) throws -> [(String, Int)] {
        var results: [(String, Int)] = []
        for rule in TaxAttributionRuleKind.allCases where rule != .byRentPeriod {
            let variants: [Int?] = rule == .apportionByCover ? coverMonths.map { $0 } : [nil]
            for months in variants {
                var whole = 0
                try db.inSavepoint {
                    try TaxAttributionRules.set(db: db, expenseType: type, startYear: startYear, rule: rule, defaultCoverMonths: months)
                    let accounts = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: startYear), personId: personId, propertyId: propertyId)
                    whole = accounts.line(type)?.whole.native ?? 0
                    return .rollback
                }
                results.append((rule.displayName + (months.map { " (\($0) months if unknown)" } ?? ""), whole))
            }
        }
        return results
    }

    // MARK: Report

    public static func report(_ comparisons: [Comparison], accounts: [String: RentalAccounts.Result]) -> String {
        var out = ""
        func money(_ value: Int?, _ currency: String) -> String {
            value.map { Money.format($0, currency: currency == "GBP" ? .gbp : .eur) } ?? "—"
        }
        let groups = Dictionary(grouping: comparisons) { "\($0.figure.startYear)|\($0.figure.person)" }
        for key in groups.keys.sorted() {
            let rows = groups[key]!
            let figure = rows[0].figure
            out += "\n== \(UKTaxYear(startYear: figure.startYear).label) · \(figure.person) ==\n"
            if let result = accounts[key] {
                if let rate = result.rate { out += "Rate: £\(rate.gbpPerUnit) per EUR (\(rate.source.rawValue))\n" }
                for warning in result.warnings { out += "! \(warning)\n" }
            }
            func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
                let padding = String(repeating: " ", count: max(0, width - text.count))
                return left ? text + padding : padding + text
            }
            out += " " + pad("field", 47, left: true) + " " + pad("cur", 4) + pad("filed", 15) + pad("app", 15) + pad("diff", 13) + "\n"
            for row in rows {
                out += (row.matches ? " " : "*") + pad(row.figure.field, 47, left: true) + " " + pad(row.figure.currency, 4)
                    + pad(money(row.figure.minorUnits, row.figure.currency), 15) + pad(money(row.app, row.figure.currency), 15)
                    + pad(money(row.difference, row.figure.currency), 13) + "\n"
            }
            // The sources of every line that differs.
            if let result = accounts[key] {
                let differing = Set(rows.filter { !$0.matches }.compactMap(\.expenseType))
                for type in TaxExpenseType.allCases where differing.contains(type) {
                    guard let line = result.line(type) else { continue }
                    out += "\n  \(line.label): \(line.ruleExplanation) Share: \(line.shareExplanation).\n"
                    for source in line.sources {
                        let date = source.date.map(MissingEvidence.day) ?? "—"
                        out += "    \(date)  \(source.description)  \(Money.format(source.attributedMinorUnits, currency: source.currency))"
                            + " of \(Money.format(source.amountMinorUnits, currency: source.currency)) — \(source.explanation)\n"
                    }
                    if line.sources.isEmpty { out += "    (no sources)\n" }
                }
            }
        }
        return out
    }

    // MARK: The real database guard

    /// The app's own data folders: `Application Support/Budget`, and the same inside any
    /// app container (`~/Library/Containers/*/Data/Library/Application Support/Budget`).
    public static func appDataFolders(fileManager: FileManager = .default) -> [URL] {
        var folders: [URL] = []
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            folders.append(support.appendingPathComponent("Budget", isDirectory: true))
        }
        let containers = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers", isDirectory: true)
        for container in (try? fileManager.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? [] {
            folders.append(container.appendingPathComponent("Data/Library/Application Support/Budget", isDirectory: true))
        }
        return folders
    }

    /// Whether `path` is (or would write into) the app's own database: inside one of
    /// `folders` once symlinks are resolved (compared case-insensitively, as APFS is), or the
    /// same file as one of their `budget.sqlite` (a hard link elsewhere). The regression tool
    /// refuses such a database path and such a report path.
    public static func isAppDatabase(_ path: String, folders: [URL]? = nil, fileManager: FileManager = .default) -> Bool {
        let folders = folders ?? appDataFolders(fileManager: fileManager)
        func resolved(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        }
        let target = URL(fileURLWithPath: path)
        // A file that doesn't exist yet (a report): resolve its folder.
        let resolvedTarget = fileManager.fileExists(atPath: target.path) ? resolved(target)
            : resolved(target.deletingLastPathComponent()) + "/" + target.lastPathComponent.lowercased()
        for folder in folders {
            let root = resolved(folder)
            if resolvedTarget == root || resolvedTarget.hasPrefix(root + "/") { return true }
        }
        guard let identity = fileIdentity(target, fileManager: fileManager) else { return false }
        for folder in folders {
            for name in ["budget.sqlite", "budget.sqlite-wal", "budget.sqlite-shm"] {
                if fileIdentity(folder.appendingPathComponent(name), fileManager: fileManager) == identity { return true }
            }
        }
        return false
    }

    /// Device and inode of an existing file.
    static func fileIdentity(_ url: URL, fileManager: FileManager) -> [UInt64]? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return [device, inode]
    }

    /// Whether two paths are the same file (or would be: equal once resolved).
    public static func isSameFile(_ a: String, _ b: String, fileManager: FileManager = .default) -> Bool {
        let ua = URL(fileURLWithPath: a), ub = URL(fileURLWithPath: b)
        if ua.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() == ub.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() {
            return true
        }
        guard let ia = fileIdentity(ua, fileManager: fileManager), let ib = fileIdentity(ub, fileManager: fileManager) else { return false }
        return ia == ib
    }

    // MARK: Helpers

    static func propertyRecord(db: Database, _ name: String) throws -> Property {
        guard let property = try Property.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db) else {
            throw RegressionError.propertyNotFound(name)
        }
        return property
    }

    static func personRecord(db: Database, _ name: String) throws -> Person {
        guard let person = try Person.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db) else {
            throw RegressionError.personNotFound(name)
        }
        return person
    }

    static func expenseType(_ raw: String) throws -> TaxExpenseType {
        guard let type = TaxExpenseType(rawValue: raw) else { throw RegressionError.badExpenseType(raw) }
        return type
    }
}
