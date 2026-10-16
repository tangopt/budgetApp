import GRDB
import Foundation

/// Sets up a property from a plan (plan 2026-10-16 phase 2, Task 5): owners, linked accounts
/// and category groups, the portal's receipts, the terms of a tenancy, credit matching and the
/// evidence rules — idempotently, in the caller's transaction. The plan holds the personal
/// values (names, shares, terms) and comes from a data file outside the repository.
public enum PropertySetUp {
    public struct Plan: Codable, Equatable, Sendable {
        public struct PropertyInfo: Codable, Equatable, Sendable {
            public var name: String
            public var country: String
            public var currency: Currency
            public var matrixArticle: String?
            /// Decimal text in the property's currency ("250000.00").
            public var purchasePrice: String?
            /// "YYYY-MM-DD".
            public var purchaseDate: String?
        }

        public struct Owner: Codable, Equatable, Sendable {
            public var name: String
            public var shortName: String?
            /// Percent, e.g. 50 or 33.33.
            public var share: Double
            public var from: String?
            public var to: String?
        }

        public struct AccountLink: Codable, Equatable, Sendable {
            /// The account's name or alias.
            public var account: String
            public var role: PropertyAccountRole
        }

        public struct Rent: Codable, Equatable, Sendable {
            /// "YYYY-MM-DD", or "start" for the tenancy's start.
            public var from: String
            /// Decimal text, e.g. "1000".
            public var amount: String
        }

        public struct TenancyTerms: Codable, Equatable, Sendable {
            /// The tenancy by contract number; `nil` = the latest-starting one.
            public var contractNumber: String?
            public var advanceRentMonths: Int?
            public var depositMonths: Int?
            /// Replaces the rent history; `nil` keeps it (or derives it, with `rentsFromReceipts`).
            public var rents: [Rent]?
            /// When `rents` is nil: derive the history from the whole-month receipts.
            public var rentsFromReceipts: Bool?
        }

        public var property: PropertyInfo
        public var owners: [Owner]
        public var accounts: [AccountLink]
        public var categoryGroups: [String]
        public var tenancies: [TenancyTerms]
        public var seedEvidenceRules: Bool?
    }

    public enum SetUpError: Error, Equatable {
        case accountNotFound(String)
        case categoryGroupNotFound(String)
        case tenancyNotFound(String)
        case badDate(String)
        case badAmount(String)
        /// `rentsFromReceipts` found no whole-month receipt to read the rent from.
        case noWholeMonthReceipts(String)
        /// Keys the plan doesn't know (a typo would otherwise be ignored), by path.
        case unknownKeys([String])
    }

    /// Reads a plan from JSON, refusing keys it doesn't know.
    public static func decodePlan(_ data: Data) throws -> Plan {
        let json = try JSONSerialization.jsonObject(with: data)
        var unknown: [String] = []
        func check(_ value: Any, _ allowed: Set<String>, _ path: String) {
            guard let object = value as? [String: Any] else { return }
            for key in object.keys.sorted() where !allowed.contains(key) { unknown.append(path.isEmpty ? key : "\(path).\(key)") }
        }
        func checkArray(_ value: Any?, _ allowed: Set<String>, _ path: String, nested: ((Any, String) -> Void)? = nil) {
            for (index, item) in ((value as? [Any]) ?? []).enumerated() {
                check(item, allowed, "\(path)[\(index)]")
                nested?(item, "\(path)[\(index)]")
            }
        }
        check(json, ["property", "owners", "accounts", "categoryGroups", "tenancies", "seedEvidenceRules"], "")
        let root = json as? [String: Any] ?? [:]
        if let property = root["property"] {
            check(property, ["name", "country", "currency", "matrixArticle", "purchasePrice", "purchaseDate"], "property")
        }
        checkArray(root["owners"], ["name", "shortName", "share", "from", "to"], "owners")
        checkArray(root["accounts"], ["account", "role"], "accounts")
        checkArray(root["tenancies"], ["contractNumber", "advanceRentMonths", "depositMonths", "rents", "rentsFromReceipts"], "tenancies") { item, path in
            checkArray((item as? [String: Any])?["rents"], ["from", "amount"], "\(path).rents")
        }
        guard unknown.isEmpty else { throw SetUpError.unknownKeys(unknown) }
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    public struct Outcome: Equatable, Sendable {
        public var propertyId: Int64
        public var createdProperty: Bool
        public var createdPeople: [String]
        public var receiptsImport: RentReceiptImport.Report?
        /// Per tenancy changed by the terms: its id and the rent history derived from receipts
        /// (for comparison with the plan's).
        public var derivedRents: [Int64: [TenancyRent]]
        public var matching: RentReceiptMatching.Result
        public var seededRules: [String]
    }

    /// Runs the plan; `receiptRows` (the parsed export) are imported when given.
    public static func run(db: Database, plan: Plan, receiptRows: [RentReceiptsExport.Row]?,
                           matchOptions: RentReceiptMatching.Options = .init()) throws -> Outcome {
        // Property.
        var created = false
        var property = try Property.filter(sql: "name = ? COLLATE NOCASE", arguments: [plan.property.name]).fetchOne(db)
            ?? { created = true; return Property(name: plan.property.name, country: plan.property.country) }()
        property.country = plan.property.country
        property.currency = plan.property.currency
        if let article = plan.property.matrixArticle { property.matrixArticle = article }
        if let price = plan.property.purchasePrice { property.purchasePriceMinorUnits = try amount(price) }
        if let date = plan.property.purchaseDate { property.purchaseDate = try day(date) }
        try Properties.save(db: db, &property)
        let propertyId = property.id!

        // People and owners.
        var createdPeople: [String] = []
        var owners: [PropertyOwner] = []
        for owner in plan.owners {
            var person = try Person.filter(sql: "name = ? COLLATE NOCASE", arguments: [owner.name]).fetchOne(db)
                ?? { createdPeople.append(owner.name); return Person(name: owner.name, shortName: owner.shortName) }()
            if person.id == nil { try People.save(db: db, &person) }
            owners.append(PropertyOwner(propertyId: propertyId, personId: person.id!, shareBasisPoints: Int((owner.share * 100).rounded()),
                                        fromDate: try owner.from.map(day), toDate: try owner.to.map(day)))
        }
        if !owners.isEmpty { _ = try Properties.setOwners(db: db, propertyId: propertyId, owners) }

        // Accounts and groups.
        let accounts = try Account.fetchAll(db)
        for link in plan.accounts {
            guard let account = accounts.first(where: { $0.name.caseInsensitiveCompare(link.account) == .orderedSame })
                    ?? accounts.first(where: { $0.displayName.caseInsensitiveCompare(link.account) == .orderedSame }) else {
                throw SetUpError.accountNotFound(link.account)
            }
            _ = try Properties.setAccount(db: db, propertyId: propertyId, accountId: account.id!, role: link.role)
        }
        let groups = try CategoryGroup.fetchAll(db)
        for name in plan.categoryGroups {
            guard let group = groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw SetUpError.categoryGroupNotFound(name)
            }
            try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: group.id!)
        }

        // Receipts.
        let report = try receiptRows.map { try RentReceiptImport.run(db: db, propertyId: propertyId, rows: $0, matchOptions: matchOptions) }

        // Tenancy terms.
        var derived: [Int64: [TenancyRent]] = [:]
        for terms in plan.tenancies {
            let tenancies = try Tenancies.all(db: db, propertyId: propertyId)
            let found = terms.contractNumber.map { number in tenancies.first { $0.contractNumber == number } } ?? tenancies.last
            guard var tenancy = found else { throw SetUpError.tenancyNotFound(terms.contractNumber ?? "latest") }
            if let months = terms.advanceRentMonths { tenancy.advanceRentMonths = months }
            if let months = terms.depositMonths { tenancy.depositMonths = months }
            try Tenancies.save(db: db, &tenancy)
            let fromReceipts = rentHistory(try RentReceipts.receipts(db: db, tenancyId: tenancy.id!), tenancyId: tenancy.id!)
            derived[tenancy.id!] = fromReceipts
            if let rents = terms.rents {
                let start = tenancy.startDate
                let rows = try rents.map { rent in
                    TenancyRent(tenancyId: tenancy.id!, fromDate: rent.from == "start" ? start : try day(rent.from),
                                monthlyAmountMinorUnits: try amount(rent.amount))
                }
                _ = try Tenancies.setRents(db: db, tenancyId: tenancy.id!, rows)
            } else if terms.rentsFromReceipts == true {
                guard !fromReceipts.isEmpty else { throw SetUpError.noWholeMonthReceipts(tenancy.contractNumber ?? tenancy.referenceLabel) }
                _ = try Tenancies.setRents(db: db, tenancyId: tenancy.id!, fromReceipts)
            }
        }

        let matching = try RentReceiptMatching.match(db: db, propertyId: propertyId, options: matchOptions)
        let seeded = plan.seedEvidenceRules == true ? try PropertyEvidence.seedRules(db: db, propertyId: propertyId).map(\.name) : []
        return Outcome(propertyId: propertyId, createdProperty: created, createdPeople: createdPeople, receiptsImport: report,
                       derivedRents: derived, matching: matching, seededRules: seeded)
    }

    /// The rent history the receipts show: from each whole-calendar-month issued receipt (1st to
    /// last day), a row where the amount changes (the first starting on that receipt's period).
    public static func rentHistory(_ receipts: [RentReceipt], tenancyId: Int64) -> [TenancyRent] {
        let calendar = MonthRange.calendar
        let monthly = receipts.filter { receipt in
            guard receipt.status == .issued, calendar.component(.day, from: receipt.periodStart) == 1 else { return false }
            let next = calendar.date(byAdding: .month, value: 1, to: receipt.periodStart)!
            return PropertyDates.nextDay(receipt.periodEnd) == next
        }.sorted { $0.periodStart < $1.periodStart }
        var rows: [TenancyRent] = []
        for receipt in monthly where rows.last?.monthlyAmountMinorUnits != receipt.amountMinorUnits {
            rows.append(TenancyRent(tenancyId: tenancyId, fromDate: receipt.periodStart, monthlyAmountMinorUnits: receipt.amountMinorUnits))
        }
        return rows
    }

    static func day(_ text: String) throws -> Date {
        guard let date = RentReceiptsExport.parseDate(text) else { throw SetUpError.badDate(text) }
        return date
    }

    static func amount(_ text: String) throws -> Int {
        guard let value = RentReceiptsExport.parseAmount(text) else { throw SetUpError.badAmount(text) }
        return value
    }
}
