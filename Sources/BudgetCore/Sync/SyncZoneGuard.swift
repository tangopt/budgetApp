import Foundation
import GRDB

/// The last check before a save reaches the transport (sharing spec 2026-10-25 §5, anti-goal 1), so nothing
/// below Everything reaches `household`, even in a retried batch or after a routing mistake.
///
/// It is a second line of defence, independent of `SyncZoneRouter`: it never asks the router. It loads, from
/// the database, the accounts below Everything, the UUIDs of their records (transactions other than §10
/// property money, import batches and profiles, balance snapshots, forecast entries, and the import runs
/// that wrote batches on them) and their identifying strings (account number, IBAN, sort code), and refuses
/// any household payload that is one of those records or whose fields contain one of those UUIDs, a stub
/// account's UUID outside `SyncZones.stubReferences`, a Hidden account's UUID, or one of those strings.
/// Load it once per push (`init`), then `check` every save.
public struct SyncZoneGuard {
    /// What was wrong with one payload. It names the record, zones, record types and fields only, never a
    /// value.
    public struct Violation: Error, Equatable {
        public var recordType: String
        public var recordName: String
        /// Where the guard expected it: a private zone, "private", or "none" (it may go nowhere).
        public var expected: String
        /// The payload's zone.
        public var actual: String
        public var reason: String

        public init(recordType: String, recordName: String, expected: String, actual: String, reason: String) {
            self.recordType = recordType
            self.recordName = recordName
            self.expected = expected
            self.actual = actual
            self.reason = reason
        }
    }

    private struct StubAccount {
        var level: SharingLevel
        var zone: String?
    }

    /// Account UUID of each account below Everything that isn't Hidden.
    private let stubAccounts: [String: StubAccount]
    /// UUID of every private record (Hidden accounts included) to its owner's zone ("private" when it has none).
    private let privateRecords: [String: String]
    /// Account numbers, IBANs and sort codes of accounts below Everything, as stored and without separators.
    private let identifying: [String]
    /// Every person's private zone.
    private let privateZones: Set<String>

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: [.caseInsensitive])

    /// Loads the private facts. Refuses until the admin has confirmed who owns each account, as routing does.
    public init(db: Database) throws {
        guard try SharingSetup.isConfirmed(db: db) else { throw SyncZoneRouterError.ownershipNotConfirmed }
        let people = try Row.fetchAll(db, sql: "SELECT localId, uuid FROM syncRecord WHERE tableName = 'person'")
        let personUuid = Dictionary(people.map { ($0["localId"] as Int64, $0["uuid"] as String) }, uniquingKeysWith: { a, _ in a })
        privateZones = Set(personUuid.values.map(SyncZones.privateZone(personUuid:)))

        var stubs: [String: StubAccount] = [:]
        var records: [String: String] = [:]
        var zoneOfAccount: [Int64: String] = [:]
        var hidden: Set<Int64> = []
        var privateStrings: Set<String> = []
        var sharedStrings: Set<String> = []
        let detailColumns = ["sortCode", "accountNumber", "iban"]
        for row in try Row.fetchAll(db, sql: """
            SELECT a.id, a.ownerPersonId, a.sharingLevel, a.sortCode, a.accountNumber, a.iban, s.uuid
            FROM account a LEFT JOIN syncRecord s ON s.tableName = 'account' AND s.localId = a.id
            """) {
            let id: Int64 = row["id"]
            let level = (row["sharingLevel"] as String?).flatMap(SharingLevel.init(rawValue:)) ?? .hidden
            let strings = detailColumns.compactMap { row[$0] as String? }.flatMap(Self.variants)
            guard level != .everything else {
                sharedStrings.formUnion(strings)
                continue
            }
            privateStrings.formUnion(strings)
            let zone = (row["ownerPersonId"] as Int64?).flatMap { personUuid[$0] }.map(SyncZones.privateZone(personUuid:))
            zoneOfAccount[id] = zone ?? "private"
            if level == .hidden { hidden.insert(id) }
            guard let uuid: String = row["uuid"] else { continue }
            if level == .hidden { records[uuid] = zone ?? "private" } else { stubs[uuid] = StubAccount(level: level, zone: zone) }
        }
        // A detail an Everything account shares (a branch's sort code) identifies nothing private.
        identifying = privateStrings.subtracting(sharedStrings).sorted()

        if !zoneOfAccount.isEmpty {
            let accountList = zoneOfAccount.keys.map(String.init).joined(separator: ",")
            let pinned = SyncZoneRouter.pinningTables
                .map { "SELECT transactionId FROM \(SyncChangeTracker.quoted($0)) WHERE transactionId IS NOT NULL" }
                .joined(separator: " UNION ")
            let propertyMoney = """
                (COALESCE(t.categoryId IN (SELECT id FROM category WHERE groupId IN (SELECT categoryGroupId FROM propertyCategoryGroup)), 0)
                 OR t.id IN (\(pinned)))
                """
            for row in try Row.fetchAll(db, sql: """
                SELECT s.uuid, t.accountId, \(propertyMoney) AS isPropertyMoney FROM transaction_ t
                JOIN syncRecord s ON s.tableName = 'transaction_' AND s.localId = t.id
                WHERE t.accountId IN (\(accountList))
                """) {
                let account: Int64 = row["accountId"]
                if row["isPropertyMoney"] as Bool, !hidden.contains(account) { continue }
                records[row["uuid"]] = zoneOfAccount[account]
            }
            for table in ["importBatch", "importProfile", "balanceSnapshot", "balanceSnapshotArchive", "forecastEntry"] {
                for row in try Row.fetchAll(db, sql: """
                    SELECT s.uuid, r.accountId FROM \(table) r JOIN syncRecord s ON s.tableName = '\(table)' AND s.localId = r.id
                    WHERE r.accountId IN (\(accountList))
                    """) {
                    records[row["uuid"]] = zoneOfAccount[row["accountId"] as Int64]
                }
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT DISTINCT s.uuid, b.accountId FROM importBatch b JOIN syncRecord s ON s.tableName = 'importRun' AND s.localId = b.importRunId
                WHERE b.accountId IN (\(accountList))
                """) {
                records[row["uuid"]] = zoneOfAccount[row["accountId"] as Int64]
            }
        }
        stubAccounts = stubs
        privateRecords = records
    }

    /// `SyncZoneGuard(db:).check(payloads)`.
    public static func check(_ payloads: [SyncPayload], db: Database) throws {
        try SyncZoneGuard(db: db).check(payloads)
    }

    /// Throws the first `Violation`:
    /// - a household payload that is a private record, an `accountDetails` record, not a synced record type,
    ///   a stub account carrying a column it leaves out (`SyncZoneRouter.privateAccountColumns`), or whose
    ///   fields (or batch tag, redirect, deleted references) contain a private record's UUID, a stub account's
    ///   UUID outside `SyncZones.stubReferences`, or an account's private details;
    /// - a payload in a zone that is neither `household` nor a person's private zone;
    /// - an `accountDetails` record that isn't a stub's, in its owner's zone, with its private columns only.
    public func check(_ payloads: [SyncPayload]) throws {
        for payload in payloads {
            try check(payload)
        }
    }

    private func check(_ payload: SyncPayload) throws {
        func violation(_ expected: String, _ reason: String) -> Violation {
            Violation(recordType: payload.recordType, recordName: payload.recordName, expected: expected, actual: payload.zone, reason: reason)
        }

        if payload.recordType == SyncZoneRouter.companionRecordType {
            guard let stub = stubAccounts[payload.recordName], let zone = stub.zone else {
                throw violation("none", "account details of an account that has none")
            }
            guard payload.zone == zone else { throw violation(zone, "account details outside the owner's zone") }
            if let extra = payload.fields.keys.sorted().first(where: { !SyncZoneRouter.privateAccountColumns.contains($0) }) {
                throw violation(zone, "account details carry \(extra)")
            }
            return
        }
        guard SyncSchema.table(payload.recordType) != nil else { throw violation("none", "not a synced record type") }
        guard payload.zone == SyncZones.household else {
            guard privateZones.contains(payload.zone) else { throw violation("none", "not a zone of this household") }
            return
        }

        if let zone = privateRecords[payload.recordName] { throw violation(zone, "a private record") }
        if payload.recordType == "account", let stub = stubAccounts[payload.recordName],
           let carried = SyncZoneRouter.privateAccountColumns.first(where: { payload.fields[$0] != nil }) {
            throw violation(stub.zone ?? "private", "carries \(carried), which stays private")
        }

        var texts: [(field: String, text: String)] = []
        for (field, value) in payload.fields.sorted(by: { $0.key < $1.key }) {
            if case .string(let text) = value { texts.append((field, text)) }
        }
        if let run = payload.importRunUuid { texts.append(("importRunUuid", run)) }
        if let target = payload.mergedInto { texts.append(("mergedInto", target)) }
        for name in payload.deletedReferences ?? [] { texts.append(("deletedReferences", name)) }

        for (field, text) in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in Self.uuidPattern.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let uuid = text[swiftRange].lowercased()
                if let zone = privateRecords[uuid] { throw violation(zone, "\(field) names a private record") }
                if let stub = stubAccounts[uuid],
                   SyncZones.stubReferences["\(payload.recordType).\(field)"]?.contains(stub.level) != true {
                    throw violation(stub.zone ?? "private", "\(field) names an account below Everything")
                }
            }
            let upper = text.uppercased()
            if identifying.contains(where: { upper.contains($0) }) {
                throw violation("private", "\(field) contains an account's private details")
            }
        }
    }

    /// A detail as stored and without spaces or dashes, upper-cased; short ones (under 6 characters) left out.
    private static func variants(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let compact = String(trimmed.filter { $0.isLetter || $0.isNumber })
        return Array(Set([trimmed, compact].filter { $0.count >= 6 }))
    }
}
