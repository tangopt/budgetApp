import Foundation
import GRDB

/// Whose figures a screen shows (sharing spec 2026-10-25 §3 goal 6): the person signed in on this device. They see
/// in full their own accounts, joint accounts and accounts at Everything; the other person's accounts below
/// Everything only through their summaries, and Hidden ones not at all.
public struct SharingViewer: Equatable, Sendable {
    /// The viewer's local `person` id; nil sees everything (tools, tests, a device with no one signed in), unless
    /// `strict`.
    public var personId: Int64?
    /// A nil person sees in full only Everything and joint accounts (the iPhone before its iCloud user is named:
    /// it shows the household's data only, step 6 Task 11).
    public var strict: Bool

    public init(personId: Int64?, strict: Bool = false) {
        self.personId = personId
        self.strict = strict
    }

    /// The viewer signed in as the `appUser` with this local id; nil (or an unknown user) sees everything.
    public static func load(appUserId: Int64?, db: Database) throws -> SharingViewer {
        guard let appUserId else { return SharingViewer(personId: nil) }
        return SharingViewer(personId: try AppUser.fetchOne(db, key: appUserId)?.personId)
    }

    public func seesInFull(_ account: Account) -> Bool {
        guard personId != nil || strict else { return true }
        return account.sharingLevel == .everything || account.ownerPersonId == nil || account.ownerPersonId == personId
    }

    /// The iPhone's viewer: the person of the `appUser` whose `cloudKitUserRecordName` is `recordName` (this iPhone's
    /// iCloud user, `CloudKitAccountStatus.userRecordName`). Nobody named yet (no record name, or no such app user
    /// here before the household pull brings it): a strict nil viewer, who sees the household's data only.
    public static func forCloudKitUser(recordName: String?, db: Database) throws -> SharingViewer {
        SharingViewer(personId: try AppUser.forCloudKitUser(recordName: recordName, db: db)?.personId, strict: true)
    }

    /// Whether the account is on the viewer's screens at all: the other person's Hidden accounts aren't.
    public func shows(_ account: Account) -> Bool {
        seesInFull(account) || account.sharingLevel != .hidden
    }

    /// Whether any of `accounts` reaches the viewer only as summaries or not at all (net worth's "Includes
    /// everything you can see").
    public func seesOnlyPart(of accounts: [Account]) -> Bool {
        accounts.contains { !seesInFull($0) }
    }

    /// The level of one of the viewer's own accounts shared below Everything, for its lock badge
    /// (`SharingCopy.badge`); nil for any other account, and for a nil viewer.
    public func badgeLevel(_ account: Account) -> SharingLevel? {
        guard let personId, account.ownerPersonId == personId, account.sharingLevel < .everything else { return nil }
        return account.sharingLevel
    }
}

/// The viewer's actuals (sync spec §6.1 "How totals count"). For accounts seen in full: their transactions and
/// balance snapshots, as the local ledger holds them. For the other person's accounts below Everything: the
/// transactions of them this device holds that the household shares (§10 property money, as `SyncZoneRouter`
/// places it; rows left from before a level was lowered are ignored, the summaries stand for them), plus one
/// synthetic transaction per `accountSummaryMonth` row and one synthetic snapshot per `accountBalancePoint`.
/// Hidden accounts of the other person contribute nothing. Nothing synthetic is dated after `today`.
///
/// - Synthetic transactions (`SharedActuals.isSummary`): id `-summaryRow.id`, the row's account, category and
///   signed amount (and its GBP total, `gbpAmountMinorUnits`, which the budget's conversion uses as it is), status
///   confirmed, no description, a manual entry (so it never moves "data through"), never a
///   payday. Dated at the end of its pay month: for the calendar owner's accounts, the end of the day of their
///   balance point for that month (their close date); otherwise the end of the month in this device's calendar
///   (its own paydays and the published closes). A month that ends after `today` (the open month) is dated no
///   later than the account's `current` date below, and never before the month starts.
/// - Synthetic snapshots: id `-point.id`, dated like the rows of the same month, so a month's rows are inside its
///   balance, not added on top. The `current` point: its publish day, or the account's latest shared transaction
///   or summary if later, never after `today`.
/// - Published closes (`publishedCloses`): the closed months' balance points of the calendar owner's summarised
///   accounts (the admin's: the household's pay months are the admin's), Balance only included. The admin's
///   devices take none; a member-owned account never moves anyone's pay months.
public struct SharedActualsSource: ActualsSource {
    public let viewer: SharingViewer
    public let today: Date

    public init(viewer: SharingViewer, today: Date) {
        self.viewer = viewer
        self.today = today
    }

    public func transactions(_ db: Database) throws -> [Transaction] {
        guard let view = try SharedView(viewer: viewer, today: today, db: db) else { return try Transaction.fetchAll(db) }
        return view.kept + view.summaries
    }

    /// Every account but the other person's Hidden ones.
    public func accounts(_ db: Database) throws -> [Account] {
        try Account.fetchAll(db).filter(viewer.shows)
    }

    public func balanceSnapshots(_ db: Database) throws -> [BalanceSnapshot] {
        guard let view = try SharedView(viewer: viewer, today: today, db: db) else { return try BalanceSnapshot.fetchAll(db) }
        return view.snapshots
    }

    public func publishedCloses(_ db: Database) throws -> [Date] {
        try SharedView(viewer: viewer, today: today, db: db)?.publishedCloses ?? []
    }
}

/// The budget drill-down's lines for the other person's private accounts (sync spec §6.1): after a cell's shared
/// transactions, one line per account the viewer sees only as category totals.
public enum SharedActuals {
    public struct PrivateLine: Equatable, Identifiable, Sendable {
        /// The account's local id.
        public var id: Int64
        /// `SharingCopy.privateLine`: "Card (Name) · 7 transactions · details private".
        public var text: String
        /// In GBP, like the budget cell it sits in.
        public var amountMinorUnits: Int

        public init(id: Int64, text: String, amountMinorUnits: Int) {
            self.id = id
            self.text = text
            self.amountMinorUnits = amountMinorUnits
        }
    }

    /// One line per summarised account with totals in `categoryIds` dated (as `SharedActualsSource` dates them at
    /// `today`) from `from` to `to`, both included: the signed sums of its rows (a transfer's correction rows count
    /// negative; the count shown never goes below zero). In the accounts' display order; none when both sums are zero.
    public static func privateLines(categoryIds: Set<Int64>, from: Date, to: Date, viewer: SharingViewer, today: Date, db: Database) throws -> [PrivateLine] {
        guard let view = try SharedView(viewer: viewer, today: today, db: db) else { return [] }
        var sums: [Int64: (amount: Int, count: Int)] = [:]
        for (transaction, count) in zip(view.summaries, view.counts) {
            guard let category = transaction.categoryId, categoryIds.contains(category), transaction.date >= from, transaction.date <= to else { continue }
            sums[transaction.accountId, default: (0, 0)].amount += transaction.gbpAmountMinorUnits ?? transaction.amountMinorUnits
            sums[transaction.accountId, default: (0, 0)].count += count
        }
        let owners = try ownerNames(db: db)
        return view.accounts.sortedForDisplay().compactMap { account -> PrivateLine? in
            guard let id = account.id, let sum = sums[id], sum.amount != 0 || sum.count != 0 else { return nil }
            let owner = account.ownerPersonId.flatMap { owners[$0] } ?? ""
            return PrivateLine(id: id, text: SharingCopy.privateLine(account: account.displayName, owner: owner, count: max(sum.count, 0)),
                               amountMinorUnits: sum.amount)
        }
    }

    /// A synthetic transaction standing for a summary row (`SharedActualsSource`), not a real one.
    public static func isSummary(_ t: Transaction) -> Bool {
        (t.id ?? 0) < 0
    }

    /// A synthetic snapshot standing for a balance point (`SharedActualsSource`), not a real one.
    public static func isSummary(_ s: BalanceSnapshot) -> Bool {
        (s.id ?? 0) < 0
    }

    /// Each person's name as the app shows it: their app user's display name, else the person's name.
    private static func ownerNames(db: Database) throws -> [Int64: String] {
        var names: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, name FROM person") { names[row["id"]] = row["name"] }
        for user in try AppUser.fetchAll(db) { names[user.personId] = user.displayName }
        return names
    }
}

/// What the viewer reads, worked out once: nil when they see every account in full (then the local ledger is it).
private struct SharedView {
    var accounts: [Account]
    /// Transactions of accounts seen in full, and the shared ones of summarised accounts.
    var kept: [Transaction]
    /// One per summary row, in row order, with `counts` its `transactionCount`.
    var summaries: [Transaction] = []
    var counts: [Int] = []
    var snapshots: [BalanceSnapshot]
    var publishedCloses: [Date] = []

    init?(viewer: SharingViewer, today: Date, db: Database) throws {
        guard viewer.personId != nil || viewer.strict else { return nil }
        let personId = viewer.personId
        accounts = try Account.fetchAll(db)
        var summarised: Set<Int64> = [], hidden: Set<Int64> = []
        for account in accounts where !viewer.seesInFull(account) {
            if account.sharingLevel == .hidden { hidden.insert(account.id!) } else { summarised.insert(account.id!) }
        }
        guard !summarised.isEmpty || !hidden.isEmpty else { return nil }

        let all = try Transaction.fetchAll(db)
        let router = summarised.isEmpty ? nil : try? SyncZoneRouter(db: db)
        kept = all.filter { transaction in
            if hidden.contains(transaction.accountId) { return false }
            guard summarised.contains(transaction.accountId), let id = transaction.id else { return true }
            return (try? router?.assignment(table: Transaction.databaseTableName, localId: id).isPrivate) == false
        }
        snapshots = try BalanceSnapshot.fetchAll(db).filter { !hidden.contains($0.accountId) && !summarised.contains($0.accountId) }
        guard !summarised.isEmpty else { return }

        let ids = Array(summarised)
        let points = try AccountBalancePoint.filter(ids.contains(Column("accountId"))).order(Column("id")).fetchAll(db)
        let rows = try AccountSummaryMonth.filter(ids.contains(Column("accountId"))).order(Column("id")).fetchAll(db)

        // The household's pay months are the calendar owner's (the admin's): their summarised accounts' closes.
        let owner = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in account.id.map { ($0, account.ownerPersonId) } })
        let calendarOwner = try AppUser.filter(Column("isAdmin") == true).fetchOne(db)?.personId
        var closes: [String: Date] = [:]
        if let calendarOwner, calendarOwner != personId {
            for point in points where point.payMonth != AccountBalancePoint.currentPayMonth && owner[point.accountId] == calendarOwner {
                closes[point.payMonth] = max(closes[point.payMonth] ?? point.date, point.date)
            }
        }
        publishedCloses = Array(Set(closes.values)).sorted()
        let calendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: kept, categories: try Category.fetchAll(db),
                                                                         publishedCloses: publishedCloses),
                                   manualCloses: try PayMonthClose.fetchAll(db), today: today)

        /// Where month `key` of `account` ends, and where it starts in this device's calendar.
        func month(_ key: String, account: Int64) -> (start: Date, end: Date)? {
            guard let month = Self.payMonth(key) else { return nil }
            let range = calendar.range(of: month)
            if owner[account] == calendarOwner, let close = closes[key] { return (range.start, Self.endOfDay(close)) }
            return range
        }

        // Months that have ended by `today` take their end; the account's base is the latest of those, its shared
        // transactions and its publish day, never after `today`.
        var base: [Int64: Date] = [:]
        func raise(_ account: Int64, _ date: Date) { base[account] = max(base[account] ?? date, date) }
        var rowDates: [Date?] = rows.map { row in
            guard let end = month(row.payMonth, account: row.accountId)?.end, end <= today else { return nil }
            raise(row.accountId, end)
            return end
        }
        var pointDates: [Date?] = points.map { point in
            if point.payMonth == AccountBalancePoint.currentPayMonth {
                raise(point.accountId, min(point.date, today))
                return nil
            }
            guard let end = month(point.payMonth, account: point.accountId)?.end, end <= today else { return nil }
            raise(point.accountId, end)
            return end
        }
        for transaction in kept where summarised.contains(transaction.accountId) { raise(transaction.accountId, min(transaction.date, today)) }

        // Months still running: at the account's base, inside the month.
        var current = base
        func running(_ key: String, account: Int64) -> Date? {
            guard let range = month(key, account: account) else { return nil }
            let date = max(range.start, min(range.end, base[account] ?? range.start, today))
            current[account] = max(current[account] ?? date, date)
            return date
        }
        for (index, row) in rows.enumerated() where rowDates[index] == nil { rowDates[index] = running(row.payMonth, account: row.accountId) }
        for (index, point) in points.enumerated() where pointDates[index] == nil && point.payMonth != AccountBalancePoint.currentPayMonth {
            pointDates[index] = running(point.payMonth, account: point.accountId)
        }

        for (row, date) in zip(rows, rowDates) {
            guard let date else { continue }
            var summary = Transaction(id: -(row.id ?? 0), importBatchId: 0, accountId: row.accountId, date: date, rawDescription: "",
                                      amountMinorUnits: row.amountMinorUnits, categoryId: row.categoryId, status: .confirmed,
                                      categorizedBy: .manual, fingerprint: "summary-\(row.id ?? 0)", isManual: true)
            summary.gbpAmountMinorUnits = row.gbpAmountMinorUnits
            summaries.append(summary)
            counts.append(row.transactionCount)
        }
        for (point, date) in zip(points, pointDates) {
            guard let date = point.payMonth == AccountBalancePoint.currentPayMonth ? current[point.accountId] : date else { continue }
            snapshots.append(BalanceSnapshot(id: -(point.id ?? 0), accountId: point.accountId, date: date, balanceMinorUnits: point.balanceMinorUnits, note: nil))
        }
    }

    private static func endOfDay(_ date: Date) -> Date {
        PayCalendar.calendar.startOfDay(for: date).addingTimeInterval(86_400 - 1)
    }

    private static func payMonth(_ key: String) -> PayMonth? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        return PayMonth(year: year, month: month)
    }
}

extension AppUser {
    /// The app user signed in with the iCloud user `recordName`; nil for nil or none here.
    static func forCloudKitUser(recordName: String?, db: Database) throws -> AppUser? {
        guard let recordName, !recordName.isEmpty else { return nil }
        return try AppUser.filter(Column("cloudKitUserRecordName") == recordName).fetchOne(db)
    }
}

extension SyncViewer {
    /// The iPhone engine's viewer (step 6 Task 11): the private zone of the person the iCloud user `recordName` is
    /// (`SharingViewer.forCloudKitUser`), once the household pull has brought that app user and person; `.none`
    /// (household only) until then. Reads only.
    public static func forCloudKitUser(recordName: String?, db: Database) throws -> SyncViewer {
        guard let personId = try AppUser.forCloudKitUser(recordName: recordName, db: db)?.personId,
              let uuid = try SyncRecordStore.existingUUID(table: "person", localId: personId, db: db) else { return .none }
        return SyncViewer(personUuid: uuid)
    }
}

/// Whose figures the iPhone's screens show (step 6 Task 11), resolved against the database at each read, so a
/// household pull that names the viewer changes what the next read shows.
public enum PhoneViewer: Equatable, Sendable {
    /// Every account in full: tests and tools (a nil, non-strict `SharingViewer`).
    case everyone
    /// Demo data ("Try with demo data", the snapshot harness): the demo's admin, as the Mac's demo shows it.
    case demoAdmin
    /// The phone's own database: this iPhone's iCloud user (`SharingViewer.forCloudKitUser`); nil before it is read.
    case iCloudUser(recordName: String?)

    public func resolve(db: Database) throws -> SharingViewer {
        switch self {
        case .everyone:
            return SharingViewer(personId: nil)
        case .demoAdmin:
            return SharingViewer(personId: try AppUser.filter(Column("isAdmin") == true).order(Column("id")).fetchOne(db)?.personId, strict: true)
        case .iCloudUser(let recordName):
            return try SharingViewer.forCloudKitUser(recordName: recordName, db: db)
        }
    }

    /// The viewer's actuals at `today` (`DashboardInput.load(db:today:actuals:)`).
    public func actuals(db: Database, today: Date) throws -> SharedActualsSource {
        SharedActualsSource(viewer: try resolve(db: db), today: today)
    }
}

