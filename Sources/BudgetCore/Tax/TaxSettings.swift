import GRDB
import Foundation

// Reading and editing the tax settings inside a caller's database transaction: tax years,
// splits, attribution rules, the category → expense type map and manual items.

// MARK: - Tax years

public enum TaxYears {
    /// The person's record for the year, created (preparing) when there is none.
    @discardableResult
    public static func ensure(db: Database, startYear: Int, personId: Int64) throws -> TaxYear {
        guard try Person.exists(db, key: personId) else { throw TaxError.personNotFound }
        if let existing = try TaxYear.filter(Column("startYear") == startYear && Column("personId") == personId).fetchOne(db) {
            return existing
        }
        var year = TaxYear(startYear: startYear, personId: personId)
        try year.insert(db)
        return year
    }

    /// Saves the status and notes (blank notes cleared).
    public static func save(db: Database, _ year: inout TaxYear) throws {
        guard try Person.exists(db, key: year.personId) else { throw TaxError.personNotFound }
        year.notes = Transaction.normalizedNote(year.notes)
        try year.save(db)
    }

    /// Every tax year (of `personId`, when given), latest first, then by person.
    public static func all(db: Database, personId: Int64? = nil) throws -> [TaxYear] {
        var request = TaxYear.order(Column("startYear").desc, Column("personId"))
        if let personId { request = request.filter(Column("personId") == personId) }
        return try request.fetchAll(db)
    }

    public static func year(db: Database, startYear: Int, personId: Int64) throws -> TaxYear? {
        try TaxYear.filter(Column("startYear") == startYear && Column("personId") == personId).fetchOne(db)
    }
}

// MARK: - Splits

/// Where a person's share of a line comes from.
public enum TaxShareOrigin: Equatable, Sendable {
    /// The year's split for that expense type.
    case splitForType
    /// The year's split for every type.
    case splitForAllTypes
    /// The property's ownership, weighted by days over the tax year.
    case ownership
}

public struct TaxShare: Equatable, Sendable {
    public var shareBasisPoints: Int
    public var origin: TaxShareOrigin

    public var fraction: Double { Double(shareBasisPoints) / Double(PropertyOwner.wholeShare) }

    /// "50% (ownership)", "60% (split for 2024/25)".
    public func explanation(year: UKTaxYear) -> String {
        let percent = TaxShare.percent(shareBasisPoints)
        switch origin {
        case .splitForType: return "\(percent) (split for this type, \(year.label))"
        case .splitForAllTypes: return "\(percent) (split for \(year.label))"
        case .ownership: return "\(percent) (ownership, weighted by days owned)"
        }
    }

    static func percent(_ basisPoints: Int) -> String {
        basisPoints % 100 == 0 ? "\(basisPoints / 100)%" : String(format: "%.2f%%", Double(basisPoints) / 100)
    }
}

public enum TaxSplits {
    /// Sets the person's share of `expenseType` (nil: of every type) of the property for the
    /// year; a `nil` share removes the split (back to ownership).
    public static func set(db: Database, startYear: Int, personId: Int64, propertyId: Int64, expenseType: TaxExpenseType?,
                           shareBasisPoints: Int?) throws {
        guard try Person.exists(db, key: personId) else { throw TaxError.personNotFound }
        guard try Property.exists(db, key: propertyId) else { throw TaxError.propertyNotFound }
        let existing = try request(startYear: startYear, personId: personId, propertyId: propertyId, expenseType: expenseType).fetchOne(db)
        guard let shareBasisPoints else {
            if let existing { try existing.delete(db) }
            return
        }
        guard (0...PropertyOwner.wholeShare).contains(shareBasisPoints) else { throw TaxError.invalidShare }
        var split = existing ?? TaxYearSplit(startYear: startYear, personId: personId, propertyId: propertyId, expenseType: expenseType,
                                             shareBasisPoints: shareBasisPoints)
        split.shareBasisPoints = shareBasisPoints
        try split.save(db)
    }

    /// The splits of the year for the property (all people), by person then type.
    public static func splits(db: Database, startYear: Int, propertyId: Int64) throws -> [TaxYearSplit] {
        try TaxYearSplit.filter(Column("startYear") == startYear && Column("propertyId") == propertyId)
            .order(Column("personId"), Column("expenseType")).fetchAll(db)
    }

    /// The person's share of `expenseType`: its split, else the all-types split, else ownership.
    public static func share(db: Database, startYear: Int, personId: Int64, propertyId: Int64, expenseType: TaxExpenseType) throws -> TaxShare {
        if let split = try request(startYear: startYear, personId: personId, propertyId: propertyId, expenseType: expenseType).fetchOne(db) {
            return TaxShare(shareBasisPoints: split.shareBasisPoints, origin: .splitForType)
        }
        if let split = try request(startYear: startYear, personId: personId, propertyId: propertyId, expenseType: nil).fetchOne(db) {
            return TaxShare(shareBasisPoints: split.shareBasisPoints, origin: .splitForAllTypes)
        }
        return TaxShare(shareBasisPoints: try ownershipShare(db: db, startYear: startYear, personId: personId, propertyId: propertyId),
                        origin: .ownership)
    }

    /// The person's ownership of the property over the UK tax year, weighted by days owned.
    public static func ownershipShare(db: Database, startYear: Int, personId: Int64, propertyId: Int64) throws -> Int {
        let interval = UKTaxYear(startYear: startYear).interval
        let total = PropertyFinance.days(interval.start, interval.end)
        var weighted = 0.0
        for owner in try Properties.owners(db: db, propertyId: propertyId) where owner.personId == personId {
            let from = max(owner.fromDate ?? interval.start, interval.start)
            let to = min(owner.toDate.map(PropertyDates.nextDay) ?? interval.end, interval.end)
            guard from < to else { continue }
            weighted += Double(owner.shareBasisPoints) * Double(PropertyFinance.days(from, to))
        }
        return total > 0 ? Int((weighted / Double(total)).rounded()) : 0
    }

    private static func request(startYear: Int, personId: Int64, propertyId: Int64, expenseType: TaxExpenseType?) -> QueryInterfaceRequest<TaxYearSplit> {
        let base = TaxYearSplit.filter(Column("startYear") == startYear && Column("personId") == personId && Column("propertyId") == propertyId)
        return expenseType.map { base.filter(Column("expenseType") == $0.rawValue) } ?? base.filter(Column("expenseType") == nil)
    }
}

// MARK: - Attribution rules

public enum TaxAttributionRules {
    /// The defaults (spec §4, the accountant's workbook): rent by rent period, mortgage
    /// interest by payment date (cash basis: the interest paid 6 April – 5 April, as the filed
    /// 2023/24 and 2024/25 returns did — the bank dates the interest rows by value date, 31st
    /// or 1st, so month buckets would shift an instalment across years), service charge by
    /// quota month, insurance by months of cover, IMI and PT IRS for the previous calendar
    /// year, everything else by date.
    public static func defaultRule(for type: TaxExpenseType) -> TaxAttributionRuleKind {
        switch type {
        case .rentalIncome: return .byRentPeriod
        case .financeCost: return .byDate
        case .serviceCharge: return .byQuotaMonth
        case .insurance: return .apportionByCover
        case .councilTax, .foreignTax: return .previousCalendarYear
        case .accountancy, .legalFees, .repairs, .utilities, .otherExpense, .notDeductible: return .byDate
        }
    }

    public static let defaultCoverMonths = 12
    public static let seededNote = "Default rule (phase 3)"

    /// The rule for the type in the year: its override, else its stored default, else `defaultRule`.
    public static func effective(db: Database, expenseType: TaxExpenseType, startYear: Int) throws -> TaxAttributionRule {
        if let override = try request(expenseType: expenseType, startYear: startYear).fetchOne(db) { return override }
        if let stored = try request(expenseType: expenseType, startYear: nil).fetchOne(db) { return stored }
        return TaxAttributionRule(expenseType: expenseType, rule: defaultRule(for: expenseType))
    }

    /// Sets the type's rule for every year (`startYear` nil) or one year.
    @discardableResult
    public static func set(db: Database, expenseType: TaxExpenseType, startYear: Int?, rule: TaxAttributionRuleKind,
                           defaultCoverMonths: Int? = nil, notes: String? = nil) throws -> TaxAttributionRule {
        if let months = defaultCoverMonths, months < 1 { throw TaxError.invalidCoverMonths }
        var row = try request(expenseType: expenseType, startYear: startYear).fetchOne(db)
            ?? TaxAttributionRule(expenseType: expenseType, startYear: startYear, rule: rule)
        row.rule = rule
        row.defaultCoverMonths = defaultCoverMonths
        row.notes = Transaction.normalizedNote(notes)
        try row.save(db)
        return row
    }

    /// Removes the year's override (or the stored default); `false` when there was none.
    @discardableResult
    public static func remove(db: Database, expenseType: TaxExpenseType, startYear: Int?) throws -> Bool {
        try request(expenseType: expenseType, startYear: startYear).deleteAll(db) > 0
    }

    /// Stores `defaultRule` for every type without a stored default. Idempotent; returns what was added.
    @discardableResult
    public static func seedDefaults(db: Database) throws -> [TaxAttributionRule] {
        var added: [TaxAttributionRule] = []
        for type in TaxExpenseType.allCases where try request(expenseType: type, startYear: nil).fetchCount(db) == 0 {
            var row = TaxAttributionRule(expenseType: type, rule: defaultRule(for: type), notes: seededNote)
            try row.insert(db)
            added.append(row)
        }
        return added
    }

    /// Every stored rule: defaults first, then overrides by year; by type within.
    public static func all(db: Database) throws -> [TaxAttributionRule] {
        try TaxAttributionRule.order(Column("startYear") != nil, Column("startYear"), Column("expenseType")).fetchAll(db)
    }

    private static func request(expenseType: TaxExpenseType, startYear: Int?) -> QueryInterfaceRequest<TaxAttributionRule> {
        let base = TaxAttributionRule.filter(Column("expenseType") == expenseType.rawValue)
        return startYear.map { base.filter(Column("startYear") == $0) } ?? base.filter(Column("startYear") == nil)
    }
}

// MARK: - Category → expense type

public enum TaxExpenseTypeMap {
    /// The type a category's name suggests (case and accent-insensitive), first match wins:
    /// income named rent/renda/aluguer → rental income (other income → not deductible); life
    /// insurance (life/vida) → not deductible; other insurance/seguro → insurance;
    /// capital/amortização/principal → not deductible (capital repaid); income named IRS/
    /// imposto/tax refund → foreign tax (a refund);
    /// mortgage/interest/juros → finance cost; condomínio/service charge → service charge; IMI/
    /// council tax → council tax; PT tax/IRS/imposto → foreign tax; accountant/contabil →
    /// accountancy; legal/advogado/court → legal fees; repair/maintenance/obras → repairs;
    /// utilities/electricity/gas/water → not deductible (recharged to the tenant until
    /// recharges are netted, phase 5); anything else (fees, other) → any other expense.
    public static func suggestedType(forCategoryName name: String, type: CategoryType) -> TaxExpenseType {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func has(_ parts: String...) -> Bool { parts.contains { folded.contains($0) } }
        if type == .income {
            if has("rent", "renda", "aluguer", "arrendamento") { return .rentalIncome }
            // A PT tax refund reduces the foreign tax (other refunds are flagged by the engine).
            if words.contains("irs") || has("imposto", "pt tax") { return .foreignTax }
            return .notDeductible
        }
        guard type == .expense else { return .notDeductible }
        if words.contains("life") || words.contains("vida") { return .notDeductible }
        if has("insurance", "seguro") { return .insurance }
        // Capital repaid is not a cost: check it before the mortgage guess. Instalments mix
        // capital and interest: not deductible until the user splits them (`needsReview`).
        if has("capital", "amortiz", "amortis", "principal") || needsReview(name) { return .notDeductible }
        if has("mortgage", "interest", "juros") { return .financeCost }
        if has("condominio", "service charge") { return .serviceCharge }
        if words.contains("imi") || has("council tax") { return .councilTax }
        if has("pt tax", "imposto") || words.contains("irs") { return .foreignTax }
        if has("accountan", "contabil") { return .accountancy }
        if has("legal", "advogad", "solicitador", "court") { return .legalFees }
        if has("repair", "maintenance", "obras", "reparac") { return .repairs }
        if has("utilit", "electric", "water") || !words.isDisjoint(with: ["gas", "agua", "luz"]) { return .notDeductible }
        return .otherExpense
    }

    /// Names whose guess must be confirmed by hand (loan instalments: capital and interest):
    /// "Confirm suggestions" leaves them out and the engine warns until a type is stored.
    public static func needsReview(_ name: String) -> Bool {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return ["instalment", "installment", "prestacao"].contains(where: folded.contains)
    }

    /// The income and expense categories of the property's category groups, by name.
    public static func propertyCategories(db: Database, propertyId: Int64) throws -> [Category] {
        let groupIds = try Properties.categoryGroupIds(db: db, propertyId: propertyId)
        return try Category
            .filter(groupIds.contains(Column("groupId")) && [CategoryType.income.rawValue, CategoryType.expense.rawValue].contains(Column("type"))
                    && Column("isReserved") == false)
            .order(Column("name").collating(.localizedCaseInsensitiveCompare), Column("id"))
            .fetchAll(db)
    }

    /// A category's type and whether it's stored (`false`: suggested from its name).
    public struct Entry: Equatable, Sendable {
        public var category: Category
        public var expenseType: TaxExpenseType
        public var isStored: Bool
    }

    /// Every property category with its type: the stored mapping, else the suggestion.
    public static func entries(db: Database, propertyId: Int64) throws -> [Entry] {
        let stored = Dictionary(uniqueKeysWithValues: try TaxExpenseTypeMapping.fetchAll(db).map { ($0.categoryId, $0.expenseType) })
        return try propertyCategories(db: db, propertyId: propertyId).map { category in
            if let type = stored[category.id!] { return Entry(category: category, expenseType: type, isStored: true) }
            return Entry(category: category, expenseType: suggestedType(forCategoryName: category.name, type: category.type), isStored: false)
        }
    }

    /// Stores (or, with `nil`, removes) the type of a category.
    public static func set(db: Database, categoryId: Int64, expenseType: TaxExpenseType?) throws {
        guard try Category.exists(db, key: categoryId) else { throw TaxError.categoryNotFound }
        let existing = try TaxExpenseTypeMapping.filter(Column("categoryId") == categoryId).fetchOne(db)
        guard let expenseType else {
            if let existing { try existing.delete(db) }
            return
        }
        var row = existing ?? TaxExpenseTypeMapping(categoryId: categoryId, expenseType: expenseType)
        row.expenseType = expenseType
        try row.save(db)
    }

    /// Stores the suggestion for every property category without a stored type, except those
    /// that `needsReview`. Idempotent; returns what was added.
    @discardableResult
    public static func seed(db: Database, propertyId: Int64) throws -> [TaxExpenseTypeMapping] {
        var added: [TaxExpenseTypeMapping] = []
        for entry in try entries(db: db, propertyId: propertyId) where !entry.isStored && !needsReview(entry.category.name) {
            var row = TaxExpenseTypeMapping(categoryId: entry.category.id!, expenseType: entry.expenseType)
            try row.insert(db)
            added.append(row)
        }
        return added
    }
}

// MARK: - Manual items

public enum TaxManualItems {
    /// Inserts or updates the item (trimmed label, positive or zero amount, day-normalised date).
    public static func save(db: Database, _ item: inout TaxManualItem) throws {
        item.label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.label.isEmpty else { throw TaxError.blankLabel }
        guard item.amountMinorUnits >= 0 else { throw TaxError.negativeAmount }
        guard try Person.exists(db, key: item.personId) else { throw TaxError.personNotFound }
        if let propertyId = item.propertyId, try !Property.exists(db, key: propertyId) { throw TaxError.propertyNotFound }
        item.date = item.date.map(PropertyDates.day)
        item.notes = Transaction.normalizedNote(item.notes)
        try item.save(db)
    }

    /// The person's items for the year (for `propertyId`, when given), by date (undated last) then id.
    public static func items(db: Database, startYear: Int, personId: Int64, propertyId: Int64? = nil) throws -> [TaxManualItem] {
        var request = TaxManualItem.filter(Column("startYear") == startYear && Column("personId") == personId)
        if let propertyId { request = request.filter(Column("propertyId") == propertyId) }
        return try request.order(Column("date") == nil, Column("date"), Column("id")).fetchAll(db)
    }

    /// Deletes the item and its document links; `false` when there was none.
    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try TaxManualItem.deleteOne(db, key: id)
    }
}

// MARK: - Evidence titles

public enum TaxEvidence {
    /// "2024/25 · Person A" for a tax year, "UK accountant · 2024/25 · A" for a manual item;
    /// `nil` when the record is gone or the entity isn't a tax record.
    public static func title(db: Database, entity: EvidenceEntity) throws -> String? {
        switch entity.type {
        case .taxYear:
            guard let year = try TaxYear.fetchOne(db, key: entity.id) else { return nil }
            let person = try Person.fetchOne(db, key: year.personId)?.name
            return [year.ukTaxYear.label, person].compactMap { $0 }.joined(separator: " · ")
        case .taxManualItem:
            guard let item = try TaxManualItem.fetchOne(db, key: entity.id) else { return nil }
            let person = try Person.fetchOne(db, key: item.personId)?.displayShortName
            return [item.label, UKTaxYear(startYear: item.startYear).label, person].compactMap { $0 }.joined(separator: " · ")
        case .employment, .employmentIncome, .hmrcPayment, .otherIncome, .pensionContribution:
            return try PersonalIncomeEvidence.title(db: db, entity: entity)
        default:
            return nil
        }
    }
}
