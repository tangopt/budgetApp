import Foundation
import GRDB
import BudgetCore

/// A rich, fully synthetic database for looking at every screen without anyone's real data
/// (the UI snapshot harness, `MakeDemoDatabase`): UK and euro accounts (one left out of net
/// worth, a mortgage, a card, savings and an ISA), three years of categorised transactions and
/// transfers, a budget plan with a reserve and scenarios, "Property A" owned by Person A and
/// Person B with two tenancies, rent receipts matched to credits, utility providers, invoices
/// and recharge statements in every status, evidence documents (generated PDFs) linked to
/// most of what needs one, and UK tax years with HMRC rates, manual items, employments,
/// benefits and payments. Every name, number and document is invented. Deterministic: the
/// same `asOf` builds the same data.
public enum DemoDatabase {
    /// The day the demo's history runs up to (and the "today" its data assumes).
    public static let defaultAsOf = date(2026, 10, 15)
    /// The first day of history.
    public static let historyStart = date(2023, 10, 1)

    public static let propertyName = "Property A"
    public static let personA = "Person A"
    public static let personB = "Person B"

    public struct Report: Equatable, Sendable {
        public var counts: [String: Int]
        public var notes: [String]

        public var summary: String {
            (counts.keys.sorted().map { "\($0): \(counts[$0]!)" } + notes).joined(separator: "\n")
        }
    }

    public enum DemoError: Error, LocalizedError {
        case notEmpty
        case appData(String)
        public var errorDescription: String? {
            switch self {
            case .notEmpty: return "The demo database must start empty (fresh file)."
            case let .appData(path): return "Refusing to write into the app's data folder: \(path)"
            }
        }
    }

    /// Creates the database at `path` (which must not hold data), migrates it, marks it as the
    /// demo's (`DemoMarker`), and fills it; the evidence PDFs go to `evidenceRoot` (the app
    /// reads `Evidence` beside the database), which gets the demo marker file. Refuses the
    /// app's own data folders.
    @discardableResult
    public static func build(at path: String, evidenceRoot: URL, asOf: Date = defaultAsOf) throws -> Report {
        for target in [path, evidenceRoot.path] where TaxRegression.isAppData(target) {
            throw DemoError.appData(target)
        }
        let manager = try DatabaseManager(path: path)
        try manager.migrate()
        try manager.dbQueue.write { db in try DemoMarker.mark(db) }
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        try Data("Synthetic demo evidence (MakeDemoDatabase).\n".utf8)
            .write(to: evidenceRoot.appendingPathComponent(DemoMarker.evidenceFileName))
        return try build(dbQueue: manager.dbQueue, evidenceRoot: evidenceRoot, asOf: asOf)
    }

    /// Fills a migrated, empty database.
    @discardableResult
    public static func build(dbQueue: DatabaseQueue, evidenceRoot: URL, asOf: Date = defaultAsOf) throws -> Report {
        let builder = Builder(asOf: asOf)
        try dbQueue.write { db in
            guard try Account.fetchCount(db) == 0, try Transaction.fetchCount(db) == 0 else { throw DemoError.notEmpty }
            try builder.buildCore(db)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("BudgetDemoPDFs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let library = EvidenceLibrary(root: evidenceRoot, database: dbQueue)
        let added = try builder.addDocuments(library: library, scratch: scratch)
        try dbQueue.write { db in try builder.linkDocuments(db, added: added) }
        return builder.report
    }

    // MARK: Dates

    static let calendar = MonthRange.calendar

    public static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

// MARK: - Builder

extension DemoDatabase {
    /// SplitMix64: a small deterministic generator.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in `range`.
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
        mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }
        mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }
    }

    /// A document to generate, add and link.
    struct DocSpec {
        var fileName: String
        var page: DemoPDF.Page
        var metadata: EvidenceMetadata
        var links: [EvidenceEntity]
        /// A utility invoice to point at the document.
        var invoiceId: Int64?
    }

    final class Builder {
        let asOf: Date
        var rng = Random(state: 0x5EED_2026)
        var report = Report(counts: [:], notes: [])

        var accounts: [String: Int64] = [:]
        var batches: [Int64: Int64] = [:]
        var categories: [String: Int64] = [:]
        var groups: [String: Int64] = [:]
        var transferCategory: [Int64: Int64] = [:]
        var fingerprint = 0
        var docs: [DocSpec] = []

        var propertyId: Int64 = 0
        var people: [String: Int64] = [:]
        var tenancy1: Int64 = 0
        var tenancy2: Int64 = 0

        init(asOf: Date) {
            self.asOf = MonthRange.calendar.startOfDay(for: asOf)
        }

        func count(_ key: String, _ n: Int = 1) { report.counts[key, default: 0] += n }

        // MARK: Core

        func buildCore(_ db: Database) throws {
            try db.execute(sql: "DELETE FROM exchangeRateSetting")
            var rate = ExchangeRateSetting(eurToGbpRate: 0.85, updatedAt: date(2026, 10, 1))
            try rate.insert(db)
            try createCategories(db)
            try createAccounts(db)
            try createRules(db)
            try ukHistory(db)
            try property(db)
            try euroHistory(db)
            try recharges(db)
            try matchRent(db)
            try tax(db)
            try evidenceRules(db)
            try forecast(db)
            try uncategorised(db)
            _ = try TransferMatcher.match(db: db, today: asOf)
            count("transactions", try Transaction.fetchCount(db))
            count("transfer links", try TransferLink.fetchCount(db))
        }

        // MARK: Categories

        @discardableResult
        func category(_ db: Database, _ name: String, _ type: CategoryType, group: String?, icon: String? = nil,
                      external: Bool = false) throws -> Int64 {
            let symbols = Set(CategoryIcons.allSymbols)
            var category = Category(name: name, type: type, groupId: group.flatMap { groups[$0] }, isExternalTransfer: external,
                                    iconName: icon.flatMap { symbols.contains($0) ? $0 : nil })
            try category.insert(db)
            categories[name] = category.id!
            count("categories")
            return category.id!
        }

        func group(_ db: Database, _ name: String, _ type: CategoryType?) throws {
            var group = CategoryGroup(name: name, type: type)
            try group.insert(db)
            groups[name] = group.id!
        }

        func createCategories(_ db: Database) throws {
            try group(db, "Income", .income)
            try group(db, "Home", .expense)
            try group(db, "Food", .expense)
            try group(db, "Transport", .expense)
            try group(db, "Subscriptions", .expense)
            try group(db, "Lifestyle", .expense)
            try group(db, "Taxes & fees", .expense)
            try group(db, DemoDatabase.propertyName, nil)
            try group(db, "Own accounts", .transfer)

            try category(db, "Income", .income, group: "Income", icon: "sterlingsign.circle.fill")
            try category(db, "Bonus", .income, group: "Income", icon: "gift.fill")
            try category(db, "Savings interest", .income, group: "Income", icon: "percent")
            try category(db, "Other income/refunds", .income, group: "Income", icon: "arrow.uturn.backward")

            try category(db, "Rent", .expense, group: "Home", icon: "house.fill")
            try category(db, "Council Tax", .expense, group: "Home", icon: "building.columns.fill")
            try category(db, "Energy", .expense, group: "Home", icon: "bolt.fill")
            try category(db, "Broadband", .expense, group: "Home", icon: "wifi")
            try category(db, "Home supplies", .expense, group: "Home", icon: "sofa.fill")

            try category(db, "Groceries", .expense, group: "Food", icon: "cart.fill")
            try category(db, "Eating Out", .expense, group: "Food", icon: "fork.knife")
            try category(db, "Coffee", .expense, group: "Food", icon: "cup.and.saucer.fill")

            try category(db, "Public Transport", .expense, group: "Transport", icon: "tram.fill")
            try category(db, "Taxi", .expense, group: "Transport", icon: "car.fill")

            try category(db, "Streaming", .expense, group: "Subscriptions", icon: "tv.fill")
            try category(db, "Phone", .expense, group: "Subscriptions", icon: "iphone")
            try category(db, "Cloud storage", .expense, group: "Subscriptions", icon: "archivebox.fill")

            try category(db, "Holidays", .expense, group: "Lifestyle", icon: "airplane")
            try category(db, "Sport", .expense, group: "Lifestyle", icon: "figure.run")
            try category(db, "Gifts", .expense, group: "Lifestyle", icon: "gift.fill")
            try category(db, "Shopping", .expense, group: "Lifestyle", icon: "bag.fill")

            try category(db, "UK Taxes", .expense, group: "Taxes & fees", icon: "doc.text.fill")
            try category(db, "Accountant", .expense, group: "Taxes & fees", icon: "briefcase.fill")

            // The property's group: rent in, its costs out (tax types follow from the names).
            let property = DemoDatabase.propertyName
            try category(db, "Rental income", .income, group: property, icon: "house.fill")
            try category(db, "Condomínio", .expense, group: property, icon: "building.2.fill")
            try category(db, "IMI", .expense, group: property, icon: "building.columns.fill")
            try category(db, "Home insurance", .expense, group: property, icon: "umbrella.fill")
            try category(db, "Electricity", .expense, group: property, icon: "bolt.fill")
            try category(db, "Water", .expense, group: property, icon: "drop.fill")
            try category(db, "Gas", .expense, group: property, icon: "flame.fill")
            try category(db, "Repairs", .expense, group: property, icon: "wrench.and.screwdriver.fill")
            try category(db, "PT accountant", .expense, group: property, icon: "briefcase.fill")
            try category(db, "Bank fees", .expense, group: property, icon: "creditcard.fill")
            try category(db, "Mortgage interest", .expense, group: property, icon: "percent")
            try category(db, "PT tax (IRS)", .expense, group: property, icon: "doc.text.fill")

            try category(db, "Tenant deposits", .transfer, group: nil, icon: "lock.fill", external: true)
        }

        // MARK: Accounts

        func createAccounts(_ db: Database) throws {
            func add(_ name: String, _ currency: Currency, _ kind: AccountKind, _ mode: AccountTrackingMode, order: Int,
                     main: Bool = false, netWorth: Bool = true, bank: String, sortCode: String? = nil, number: String? = nil,
                     iban: String? = nil, opening: Int) throws {
                // A transfer category waiting in "Own accounts", tied by `TransferCategories.ensure`.
                try category(db, "Transfer: \(name)", .transfer, group: "Own accounts", icon: "arrow.left.arrow.right")
                var account = Account(name: name, currency: currency, kind: kind, trackingMode: mode, sortCode: sortCode,
                                      accountNumber: number, iban: iban, sortOrder: order, bankName: bank, isMain: main,
                                      includeInNetWorth: netWorth)
                try account.insert(db)
                let id = account.id!
                accounts[name] = id
                var batch = ImportBatch(accountId: id, sourceFileName: mode == .manual ? "Manual entries" : "\(name) statement.csv",
                                        importedAt: asOf)
                try batch.insert(db)
                batches[id] = batch.id!
                var snapshot = BalanceSnapshot(accountId: id, date: date(2023, 9, 30),
                                               balanceMinorUnits: NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: opening, accountKind: kind),
                                               note: "Opening balance (demo)")
                try snapshot.insert(db)
                count("accounts")
            }
            try add("Everyday Current", .gbp, .cash, .imported, order: 0, main: true, bank: "Demo Bank", sortCode: "12-34-56", number: "00012345", opening: 240_000)
            try add("Rainy Day Saver", .gbp, .cash, .imported, order: 1, bank: "Demo Bank", sortCode: "12-34-56", number: "00067890", opening: 600_000)
            try add("Travel Card", .gbp, .credit, .imported, order: 2, bank: "Example Card Co", opening: 32_000)
            try add("Index Fund ISA", .gbp, .investment, .manual, order: 3, bank: "Example Invest", opening: 1_200_000)
            try add("Euro Current", .eur, .cash, .imported, order: 4, bank: "Banco Exemplo", iban: "PT50 0000 0000 0000 0000 0000 0", opening: 350_000)
            try add("Property Mortgage", .eur, .credit, .imported, order: 5, bank: "Banco Exemplo", opening: 18_200_000)
            try add("Deposit Holding", .eur, .cash, .imported, order: 6, netWorth: false, bank: "Banco Exemplo", opening: 0)
            // The flat's estimated value, so net worth carries the asset against its mortgage.
            try add("Property A valuation", .eur, .investment, .manual, order: 7, bank: "Estimate", opening: 24_000_000)
            for (day, value) in [(date(2024, 12, 31), 24_600_000), (date(2025, 12, 31), 25_400_000)] {
                var snapshot = BalanceSnapshot(accountId: accounts["Property A valuation"]!, date: day, balanceMinorUnits: value, note: "Yearly estimate")
                try snapshot.insert(db)
            }
            _ = try TransferCategories.ensure(db: db)
            transferCategory = try TransferCategories.categoryIdsByAccount(db: db)
        }

        func createRules(_ db: Database) throws {
            let rules: [(String, String)] = [
                ("GREENLEAF", "Groceries"), ("CORNER GROCER", "Groceries"), ("CITY TRANSIT", "Public Transport"),
                ("STREAMFLIX", "Streaming"), ("TUNEBOX", "Streaming"), ("BEAN THERE", "Coffee"), ("QUICKRIDE", "Taxi"),
                ("EXAMPLE POWER", "Electricity"), ("EXAMPLE WATER", "Water"), ("EXAMPLE GAS", "Gas")
            ]
            for (index, (pattern, name)) in rules.enumerated() {
                var rule = Rule(matchPattern: pattern, matchType: .contains, categoryId: categories[name]!, priority: index)
                try rule.insert(db)
            }
            count("rules", rules.count)
        }

        // MARK: Transactions

        @discardableResult
        func tx(_ db: Database, _ account: String, _ day: Date, _ description: String, _ amount: Int, _ category: String?,
                status: TransactionStatus = .confirmed, by: CategorizedBy = .rule, note: String? = nil) throws -> Transaction {
            let accountId = accounts[account]!
            fingerprint += 1
            var transaction = Transaction(importBatchId: batches[accountId]!, accountId: accountId, date: day, rawDescription: description,
                                          amountMinorUnits: amount, categoryId: category.map { categories[$0]! }, status: status,
                                          categorizedBy: category == nil ? .none : by, fingerprint: "demo-\(fingerprint)", note: note)
            try transaction.insert(db)
            return transaction
        }

        /// Both legs of a move between own accounts, each filed under the other account's
        /// transfer category.
        @discardableResult
        func transfer(_ db: Database, from: String, to: String, _ day: Date, out: Int, into: Int? = nil,
                      _ outDescription: String, _ inDescription: String, inDay: Date? = nil) throws -> (Transaction, Transaction) {
            let fromId = accounts[from]!, toId = accounts[to]!
            fingerprint += 1
            var outLeg = Transaction(importBatchId: batches[fromId]!, accountId: fromId, date: day, rawDescription: outDescription,
                                     amountMinorUnits: -out, categoryId: transferCategory[toId], status: .confirmed, categorizedBy: .transfer,
                                     fingerprint: "demo-\(fingerprint)")
            try outLeg.insert(db)
            fingerprint += 1
            var inLeg = Transaction(importBatchId: batches[toId]!, accountId: toId, date: inDay ?? day, rawDescription: inDescription,
                                    amountMinorUnits: into ?? out, categoryId: transferCategory[fromId], status: .confirmed,
                                    categorizedBy: .transfer, fingerprint: "demo-\(fingerprint)")
            try inLeg.insert(db)
            return (outLeg, inLeg)
        }

        /// Months from `start`'s month to `asOf`'s, as (year, month).
        func months(from start: Date = DemoDatabase.historyStart) -> [(Int, Int)] {
            var result: [(Int, Int)] = []
            var (year, month) = MonthRange.components(of: start)
            let (endYear, endMonth) = MonthRange.components(of: asOf)
            while (year, month) <= (endYear, endMonth) {
                result.append((year, month))
                month += 1
                if month > 12 { month = 1; year += 1 }
            }
            return result
        }

        func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
            let last = calendar.range(of: .day, in: .month, for: date(year, month, 1))!.count
            return date(year, month, min(day, last))
        }

        func inRange(_ day: Date) -> Bool { day >= DemoDatabase.historyStart && day <= asOf }

        /// The weekday on or before `day` (pay on Friday when the 25th is a weekend).
        func workingDay(_ day: Date) -> Date {
            var result = day
            while [1, 7].contains(calendar.component(.weekday, from: result)) {
                result = calendar.date(byAdding: .day, value: -1, to: result)!
            }
            return result
        }

        func pence(_ low: Int, _ high: Int) -> Int { rng.int(low...high) }

        // MARK: UK history

        func ukHistory(_ db: Database) throws {
            var cardSpend: [String: Int] = [:]
            var isaValue = 1_200_000
            for (year, month) in months() {
                let key = "\(year)-\(month)"
                func on(_ d: Int) -> Date { day(year, month, d) }
                // Salary on the 25th (or the Friday before), rising each April.
                let salary: Int
                switch (year, month) {
                case let (y, m) where y < 2024 || (y == 2024 && m < 4): salary = 315_000
                case let (y, m) where y < 2025 || (y == 2025 && m < 4): salary = 332_000
                case let (y, m) where y < 2026 || (y == 2026 && m < 4): salary = 348_000
                default: salary = 361_000
                }
                let payday = workingDay(on(25))
                if inRange(payday) { try tx(db, "Everyday Current", payday, "ACME WIDGETS LTD SALARY", salary, "Income") }
                if month == 12, year >= 2024, inRange(on(20)) {
                    try tx(db, "Everyday Current", workingDay(on(20)), "ACME WIDGETS LTD BONUS", year == 2024 ? 150_000 : 180_000, "Bonus")
                }
                let rent = (year, month) >= (2025, 9) ? -149_500 : -145_000
                if inRange(on(1)) { try tx(db, "Everyday Current", on(1), "OAKWOOD LETTINGS RENT", rent, "Rent") }
                if ![2, 3].contains(month), inRange(on(3)) {
                    try tx(db, "Everyday Current", on(3), "CITY COUNCIL CTAX", (year, month) >= (2025, 4) ? -17_600 : -16_800, "Council Tax")
                }
                let winter = [11, 12, 1, 2, 3].contains(month)
                if inRange(on(12)) { try tx(db, "Everyday Current", on(12), "BRIGHTSPARK ENERGY", winter ? -11_800 : -9_200, "Energy") }
                if inRange(on(15)) { try tx(db, "Everyday Current", on(15), "FIBRELINE BROADBAND", -3_200, "Broadband") }
                if inRange(on(20)) { try tx(db, "Everyday Current", on(20), "PEBBLE MOBILE", -1_400, "Phone") }
                if inRange(on(8)) { try tx(db, "Everyday Current", on(8), "STREAMFLIX", -1_099, "Streaming") }
                if inRange(on(18)) { try tx(db, "Everyday Current", on(18), "TUNEBOX MUSIC", -1_199, "Streaming") }
                if inRange(on(9)) { try tx(db, "Everyday Current", on(9), "CLOUDVAULT STORAGE", -299, "Cloud storage") }
                if inRange(on(2)) { try tx(db, "Everyday Current", on(2), "IRONWORKS GYM", -3_900, "Sport") }
                // Weekly shop, top-ups, coffee, transport.
                for week in 0..<4 {
                    let shop = on(6 + week * 7)
                    if inRange(shop) { try tx(db, "Everyday Current", shop, "GREENLEAF MARKET", -pence(4_500, 9_500), "Groceries") }
                    if rng.chance(60), inRange(on(3 + week * 7)) {
                        try tx(db, "Everyday Current", on(3 + week * 7), "CORNER GROCER", -pence(800, 2_200), "Groceries")
                    }
                    if inRange(on(4 + week * 7)) { try tx(db, "Everyday Current", on(4 + week * 7), "CITY TRANSIT", -pence(1_200, 2_400), "Public Transport") }
                    if rng.chance(70), inRange(on(5 + week * 7)) { try tx(db, "Everyday Current", on(5 + week * 7), "BEAN THERE COFFEE", -pence(320, 410), "Coffee") }
                }
                for _ in 0..<rng.int(2...4) {
                    let d = on(rng.int(1...28))
                    if inRange(d) { try tx(db, "Everyday Current", d, rng.pick(["CAFE NOVA", "THE GOLDEN SPOON", "NOODLE HOUSE"]), -pence(1_200, 4_800), "Eating Out") }
                }
                let taxiDay = on(rng.int(1...28))
                if rng.chance(50), inRange(taxiDay) {
                    try tx(db, "Everyday Current", taxiDay, "QUICKRIDE", -pence(900, 2_600), "Taxi")
                }
                // Card spending, paid off on the 5th of the next month.
                var spent = 0
                for _ in 0..<rng.int(2...3) {
                    let d = on(rng.int(1...28))
                    guard inRange(d) else { continue }
                    let amount = pence(1_500, 8_000)
                    spent += amount
                    try tx(db, "Travel Card", d, rng.pick(["NORTHWIND STORE", "BOOKNOOK ONLINE", "HOMEWARE HUB"]), -amount, "Shopping")
                }
                if [(2024, 5), (2025, 8), (2026, 4)].contains(where: { $0 == (year, month) }) {
                    for (merchant, amount) in [("SKYHOP AIRLINES", 21_000), ("HARBOUR HOTEL", 48_000), ("SEASIDE TOURS", 9_500)] {
                        let d = on(rng.int(5...20))
                        guard inRange(d) else { continue }
                        spent += amount
                        try tx(db, "Travel Card", d, merchant, -amount, "Holidays")
                    }
                }
                if month == 12, inRange(on(14)) {
                    spent += 12_000
                    try tx(db, "Travel Card", on(14), "GIFTHOUSE", -12_000, "Gifts")
                }
                cardSpend[key] = spent
                let previous = month == 1 ? "\(year - 1)-12" : "\(year)-\(month - 1)"
                let payOff = (cardSpend[previous] ?? 32_000)
                if payOff > 0, inRange(on(5)) {
                    try transfer(db, from: "Everyday Current", to: "Travel Card", on(5), out: payOff, "EXAMPLE CARD CO PAYMENT", "PAYMENT RECEIVED - THANK YOU")
                }
                // Savings and the ISA.
                if inRange(on(26)) {
                    try transfer(db, from: "Everyday Current", to: "Rainy Day Saver", on(26), out: 40_000, "TO RAINY DAY SAVER", "FROM EVERYDAY CURRENT")
                }
                if inRange(on(28)) { try tx(db, "Rainy Day Saver", on(28), "INTEREST PAID", pence(1_200, 2_200), "Savings interest") }
                if inRange(on(27)) {
                    try transfer(db, from: "Everyday Current", to: "Index Fund ISA", on(27), out: 30_000, "EXAMPLE INVEST ISA", "Contribution")
                    isaValue += 30_000
                }
                if [3, 6, 9, 12].contains(month) {
                    let quarterEnd = day(year, month, 31)
                    if inRange(quarterEnd) {
                        isaValue = isaValue * (1_000 + rng.int(-25...45)) / 1_000
                        var snapshot = BalanceSnapshot(accountId: accounts["Index Fund ISA"]!, date: quarterEnd, balanceMinorUnits: isaValue,
                                                       note: "Quarterly valuation")
                        try snapshot.insert(db)
                    }
                }
            }
            // Self Assessment, the accountant, and one move to the euro account.
            for (when, amount) in [(date(2025, 1, 29), 98_000), (date(2026, 1, 28), 186_000), (date(2026, 7, 30), 62_000)] where inRange(when) {
                try tx(db, "Everyday Current", when, "HMRC SELF ASSESSMENT", -amount, "UK Taxes")
            }
            for when in [date(2025, 1, 10), date(2026, 1, 12)] where inRange(when) {
                try tx(db, "Everyday Current", when, "LEDGERLY ACCOUNTANTS", -45_000, "Accountant")
            }
            try transfer(db, from: "Everyday Current", to: "Euro Current", date(2025, 6, 10), out: 100_000, into: 116_500,
                         "TO EURO CURRENT", "TRANSFER FROM UK", inDay: date(2025, 6, 11))
        }

        // MARK: Property

        func property(_ db: Database) throws {
            var property = Property(name: DemoDatabase.propertyName, country: "PT", currency: .eur, matrixArticle: "U-0000-X",
                                    purchasePriceMinorUnits: 24_000_000, purchaseDate: date(2023, 9, 1),
                                    notes: "A fictional two-bedroom flat used by the demo database.")
            try Properties.save(db: db, &property)
            propertyId = property.id!
            var a = Person(name: DemoDatabase.personA, shortName: "A", ukUtr: "0000000001", ukNino: "QQ123456A", ptNif: "000000001")
            var b = Person(name: DemoDatabase.personB, shortName: "B", ukUtr: "0000000002", ukNino: "QQ654321B", ptNif: "000000002")
            try People.save(db: db, &a)
            try People.save(db: db, &b)
            people = [DemoDatabase.personA: a.id!, DemoDatabase.personB: b.id!]
            _ = try Properties.setOwners(db: db, propertyId: propertyId, [
                PropertyOwner(propertyId: propertyId, personId: a.id!, shareBasisPoints: 5_000, fromDate: date(2023, 9, 1)),
                PropertyOwner(propertyId: propertyId, personId: b.id!, shareBasisPoints: 5_000, fromDate: date(2023, 9, 1))
            ])
            _ = try Properties.setAccount(db: db, propertyId: propertyId, accountId: accounts["Euro Current"]!, role: .current)
            _ = try Properties.setAccount(db: db, propertyId: propertyId, accountId: accounts["Property Mortgage"]!, role: .mortgage)
            _ = try Properties.setAccount(db: db, propertyId: propertyId, accountId: accounts["Deposit Holding"]!, role: .deposit)
            try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: groups[DemoDatabase.propertyName]!)

            var first = Tenancy(propertyId: propertyId, referenceLabel: "Tenancy 1", contractNumber: "CT-0001", tenantName: "Tenant One",
                                startDate: date(2023, 11, 1), endDate: date(2024, 6, 30), advanceRentMonths: 0, depositMonths: 2,
                                notes: "Fixed-term contract, not renewed.", tenantEmail: "tenant.one@example.com")
            try Tenancies.save(db: db, &first)
            tenancy1 = first.id!
            _ = try Tenancies.setRents(db: db, tenancyId: tenancy1, [TenancyRent(tenancyId: tenancy1, fromDate: first.startDate, monthlyAmountMinorUnits: 100_000)])
            var second = Tenancy(propertyId: propertyId, referenceLabel: "Tenancy 2", contractNumber: "CT-0002", tenantName: "Tenant Two",
                                 startDate: date(2024, 8, 1), endDate: nil, advanceRentMonths: 1, depositMonths: 2,
                                 notes: "Renews yearly; utilities recharged monthly.", tenantEmail: "tenant.two@example.com")
            try Tenancies.save(db: db, &second)
            tenancy2 = second.id!
            _ = try Tenancies.setRents(db: db, tenancyId: tenancy2, [
                TenancyRent(tenancyId: tenancy2, fromDate: second.startDate, monthlyAmountMinorUnits: 115_000),
                TenancyRent(tenancyId: tenancy2, fromDate: date(2025, 8, 1), monthlyAmountMinorUnits: 120_000)
            ])
            count("tenancies", 2)
            docs.append(doc("Tenancy contract CT-0001.pdf", kind: .rentContract, issuer: "Property A", title: "Tenancy contract CT-0001",
                            lines: [("Tenant", "Tenant One"), ("Start", "1 Nov 2023"), ("End", "30 Jun 2024"), ("Monthly rent", "€1,000.00"), ("Deposit", "Two months")],
                            date: date(2023, 10, 20), amount: nil, links: [EvidenceEntity(type: .tenancy, id: tenancy1)]))
            docs.append(doc("Tenancy contract CT-0002.pdf", kind: .rentContract, issuer: "Property A", title: "Tenancy contract CT-0002",
                            lines: [("Tenant", "Tenant Two"), ("Start", "1 Aug 2024"), ("Monthly rent", "€1,150.00"), ("Deposit", "Two months"), ("Advance rent", "One month")],
                            date: date(2024, 7, 15), amount: nil, links: [EvidenceEntity(type: .tenancy, id: tenancy2)]))
            docs.append(doc("Property deed.pdf", kind: .propertyDeed, issuer: "Registry Office", title: "Deed of purchase",
                            lines: [("Property", "Property A"), ("Price", "€240,000.00"), ("Date", "1 Sep 2023"), ("Buyers", "Person A, Person B")],
                            date: date(2023, 9, 1), amount: 24_000_000, links: [EvidenceEntity(type: .property, id: propertyId)]))
            docs.append(doc("Energy certificate.pdf", kind: .certificate, issuer: "Energy Agency", title: "Energy performance certificate",
                            lines: [("Property", "Property A"), ("Rating", "B"), ("Valid until", "2033")],
                            date: date(2023, 8, 10), amount: nil, links: [EvidenceEntity(type: .property, id: propertyId)]))
        }

        // MARK: Euro history (the property's money)

        var utilityDebits: [(kind: UtilityKind, day: Date, amount: Int, transactionId: Int64, period: (Date, Date), issue: Date)] = []

        func euroHistory(_ db: Database) throws {
            // Deposits on the deposit account.
            try tx(db, "Deposit Holding", date(2023, 10, 25), "DEPOSIT TENANT ONE", 200_000, "Tenant deposits")
            try tx(db, "Deposit Holding", date(2024, 7, 5), "DEPOSIT RETURNED TENANT ONE", -200_000, "Tenant deposits")
            try tx(db, "Deposit Holding", date(2024, 7, 26), "DEPOSIT TENANT TWO", 230_000, "Tenant deposits")
            var owed = 18_200_000
            for (year, month) in months() {
                func on(_ d: Int) -> Date { day(year, month, d) }
                // Mortgage: interest charged on the loan, the instalment paid into it.
                if inRange(on(1)) {
                    let interest = owed * 21 / 12_000
                    owed += interest - 76_000
                    let interestRow = try tx(db, "Property Mortgage", on(1), "LOAN INTEREST", -interest, "Mortgage interest")
                    let (instalment, _) = try transfer(db, from: "Euro Current", to: "Property Mortgage", on(1), out: 76_000,
                                                       "LOAN INSTALMENT", "INSTALMENT RECEIVED")
                    if (year, month) < (2026, 7) {
                        docs.append(doc("Mortgage notice \(year)-\(String(format: "%02d", month)).pdf", kind: .mortgageNotice, issuer: "Banco Exemplo",
                                        title: "Loan instalment notice",
                                        lines: [("Instalment", Money.format(76_000, currency: .eur)), ("Interest", Money.format(interest, currency: .eur)),
                                                ("Capital", Money.format(76_000 - interest, currency: .eur)), ("Outstanding", Money.format(owed, currency: .eur))],
                                        date: on(1), amount: 76_000, links: [.transaction(instalment.id!), .transaction(interestRow.id!)]))
                    }
                }
                // Monthly bank fee.
                if inRange(on(28)) {
                    let fee = try tx(db, "Euro Current", on(28), "ACCOUNT MAINTENANCE FEE", -416, "Bank fees")
                    if year == 2025 { bankFees2025.append(fee.id!) }
                }
                // Condomínio quarterly.
                if [1, 4, 7, 10].contains(month), inRange(on(8)) {
                    let row = try tx(db, "Euro Current", on(8), "CONDOMINIO EDIFICIO EXEMPLO", -21_000, "Condomínio")
                    if (year, month) < (2026, 7) {
                        docs.append(doc("Condominio receipt \(year)-\(String(format: "%02d", month)).pdf", kind: .condominioReceipt, issuer: "Condomínio Exemplo",
                                        title: "Quarterly service charge receipt", lines: [("Quarter", "\(month)/\(year)"), ("Amount", "€210.00")],
                                        date: on(8), amount: 21_000, links: [.transaction(row.id!)]))
                    }
                }
                // IMI in May and November.
                if [5, 11].contains(month), inRange(on(15)) {
                    let row = try tx(db, "Euro Current", on(15), "AT IMI PAYMENT", -16_500, "IMI")
                    if month == 5 {
                        docs.append(doc("IMI notice \(year).pdf", kind: .imiNotice, issuer: "Tax Authority", title: "Municipal property tax notice \(year - 1)",
                                        lines: [("Total", "€330.00"), ("Instalments", "May and November")], date: date(year, 4, 2), amount: 33_000,
                                        links: [.transaction(row.id!)]))
                        imiNotices[year] = docs.count - 1
                    } else if let index = imiNotices[year] {
                        docs[index].links.append(.transaction(row.id!))
                    }
                }
                // Insurance in March, the PT accountant in April, PT tax in August.
                if month == 3, inRange(on(1)) {
                    let row = try tx(db, "Euro Current", on(1), "SEGUROS EXEMPLO HOME POLICY", -26_400, "Home insurance")
                    docs.append(doc("Home insurance receipt \(year).pdf", kind: .insuranceReceipt, issuer: "Seguros Exemplo", title: "Home insurance — annual premium",
                                    lines: [("Policy", "HP-000123"), ("Cover", "Mar \(year) – Feb \(year + 1)"), ("Premium", "€264.00")],
                                    date: on(1), amount: 26_400, links: [.transaction(row.id!)]))
                }
                if month == 4, inRange(on(20)) {
                    let row = try tx(db, "Euro Current", on(20), "CONTABILIDADE EXEMPLO", -18_000, "PT accountant")
                    if year < 2026 {
                        docs.append(doc("Accountant invoice \(year).pdf", kind: .accountantInvoice, issuer: "Contabilidade Exemplo", title: "Invoice — annual tax return",
                                        lines: [("Service", "IRS Modelo 3, \(year - 1)"), ("Amount", "€180.00")], date: on(18), amount: 18_000,
                                        links: [.transaction(row.id!)]))
                    }
                }
                if month == 8, inRange(on(20)) {
                    let amount = [2024: 98_000, 2025: 112_000, 2026: 118_000][year] ?? 100_000
                    let row = try tx(db, "Euro Current", on(20), "AT IRS PAYMENT", -amount, "PT tax (IRS)")
                    if year < 2026 {
                        docs.append(doc("IRS assessment \(year - 1).pdf", kind: .ptIRSAssessment, issuer: "Tax Authority", title: "IRS assessment \(year - 1)",
                                        lines: [("Tax due", Money.format(amount, currency: .eur)), ("Pay by", "31 Aug \(year)")], date: date(year, 7, 20),
                                        amount: amount, links: [.transaction(row.id!)]))
                    }
                }
                // Utilities, paid by direct debit: electricity monthly, gas in winter, water every two months.
                let electricity = [11, 12, 1, 2, 3].contains(month) ? pence(5_800, 7_600) : pence(3_900, 5_400)
                try utility(db, .electricity, year: year, month: month, amount: electricity, debitDay: 25, issueDay: 18, months: 1)
                if [10, 11, 12, 1, 2, 3, 4].contains(month) {
                    try utility(db, .gas, year: year, month: month, amount: pence(1_800, 4_500), debitDay: 22, issueDay: 15, months: 1)
                }
                if month % 2 == 0 {
                    try utility(db, .water, year: year, month: month, amount: pence(2_200, 3_000), debitDay: 20, issueDay: 10, months: 2)
                }
            }
            // A boiler repair (with its invoice) and a plumber (without).
            let repair = try tx(db, "Euro Current", date(2025, 2, 11), "BOILER REPAIR LDA", -32_000, "Repairs", note: "Boiler pressure valve replaced")
            docs.append(doc("Boiler repair invoice.pdf", kind: .other, issuer: "Boiler Repair Lda", title: "Invoice 2025/118",
                            lines: [("Work", "Pressure valve replaced"), ("Amount", "€320.00")], date: date(2025, 2, 10), amount: 32_000,
                            links: [.transaction(repair.id!)]))
            try tx(db, "Euro Current", date(2026, 3, 5), "PLUMBER SERVICES", -14_500, "Repairs")
            docs.append(doc("Bank statement 2025.pdf", kind: .bankStatement, issuer: "Banco Exemplo", title: "Annual statement of fees 2025",
                            lines: [("Account", "Euro Current"), ("Fees", "€49.92")], date: date(2026, 1, 15), amount: 4_992,
                            links: bankFees2025.map { .transaction($0) }))

            try rentHistory(db)
        }

        var bankFees2025: [Int64] = []
        var imiNotices: [Int: Int] = [:]

        func utility(_ db: Database, _ kind: UtilityKind, year: Int, month: Int, amount: Int, debitDay: Int, issueDay: Int, months: Int) throws {
            let debit = day(year, month, debitDay)
            guard inRange(debit) else { return }
            let name: String, category: String
            switch kind {
            case .electricity: (name, category) = ("EXAMPLE POWER DD", "Electricity")
            case .gas: (name, category) = ("EXAMPLE GAS DD", "Gas")
            case .water: (name, category) = ("EXAMPLE WATER DD", "Water")
            case .other: (name, category) = ("UTILITY", "Electricity")
            }
            let row = try tx(db, "Euro Current", debit, name, -amount, category)
            // The consumption period: the month(s) before the issue date, from the 15th.
            let periodEnd = day(year, month, 14)
            let periodStart = calendar.date(byAdding: .month, value: -months, to: day(year, month, 15))!
            utilityDebits.append((kind, debit, amount, row.id!, (periodStart, periodEnd), day(year, month, issueDay)))
        }

        func rentHistory(_ db: Database) throws {
            // Tenancy 1: €1,000 on the 2nd of each month, Nov 2023 – Jun 2024.
            for (year, month) in months() where (year, month) >= (2023, 11) && (year, month) <= (2024, 6) {
                let credit = try tx(db, "Euro Current", day(year, month, 2), "TRF TENANT ONE RENT", 100_000, "Rental income")
                try receipt(tenancy: tenancy1, number: "T1-\(String(format: "%03d", receiptCounter[tenancy1, default: 0] + 1))",
                            year: year, month: month, amount: 100_000, receiptDate: credit.date, db: db, withPDF: (year, month) != (2024, 3))
            }
            // Tenancy 2: the first two months together (advance rent), then monthly with the
            // previous month's utility recharge on top (added after the statements exist).
            let advance = try tx(db, "Euro Current", date(2024, 7, 26), "TRF TENANT TWO RENT AUG SEP", 230_000, "Rental income")
            for month in [8, 9] {
                try receipt(tenancy: tenancy2, number: "T2-\(String(format: "%03d", receiptCounter[tenancy2, default: 0] + 1))",
                            year: 2024, month: month, amount: 115_000, receiptDate: advance.date, db: db, withPDF: true)
            }
        }

        var receiptCounter: [Int64: Int] = [:]

        @discardableResult
        func receipt(tenancy: Int64, number: String, year: Int, month: Int, amount: Int, receiptDate: Date, db: Database,
                     withPDF: Bool) throws -> RentReceipt {
            let start = date(year, month, 1)
            let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
            var receipt = RentReceipt(tenancyId: tenancy, receiptNumber: number, periodStart: start, periodEnd: end,
                                      receiptDate: receiptDate, amountMinorUnits: amount)
            try RentReceipts.save(db: db, &receipt)
            receiptCounter[tenancy, default: 0] += 1
            count("rent receipts")
            if withPDF {
                let tenant = tenancy == tenancy1 ? "Tenant One" : "Tenant Two"
                docs.append(doc("Rent receipt \(number).pdf", kind: .rentReceipt, issuer: "Tax Authority portal", title: "Rent receipt \(number)",
                                lines: [("Tenant", tenant), ("Period", "\(DemoDatabase.monthName(month)) \(year)"), ("Rent", Money.format(amount, currency: .eur)),
                                        ("Withholding", "€0.00")],
                                date: receiptDate, amount: amount, links: [EvidenceEntity(type: .rentReceipt, id: receipt.id!)]))
            }
            return receipt
        }

        // MARK: Recharges

        func recharges(_ db: Database) throws {
            var providers: [UtilityKind: UtilityProvider] = [:]
            for (kind, name, reference, pattern) in [(UtilityKind.electricity, "Example Power", "EP-000123", "EXAMPLE POWER"),
                                                     (.gas, "Example Gas", "EG-008910", "EXAMPLE GAS"),
                                                     (.water, "Example Water", "EW-004567", "EXAMPLE WATER")] {
                // Reading rules for the demo's own invoice layout (the intake sheet fills its lines).
                let rules = UtilityInvoiceRules(textMarkers: [name.uppercased()], invoiceNumberPatterns: [#"INVOICE\s+([A-Z]{2}-\d{4}-\d{4})"#],
                                                issueDateLabels: ["ISSUED"], periodLabels: ["PERIOD"], amountLabels: ["AMOUNT DUE"])
                var provider = UtilityProvider(propertyId: propertyId, name: name, kind: kind, accountReference: reference,
                                               bankDescriptionPattern: pattern, notes: "Direct debit from Euro Current", invoiceRules: rules)
                try Recharges.saveProvider(db: db, &provider)
                providers[kind] = provider
            }
            // Invoices from July 2024 (the month before Tenancy 2), each settled by its debit.
            var invoiceCounter: [UtilityKind: Int] = [:]
            let recorded = utilityDebits.filter { $0.day >= date(2024, 7, 1) }
            for (index, debit) in recorded.enumerated() {
                let provider = providers[debit.kind]!
                invoiceCounter[debit.kind, default: 0] += 1
                let number = "\(provider.accountReference!.prefix(2))-\(MonthRange.components(of: debit.issue).year)-\(String(format: "%04d", invoiceCounter[debit.kind]!))"
                var invoice = UtilityInvoice(providerId: provider.id!, invoiceNumber: number, periodStart: debit.period.0, periodEnd: debit.period.1,
                                             issueDate: debit.issue, amountMinorUnits: debit.amount, transactionId: debit.transactionId)
                try Recharges.saveInvoice(db: db, &invoice)
                count("utility invoices")
                // The latest two invoices have no PDF yet.
                guard index < recorded.count - 2 else { continue }
                var spec = doc("\(provider.name) invoice \(number).pdf", kind: .utilityInvoice, issuer: provider.name, title: "Invoice \(number)",
                               lines: [("Account", provider.accountReference!), ("Issued", DemoDatabase.short(debit.issue)),
                                       ("Period", "\(DemoDatabase.short(debit.period.0)) – \(DemoDatabase.short(debit.period.1))"),
                                       ("Amount due", Money.format(debit.amount, currency: .eur)), ("Direct debit", DemoDatabase.short(debit.day))],
                               date: debit.issue, amount: debit.amount, links: [.transaction(debit.transactionId)])
                spec.invoiceId = invoice.id!
                docs.append(spec)
            }
            // One invoice PDF waiting in the library for intake (not recorded yet).
            docs.append(doc("Example Power invoice EP-2026-pending.pdf", kind: .utilityInvoice, issuer: "Example Power", title: "Invoice EP-2026-0099",
                            lines: [("Account", "EP-000123"), ("Issued", "14 Oct 2026"), ("Period", "15 Sep 2026 – 14 Oct 2026"), ("Amount due", "€47.80")],
                            date: date(2026, 10, 14), amount: 4_780, links: []))

            // Statements, month by month up to last month: drafted at the month's end, sent on
            // the 3rd — except the latest, still a draft.
            var totals: [Int: Int] = [:]  // year*12+month → total
            let (asOfYear, asOfMonth) = MonthRange.components(of: asOf)
            let statementMonths = months(from: date(2024, 8, 1)).filter { $0 != (asOfYear, asOfMonth) }
            for (index, (year, month)) in statementMonths.enumerated() {
                let statement = try Recharges.draftStatement(db: db, tenancyId: tenancy2, month: date(year, month, 1))
                totals[year * 12 + month] = statement.totalMinorUnits
                let sendDay = calendar.date(byAdding: DateComponents(month: 1, day: 2), to: date(year, month, 1))!
                if index < statementMonths.count - 1 { try Recharges.markSent(db: db, statementId: statement.id!, at: sendDay) }
                count("recharge statements")
            }
            // Tenancy 2's monthly credits from October 2024: the rent plus the statements sent
            // since the last credit. September 2026's leaves August's utilities unpaid;
            // October 2026's rent comes late (the 12th) and has no receipt yet.
            var unpaid: [Int] = [8, 9].map { 2024 * 12 + $0 }
            for (year, month) in months(from: date(2024, 10, 1)) {
                let creditDay = (year, month) == (2026, 10) ? date(2026, 10, 12) : day(year, month, 4)
                guard inRange(creditDay) else { continue }
                let rent = (year, month) >= (2025, 8) ? 120_000 : 115_000
                let recharge = [(2026, 9), (2026, 10)].contains(where: { $0 == (year, month) }) ? 0 : unpaid.reduce(0) { $0 + (totals[$1] ?? 0) }
                let credit = try tx(db, "Euro Current", creditDay, recharge > 0 ? "TRF TENANT TWO RENT + UTILITIES" : "TRF TENANT TWO RENT",
                                    rent + recharge, "Rental income")
                if (year, month) != (2026, 10) {
                    unpaid = [year * 12 + month]
                    try receipt(tenancy: tenancy2, number: "T2-\(String(format: "%03d", receiptCounter[tenancy2, default: 0] + 1))",
                                year: year, month: month, amount: rent, receiptDate: credit.date, db: db,
                                withPDF: (year, month) < (2026, 8))
                } else {
                    unpaid.append(year * 12 + month)
                }
            }
        }

        func matchRent(_ db: Database) throws {
            let rent = try RentReceiptMatching.match(db: db, propertyId: propertyId)
            let recharges = try Recharges.matchPayments(db: db, propertyId: propertyId)
            count("rent links", rent.created.count)
            count("recharge payments", recharges.count)
            report.notes.append("Unmatched receipts: \(rent.unmatchedReceipts.count), unmatched credits: \(rent.unmatchedCredits.count)")
        }

        // MARK: Tax

        func tax(_ db: Database) throws {
            let a = people[DemoDatabase.personA]!, b = people[DemoDatabase.personB]!
            for (year, units, source) in [(2023, 1.1501, HMRCRateSource.filedReturn), (2024, 1.1812, .hmrcPublished), (2025, 1.1655, .hmrcPublished)] {
                let gbp = (1 / units * 1_000_000).rounded() / 1_000_000
                try HMRCRates.set(db: db, startYear: year, currencyCode: "EUR", gbpPerUnit: gbp, unitsPerPound: units, source: source,
                                  fetchedAt: source == .hmrcPublished ? date(year + 1, 4, 10) : nil)
            }
            _ = try TaxAttributionRules.seedDefaults(db: db)
            _ = try TaxExpenseTypeMap.seed(db: db, propertyId: propertyId)
            // The filed 2024/25 returns: foreign tax on the previous calendar year, utilities
            // left out (fully recharged), as filed.
            try TaxAttributionRules.set(db: db, expenseType: .foreignTax, startYear: 2024, rule: .previousCalendarYear,
                                        notes: "Kept for the filed return")
            try RechargeNetting.set(db: db, startYear: 2024, mode: .notDeductible, notes: "As filed")
            for (person, year, status) in [(a, 2023, TaxYearStatus.paid), (a, 2024, .filed), (a, 2025, .preparing),
                                           (b, 2023, .paid), (b, 2024, .filed), (b, 2025, .ready)] {
                var record = try TaxYears.ensure(db: db, startYear: year, personId: person)
                record.status = status
                try TaxYears.save(db: db, &record)
            }
            // Manual items.
            for (person, year, type, label, amount, currency, day, whole) in [
                (a, 2024, TaxExpenseType.accountancy, "UK accountant fee", 42_000, Currency.gbp, date(2025, 1, 10), false),
                (a, 2025, .accountancy, "UK accountant fee", 45_000, .gbp, date(2026, 1, 12), false),
                (a, 2025, .otherExpense, "Travel to inspect the property", 18_500, .eur, date(2025, 9, 14), true),
                (b, 2025, .otherExpense, "Postage and copies", 1_200, .eur, date(2025, 11, 3), true),
                // 2026's PT tax isn't assessed until 2027: an estimate for its days in 2025/26.
                (a, 2025, .foreignTax, "PT tax 2026 (estimate)", 120_000, .eur, date(2026, 4, 5), true),
                (b, 2025, .foreignTax, "PT tax 2026 (estimate)", 120_000, .eur, date(2026, 4, 5), true)
            ] {
                var item = TaxManualItem(startYear: year, personId: person, propertyId: propertyId, expenseType: type, label: label,
                                         amountMinorUnits: amount, currency: currency, date: day, isWholeProperty: whole)
                try TaxManualItems.save(db: db, &item)
                count("tax manual items")
            }
            // Employments: P60s (and P11D benefits) for Person A, a smaller job for Person B.
            func employment(_ person: Int64, _ year: Int, _ employer: String, _ paye: String, pay: Int, tax: Int, medical: Int?, p60PDF: Bool) throws {
                var job = Employment(startYear: year, personId: person, employerName: employer, payeReference: paye)
                try Employments.save(db: db, &job)
                var income = EmploymentIncome(employmentId: job.id!, source: .p60, payMinorUnits: pay, taxDeductedMinorUnits: tax,
                                              taxCode: "1257L", periodEnd: date(year + 1, 4, 5), entryMethod: .textLayer)
                try Employments.save(db: db, &income)
                if let medical {
                    var benefit = BenefitInKind(employmentId: job.id!, kind: .medical, description: "Private medical insurance",
                                                cashEquivalentMinorUnits: medical, entryMethod: .textLayer, isFromP11DImport: true)
                    try Employments.save(db: db, &benefit)
                    docs.append(doc("P11D \(year)-\(String((year + 1) % 100)) \(employer).pdf", kind: .p11d, issuer: employer, title: "P11D \(year)/\(String((year + 1) % 100))",
                                    lines: [("Employee", person == a ? DemoDatabase.personA : DemoDatabase.personB), ("Section I — medical", Money.format(medical, currency: .gbp))],
                                    date: date(year + 1, 6, 30), amount: medical, links: [EvidenceEntity(type: .employment, id: job.id!)]))
                }
                if p60PDF {
                    docs.append(doc("P60 \(year)-\(String((year + 1) % 100)) \(employer).pdf", kind: .p60, issuer: employer, title: "P60 End of Year Certificate \(year)/\(String((year + 1) % 100))",
                                    lines: [("Employee", person == a ? DemoDatabase.personA : DemoDatabase.personB), ("PAYE reference", paye),
                                            ("Pay in this employment", Money.format(pay, currency: .gbp)), ("Tax deducted", Money.format(tax, currency: .gbp)),
                                            ("Final tax code", "1257L")],
                                    date: date(year + 1, 5, 20), amount: pay, links: [EvidenceEntity(type: .employmentIncome, id: income.id!)]))
                }
                count("employments")
            }
            try employment(a, 2023, "Acme Widgets Ltd", "123/AB45678", pay: 3_780_000, tax: 504_600, medical: nil, p60PDF: true)
            try employment(a, 2024, "Acme Widgets Ltd", "123/AB45678", pay: 3_984_000, tax: 545_400, medical: 115_000, p60PDF: true)
            try employment(a, 2025, "Acme Widgets Ltd", "123/AB45678", pay: 4_176_000, tax: 583_800, medical: 121_000, p60PDF: true)
            try employment(b, 2024, "Example Studio Ltd", "456/CD12345", pay: 2_650_000, tax: 278_600, medical: nil, p60PDF: true)
            try employment(b, 2025, "Example Studio Ltd", "456/CD12345", pay: 2_740_000, tax: 296_600, medical: nil, p60PDF: false)
            var interest = OtherIncome(startYear: 2025, personId: a, kind: .ukInterest, payer: "Demo Bank", amountMinorUnits: 18_600, date: date(2026, 4, 5))
            try OtherIncomes.save(db: db, &interest)
            var pension = PensionContribution(startYear: 2025, personId: a, kind: .reliefAtSource, provider: "Example Pensions", paidMinorUnits: 120_000,
                                              date: date(2026, 3, 31))
            try PensionContributions.save(db: db, &pension)
            for (person, year, day, amount, kind, proof) in [
                (a, 2023, date(2025, 1, 29), 98_000, HMRCPaymentKind.balancingPayment, false),
                (a, 2024, date(2026, 1, 28), 124_000, .balancingPayment, true),
                (a, 2025, date(2026, 1, 28), 62_000, .firstPaymentOnAccount, true),
                (a, 2025, date(2026, 7, 30), 62_000, .secondPaymentOnAccount, false),
                (b, 2024, date(2026, 1, 27), 41_000, .balancingPayment, false)
            ] {
                var payment = HMRCPayment(personId: person, startYear: year, date: day, amountMinorUnits: amount, kind: kind,
                                          reference: "0000000001K")
                try HMRCPayments.save(db: db, &payment)
                if proof {
                    docs.append(doc("HMRC payment \(DemoDatabase.short(day)).pdf", kind: .hmrcPaymentProof, issuer: "Demo Bank", title: "Payment confirmation",
                                    lines: [("Payee", "HMRC Self Assessment"), ("Amount", Money.format(amount, currency: .gbp)), ("Date", DemoDatabase.short(day))],
                                    date: day, amount: amount, links: [EvidenceEntity(type: .hmrcPayment, id: payment.id!)]))
                }
                count("HMRC payments")
            }
        }

        // MARK: Evidence rules

        func evidenceRules(_ db: Database) throws {
            var rules = try EvidenceRequirementDefaults.seedPropertyRules(db: db, categoryGroupId: groups[DemoDatabase.propertyName]!,
                                                                          mortgageAccountIds: [accounts["Property Mortgage"]!])
            rules += try PropertyEvidence.seedRules(db: db, propertyId: propertyId)
            rules += try PersonalIncomeEvidence.seedRules(db: db)
            count("evidence rules", rules.count)
        }

        // MARK: Forecast

        func forecast(_ db: Database) throws {
            try AutoForecastGenerator.refresh(db: db)
            _ = try ReservedCategories.addReserve(db: db, name: "Day-to-day spending", amountMinorUnits: 120_000, frequency: .monthly, interval: 1,
                                                  startDate: date(2026, 1, 1), endDate: nil)
            try PlannedItems.add(db: db, categoryId: categories["Holidays"]!, amountMinorUnits: -150_000, frequency: .annually, interval: 1,
                                 startDate: date(2027, 5, 1), endDate: nil)
            try PlannedItems.add(db: db, categoryId: categories["Bonus"]!, amountMinorUnits: 180_000, frequency: .once, interval: 1,
                                 startDate: date(2026, 12, 18), endDate: nil)
            try PlannedItems.add(db: db, categoryId: categories["Gifts"]!, amountMinorUnits: -30_000, frequency: .annually, interval: 1,
                                 startDate: date(2026, 12, 1), endDate: nil)
            // Scenarios: a bigger flat from January, and a pay rise.
            let flat = try Scenarios.create(db: db, name: "Bigger flat from 2027", now: asOf)
            for var entry in try ForecastEntry.filter(Column("scenarioId") == flat.id! && Column("categoryId") == categories["Rent"]!).fetchAll(db) {
                entry.amountMinorUnits = -185_000
                entry.startDate = date(2027, 1, 1)
                entry.scenarioChange = .changed
                try entry.update(db)
            }
            try PlannedItems.add(db: db, categoryId: categories["Home supplies"]!, amountMinorUnits: -250_000, frequency: .once, interval: 1,
                                 startDate: date(2027, 1, 15), endDate: nil, scenarioId: flat.id!)
            let rise = try Scenarios.create(db: db, name: "Pay rise 2027", now: asOf)
            try PlannedItems.add(db: db, categoryId: categories["Income"]!, amountMinorUnits: 22_000, frequency: .monthly, interval: 1,
                                 startDate: date(2027, 4, 25), endDate: nil, scenarioId: rise.id!)
            count("forecast entries", try ForecastEntry.fetchCount(db))
            count("scenarios", 2)
        }

        /// A few recent rows still waiting for a category.
        func uncategorised(_ db: Database) throws {
            for (offset, description, amount) in [(1, "AMZN MKTPLACE 2Q4X", -2_399), (2, "PAYPAL *SOMESHOP", -1_450), (3, "CONTACTLESS 4471 MARKET STALL", -650),
                                                  (5, "REFUND NORTHWIND STORE", 2_999), (6, "SQ *POP-UP BAKERY", -480)] {
                let day = calendar.date(byAdding: .day, value: -offset, to: asOf)!
                try tx(db, "Everyday Current", day, description, amount, nil, status: .pendingReview)
            }
            count("uncategorised", 5)
        }

        // MARK: Documents

        func doc(_ fileName: String, kind: DocumentKind, issuer: String, title: String, lines: [(String, String)], date: Date,
                 amount: Int?, links: [EvidenceEntity]) -> DocSpec {
            let tints: [(Double, Double, Double)] = [(0.16, 0.36, 0.62), (0.13, 0.50, 0.42), (0.55, 0.30, 0.18), (0.42, 0.26, 0.58), (0.20, 0.45, 0.55)]
            let tint = tints[abs(issuer.hashValueStable) % tints.count]
            let currency: Currency? = [.p60, .p11d, .hmrcPaymentProof].contains(kind) ? .gbp : (amount == nil ? nil : .eur)
            return DocSpec(fileName: fileName, page: DemoPDF.Page(issuer: issuer, title: title, lines: lines, tint: tint),
                           metadata: EvidenceMetadata(kind: kind, docDate: date, amountMinorUnits: amount, currency: currency,
                                                      canonicalName: fileName.replacingOccurrences(of: ".pdf", with: ""),
                                                      textStatus: .text,
                                                      extractedText: ([issuer, title] + lines.map { "\($0.0) \($0.1)" }).joined(separator: "\n")),
                           links: links)
        }

        /// Generates and adds every document (outside a write: the library writes itself).
        func addDocuments(library: EvidenceLibrary, scratch: URL) throws -> [Int64] {
            var ids: [Int64] = []
            for (index, spec) in docs.enumerated() {
                let url = scratch.appendingPathComponent("\(index)-\(spec.fileName)")
                try DemoPDF.write(spec.page, to: url)
                // Named after the spec (the scratch prefix keeps the files apart).
                let named = scratch.appendingPathComponent(spec.fileName)
                try? FileManager.default.removeItem(at: named)
                try FileManager.default.moveItem(at: url, to: named)
                let result = try library.add(named, metadata: spec.metadata, now: asOf)
                try? FileManager.default.removeItem(at: named)
                ids.append(result.document.id!)
            }
            count("documents", ids.count)
            return ids
        }

        func linkDocuments(_ db: Database, added: [Int64]) throws {
            for (spec, documentId) in zip(docs, added) {
                for entity in spec.links {
                    _ = try EvidenceLinks.link(db: db, documentId: documentId, to: entity)
                    count("document links")
                }
                if let invoiceId = spec.invoiceId, var invoice = try UtilityInvoice.fetchOne(db, key: invoiceId) {
                    invoice.documentId = documentId
                    try Recharges.saveInvoice(db: db, &invoice)
                }
            }
            // A couple of unfiled scans.
            report.notes.append("Unlinked documents: \(try EvidenceLinks.unlinkedDocuments(db: db).count)")
        }
    }

    static func monthName(_ month: Int) -> String {
        ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"][month - 1]
    }

    static func short(_ day: Date) -> String {
        let (year, month) = MonthRange.components(of: day)
        return "\(calendar.component(.day, from: day)) \(monthName(month).prefix(3)) \(year)"
    }
}

private extension String {
    /// A hash that's the same on every run (Swift's `hashValue` is seeded per process).
    var hashValueStable: Int {
        var hash = 5381
        for byte in utf8 { hash = (hash &* 33) &+ Int(byte) }
        return hash
    }
}
