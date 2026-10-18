import GRDB
import Foundation

/// One-off tax data for a property, from a plan (a personal JSON data file kept outside the
/// repository; this code only knows its shape): debits to categorise, the category → expense
/// type map, insurers' and condomínio receipts, payments that are one person's, HMRC rates
/// implied by filed returns, GBP manual items, attribution rules and HMRC's published rates
/// (fetched before the write, `fetchRates`). `apply` runs inside the caller's write and
/// is idempotent: what is already there is left alone (reported unchanged), and anything that
/// contradicts the stored data is refused — nothing is written then (the caller's transaction
/// rolls back). Tax year statuses are never touched.
public enum TaxDataPlan {
    // MARK: The plan

    public struct Plan: Codable, Equatable, Sendable {
        /// A debit identified by account (one of the property's), day and amount (and optionally
        /// text in its description); never a leg of an active transfer.
        public struct Categorize: Codable, Equatable, Sendable {
            /// The account's name.
            public var account: String
            /// "YYYY-MM-DD", the debit's day.
            public var date: String
            /// The debit, positive decimal text ("12.34").
            public var amount: String
            public var description: String?
            /// A category of the property's groups.
            public var category: String
            /// Creates the category (expense, in the property's first group) when missing.
            public var createCategory: Bool?
        }

        /// An insurer's (or condomínio) receipt: linked to the one debit of its amount on a
        /// property account within a week of `debitDate` (else `date`), else kept on its own.
        public struct PolicyReceipt: Codable, Equatable, Sendable {
            /// A `TaxExpenseType` raw value; `nil` = insurance.
            public var expenseType: String?
            public var date: String
            public var debitDate: String?
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

        /// Whose a payment is: the one transaction of the property's accounts whose description
        /// holds `reference` (checked against `amount` and `date` when given), else the one of
        /// `amount` within 3 days of `date`.
        public struct Owner: Codable, Equatable, Sendable {
            public var person: String
            public var reference: String?
            public var date: String?
            public var amount: String?
            public var note: String?
        }

        /// An HMRC rate implied by a filed return, stored when the year has none, and replacing a
        /// rate fetched automatically (the same figure is left as it is); a stored filed-return
        /// rate that differs is refused, and another source's (typed in) is left as it is.
        public struct Rate: Codable, Equatable, Sendable {
            public var startYear: Int
            /// ISO code; `nil` = "EUR".
            public var currency: String?
            /// Pounds per unit.
            public var gbpPerUnit: Double
            public var note: String?
        }

        /// A manual item, added only when the person's year has none with its label or with
        /// the same type, currency and amount.
        public struct ManualItem: Codable, Equatable, Sendable {
            public var startYear: Int
            public var person: String
            /// A `TaxExpenseType` raw value.
            public var expenseType: String
            public var label: String
            public var amount: String
            /// "GBP" or "EUR".
            public var currency: String
            public var date: String?
            public var wholeProperty: Bool?
            public var note: String?
        }

        /// An attribution rule, stored only when the scope has none, or has the seeded default
        /// (a rule the user set that differs is refused).
        public struct AttributionRule: Codable, Equatable, Sendable {
            /// A `TaxExpenseType` raw value.
            public var expenseType: String
            /// A `TaxAttributionRuleKind` raw value.
            public var rule: String
            /// `nil` = every year (the stored default); else that year's override.
            public var startYear: Int?
            /// For `apportionByCover`: the cover months assumed without a period.
            public var coverMonths: Int?
        }

        /// HMRC's published averages to fetch (the year to 31 March) and store where the year
        /// has no rate for the currency.
        public struct FetchRates: Codable, Equatable, Sendable {
            /// UK tax years (start years).
            public var years: [Int]
            /// ISO codes; `nil` = ["EUR"].
            public var currencies: [String]?
        }

        public var property: String
        public var categorize: [Categorize]?
        /// Category name → `TaxExpenseType` raw value.
        public var expenseTypes: [String: String]?
        public var policyReceipts: [PolicyReceipt]?
        public var transactionOwners: [Owner]?
        public var rates: [Rate]?
        public var manualItems: [ManualItem]?
        /// The UK tax years (start years) whose figures the tool reports after applying.
        public var summaryYears: [Int]?
        public var attributionRules: [AttributionRule]?
        public var fetchHMRCRates: FetchRates?
    }

    public enum PlanError: Error, Equatable, CustomStringConvertible {
        case unknownKeys([String])
        case propertyNotFound(String)
        /// Every contradiction or ambiguity found; nothing was applied.
        case refused([String])

        public var description: String {
            switch self {
            case .unknownKeys(let keys): return "Unknown keys in the plan: \(keys.joined(separator: ", "))"
            case .propertyNotFound(let name): return "No property named \(name)"
            case .refused(let problems): return "Refused (nothing applied):\n" + problems.map { "  - \($0)" }.joined(separator: "\n")
            }
        }
    }

    static let keys: [String: Set<String>] = [
        "": ["property", "categorize", "expenseTypes", "policyReceipts", "transactionOwners", "rates", "manualItems", "summaryYears",
             "attributionRules", "fetchHMRCRates"],
        "categorize": ["account", "date", "amount", "description", "category", "createCategory"],
        "policyReceipts": ["expenseType", "date", "debitDate", "amount", "currency", "policyYear", "instalment", "of", "coverFrom", "coverTo", "note"],
        "transactionOwners": ["person", "reference", "date", "amount", "note"],
        "rates": ["startYear", "currency", "gbpPerUnit", "note"],
        "manualItems": ["startYear", "person", "expenseType", "label", "amount", "currency", "date", "wholeProperty", "note"],
        "attributionRules": ["expenseType", "rule", "startYear", "coverMonths"],
        "fetchHMRCRates": ["years", "currencies"]
    ]

    /// Decodes the plan, refusing unknown keys (a typo would silently drop data).
    public static func decodePlan(_ data: Data) throws -> Plan {
        let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var unknown = root.keys.filter { !keys[""]!.contains($0) }.sorted()
        for (list, allowed) in keys.sorted(by: { $0.key < $1.key }) where !list.isEmpty {
            if let object = root[list] as? [String: Any] {
                unknown += object.keys.filter { !allowed.contains($0) }.sorted().map { "\(list).\($0)" }
            }
            for (index, item) in ((root[list] as? [Any]) ?? []).enumerated() {
                unknown += ((item as? [String: Any]) ?? [:]).keys.filter { !allowed.contains($0) }.sorted().map { "\(list)[\(index)].\($0)" }
            }
        }
        guard unknown.isEmpty else { throw PlanError.unknownKeys(unknown) }
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    // MARK: Applying

    public enum ChangeKind: String, Sendable {
        case added
        case unchanged
        /// Left as it is although the plan says otherwise (rates and manual items already present).
        case kept
    }

    public struct Change: Equatable, Sendable {
        public var section: String
        public var kind: ChangeKind
        public var text: String
    }

    public struct Outcome: Equatable, Sendable {
        public var propertyId: Int64
        public var changes: [Change]
        /// Categories created for the categorised debits.
        public var createdCategories: [String]

        public func count(_ kind: ChangeKind, in section: String? = nil) -> Int {
            changes.filter { $0.kind == kind && (section == nil || $0.section == section) }.count
        }
    }

    public static let sections = ["Categorised debits", "Expense types", "Policy receipts", "Payment owners", "HMRC rates", "Manual items",
                                  "Attribution rules", "HMRC rates fetched"]

    // MARK: Fetching HMRC's rates (before the write)

    /// HMRC's average-rates files fetched for the plan's `fetchHMRCRates`: start year → the
    /// file's rates, `nil` when it couldn't be fetched (offline, not published yet).
    public struct FetchedRates: Equatable, Sendable {
        public var byYear: [Int: [HMRCPublishedRate]?]

        public init(byYear: [Int: [HMRCPublishedRate]?] = [:]) {
            self.byYear = byYear
        }
    }

    /// The plan's `fetchHMRCRates` currencies (upper case; bad codes left for `apply` to refuse).
    static func fetchCodes(_ request: Plan.FetchRates) -> [String] {
        (request.currencies ?? ["EUR"]).compactMap { try? HMRCRates.normalizedCode($0) }
    }

    /// The `fetchHMRCRates` years that lack a stored rate for one of its currencies: the files
    /// to fetch (a year with every rate stored is skipped, not fetched).
    public static func yearsToFetch(db: Database, plan: Plan) throws -> [Int] {
        guard let request = plan.fetchHMRCRates else { return [] }
        let codes = fetchCodes(request)
        var years: [Int] = []
        for startYear in request.years where !years.contains(startYear) {
            if try codes.contains(where: { try HMRCRates.rate(db: db, startYear: startYear, currencyCode: $0) == nil }) { years.append(startYear) }
        }
        return years
    }

    /// Fetches each year's file once (HMRC's average for the year to 31 March).
    public static func fetchRates(years: [Int], fetcher: HMRCRateFetching) async -> FetchedRates {
        var fetched = FetchedRates()
        for startYear in years where fetched.byYear[startYear] == nil {
            fetched.byYear[startYear] = .some(await fetcher.fetchAverageRates(for: UKTaxYear(startYear: startYear)))
        }
        return fetched
    }

    /// Applies the plan inside the caller's write. Throws `PlanError.refused` with every
    /// problem found (the caller rolls back); otherwise returns what was added and what was
    /// already there. `fetched` holds the files `fetchRates` read for `fetchHMRCRates`.
    public static func apply(db: Database, plan: Plan, fetched: FetchedRates = FetchedRates(), now: Date = Date()) throws -> Outcome {
        guard let property = try Property.filter(sql: "name = ? COLLATE NOCASE", arguments: [plan.property]).fetchOne(db) else {
            throw PlanError.propertyNotFound(plan.property)
        }
        let propertyId = property.id!
        var state = State(db: db, propertyId: propertyId, now: now)
        try state.categorize(plan.categorize ?? [])
        try state.expenseTypes(plan.expenseTypes ?? [:])
        try state.policyReceipts(plan.policyReceipts ?? [])
        try state.owners(plan.transactionOwners ?? [])
        try state.rates(plan.rates ?? [])
        try state.manualItems(plan.manualItems ?? [])
        try state.attributionRules(plan.attributionRules ?? [])
        try state.fetchedRates(plan.fetchHMRCRates, fetched: fetched)
        guard state.problems.isEmpty else { throw PlanError.refused(state.problems) }
        return Outcome(propertyId: propertyId, changes: state.changes, createdCategories: state.created)
    }

    private struct State {
        let db: Database
        let propertyId: Int64
        let now: Date
        var changes: [Change] = []
        var problems: [String] = []
        var created: [String] = []

        init(db: Database, propertyId: Int64, now: Date) {
            self.db = db
            self.propertyId = propertyId
            self.now = now
        }

        mutating func note(_ section: String, _ kind: ChangeKind, _ text: String) {
            changes.append(Change(section: section, kind: kind, text: text))
        }

        func eur(_ minor: Int, _ currency: Currency = .eur) -> String { Money.format(minor, currency: currency) }

        func person(_ name: String) throws -> Person? {
            try Person.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db)
        }

        func dayRange(_ date: Date, days: Int) -> (Date, Date) {
            (date.addingTimeInterval(Double(-days) * 86_400), date.addingTimeInterval(Double(days + 1) * 86_400 - 1))
        }

        func describe(_ t: Transaction) -> String {
            "\(MissingEvidence.day(t.date)) \(t.rawDescription) \(eur(-t.amountMinorUnits))"
        }

        // 1. Debits to categorise.
        mutating func categorize(_ entries: [Plan.Categorize]) throws {
            let section = TaxDataPlan.sections[0]
            let groupIds = try Properties.categoryGroupIds(db: db, propertyId: propertyId)
            let accountIds = Set(try Properties.accounts(db: db, propertyId: propertyId).map(\.accountId))
            let transferLegs = Set(try TransferLink.active.fetchAll(db).flatMap { [$0.outTransactionId, $0.inTransactionId] })
            var used: Set<Int64> = []
            for entry in entries {
                let what = "\(entry.date) \(entry.amount) (\(entry.account))"
                guard let amount = Money.parseMinorUnits(entry.amount), amount > 0 else { problems.append("\(section): bad amount \(entry.amount)"); continue }
                guard let date = try? TaxDataPlan.day(entry.date) else { problems.append("\(section): bad date \(entry.date)"); continue }
                guard let account = try Account.filter(sql: "name = ? COLLATE NOCASE", arguments: [entry.account]).fetchOne(db) else {
                    problems.append("\(section): no account named \(entry.account)"); continue
                }
                guard accountIds.contains(account.id!) else {
                    problems.append("\(section): \(entry.account) is not an account of the property (for \(what))"); continue
                }
                var category = try Category.filter(groupIds.contains(Column("groupId")))
                    .filter(sql: "name = ? COLLATE NOCASE", arguments: [entry.category]).fetchOne(db)
                if category == nil, entry.createCategory == true, let groupId = groupIds.first {
                    category = try Categories.create(db: db, name: entry.category, type: .expense, groupId: groupId)
                    created.append(entry.category)
                }
                guard let category else { problems.append("\(section): no category \(entry.category) in the property's groups (for \(what))"); continue }
                guard !category.isBuiltIn, category.isAssignable else {
                    problems.append("\(section): \(category.name) can't hold transactions (built-in or reserved)"); continue
                }
                let (from, to) = dayRange(date, days: 0)
                var matches = try Transaction.filter(Column("accountId") == account.id! && Column("amountMinorUnits") == -amount
                                                     && Column("date") >= from && Column("date") <= to).fetchAll(db)
                if let text = entry.description { matches = matches.filter { $0.rawDescription.localizedCaseInsensitiveContains(text) } }
                matches = matches.filter { !transferLegs.contains($0.id!) }
                guard matches.count == 1, let transaction = matches.first else {
                    problems.append("\(section): \(matches.count) debits match \(what), expected exactly one"); continue
                }
                guard used.insert(transaction.id!).inserted else {
                    problems.append("\(section): \(describe(transaction)) is matched by more than one entry"); continue
                }
                if transaction.categoryId == category.id {
                    note(section, .unchanged, "\(describe(transaction)) already \(category.name)")
                } else if let current = transaction.categoryId {
                    let name = try Category.fetchOne(db, key: current)?.name ?? "#\(current)"
                    problems.append("\(section): \(describe(transaction)) is already categorised as \(name), not \(category.name)")
                } else {
                    try TransactionEditing.setCategory(db: db, ids: [transaction.id!], categoryId: category.id!, remember: false)
                    note(section, .added, "\(describe(transaction)) → \(category.name)")
                }
            }
        }

        // 2. Category → expense type.
        mutating func expenseTypes(_ map: [String: String]) throws {
            let section = TaxDataPlan.sections[1]
            guard !map.isEmpty else { return }
            let entries = try TaxExpenseTypeMap.entries(db: db, propertyId: propertyId)
            var planned: [Int64: TaxExpenseType] = [:]
            for (name, raw) in map.sorted(by: { $0.key < $1.key }) {
                guard let type = TaxExpenseType(rawValue: raw) else { problems.append("\(section): unknown type \(raw) for \(name)"); continue }
                guard let entry = entries.first(where: { $0.category.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    problems.append("\(section): \(name) is not an income or expense category of the property"); continue
                }
                planned[entry.category.id!] = type
            }
            for entry in entries {
                guard let type = planned[entry.category.id!] else {
                    note(section, .kept, "\(entry.category.name): not in the plan, left \(entry.isStored ? "stored as" : "to the suggestion") \(entry.expenseType.displayName)")
                    continue
                }
                let suggested = TaxExpenseTypeMap.suggestedType(forCategoryName: entry.category.name, type: entry.category.type)
                let versus = type == suggested ? "confirms the suggestion" : "suggestion was \(suggested.displayName)"
                if entry.isStored {
                    if entry.expenseType == type {
                        note(section, .unchanged, "\(entry.category.name): already \(type.displayName)")
                    } else {
                        problems.append("\(section): \(entry.category.name) is stored as \(entry.expenseType.displayName), the plan says \(type.displayName)")
                    }
                } else {
                    try TaxExpenseTypeMap.set(db: db, categoryId: entry.category.id!, expenseType: type)
                    note(section, .added, "\(entry.category.name) → \(type.displayName) (\(versus))")
                }
            }
        }

        // 3. Insurers' and condomínio receipts.
        mutating func policyReceipts(_ entries: [Plan.PolicyReceipt]) throws {
            let section = TaxDataPlan.sections[2]
            let accountIds = try Properties.accounts(db: db, propertyId: propertyId).map(\.accountId)
            var used: Set<Int64> = []
            for entry in entries {
                let what = "\(entry.date) \(entry.amount)"
                guard let amount = Money.parseMinorUnits(entry.amount), amount > 0 else { problems.append("\(section): bad amount \(entry.amount)"); continue }
                guard let currency = Currency(rawValue: (entry.currency ?? "EUR").lowercased()) else {
                    problems.append("\(section): bad currency \(entry.currency ?? "")"); continue
                }
                let type = entry.expenseType.flatMap(TaxExpenseType.init(rawValue:)) ?? (entry.expenseType == nil ? .insurance : nil)
                guard let type else { problems.append("\(section): unknown type \(entry.expenseType ?? "") for \(what)"); continue }
                guard let date = try? TaxDataPlan.day(entry.date), let debitDate = TaxDataPlan.optionalDay(entry.debitDate),
                      let coverStart = TaxDataPlan.optionalDay(entry.coverFrom), let coverEnd = TaxDataPlan.optionalDay(entry.coverTo) else {
                    problems.append("\(section): bad date in \(what)"); continue
                }
                let debitDay = debitDate ?? date
                let (from, to) = dayRange(debitDay, days: 7)
                let candidates = try Transaction
                    .filter(accountIds.contains(Column("accountId")) && Column("amountMinorUnits") == -amount
                            && Column("date") >= from && Column("date") <= to)
                    .fetchAll(db).filter { !used.contains($0.id!) }
                guard candidates.count <= 1 else {
                    problems.append("\(section): \(candidates.count) debits of \(entry.amount) within a week of \(MissingEvidence.day(debitDay)): ambiguous")
                    continue
                }
                let debit = candidates.first
                if let id = debit?.id { used.insert(id) }
                var receipt = TaxPolicyReceipt(propertyId: propertyId, expenseType: type, transactionId: debit?.id, date: debit?.date ?? date,
                                               amountMinorUnits: amount, currency: currency, policyYear: entry.policyYear,
                                               instalment: entry.instalment, instalmentCount: entry.of, coverStart: coverStart,
                                               coverEnd: coverEnd, notes: entry.note ?? "Tax data plan")
                let label = "\(type.displayName) \(what) \(receipt.label)"
                    + (receipt.cover.map { ", cover \(MissingEvidence.day($0.start)) – \(MissingEvidence.day($0.end))" } ?? "")
                    + (debit.map { " → debit \(describe($0))" } ?? " → no debit (kept on its own)")
                // Already there: the receipt of that debit, else one on its own of that amount and
                // type on the plan's day or the debit's (linked to the debit when there is one).
                var existing: TaxPolicyReceipt? = nil
                if let id = debit?.id { existing = try TaxPolicyReceipt.filter(Column("transactionId") == id).fetchOne(db) }
                if existing == nil {
                    let days = Set([date] + (debit.map { [PropertyDates.day($0.date)] } ?? []))
                    existing = try TaxPolicyReceipt.filter(Column("propertyId") == propertyId && Column("transactionId") == nil
                                                           && Column("expenseType") == type.rawValue && Column("amountMinorUnits") == amount)
                        .fetchAll(db).first { days.contains(PropertyDates.day($0.date)) }
                }
                if var existing {
                    func same(_ a: Date?, _ b: Date?) -> Bool { a.map(PropertyDates.day) == b.map(PropertyDates.day) }
                    guard existing.propertyId == propertyId, existing.expenseType == type, existing.currency == currency,
                          existing.policyYear == entry.policyYear, existing.instalment == entry.instalment,
                          existing.instalmentCount == entry.of, same(existing.coverStart, coverStart), same(existing.coverEnd, coverEnd) else {
                        problems.append("\(section): a different receipt is already recorded for \(what) (\(existing.label))")
                        continue
                    }
                    if existing.transactionId == nil, let debit {
                        existing.transactionId = debit.id
                        existing.date = debit.date
                        try TaxPolicyReceipts.save(db: db, &existing)
                        note(section, .added, label + " (the recorded receipt, now linked to its debit)")
                    } else {
                        note(section, .unchanged, label + " (already recorded)")
                    }
                    continue
                }
                do {
                    try TaxPolicyReceipts.save(db: db, &receipt)
                    note(section, .added, label)
                } catch {
                    problems.append("\(section): \(what): \(error)")
                }
            }
        }

        // 4. Payments that are one person's.
        mutating func owners(_ entries: [Plan.Owner]) throws {
            let section = TaxDataPlan.sections[3]
            let accountIds = try Properties.accounts(db: db, propertyId: propertyId).map(\.accountId)
            for entry in entries {
                let what = entry.reference ?? "\(entry.date ?? "?") \(entry.amount ?? "?")"
                guard let person = try person(entry.person) else { problems.append("\(section): no person named \(entry.person)"); continue }
                let amount = entry.amount.flatMap(Money.parseMinorUnits)
                if entry.amount != nil && amount == nil { problems.append("\(section): bad amount \(entry.amount!)"); continue }
                guard let date = TaxDataPlan.optionalDay(entry.date) else { problems.append("\(section): bad date \(entry.date ?? "")"); continue }
                var matches: [Transaction]
                if let reference = entry.reference {
                    // Filtered here: a reference may hold LIKE wildcards.
                    matches = try Transaction.filter(accountIds.contains(Column("accountId"))).fetchAll(db)
                        .filter { $0.rawDescription.contains(reference) }
                } else if let amount, let date {
                    let (from, to) = dayRange(date, days: 3)
                    matches = try Transaction.filter(accountIds.contains(Column("accountId")) && Column("amountMinorUnits") == -amount
                                                     && Column("date") >= from && Column("date") <= to).fetchAll(db)
                } else {
                    problems.append("\(section): \(entry.person) needs a reference, or an amount and a date"); continue
                }
                guard matches.count == 1, let transaction = matches.first else {
                    problems.append("\(section): \(matches.count) transactions match \(what), expected exactly one"); continue
                }
                if let amount, transaction.amountMinorUnits != -amount {
                    problems.append("\(section): \(describe(transaction)) is not \(entry.amount!)"); continue
                }
                if let date, abs(PropertyDates.day(transaction.date).timeIntervalSince(date)) > 3 * 86_400 {
                    problems.append("\(section): \(describe(transaction)) is not on \(entry.date!)"); continue
                }
                if let existing = try TaxTransactionOwner.filter(Column("transactionId") == transaction.id!).fetchOne(db) {
                    if existing.personId == person.id {
                        note(section, .unchanged, "\(describe(transaction)) already \(person.name)'s")
                    } else {
                        let other = try Person.fetchOne(db, key: existing.personId)?.name ?? "#\(existing.personId)"
                        problems.append("\(section): \(describe(transaction)) is already assigned to \(other), not \(person.name)")
                    }
                    continue
                }
                do {
                    try TaxTransactionOwners.set(db: db, transactionId: transaction.id!, personId: person.id!, notes: entry.note ?? "Tax data plan")
                    note(section, .added, "\(describe(transaction)) → \(person.name)")
                } catch {
                    problems.append("\(section): \(describe(transaction)) → \(person.name): \(error)")
                }
            }
        }

        // 5a. HMRC rates as filed.
        mutating func rates(_ entries: [Plan.Rate]) throws {
            let section = TaxDataPlan.sections[4]
            for entry in entries {
                let code = (entry.currency ?? "EUR").uppercased()
                let year = UKTaxYear(startYear: entry.startYear).label
                if let existing = try HMRCRates.rate(db: db, startYear: entry.startYear, currencyCode: code), existing.isFetchedAutomatically {
                    // The filed return's rate is what was filed: it replaces a rate fetched
                    // automatically. The same figure stays as it is, now marked as the filed
                    // return's, so a later automatic fetch leaves it alone.
                    if abs(existing.gbpPerUnit - entry.gbpPerUnit) < 1e-9 {
                        do {
                            try HMRCRates.set(db: db, startYear: entry.startYear, currencyCode: code, gbpPerUnit: existing.gbpPerUnit,
                                              unitsPerPound: existing.unitsPerPound, source: .filedReturn,
                                              notes: entry.note ?? "Implied by the filed return")
                            note(section, .unchanged, "\(year) \(code) £\(entry.gbpPerUnit) the same as filed; now marked as the filed return's")
                        } catch {
                            problems.append("\(section): \(year) \(code) £\(entry.gbpPerUnit): \(error)")
                        }
                        continue
                    }
                    do {
                        try HMRCRates.set(db: db, startYear: entry.startYear, currencyCode: code, gbpPerUnit: entry.gbpPerUnit, source: .filedReturn,
                                          notes: entry.note ?? "Implied by the filed return")
                        note(section, .added, "\(year) \(code) £\(entry.gbpPerUnit) (filed return) replaces the automatically fetched £\(existing.gbpPerUnit)")
                    } catch {
                        problems.append("\(section): \(year) \(code) £\(entry.gbpPerUnit): \(error)")
                    }
                    continue
                }
                if let existing = try HMRCRates.rate(db: db, startYear: entry.startYear, currencyCode: code) {
                    if abs(existing.gbpPerUnit - entry.gbpPerUnit) < 1e-9 && existing.source == .filedReturn {
                        note(section, .unchanged, "\(year) \(code) £\(entry.gbpPerUnit) already stored (filed return)")
                    } else if existing.source == .filedReturn {
                        problems.append("\(section): \(year) \(code) has the filed-return rate £\(existing.gbpPerUnit) stored, the plan says £\(entry.gbpPerUnit)")
                    } else {
                        note(section, .kept, "\(year) \(code): kept the stored £\(existing.gbpPerUnit) (\(existing.source.rawValue)); the plan has £\(entry.gbpPerUnit)")
                    }
                    continue
                }
                do {
                    try HMRCRates.set(db: db, startYear: entry.startYear, currencyCode: code, gbpPerUnit: entry.gbpPerUnit, source: .filedReturn,
                                      notes: entry.note ?? "Implied by the filed return")
                    note(section, .added, "\(year) \(code) £\(entry.gbpPerUnit) (filed return)")
                } catch {
                    problems.append("\(section): \(year) \(code) £\(entry.gbpPerUnit): \(error)")
                }
            }
        }

        // 5b. Manual items (GBP accountant, postage…).
        mutating func manualItems(_ entries: [Plan.ManualItem]) throws {
            let section = TaxDataPlan.sections[5]
            for entry in entries {
                let year = UKTaxYear(startYear: entry.startYear).label
                guard let person = try person(entry.person) else { problems.append("\(section): no person named \(entry.person)"); continue }
                guard let type = TaxExpenseType(rawValue: entry.expenseType) else { problems.append("\(section): unknown type \(entry.expenseType)"); continue }
                guard let amount = Money.parseMinorUnits(entry.amount), amount >= 0 else { problems.append("\(section): bad amount \(entry.amount)"); continue }
                guard let currency = Currency(rawValue: entry.currency.lowercased()) else { problems.append("\(section): bad currency \(entry.currency)"); continue }
                guard let date = TaxDataPlan.optionalDay(entry.date) else { problems.append("\(section): bad date \(entry.date ?? "")"); continue }
                let what = "\(year) \(person.name): \(entry.label) \(eur(amount, currency))"
                let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let theirs = try TaxManualItems.items(db: db, startYear: entry.startYear, personId: person.id!)
                if let same = theirs.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
                    let identical = same.amountMinorUnits == amount && same.currency == currency && same.expenseType == type
                    note(section, identical ? .unchanged : .kept,
                         identical ? "\(what) already present" : "\(what): kept the stored item of that label (\(eur(same.amountMinorUnits, same.currency)), \(same.expenseType.displayName))")
                    continue
                }
                if let same = theirs.first(where: { $0.expenseType == type && $0.currency == currency && $0.amountMinorUnits == amount }) {
                    note(section, .kept, "\(what): the year already has \"\(same.label)\" of that type and amount — not added")
                    continue
                }
                var item = TaxManualItem(startYear: entry.startYear, personId: person.id!, propertyId: propertyId, expenseType: type, label: label,
                                         amountMinorUnits: amount, currency: currency, date: date, isWholeProperty: entry.wholeProperty ?? false,
                                         notes: entry.note ?? "Tax data plan")
                do {
                    try TaxManualItems.save(db: db, &item)
                    note(section, .added, what + (item.isWholeProperty ? " (whole property)" : ""))
                } catch {
                    problems.append("\(section): \(what): \(error)")
                }
            }
        }

        // 6. Attribution rules.
        mutating func attributionRules(_ entries: [Plan.AttributionRule]) throws {
            let section = TaxDataPlan.sections[6]
            func text(_ rule: TaxAttributionRuleKind, _ months: Int?) -> String {
                rule.displayName + (months.map { ", \($0) months of cover assumed" } ?? "")
            }
            func scope(_ startYear: Int?) -> String { startYear.map { UKTaxYear(startYear: $0).label } ?? "every year" }
            var seen: Set<String> = []
            for entry in entries {
                guard let type = TaxExpenseType(rawValue: entry.expenseType) else { problems.append("\(section): unknown type \(entry.expenseType)"); continue }
                guard let rule = TaxAttributionRuleKind(rawValue: entry.rule) else {
                    problems.append("\(section): unknown rule \(entry.rule) for \(type.displayName)"); continue
                }
                let what = "\(type.displayName), \(scope(entry.startYear))"
                if let months = entry.coverMonths, months < 1 { problems.append("\(section): \(what): cover months must be 1 or more"); continue }
                guard seen.insert("\(type.rawValue):\(entry.startYear.map(String.init) ?? "-")").inserted else {
                    problems.append("\(section): \(what) is in the plan more than once"); continue
                }
                let planned = text(rule, entry.coverMonths)
                var request = TaxAttributionRule.filter(Column("expenseType") == type.rawValue)
                request = entry.startYear.map { request.filter(Column("startYear") == $0) } ?? request.filter(Column("startYear") == nil)
                if let existing = try request.fetchOne(db) {
                    let stored = text(existing.rule, existing.defaultCoverMonths)
                    if existing.rule == rule && existing.defaultCoverMonths == entry.coverMonths {
                        note(section, .unchanged, "\(what): already \(planned)")
                    } else if existing.notes == TaxAttributionRules.seededNote {
                        // The seeded default isn't the user's choice: the plan's replaces it.
                        try TaxAttributionRules.set(db: db, expenseType: type, startYear: entry.startYear, rule: rule,
                                                    defaultCoverMonths: entry.coverMonths, notes: "Tax data plan")
                        note(section, .added, "\(what): \(planned) (replaces the seeded default, \(stored))")
                    } else {
                        problems.append("\(section): \(what) is set to \(stored), the plan says \(planned)")
                        continue
                    }
                } else {
                    let before = try TaxAttributionRules.effective(db: db, expenseType: type, startYear: entry.startYear ?? Int.min)
                    let origin = before.id == nil ? "the built-in default" : "the every-year rule"
                    try TaxAttributionRules.set(db: db, expenseType: type, startYear: entry.startYear, rule: rule,
                                                defaultCoverMonths: entry.coverMonths, notes: "Tax data plan")
                    note(section, .added, "\(what): \(planned) (was \(origin), \(text(before.rule, before.defaultCoverMonths)))")
                }
                // An every-year rule: a year with its own (different) rule keeps it.
                if entry.startYear == nil {
                    let overrides = try TaxAttributionRule.filter(Column("expenseType") == type.rawValue && Column("startYear") != nil)
                        .order(Column("startYear")).fetchAll(db)
                    for override in overrides where override.rule != rule || override.defaultCoverMonths != entry.coverMonths {
                        note(section, .kept, "\(type.displayName), \(scope(override.startYear)): its own rule, \(text(override.rule, override.defaultCoverMonths)), still applies")
                    }
                }
            }
        }

        // 7. HMRC's published averages, fetched before the write.
        mutating func fetchedRates(_ request: Plan.FetchRates?, fetched: FetchedRates) throws {
            guard let request else { return }
            let section = TaxDataPlan.sections[7]
            for raw in request.currencies ?? [] where (try? HMRCRates.normalizedCode(raw)) == nil {
                problems.append("\(section): bad currency \(raw)")
            }
            let codes = TaxDataPlan.fetchCodes(request)
            var years: [Int] = []
            for startYear in request.years where !years.contains(startYear) { years.append(startYear) }
            for startYear in years {
                let year = UKTaxYear(startYear: startYear)
                let url = HMRCRateFile.averageURL(for: year).absoluteString
                let average = "HMRC average for the year to 31 March \(startYear + 1)"
                for code in codes {
                    if let existing = try HMRCRates.rate(db: db, startYear: startYear, currencyCode: code) {
                        note(section, .unchanged, "\(year.label) \(code): already stored, \(existing.bothWaysText) (\(existing.source.rawValue)) — not fetched")
                        continue
                    }
                    guard let file = fetched.byYear[startYear] else {
                        problems.append("\(section): \(year.label) wasn't fetched"); continue
                    }
                    guard let rates = file else {
                        problems.append("\(section): couldn't fetch HMRC's average rates for \(year.label) from \(url) (offline, or not published yet)")
                        continue
                    }
                    guard let published = rates.first(where: { $0.currencyCode == code }) else {
                        problems.append("\(section): HMRC's average rates for \(year.label) (\(url)) have no \(code) rate"); continue
                    }
                    let rate = try HMRCRates.set(db: db, startYear: startYear, currencyCode: code, gbpPerUnit: published.gbpPerUnit,
                                                 unitsPerPound: published.unitsPerPound, source: .hmrcPublished, fetchedAt: now,
                                                 notes: "\(HMRCRates.autoFetchedNotePrefix) (tax data plan): \(average), \(url)")
                    note(section, .added, "\(year.label) \(code): \(rate.bothWaysText), \(average) — \(url)")
                }
            }
        }
    }

    static func day(_ text: String) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = EvidenceDateParser.makeDate(year: parts[0], month: parts[1], day: parts[2]) else {
            throw TaxRegression.RegressionError.badDate(text)
        }
        return PropertyDates.day(date)
    }

    /// A plan's optional day: `.some(nil)` when absent, `nil` when it doesn't parse.
    static func optionalDay(_ text: String?) -> Date?? {
        guard let text else { return .some(nil) }
        guard let date = try? day(text) else { return nil }
        return .some(date)
    }

    // MARK: Report

    /// The changes, by section.
    public static func report(_ outcome: Outcome) -> String {
        var out = ""
        for section in sections {
            let rows = outcome.changes.filter { $0.section == section }
            guard !rows.isEmpty else { continue }
            out += "== \(section): \(outcome.count(.added, in: section)) added, \(outcome.count(.unchanged, in: section)) already there"
                + (outcome.count(.kept, in: section) > 0 ? ", \(outcome.count(.kept, in: section)) left as stored" : "") + " ==\n"
            for row in rows {
                let mark: String
                switch row.kind {
                case .added: mark = "+"
                case .unchanged: mark = "="
                case .kept: mark = "~"
                }
                out += "\(mark) \(row.text)\n"
            }
            out += "\n"
        }
        if !outcome.createdCategories.isEmpty { out += "Categories created: \(outcome.createdCategories.joined(separator: ", "))\n\n" }
        return out
    }

    /// Each owner's rental accounts for the years, as the app computes them from the stored
    /// records: lines in the property's currency, totals in GBP at the year's rate, warnings.
    public static func figures(db: Database, propertyId: Int64, years: [Int]) throws -> String {
        var out = ""
        let ownerIds = Array(Set(try Properties.owners(db: db, propertyId: propertyId).map(\.personId))).sorted()
        for startYear in years {
            for personId in ownerIds {
                let name = try Person.fetchOne(db, key: personId)?.name ?? "#\(personId)"
                let result = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: startYear), personId: personId, propertyId: propertyId)
                let currency = result.currency
                func money(_ amount: RentalAccounts.Amount) -> String {
                    Money.format(amount.native, currency: currency) + (amount.gbp.map { " (\(Money.format($0, currency: .gbp)))" } ?? "")
                }
                out += "\n== \(UKTaxYear(startYear: startYear).label) · \(name) ==\n"
                // A published rate (units per £1) shows both forms, the pounds to 4 places.
                out += "Rate: " + (result.rate.map { rate in
                    let pounds = rate.unitsPerPound == nil ? "\(rate.gbpPerUnit)" : String(format: "%.4f", rate.gbpPerUnit)
                    return "£\(pounds) per \(currency.rawValue.uppercased()) (\(rate.source.rawValue))"
                        + (rate.unitsPerPound.map { " = \($0) per £1" } ?? "")
                } ?? "none stored") + "\n"
                for line in result.allLines where line.amount.native != 0 || line.amount.gbpNative != 0 || line.expenseType == .rentalIncome {
                    let padded = line.label.padding(toLength: 34, withPad: " ", startingAt: 0)
                    out += "  \(padded) \(money(line.amount))  [\(line.rule.displayName); \(line.shareExplanation)]\n"
                }
                out += "  Total expenses \(money(result.totals.expenses)) · finance costs \(money(result.totals.financeCosts))"
                    + " · profit \(money(result.totals.profit)) · foreign tax \(money(result.totals.foreignTax))\n"
                for warning in result.warnings { out += "  ! \(warning)\n" }
            }
        }
        return out
    }
}
