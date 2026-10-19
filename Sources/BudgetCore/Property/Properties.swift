import GRDB
import Foundation

public enum PropertyError: Error, Equatable {
    case blankName
    case duplicateName
    case invalidCountry
    case personNotFound
    case propertyNotFound
    case accountNotFound
    case categoryGroupNotFound
    case tenancyNotFound
    /// The person owns (or owned) a share of a property: remove the ownership first.
    case personIsOwner
    /// A share outside 0–100% (exclusive of 0).
    case invalidShare
    /// A range whose end is before its start.
    case invalidDateRange
    /// One person's ownership ranges overlap.
    case overlappingOwnership(personId: Int64)
    /// At `date`, the owners' shares sum to `totalBasisPoints`, not 100%.
    case sharesDoNotSumToWhole(date: Date?, totalBasisPoints: Int)
    case blankReference
    case duplicateContractNumber
    case negativeMonths
    case negativeAmount
    case duplicateRentDate
    case blankReceiptNumber
    case duplicateReceiptNumber
    /// Withholding larger than the rent.
    case invalidWithholding
    /// A tenant email that isn't an address.
    case invalidEmail(String)
}

/// Day-granularity dates for the property records: 00:00 UTC of the day.
enum PropertyDates {
    static func day(_ date: Date) -> Date { MonthRange.calendar.startOfDay(for: date) }
    static func nextDay(_ date: Date) -> Date { MonthRange.calendar.date(byAdding: .day, value: 1, to: day(date))! }
    /// "2024-05-02".
    static func isoDay(_ date: Date) -> String {
        let c = MonthRange.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

// MARK: - People

/// Reading and editing people inside a caller's database transaction.
public enum People {
    /// Inserts or updates `person` (trimmed name, unique case-insensitively; blank optionals cleared).
    public static func save(db: Database, _ person: inout Person) throws {
        person.name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !person.name.isEmpty else { throw PropertyError.blankName }
        person.shortName = Transaction.normalizedNote(person.shortName)
        person.ukUtr = Transaction.normalizedNote(person.ukUtr)
        person.ukNino = Transaction.normalizedNote(person.ukNino)
        person.ptNif = Transaction.normalizedNote(person.ptNif)
        person.notes = Transaction.normalizedNote(person.notes)
        var clash = Person.filter(sql: "name = ? COLLATE NOCASE", arguments: [person.name])
        if let id = person.id { clash = clash.filter(Column("id") != id) }
        guard try clash.fetchCount(db) == 0 else { throw PropertyError.duplicateName }
        try person.save(db)
    }

    /// Everyone, by name.
    public static func all(db: Database) throws -> [Person] {
        try Person.order(Column("name").collating(.localizedCaseInsensitiveCompare), Column("id")).fetchAll(db)
    }

    /// Deletes the person (and their document links); refuses an owner. `false` when there was none.
    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        guard try PropertyOwner.filter(Column("personId") == id).fetchCount(db) == 0 else { throw PropertyError.personIsOwner }
        return try Person.deleteOne(db, key: id)
    }
}

// MARK: - Properties

/// Shares of a property at a date.
public struct PropertyShare: Equatable, Sendable {
    public var personId: Int64
    public var shareBasisPoints: Int

    public init(personId: Int64, shareBasisPoints: Int) {
        self.personId = personId
        self.shareBasisPoints = shareBasisPoints
    }

    /// The share as a fraction (0.5 for 50%).
    public var fraction: Double { Double(shareBasisPoints) / Double(PropertyOwner.wholeShare) }
}

/// Reading and editing properties, their owners, accounts and category groups inside a
/// caller's database transaction.
public enum Properties {
    /// Inserts or updates `property` (trimmed unique name, upper-case two-letter country).
    public static func save(db: Database, _ property: inout Property) throws {
        property.name = property.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !property.name.isEmpty else { throw PropertyError.blankName }
        property.country = property.country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard property.country.count == 2, property.country.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw PropertyError.invalidCountry
        }
        if let price = property.purchasePriceMinorUnits, price < 0 { throw PropertyError.negativeAmount }
        property.purchaseDate = property.purchaseDate.map(PropertyDates.day)
        property.matrixArticle = Transaction.normalizedNote(property.matrixArticle)
        property.notes = Transaction.normalizedNote(property.notes)
        var clash = Property.filter(sql: "name = ? COLLATE NOCASE", arguments: [property.name])
        if let id = property.id { clash = clash.filter(Column("id") != id) }
        guard try clash.fetchCount(db) == 0 else { throw PropertyError.duplicateName }
        try property.save(db)
    }

    /// Every property, by name.
    public static func all(db: Database) throws -> [Property] {
        try Property.order(Column("name").collating(.localizedCaseInsensitiveCompare), Column("id")).fetchAll(db)
    }

    /// Deletes the property with its owners, account and category-group links, tenancies,
    /// rents and receipts (and their document links). `false` when there was none.
    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try Property.deleteOne(db, key: id)
    }

    // MARK: Owners

    /// The ownership rows of the property, by start date (open start first) then person.
    public static func owners(db: Database, propertyId: Int64) throws -> [PropertyOwner] {
        try PropertyOwner.filter(Column("propertyId") == propertyId)
            .order(sql: "fromDate IS NOT NULL, fromDate, personId, id")
            .fetchAll(db)
    }

    /// Replaces the property's whole ownership history. Each share is above 0 and at most
    /// 100%; one person's ranges don't overlap; at every date someone owns the property, the
    /// shares sum to exactly 100%. Returns the rows as saved.
    @discardableResult
    public static func setOwners(db: Database, propertyId: Int64, _ owners: [PropertyOwner]) throws -> [PropertyOwner] {
        guard try Property.exists(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let rows = owners.map { owner -> PropertyOwner in
            var row = owner
            row.id = nil
            row.propertyId = propertyId
            row.fromDate = row.fromDate.map(PropertyDates.day)
            row.toDate = row.toDate.map(PropertyDates.day)
            return row
        }
        try validateOwnership(db: db, rows)
        try PropertyOwner.filter(Column("propertyId") == propertyId).deleteAll(db)
        var saved: [PropertyOwner] = []
        for var row in rows {
            try row.insert(db)
            saved.append(row)
        }
        return saved
    }

    static func validateOwnership(db: Database, _ rows: [PropertyOwner]) throws {
        for row in rows {
            guard row.shareBasisPoints > 0, row.shareBasisPoints <= PropertyOwner.wholeShare else { throw PropertyError.invalidShare }
            if let from = row.fromDate, let to = row.toDate, to < from { throw PropertyError.invalidDateRange }
            guard try Person.exists(db, key: row.personId) else { throw PropertyError.personNotFound }
        }
        for (index, row) in rows.enumerated() {
            for other in rows[(index + 1)...] where other.personId == row.personId && overlap(row, other) {
                throw PropertyError.overlappingOwnership(personId: row.personId)
            }
        }
        // Shares are constant between boundaries (each start, each day after an end): check
        // the open start and every boundary.
        var probes: [Date?] = [nil]
        probes += Set(rows.compactMap(\.fromDate) + rows.compactMap(\.toDate).map(PropertyDates.nextDay)).sorted().map { Optional($0) }
        for probe in probes {
            let covering = rows.filter { row in
                guard let probe else { return row.fromDate == nil }
                return row.covers(probe)
            }
            let total = covering.reduce(0) { $0 + $1.shareBasisPoints }
            if total != 0 && total != PropertyOwner.wholeShare {
                throw PropertyError.sharesDoNotSumToWhole(date: probe, totalBasisPoints: total)
            }
        }
    }

    private static func overlap(_ a: PropertyOwner, _ b: PropertyOwner) -> Bool {
        let aStartsBeforeBEnds = b.toDate.map { end in a.fromDate.map { $0 <= end } ?? true } ?? true
        let bStartsBeforeAEnds = a.toDate.map { end in b.fromDate.map { $0 <= end } ?? true } ?? true
        return aStartsBeforeBEnds && bStartsBeforeAEnds
    }

    /// Who owns the property on `date` and with what share, largest share first then person
    /// id; empty when nobody does.
    public static func shares(db: Database, propertyId: Int64, at date: Date) throws -> [PropertyShare] {
        let day = PropertyDates.day(date)
        return try owners(db: db, propertyId: propertyId)
            .filter { $0.covers(day) }
            .map { PropertyShare(personId: $0.personId, shareBasisPoints: $0.shareBasisPoints) }
            .sorted { ($0.shareBasisPoints, -$0.personId) > ($1.shareBasisPoints, -$1.personId) }
    }

    /// The person's share of the property on `date` in basis points (0 when not an owner).
    public static func share(db: Database, propertyId: Int64, personId: Int64, at date: Date) throws -> Int {
        try shares(db: db, propertyId: propertyId, at: date).first { $0.personId == personId }?.shareBasisPoints ?? 0
    }

    // MARK: Accounts

    /// Links the account to the property with `role`, or changes the role of the existing link.
    @discardableResult
    public static func setAccount(db: Database, propertyId: Int64, accountId: Int64, role: PropertyAccountRole) throws -> PropertyAccount {
        guard try Property.exists(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        guard try Account.exists(db, key: accountId) else { throw PropertyError.accountNotFound }
        if var existing = try PropertyAccount.filter(Column("propertyId") == propertyId && Column("accountId") == accountId).fetchOne(db) {
            if existing.role != role {
                existing.role = role
                try existing.update(db)
            }
            return existing
        }
        var link = PropertyAccount(propertyId: propertyId, accountId: accountId, role: role)
        try link.insert(db)
        return link
    }

    /// Unlinks the account; `false` when it wasn't linked.
    @discardableResult
    public static func removeAccount(db: Database, propertyId: Int64, accountId: Int64) throws -> Bool {
        try PropertyAccount.filter(Column("propertyId") == propertyId && Column("accountId") == accountId).deleteAll(db) > 0
    }

    /// The property's accounts, in role order (current, mortgage, deposit, other) then id;
    /// `role` narrows to one role.
    public static func accounts(db: Database, propertyId: Int64, role: PropertyAccountRole? = nil) throws -> [PropertyAccount] {
        var request = PropertyAccount.filter(Column("propertyId") == propertyId)
        if let role { request = request.filter(Column("role") == role.rawValue) }
        let order = PropertyAccountRole.allCases
        return try request.order(Column("id")).fetchAll(db)
            .sorted { (order.firstIndex(of: $0.role)!, $0.id ?? 0) < (order.firstIndex(of: $1.role)!, $1.id ?? 0) }
    }

    /// The properties the account belongs to, with its role there.
    public static func properties(db: Database, accountId: Int64) throws -> [PropertyAccount] {
        try PropertyAccount.filter(Column("accountId") == accountId).order(Column("propertyId")).fetchAll(db)
    }

    // MARK: Category groups

    /// Adds a category group to the property (no-op when already there).
    public static func addCategoryGroup(db: Database, propertyId: Int64, categoryGroupId: Int64) throws {
        guard try Property.exists(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        guard try CategoryGroup.exists(db, key: categoryGroupId) else { throw PropertyError.categoryGroupNotFound }
        try db.execute(sql: "INSERT OR IGNORE INTO propertyCategoryGroup (propertyId, categoryGroupId) VALUES (?, ?)",
                       arguments: [propertyId, categoryGroupId])
    }

    /// Removes a category group from the property; `false` when it wasn't there.
    @discardableResult
    public static func removeCategoryGroup(db: Database, propertyId: Int64, categoryGroupId: Int64) throws -> Bool {
        try PropertyCategoryGroup.filter(Column("propertyId") == propertyId && Column("categoryGroupId") == categoryGroupId).deleteAll(db) > 0
    }

    /// The ids of the property's category groups, in the order they were added.
    public static func categoryGroupIds(db: Database, propertyId: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT categoryGroupId FROM propertyCategoryGroup WHERE propertyId = ? ORDER BY id",
                           arguments: [propertyId])
    }
}

// MARK: - Tenancies

/// Reading and editing tenancies and their rent history inside a caller's database transaction.
public enum Tenancies {
    /// Inserts or updates `tenancy`: non-blank reference, contract number unique per property,
    /// end not before start, months not negative.
    public static func save(db: Database, _ tenancy: inout Tenancy) throws {
        guard try Property.exists(db, key: tenancy.propertyId) else { throw PropertyError.propertyNotFound }
        tenancy.referenceLabel = tenancy.referenceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenancy.referenceLabel.isEmpty else { throw PropertyError.blankReference }
        tenancy.contractNumber = Transaction.normalizedNote(tenancy.contractNumber)
        tenancy.tenantName = Transaction.normalizedNote(tenancy.tenantName)
        tenancy.notes = Transaction.normalizedNote(tenancy.notes)
        // Addresses separated by commas or semicolons, "Name <address>" accepted, stored plain.
        if let text = Transaction.normalizedNote(tenancy.tenantEmail) {
            var addresses: [String] = []
            for part in Tenancies.emailParts(text) {
                guard Tenancies.isEmailAddress(part) else { throw PropertyError.invalidEmail(part) }
                addresses.append(part)
            }
            tenancy.tenantEmail = addresses.isEmpty ? nil : addresses.joined(separator: ", ")
        } else {
            tenancy.tenantEmail = nil
        }
        tenancy.startDate = PropertyDates.day(tenancy.startDate)
        tenancy.endDate = tenancy.endDate.map(PropertyDates.day)
        if let end = tenancy.endDate, end < tenancy.startDate { throw PropertyError.invalidDateRange }
        guard tenancy.advanceRentMonths >= 0, tenancy.depositMonths >= 0 else { throw PropertyError.negativeMonths }
        if let number = tenancy.contractNumber {
            var clash = Tenancy.filter(Column("propertyId") == tenancy.propertyId && Column("contractNumber") == number)
            if let id = tenancy.id { clash = clash.filter(Column("id") != id) }
            guard try clash.fetchCount(db) == 0 else { throw PropertyError.duplicateContractNumber }
        }
        try tenancy.save(db)
    }

    /// The parts of an email list: split on commas and semicolons, "Name <address>" read as the
    /// address, angle brackets dropped, blanks left out.
    public static func emailParts(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" }).compactMap { part -> String? in
            var item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = item.lastIndex(of: "<"), let close = item.lastIndex(of: ">"), open < close {
                item = String(item[item.index(after: open)..<close])
            }
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: "<> ").union(.whitespacesAndNewlines))
            return item.isEmpty ? nil : item
        }
    }

    /// One `local@domain.tld`, no spaces.
    public static func isEmailAddress(_ text: String) -> Bool {
        text.range(of: #"^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$"#, options: .regularExpression) != nil
    }

    /// The tenancy's valid email addresses.
    public static func emailAddresses(_ tenancy: Tenancy) -> [String] {
        emailParts(tenancy.tenantEmail ?? "").filter(isEmailAddress)
    }

    /// The property's tenancies, oldest start first.
    public static func all(db: Database, propertyId: Int64) throws -> [Tenancy] {
        try Tenancy.filter(Column("propertyId") == propertyId).order(Column("startDate"), Column("id")).fetchAll(db)
    }

    /// The property's tenancies running on `date`, oldest start first.
    public static func active(db: Database, propertyId: Int64, at date: Date) throws -> [Tenancy] {
        let day = PropertyDates.day(date)
        return try all(db: db, propertyId: propertyId).filter { $0.covers(day) }
    }

    /// The property's tenancy with that contract number, if any.
    public static func tenancy(db: Database, propertyId: Int64, contractNumber: String) throws -> Tenancy? {
        guard let number = Transaction.normalizedNote(contractNumber) else { return nil }
        return try Tenancy.filter(Column("propertyId") == propertyId && Column("contractNumber") == number).fetchOne(db)
    }

    /// Deletes the tenancy with its rents and receipts (and their document links).
    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try Tenancy.deleteOne(db, key: id)
    }

    // MARK: Rent history

    /// The tenancy's rent history, oldest first.
    public static func rents(db: Database, tenancyId: Int64) throws -> [TenancyRent] {
        try TenancyRent.filter(Column("tenancyId") == tenancyId).order(Column("fromDate")).fetchAll(db)
    }

    /// Replaces the tenancy's rent history (distinct from-dates, amounts not negative).
    @discardableResult
    public static func setRents(db: Database, tenancyId: Int64, _ rents: [TenancyRent]) throws -> [TenancyRent] {
        guard try Tenancy.exists(db, key: tenancyId) else { throw PropertyError.tenancyNotFound }
        let rows = rents.map { rent -> TenancyRent in
            var row = rent
            row.id = nil
            row.tenancyId = tenancyId
            row.fromDate = PropertyDates.day(row.fromDate)
            return row
        }
        guard rows.allSatisfy({ $0.monthlyAmountMinorUnits >= 0 }) else { throw PropertyError.negativeAmount }
        guard Set(rows.map(\.fromDate)).count == rows.count else { throw PropertyError.duplicateRentDate }
        try TenancyRent.filter(Column("tenancyId") == tenancyId).deleteAll(db)
        var saved: [TenancyRent] = []
        for var row in rows.sorted(by: { $0.fromDate < $1.fromDate }) {
            try row.insert(db)
            saved.append(row)
        }
        return saved
    }

    /// Sets the rent from `fromDate` on (replacing a row with the same date).
    @discardableResult
    public static func setRent(db: Database, tenancyId: Int64, from fromDate: Date, monthlyAmountMinorUnits: Int) throws -> TenancyRent {
        var rows = try rents(db: db, tenancyId: tenancyId)
        let day = PropertyDates.day(fromDate)
        rows.removeAll { $0.fromDate == day }
        rows.append(TenancyRent(tenancyId: tenancyId, fromDate: day, monthlyAmountMinorUnits: monthlyAmountMinorUnits))
        return try setRents(db: db, tenancyId: tenancyId, rows).first { $0.fromDate == day }!
    }

    /// The monthly rent on `date`: the latest rent from on or before it, while the tenancy
    /// runs; `nil` outside the tenancy or before the first rent.
    public static func rent(db: Database, tenancyId: Int64, at date: Date) throws -> Int? {
        guard let tenancy = try Tenancy.fetchOne(db, key: tenancyId) else { throw PropertyError.tenancyNotFound }
        let day = PropertyDates.day(date)
        guard tenancy.covers(day) else { return nil }
        return try rents(db: db, tenancyId: tenancyId).last { $0.fromDate <= day }?.monthlyAmountMinorUnits
    }
}

// MARK: - Rent receipts

/// Reading and editing rent receipts inside a caller's database transaction.
public enum RentReceipts {
    /// Inserts or updates `receipt`: receipt number non-blank and unique per tenancy, period
    /// end not before start, amounts not negative, withholding at most the rent.
    public static func save(db: Database, _ receipt: inout RentReceipt) throws {
        guard try Tenancy.exists(db, key: receipt.tenancyId) else { throw PropertyError.tenancyNotFound }
        receipt.receiptNumber = receipt.receiptNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !receipt.receiptNumber.isEmpty else { throw PropertyError.blankReceiptNumber }
        receipt.periodStart = PropertyDates.day(receipt.periodStart)
        receipt.periodEnd = PropertyDates.day(receipt.periodEnd)
        receipt.receiptDate = receipt.receiptDate.map(PropertyDates.day)
        guard receipt.periodStart <= receipt.periodEnd else { throw PropertyError.invalidDateRange }
        guard receipt.amountMinorUnits >= 0, receipt.withholdingMinorUnits >= 0, receipt.amountReceivedMinorUnits >= 0 else {
            throw PropertyError.negativeAmount
        }
        guard receipt.withholdingMinorUnits <= receipt.amountMinorUnits else { throw PropertyError.invalidWithholding }
        var clash = RentReceipt.filter(Column("tenancyId") == receipt.tenancyId && Column("receiptNumber") == receipt.receiptNumber)
        if let id = receipt.id { clash = clash.filter(Column("id") != id) }
        guard try clash.fetchCount(db) == 0 else { throw PropertyError.duplicateReceiptNumber }
        try receipt.save(db)
    }

    /// The tenancy's receipt with that number, if any.
    public static func receipt(db: Database, tenancyId: Int64, receiptNumber: String) throws -> RentReceipt? {
        let number = receiptNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return try RentReceipt.filter(Column("tenancyId") == tenancyId && Column("receiptNumber") == number).fetchOne(db)
    }

    /// The tenancy's receipts by rent period then receipt date and id; cancelled ones only
    /// when asked.
    public static func receipts(db: Database, tenancyId: Int64, includeCancelled: Bool = false) throws -> [RentReceipt] {
        var request = RentReceipt.filter(Column("tenancyId") == tenancyId)
        if !includeCancelled { request = request.filter(Column("status") == RentReceiptStatus.issued.rawValue) }
        return try request.order(Column("periodStart"), Column("receiptDate"), Column("id")).fetchAll(db)
    }

    /// The property's receipts (all tenancies) whose rent period overlaps `period`
    /// (half-open, like `MissingEvidence`'s periods), by rent period; cancelled ones only when asked.
    public static func receipts(db: Database, propertyId: Int64, overlapping period: DateInterval,
                                includeCancelled: Bool = false) throws -> [RentReceipt] {
        try receipts(db: db, overlapping: period, includeCancelled: includeCancelled,
                     scope: "tenancyId IN (SELECT id FROM tenancy WHERE propertyId = ?)", argument: propertyId)
    }

    /// The tenancy's receipts whose rent period overlaps `period` (half-open).
    public static func receipts(db: Database, tenancyId: Int64, overlapping period: DateInterval,
                                includeCancelled: Bool = false) throws -> [RentReceipt] {
        try receipts(db: db, overlapping: period, includeCancelled: includeCancelled, scope: "tenancyId = ?", argument: tenancyId)
    }

    private static func receipts(db: Database, overlapping period: DateInterval, includeCancelled: Bool,
                                 scope: String, argument: Int64) throws -> [RentReceipt] {
        // An inclusive period [start, end] meets [p.start, p.end) when start < p.end and the
        // day after `end` is after p.start, i.e. end >= day(p.start) - covers partial first days.
        var request = RentReceipt
            .filter(sql: scope, arguments: [argument])
            .filter(Column("periodStart") < period.end && Column("periodEnd") >= PropertyDates.day(period.start))
        if !includeCancelled { request = request.filter(Column("status") == RentReceiptStatus.issued.rawValue) }
        return try request.order(Column("periodStart"), Column("receiptDate"), Column("id")).fetchAll(db)
    }

    /// Deletes the receipt (and its document links); `false` when there was none.
    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try RentReceipt.deleteOne(db, key: id)
    }
}
