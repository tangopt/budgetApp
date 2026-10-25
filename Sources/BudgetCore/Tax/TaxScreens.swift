import GRDB
import Foundation

/// What the Tax years screens read (plan phase 3 Task 4): the list of people's tax years, and
/// one year's page (rental accounts, settings, manual items), plus the evidence pack's plan.
/// The App only lays these out.
public enum TaxOverview {
    /// One person's UK tax year in the list.
    public struct YearRow: Equatable, Identifiable, Sendable {
        public var person: Person
        public var year: UKTaxYear
        /// `preparing` while there's no record.
        public var status: TaxYearStatus
        public var taxYearId: Int64?
        /// The HMRC average EUR rate for the year, if stored.
        public var eurRate: HMRCRate?
        /// The properties the person owns a share of during the year.
        public var properties: [Property]
        /// What was saved anyway after the year was filed, one line each, oldest first
        /// (`FiledYearEditCheck.changesAfterFiling`, from the year's notes).
        public var changedAfterFiling: [String] = []

        public var id: String { "\(person.id ?? 0)-\(year.startYear)" }
        public var deadlines: TaxYearDeadlines { year.deadlines }
    }

    /// Every person who owns (or owned) a property, or has a tax year record, for each UK
    /// year from the first one they own a property in (or have a record for) to the current
    /// one: latest year first, then by person name.
    public static func rows(db: Database, now: Date = Date()) throws -> [YearRow] {
        let current = UKTaxYear.containing(now)
        let people = try People.all(db: db)
        let owners = try PropertyOwner.fetchAll(db)
        let records = try TaxYear.fetchAll(db)
        let employmentYears = Dictionary(grouping: try Employment.fetchAll(db), by: \.personId).mapValues { $0.map(\.startYear) }
        let properties = Dictionary(uniqueKeysWithValues: try Property.fetchAll(db).compactMap { p in p.id.map { ($0, p) } })
        let tenancyStarts = Dictionary(grouping: try Tenancy.fetchAll(db), by: \.propertyId).mapValues { $0.map(\.startDate).min() }
        var rows: [YearRow] = []
        for person in people {
            guard let personId = person.id else { continue }
            let owned = owners.filter { $0.personId == personId }
            let personRecords = records.filter { $0.personId == personId }
            let employed = employmentYears[personId] ?? []
            guard !owned.isEmpty || !personRecords.isEmpty || !employed.isEmpty else { continue }
            // From ownership (or the first tenancy, or the purchase) — whichever is later — to now.
            let firstOwned = owned.compactMap { owner -> Int? in
                let property = properties[owner.propertyId]
                let starts = [owner.fromDate, property?.purchaseDate, tenancyStarts[owner.propertyId] ?? nil].compactMap { $0 }
                return starts.max().map { UKTaxYear.containing($0).startYear }
            }.min()
            let firstRecord = personRecords.map(\.startYear).min()
            let first = [firstOwned, firstRecord, employed.min(), current.startYear].compactMap { $0 }.min()!
            let last = max(current.startYear, personRecords.map(\.startYear).max() ?? current.startYear)
            for startYear in stride(from: last, through: first, by: -1) {
                let year = UKTaxYear(startYear: startYear)
                let record = personRecords.first { $0.startYear == startYear }
                rows.append(YearRow(person: person, year: year, status: record?.status ?? .preparing, taxYearId: record?.id,
                                    eurRate: try HMRCRates.rate(db: db, startYear: startYear, currencyCode: "EUR"),
                                    properties: try propertiesOwned(db: db, personId: personId, year: year),
                                    changedAfterFiling: FiledYearEditCheck.changesAfterFiling(record?.notes)))
            }
        }
        return rows.sorted { ($1.year.startYear, $0.person.name) < ($0.year.startYear, $1.person.name) }
    }

    /// The properties the person owns a share of at some point in the year, by name.
    public static func propertiesOwned(db: Database, personId: Int64, year: UKTaxYear) throws -> [Property] {
        let ids = Set(try PropertyOwner.filter(Column("personId") == personId).fetchAll(db).filter { owner in
            (owner.fromDate.map { $0 < year.end } ?? true) && (owner.toDate.map { $0 >= year.start } ?? true)
        }.map(\.propertyId))
        return try Properties.all(db: db).filter { ids.contains($0.id ?? -1) }
    }

    /// Sets the person's status for the year (creating the record).
    public static func setStatus(db: Database, startYear: Int, personId: Int64, status: TaxYearStatus) throws {
        var year = try TaxYears.ensure(db: db, startYear: startYear, personId: personId)
        year.status = status
        try TaxYears.save(db: db, &year)
    }

    /// Where an attribution rule comes from.
    public enum RuleScope: Equatable, Sendable {
        /// `TaxAttributionRules.defaultRule`, not stored.
        case builtIn
        /// The stored rule for every year.
        case allYears
        /// This year's override.
        case thisYear
    }

    public struct RuleRow: Equatable, Identifiable, Sendable {
        public var expenseType: TaxExpenseType
        public var rule: TaxAttributionRuleKind
        public var defaultCoverMonths: Int?
        public var scope: RuleScope
        /// The year's window moved by this many months (`TaxAttributionRule.effectiveWindowShift`); 0 = April–March.
        public var windowShiftMonths: Int = 0
        public var id: TaxExpenseType { expenseType }
    }

    /// One person's year page for a property.
    public struct YearPage: Equatable, Sendable {
        public var row: YearRow
        public var property: Property?
        public var accounts: RentalAccounts.Result?
        /// The year's rates by currency code.
        public var rates: [HMRCRate]
        /// The person's splits for the year and property.
        public var splits: [TaxYearSplit]
        /// The ownership share the splits override.
        public var ownershipShareBasisPoints: Int
        public var rules: [RuleRow]
        public var categoryTypes: [TaxExpenseTypeMap.Entry]
        public var manualItems: [TaxManualItem]
        public var manualItemDocumentCounts: [Int64: Int]
        /// The Self Assessment tabs (phase 4).
        public var income = SelfAssessmentOverview.IncomePage()
        public var selfAssessment: SelfAssessment.Result?
        public var selfAssessmentError: String?
        public var filing: [SelfAssessmentFiling.Step] = []
    }

    /// The page of `personId`'s year for `propertyId` (default: the first property they own in
    /// it). `rows` (already read) saves reading the list again. `includeSelfAssessment` false
    /// leaves the return and the filing steps out (they compute every earlier year too).
    public static func page(db: Database, personId: Int64, startYear: Int, propertyId: Int64? = nil, rows known: [YearRow]? = nil,
                            includeSelfAssessment: Bool = true, now: Date = Date()) throws -> YearPage? {
        guard let row = try (known ?? rows(db: db, now: now)).first(where: { $0.person.id == personId && $0.year.startYear == startYear })
                ?? (try Person.fetchOne(db, key: personId)).map({ person in
                    YearRow(person: person, year: UKTaxYear(startYear: startYear), status: .preparing, taxYearId: nil, eurRate: nil, properties: [])
                }) else { return nil }
        let property = propertyId.flatMap { id in row.properties.first { $0.id == id } } ?? row.properties.first
        var accounts: RentalAccounts.Result?
        var splits: [TaxYearSplit] = []
        var ownership = 0
        var categoryTypes: [TaxExpenseTypeMap.Entry] = []
        if let propertyId = property?.id {
            accounts = try RentalAccounts.compute(db: db, taxYear: row.year, personId: personId, propertyId: propertyId)
            splits = try TaxSplits.splits(db: db, startYear: startYear, propertyId: propertyId).filter { $0.personId == personId }
            ownership = try TaxSplits.ownershipShare(db: db, startYear: startYear, personId: personId, propertyId: propertyId)
            categoryTypes = try TaxExpenseTypeMap.entries(db: db, propertyId: propertyId)
        }
        var rules: [RuleRow] = []
        for type in TaxExpenseType.allCases {
            let rule = try TaxAttributionRules.effective(db: db, expenseType: type, startYear: startYear)
            let scope: RuleScope = rule.id == nil ? .builtIn : (rule.startYear == nil ? .allYears : .thisYear)
            rules.append(RuleRow(expenseType: type, rule: rule.rule, defaultCoverMonths: rule.defaultCoverMonths, scope: scope,
                                 windowShiftMonths: rule.effectiveWindowShift))
        }
        var items = try TaxManualItems.items(db: db, startYear: startYear, personId: personId)
        if let propertyId = property?.id { items = items.filter { $0.propertyId == nil || $0.propertyId == propertyId } }
        var page = YearPage(row: row, property: property, accounts: accounts,
                            rates: try HMRCRate.filter(Column("startYear") == startYear).order(Column("currencyCode")).fetchAll(db),
                            splits: splits, ownershipShareBasisPoints: ownership, rules: rules, categoryTypes: categoryTypes,
                            manualItems: items, manualItemDocumentCounts: try EvidenceLinks.linkCounts(db: db, .taxManualItem))
        page.income = try SelfAssessmentOverview.incomePage(db: db, startYear: startYear, personId: personId)
        if includeSelfAssessment {
            (page.selfAssessment, page.selfAssessmentError) = SelfAssessmentOverview.selfAssessment(db: db, startYear: startYear, personId: personId)
            page.filing = page.selfAssessment.map(SelfAssessmentFiling.steps) ?? []
        }
        return page
    }
}

extension TaxManualItems {
    /// Saves the item and applies its staged document links in the same write (Save of the
    /// manual item sheet).
    public static func save(db: Database, _ item: inout TaxManualItem, documents: EvidenceLinkChanges) throws {
        try save(db: db, &item)
        try documents.apply(db: db, to: .taxManualItem(item.id!))
    }
}

/// The evidence pack of a person's year (spec §3 Export): every document behind the rental
/// accounts' sources and the tax year itself, one folder per line, under canonical names.
public enum TaxEvidencePack {
    public struct File: Equatable, Sendable {
        /// "01 Rental income".
        public var folder: String
        public var documentId: Int64
        /// The canonical name (else the original one) with the stored extension; unique in its folder.
        public var fileName: String
    }

    /// "Evidence 2024-25 - Person A".
    public static func folderName(year: UKTaxYear, personName: String) -> String {
        TaxFileNames.sanitized("Evidence \(year.fileLabel) - \(personName)")
    }

    /// The files, by folder; a document behind several lines is listed under the first.
    public static func files(db: Database, accounts: RentalAccounts.Result, taxYearId: Int64?) throws -> [File] {
        var seen: Set<Int64> = []
        var files: [File] = []
        var namesByFolder: [String: Set<String>] = [:]
        func add(_ documentIds: [Int64], folder: String) throws {
            for id in documentIds where seen.insert(id).inserted {
                guard let document = try EvidenceDocument.fetchOne(db, key: id) else { continue }
                let base = document.canonicalName ?? (document.originalFileName as NSString).deletingPathExtension
                let ext = document.fileExtension
                var name = TaxFileNames.fileName(base, ext: ext)
                var counter = 2
                while namesByFolder[folder, default: []].contains(name.lowercased()) {
                    name = TaxFileNames.fileName(TaxFileNames.sanitized(base, maxBytes: 190) + " (\(counter))", ext: ext)
                    counter += 1
                }
                namesByFolder[folder, default: []].insert(name.lowercased())
                files.append(File(folder: folder, documentId: id, fileName: name))
            }
        }
        if let taxYearId {
            try add(try EvidenceLinks.documents(db: db, for: .taxYear(taxYearId)).compactMap(\.id), folder: "00 Tax year")
        }
        for (index, line) in accounts.allLines.enumerated() where line.expenseType != .notDeductible {
            try add(line.sources.flatMap(\.documentIds), folder: String(format: "%02d %@", index + 1, sanitized(line.label)))
        }
        return files
    }

    static func sanitized(_ text: String) -> String { TaxFileNames.sanitized(text) }
}

extension UKTaxYear {
    /// "2024-25": the year in file and folder names.
    public var fileLabel: String { label.replacingOccurrences(of: "/", with: "-") }
}

/// File and folder names the tax exports write.
public enum TaxFileNames {
    /// A name safe for a file system: control characters and line breaks dropped, slashes and
    /// colons turned into hyphens, no leading dots or surrounding spaces, at most 200 UTF-8
    /// bytes (cut on a character boundary). An empty result becomes "Untitled".
    public static func sanitized(_ text: String, maxBytes: Int = 200) -> String {
        var result = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }))
        result = result.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        result = result.trimmingCharacters(in: .whitespaces)
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespaces)
        while result.utf8.count > maxBytes { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Untitled" : result
    }

    /// `sanitized(base)` + "." + `ext`, the whole within 200 bytes.
    public static func fileName(_ base: String, ext: String) -> String {
        guard !ext.isEmpty else { return sanitized(base) }
        return sanitized(base, maxBytes: 200 - ext.utf8.count - 1) + "." + ext
    }

    /// "Rental accounts - 2024-25 - Person A.pdf".
    public static func rentalAccountsPDF(year: UKTaxYear, personName: String) -> String {
        fileName("Rental accounts - \(year.fileLabel) - \(personName)", ext: "pdf")
    }
}
