import Foundation
import GRDB

/// The last check before a save reaches the transport (sharing spec 2026-10-25 §5, anti-goal 1), so nothing
/// below Everything reaches `household`, even in a retried batch or after a routing mistake.
///
/// It is a second line of defence, independent of `SyncZoneRouter`: it never asks the router. It loads, from
/// the database, the accounts below Everything, the UUIDs of their records (transactions other than §10
/// property money, import batches and profiles, balance snapshots, forecast entries, and the import runs
/// that wrote batches on them) and their identifying details (`SyncPrivateDetails`), and refuses any household
/// payload that is one of those records or a kept (waiting) file, or whose fields contain one of those UUIDs,
/// a stub account's UUID outside `SyncZones.stubReferences`, a Hidden account's UUID, or one of those details.
/// Load it once per push (`init`), then `review` (or `check`) every save. A refused payload stops the push for
/// its zone (`Review.haltedZones`).
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
    /// Owner's zone of each account below Everything, by local id.
    private let accountZones: [Int64: String]
    /// The accounts' identifying details and where they may be quoted.
    private let details: SyncPrivateDetails
    /// Every person's private zone.
    private let privateZones: Set<String>
    /// Companion record name of each stub account, to the account's UUID.
    private let companions: [String: String]
    /// Records that were saved to the household (`syncPresence`): the only ones a household marker may name.
    private let inHousehold: Set<String>

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: [.caseInsensitive])

    /// Loads the private facts. Refuses until the admin has confirmed who owns each account, as routing does.
    public init(db: Database) throws {
        guard try SharingSetup.isConfirmed(db: db) else { throw SyncZoneRouterError.ownershipNotConfirmed }
        let people = try Row.fetchAll(db, sql: "SELECT localId, uuid FROM syncRecord WHERE tableName = 'person'")
        let personUuid = Dictionary(people.map { ($0["localId"] as Int64, $0["uuid"] as String) }, uniquingKeysWith: { a, _ in a })
        privateZones = Set(personUuid.values.map(SyncZones.privateZone(personUuid:)))
        details = try SyncPrivateDetails(db: db)

        var stubs: [String: StubAccount] = [:]
        var records: [String: String] = [:]
        var zoneOfAccount: [Int64: String] = [:]
        var hidden: Set<Int64> = []
        for row in try Row.fetchAll(db, sql: """
            SELECT a.id, a.ownerPersonId, a.sharingLevel, s.uuid
            FROM account a LEFT JOIN syncRecord s ON s.tableName = 'account' AND s.localId = a.id
            """) {
            let id: Int64 = row["id"]
            let level = (row["sharingLevel"] as String?).flatMap(SharingLevel.init(rawValue:)) ?? .hidden
            guard level != .everything else { continue }
            let zone = (row["ownerPersonId"] as Int64?).flatMap { personUuid[$0] }.map(SyncZones.privateZone(personUuid:))
            zoneOfAccount[id] = zone ?? "private"
            if level == .hidden { hidden.insert(id) }
            guard let uuid: String = row["uuid"] else { continue }
            if level == .hidden { records[uuid] = zone ?? "private" } else { stubs[uuid] = StubAccount(level: level, zone: zone) }
        }
        accountZones = zoneOfAccount

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
        companions = Dictionary(stubs.keys.map { (SyncZoneRouter.companionRecordName(accountUuid: $0), $0) }, uniquingKeysWith: { a, _ in a })
        inHousehold = Set(try String.fetchAll(db, sql: "SELECT uuid FROM syncPresence WHERE zone = ?", arguments: [SyncZones.household]))
    }

    /// What a push does with a chunk: send it, or stop sending to the zones named (Task 5 logs each violation
    /// as a "needs attention" entry, `attentionText`, and sends nothing more to those zones this push).
    public struct Review: Equatable {
        public var violations: [Violation]
        public var isClear: Bool { violations.isEmpty }
        /// The zones whose upload stops: the zone each refused payload was going to.
        public var haltedZones: Set<String> { Set(violations.map(\.actual)) }
    }

    /// Every violation in `payloads` (none: the chunk may be sent).
    public func review(_ payloads: [SyncPayload]) -> Review {
        Review(violations: payloads.compactMap { payload in
            do {
                try check(payload)
                return nil
            } catch let violation as Violation {
                return violation
            } catch {
                return Violation(recordType: payload.recordType, recordName: payload.recordName, expected: "none",
                                 actual: payload.zone, reason: "could not be checked")
            }
        })
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
    /// - an `accountDetails` record that isn't a stub's, in its owner's zone, with its private columns only;
    /// - a move marker carrying anything but where the record went (`movedTo`, another zone of this household);
    /// - a payload carrying (a value or a clock of) a field its `omittedFields` leaves out, or leaving out a
    ///   column that doesn't sync.
    /// A household move marker is the one household payload that may name a private record, and only one that was
    /// saved to the household before (`syncPresence`): its old copy is already there, and the marker replaces it.
    public func check(_ payloads: [SyncPayload]) throws {
        for payload in payloads {
            try check(payload)
        }
    }

    private func check(_ payload: SyncPayload) throws {
        try checkPlacement(payload)
        guard payload.zone == SyncZones.household,
              let (account, field) = details.quote(in: payload.recordType, fields: payload.fields, isShared: { [stubAccounts, privateRecords] value in
                  guard case .string(let uuid) = value else { return false }
                  return stubAccounts[uuid] == nil && privateRecords[uuid] == nil
              }) else { return }
        throw Violation(recordType: payload.recordType, recordName: payload.recordName, expected: accountZones[account] ?? "private",
                        actual: payload.zone, reason: "\(field) contains an account's private details")
    }

    private func checkPlacement(_ payload: SyncPayload) throws {
        func violation(_ expected: String, _ reason: String) -> Violation {
            Violation(recordType: payload.recordType, recordName: payload.recordName, expected: expected, actual: payload.zone, reason: reason)
        }

        if payload.recordType == SyncZoneRouter.companionRecordType {
            guard let account = companions[payload.recordName], let stub = stubAccounts[account], let zone = stub.zone else {
                throw violation("none", "account details of an account that has none")
            }
            guard payload.zone == zone else { throw violation(zone, "account details outside the owner's zone") }
            if let extra = payload.fields.keys.sorted().first(where: { !SyncZoneRouter.privateAccountColumns.contains($0) }) {
                throw violation(zone, "account details carry \(extra)")
            }
            return
        }
        guard let schema = SyncSchema.table(payload.recordType) else { throw violation("none", "not a synced record type") }
        if let target = payload.movedTo {
            // A move marker names the record (its old copy is already there) and where it went; nothing else.
            guard payload.fields.isEmpty, payload.clocks.isEmpty, payload.mergedInto == nil, payload.importRunUuid == nil,
                  payload.batchGeneration == nil, payload.manifest == nil, payload.deletedReferences == nil, payload.largePayload == nil,
                  payload.documentFile == nil, payload.omittedFields == nil else {
                throw violation("none", "a move marker carrying more than where the record went")
            }
            guard payload.zone == SyncZones.household || privateZones.contains(payload.zone) else {
                throw violation("none", "not a zone of this household")
            }
            guard target != payload.zone, target == SyncZones.household || privateZones.contains(target) else {
                throw violation("none", "a move marker to a zone that isn't another of this household")
            }
            // In the household, only over a copy the household already has: a marker never names a record first.
            if payload.zone == SyncZones.household, !inHousehold.contains(payload.recordName) {
                throw violation("none", "a move marker for a record that was never in the household")
            }
            return
        }
        if let omitted = payload.omittedFields {
            let synced = Set(schema.syncedColumns)
            if let unknown = omitted.first(where: { !synced.contains($0) }) {
                throw violation("none", "leaves out \(unknown), which isn't a synced column")
            }
            if let carried = omitted.sorted().first(where: { payload.fields[$0] != nil || payload.clocks[$0] != nil }) {
                throw violation("none", "carries \(carried), which it leaves out")
            }
        }
        guard payload.zone == SyncZones.household else {
            guard privateZones.contains(payload.zone) else { throw violation("none", "not a zone of this household") }
            return
        }

        if let zone = privateRecords[payload.recordName] { throw violation(zone, "a private record") }
        if payload.recordType == "importWaitingFile" { throw violation("private", "a kept file, which is never shared") }
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
        }
    }
}

/// The identifying details of accounts below Everything (account number, IBAN, sort code) and how a record
/// quotes them. Both the router (which keeps such a record private) and the guard (which refuses it in
/// household) use it, so they agree. Details an Everything account also has (a branch's sort code) identify
/// nothing private and are left out.
///
/// - **Structured:** a whole string value, or a whole string inside JSON, equal to a detail once spaces, dashes
///   and dots are removed (sort codes are only ever matched this way).
/// - **Free text:** digit runs joined by spaces, dashes or dots are read as groups, and every run of
///   consecutive groups is compared, as one token, with the 8-or-more-digit details (account numbers, an
///   IBAN's digits after its country and check digits, such as a 20-digit BBVA number); a compact IBAN is
///   matched anywhere in the compacted text. A transaction of an Everything account (and an import change
///   recording one) may quote anything in its description and note: that is the shared account's own text.
/// Numbers (not strings) are never matched.
struct SyncPrivateDetails {
    private var structured: [String: Int64] = [:]
    private var digitTokens: [String: Int64] = [:]
    private var ibans: [String: Int64] = [:]

    private static let digitRuns = try! NSRegularExpression(pattern: "[0-9]+(?:[ .\\-][0-9]+)*")
    private static let freeTextExemptions: Set<String> = ["rawDescription", "note"]

    /// `levels`: account levels to use in place of the stored ones (a level change worked out before it is written).
    init(db: Database, levels: [Int64: SharingLevel] = [:]) throws {
        var shared: Set<String> = []
        for row in try Row.fetchAll(db, sql: "SELECT id, sharingLevel, sortCode, accountNumber, iban FROM account ORDER BY id") {
            let id: Int64 = row["id"]
            let level = levels[id] ?? (row["sharingLevel"] as String?).flatMap(SharingLevel.init(rawValue:)) ?? .hidden
            let sortCode = Self.compact(row["sortCode"] as String? ?? "")
            let number = Self.compact(row["accountNumber"] as String? ?? "")
            let iban = Self.compact(row["iban"] as String? ?? "")
            let bban = iban.count > 12 ? String(iban.dropFirst(4)) : ""
            let values = [sortCode, number, iban, bban].filter { $0.count >= 6 }
            guard level != .everything else {
                shared.formUnion(values)
                continue
            }
            for value in values { structured[value] = structured[value] ?? id }
            for value in [number, bban] where value.count >= 8 && value.allSatisfy(\.isNumber) {
                digitTokens[value] = digitTokens[value] ?? id
            }
            if iban.count >= 15 { ibans[iban] = ibans[iban] ?? id }
        }
        for value in shared {
            structured[value] = nil
            digitTokens[value] = nil
            ibans[value] = nil
        }
    }

    var isEmpty: Bool { structured.isEmpty }

    /// The account whose detail the record quotes, and the field quoting it; nil when none. `isShared` tells
    /// whether an `accountId` value (a local id or a UUID, as the fields hold them) is an Everything account.
    func quote(in table: String, fields: [String: SyncValue], isShared: (SyncValue) -> Bool) -> (account: Int64, field: String)? {
        guard !isEmpty else { return nil }
        let ownText = table == "transaction_" && isShared(fields["accountId"] ?? .null)
        let recordsSharedTransaction = table == "importChange" && fields["tableName"] == .string("transaction_")
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
            guard case .string(let text) = value else { continue }
            if let root = SyncJSONNode.parse(text), Self.isContainer(root) {
                let exempt = recordsSharedTransaction && isShared(Self.member("accountId", of: root, text: text))
                for (path, leaf) in root.stringPaths() {
                    if let account = structured[Self.compact(leaf)] { return (account, field) }
                    if exempt, Self.freeTextExemptions.contains(path) { continue }
                    if let account = freeText(leaf) { return (account, field) }
                }
            } else {
                if let account = structured[Self.compact(text)] { return (account, field) }
                if ownText, Self.freeTextExemptions.contains(field) { continue }
                if let account = freeText(text) { return (account, field) }
            }
        }
        return nil
    }

    /// `quote(…)`'s account only.
    func account(quotedIn table: String, fields: [String: SyncValue], isShared: (SyncValue) -> Bool) -> Int64? {
        quote(in: table, fields: fields, isShared: isShared)?.account
    }

    private func freeText(_ text: String) -> Int64? {
        if !ibans.isEmpty {
            let compacted = Self.compact(text)
            if let match = ibans.first(where: { compacted.contains($0.key) }) { return match.value }
        }
        guard !digitTokens.isEmpty else { return nil }
        for match in Self.digitRuns.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let groups = text[range].split(whereSeparator: { !$0.isNumber }).map(String.init)
            for start in groups.indices {
                var token = ""
                for group in groups[start...] {
                    token += group
                    if token.count > 34 { break }
                    if let account = digitTokens[token] { return account }
                }
            }
        }
        return nil
    }

    /// Letters and digits only, upper-cased.
    static func compact(_ value: String) -> String {
        String(value.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func isContainer(_ node: SyncJSONNode) -> Bool {
        switch node.kind {
        case .object, .array: return true
        default: return false
        }
    }

    /// A top-level member of a JSON object as a value: a number as `.int`, a string as `.string`.
    private static func member(_ name: String, of root: SyncJSONNode, text: String) -> SyncValue {
        guard case .object(let members) = root.kind, let node = members.first(where: { $0.key == name })?.value else { return .null }
        switch node.kind {
        case .string(let value): return .string(value)
        case .number:
            return Int64(String(decoding: Array(text.utf8)[node.range], as: UTF8.self)).map(SyncValue.int) ?? .null
        default: return .null
        }
    }
}
