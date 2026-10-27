import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 8 Task 3: every iPad write goes through `DeviceWriter`. It writes as the app user bound to the
/// device's iCloud user, inside that user's Edit areas, stamped with the write's origin; a filed-year
/// question becomes an inline refusal pointing to the Mac; the iPhone stays read-only.
/// Synthetic data only: admin Person A (iCloud "_admin") owns Property A; member Person B ("_member").
final class DeviceWriterTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var ids: [String: Int64] = [:]
    private var after: Counter!

    private static let admin = "_admin"
    private static let member = "_member"

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        queue = try TestDatabase.migrated()
        after = Counter()
        ids = try queue.write { db in
            var ids: [String: Int64] = [:]
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            ids["A"] = a.id!
            ids["B"] = b.id!
            var admin = AppUser(personId: a.id!, displayName: "A", cloudKitUserRecordName: Self.admin, isAdmin: true, createdAt: Self.day(2026, 1, 1))
            try admin.insert(db)
            var member = AppUser(personId: b.id!, displayName: "B", cloudKitUserRecordName: Self.member, isAdmin: false, createdAt: Self.day(2026, 1, 1))
            try member.insert(db)
            ids["adminUser"] = admin.id!
            ids["memberUser"] = member.id!
            for start in [2023, 2024] {
                var year = TaxYear(startYear: start, personId: a.id!, status: .filed)
                try year.insert(db)
            }
            var property = Property(name: "Property A", country: "PT", currency: .gbp)
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: a.id!, shareBasisPoints: 10_000)
            ])
            var account = Account(name: "Bank A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            ids["account"] = account.id!
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Self.day(2025, 1, 1))
            try batch.insert(db)
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("repairs", "Repairs", .expense), ("legal", "Legal", .expense)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            try TaxExpenseTypeMap.set(db: db, categoryId: ids["legal"]!, expenseType: .legalFees)
            return ids
        }
    }

    // MARK: Helpers

    private func id(_ key: String) -> Int64 { ids[key]! }

    private func writer(_ viewer: PhoneViewer) -> DeviceWriter {
        let after = after!
        return DeviceWriter(db: queue, viewer: { viewer }, afterWrite: { after.bump() })
    }

    private var memberWriter: DeviceWriter { writer(.iCloudUser(recordName: Self.member)) }

    private func uuid(_ table: String, _ id: Int64) throws -> String {
        try queue.write { db in try SyncRecordStore.uuid(for: table, localId: id, db: db) }
    }

    @discardableResult
    private func transaction(_ date: Date, _ amount: Int, _ description: String, category: String) throws -> Int64 {
        try queue.write { db in
            var t = Transaction(importBatchId: id("batch"), accountId: id("account"), date: date, rawDescription: description,
                                amountMinorUnits: amount, categoryId: id(category), status: .confirmed, categorizedBy: .manual,
                                fingerprint: UUID().uuidString)
            try t.insert(db)
            return t.id!
        }
    }

    /// Synchronous reads for the async tests (the async `read` would be picked in an assertion).
    private func value<T: DatabaseValueConvertible>(_ sql: String, _ arguments: StatementArguments = []) throws -> T? {
        try queue.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    private func syncRecords() throws -> [Row] {
        try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM syncRecord ORDER BY tableName, localId") }
    }

    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    // MARK: Writes

    func testMemberWritesPropertyStampedHerWithOrigin() async throws {
        let memberUuid = try uuid("appUser", id("memberUser"))
        let propertyId = id("property")
        let renamed = try await memberWriter.write(.property, origin: .propertyMatching) { db -> String in
            try db.execute(sql: "UPDATE property SET name = 'Property A (flat)' WHERE id = ?", arguments: [propertyId])
            return "renamed"
        }
        XCTAssertEqual(renamed, "renamed")
        try await queue.read { db in
            let record = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT origin, modifiedBy FROM syncRecord WHERE tableName = 'property' AND localId = ?",
                                                        arguments: [propertyId]))
            XCTAssertEqual(record["origin"] as String?, "propertyMatching")
            XCTAssertEqual(record["modifiedBy"] as String?, memberUuid)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT name FROM property WHERE id = ?", arguments: [propertyId]), "Property A (flat)")
        }
        XCTAssertEqual(after.value, 1)
        let actor = try await memberWriter.actor()
        XCTAssertEqual(actor?.appUserUuid, memberUuid)
        XCTAssertEqual(actor?.isAdmin, false)
        let canEditProperty = await memberWriter.canEdit(.property)
        let canEditBudget = await memberWriter.canEdit(.budgetAndAccounts)
        XCTAssertTrue(canEditProperty)
        XCTAssertFalse(canEditBudget)
    }

    func testMemberBudgetWriteDenied() async throws {
        let before = try syncRecords()
        let error = await thrown {
            _ = try await self.memberWriter.write(.budgetAndAccounts) { db in
                var account = Account(name: "Synthetic new", currency: .gbp, kind: .cash, trackingMode: .imported)
                try account.insert(db)
            }
        }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .budgetAndAccounts))
        XCTAssertEqual((error as? LocalizedError)?.errorDescription, "You can't change Budget & accounts in this household.")
        XCTAssertEqual(try value("SELECT COUNT(*) FROM account") as Int?, 1)
        XCTAssertEqual(try syncRecords(), before, "nothing queued")
        XCTAssertEqual(after.value, 0)
    }

    func testUnboundDeviceRefusesNotLinkedYet() async throws {
        for viewer in [PhoneViewer.iCloudUser(recordName: nil), .iCloudUser(recordName: "_stranger")] {
            let device = writer(viewer)
            let before = try syncRecords()
            let error = await thrown {
                _ = try await device.write(.documents) { db in
                    try db.execute(sql: "UPDATE property SET name = 'Changed' WHERE id = ?", arguments: [self.id("property")])
                }
            }
            XCTAssertEqual(error as? DeviceWriteRefusal, .notLinkedYet)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Mango hasn't linked this device to you yet. Sync, then try again.")
            XCTAssertEqual(try syncRecords(), before)
            let actor = try await device.actor()
            XCTAssertNil(actor)
            let canEdit = await device.canEdit(.documents)
            XCTAssertFalse(canEdit)
        }
        XCTAssertEqual(try value("SELECT name FROM property") as String?, "Property A")
        XCTAssertEqual(after.value, 0)

        // Demo data and tests write as the admin.
        for viewer in [PhoneViewer.demoAdmin, .everyone] {
            let actor = try await writer(viewer).actor()
            XCTAssertEqual(actor?.isAdmin, true)
        }
    }

    func testThrowingBodyDoesNotCallAfterWrite() async throws {
        struct Boom: Error {}
        let error = await thrown { _ = try await self.memberWriter.write(.property) { _ in throw Boom() } }
        XCTAssertTrue(error is Boom)
        XCTAssertEqual(after.value, 0)
    }

    // MARK: Filed years

    /// Re-dating a 2024/25 repair into the open 2025/26 would raise the filed 2024/25 profit. (A 2023/24 one would
    /// also move 2024/25's payments on account: two years.)
    func testFiledYearQuestionBecomesRefusal() async throws {
        try transaction(Self.day(2024, 6, 1), 500_000, "TENANT RENT", category: "rent")
        let repair = try transaction(Self.day(2024, 11, 1), -40_000, "PLUMBER", category: "repairs")
        let before = try syncRecords()
        let moved = Self.day(2025, 8, 1)
        let error = await thrown {
            _ = try await self.memberWriter.writeCheckingFiledYears(.property, edit: "Edit transaction",
                                                                    scope: FiledYearEditCheck.Scope(transactionIds: [repair], dates: [moved])) { db in
                try db.execute(sql: "UPDATE transaction_ SET date = ? WHERE id = ?", arguments: [moved, repair])
            }
        }
        guard case .filedYear(let question)? = error as? DeviceWriteRefusal else {
            return XCTFail("expected a filed-year refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(question.years.map(\.label), ["2024/25"])
        XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                       "Not saved: this would change the filed 2024/25 return. To change it anyway, use the Mac.")
        XCTAssertEqual(try value("SELECT date FROM transaction_ WHERE id = ?", [repair]) as Date?, Self.day(2024, 11, 1), "the row unchanged")
        XCTAssertEqual(try syncRecords(), before, "nothing queued")
        XCTAssertEqual(after.value, 0)

        // An edit that moves no filed figure saves, through the same path.
        let note = try await memberWriter.writeCheckingFiledYears(.property, edit: "Edit transaction",
                                                                  scope: FiledYearEditCheck.Scope(transactionIds: [repair])) { db -> Int in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Synthetic note' WHERE id = ?", arguments: [repair])
            return db.changesCount
        }
        XCTAssertEqual(note, 1)
        XCTAssertEqual(after.value, 1)
    }

    func testFiledYearEditOutsideEditAreasIsDeniedFirst() async throws {
        let repair = try transaction(Self.day(2023, 11, 1), -40_000, "PLUMBER", category: "repairs")
        let error = await thrown {
            _ = try await self.memberWriter.writeCheckingFiledYears(.budgetAndAccounts, edit: "Edit transaction",
                                                                    scope: FiledYearEditCheck.Scope(transactionIds: [repair])) { db in
                try db.execute(sql: "UPDATE transaction_ SET note = 'x' WHERE id = ?", arguments: [repair])
            }
        }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .budgetAndAccounts))
        XCTAssertEqual(after.value, 0)
    }

    /// A legal bill dated in the filed 2024/25 year dates both payments it is linked to; unlinking the
    /// 2025/26 one would move it out of the filed year: `EvidenceLinkGuard`'s own refusal comes through.
    func testEvidenceLinkGuardRefusalPassesThrough() async throws {
        try transaction(Self.day(2024, 6, 1), 500_000, "TENANT RENT", category: "rent")
        let paidBefore = try transaction(Self.day(2025, 3, 30), -4_000, "PAG ADVOGADOS DEMO 0001", category: "legal")
        let paidAfter = try transaction(Self.day(2025, 4, 20), -3_995, "PAG ADVOGADOS DEMO 0002", category: "legal")
        let bill = try await queue.write { db -> Int64 in
            var document = EvidenceDocument(sha256: "legal", storedRelativePath: "x/legal.pdf", originalFileName: "legal.pdf", byteCount: 1,
                                            kind: .legalInvoice, docDate: Self.day(2025, 3, 30), amountMinorUnits: 7_995, currency: .gbp,
                                            addedAt: Self.day(2025, 4, 21))
            try document.insert(db)
            try EvidenceLinks.link(db: db, documentId: document.id!, to: .transaction(paidBefore))
            try EvidenceLinks.link(db: db, documentId: document.id!, to: .transaction(paidAfter))
            return document.id!
        }
        let before = try syncRecords()
        let error = await thrown {
            _ = try await self.memberWriter.write(.documents, origin: .documentLink) { db in
                try EvidenceLinkGuard.checked(db: db) { try EvidenceLinks.unlink(db: db, documentId: bill, from: .transaction(paidAfter)) }
            }
        }
        XCTAssertEqual(error as? EvidenceLinkGuard.Failure, .changesFiledYear(years: ["2024/25"]))
        XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Links not changed: this would change the filed 2024/25 return.")
        XCTAssertEqual(try value("SELECT COUNT(*) FROM documentLink") as Int?, 2)
        XCTAssertEqual(try syncRecords(), before)
        XCTAssertEqual(after.value, 0)
    }

    // MARK: Modes

    func testDecideModes() throws {
        let personA = try uuid("person", id("A"))
        try queue.read { db in
            func decide(_ recordName: String?, isMember: Bool, canWrite: Bool) throws -> SyncWriteMode {
                try DeviceWriteMode.decide(recordName: recordName, isMember: isMember, canWrite: canWrite, db: db)
            }
            // A device that may not write: read-only, the admin's too.
            XCTAssertEqual(try decide(Self.admin, isMember: false, canWrite: false), .readOnly)
            XCTAssertEqual(try decide(Self.member, isMember: true, canWrite: false), .readOnly)
            // Writers.
            XCTAssertEqual(try decide(Self.member, isMember: true, canWrite: true), .device(zones: [SyncZones.household]))
            XCTAssertEqual(try decide(Self.admin, isMember: false, canWrite: true),
                           .device(zones: [SyncZones.household, SyncZones.privateZone(personUuid: personA)]))
            // Unbound: read-only, never a default writer.
            XCTAssertEqual(try decide(nil, isMember: true, canWrite: true), .readOnly)
            XCTAssertEqual(try decide("_stranger", isMember: true, canWrite: true), .readOnly)
            XCTAssertEqual(try decide("_stranger", isMember: false, canWrite: true), .readOnly)
            // A member's device on the admin's own database never gets the admin's zones.
            XCTAssertEqual(try decide(Self.member, isMember: false, canWrite: true), .readOnly)
        }
        // A member who views everything: read-only.
        try queue.write { db in
            try MemberPermissions.ensureDefaults(appUserId: id("memberUser"), db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE appUserId = ?", arguments: [id("memberUser")])
        }
        try queue.read { db in
            XCTAssertEqual(try DeviceWriteMode.decide(recordName: Self.member, isMember: true, canWrite: true, db: db), .readOnly)
        }
        // Edit on one area only (her tax) is enough.
        try queue.write { db in
            let personB = try SyncRecordStore.uuid(for: "person", localId: id("B"), db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = 'edit' WHERE appUserId = ? AND area = ?",
                           arguments: [id("memberUser"), AccessArea.tax(personUuid: personB).storageKey])
        }
        try queue.read { db in
            XCTAssertEqual(try DeviceWriteMode.decide(recordName: Self.member, isMember: true, canWrite: true, db: db),
                           .device(zones: [SyncZones.household]))
        }
    }

    /// Step 7b: the iPhone writes as the iPad does (`canWrite: true` on both idioms). The member with Edit pushes the
    /// household; the admin the household and his own zone; a member who only views, or no bound user, reads only.
    func testDecideModesIPhone() throws {
        let personA = try uuid("person", id("A"))
        func iPhone(_ recordName: String?, isMember: Bool) throws -> SyncWriteMode {
            try queue.read { db in try DeviceWriteMode.decide(recordName: recordName, isMember: isMember, canWrite: true, db: db) }
        }
        XCTAssertEqual(try iPhone(Self.member, isMember: true), .device(zones: [SyncZones.household]), "her iPhone, Edit on Property")
        XCTAssertEqual(try iPhone(Self.admin, isMember: false),
                       .device(zones: [SyncZones.household, SyncZones.privateZone(personUuid: personA)]), "the admin's iPhone")
        XCTAssertEqual(try iPhone(nil, isMember: true), .readOnly, "unbound")
        XCTAssertEqual(try iPhone("_stranger", isMember: true), .readOnly, "unbound")
        try queue.write { db in
            try MemberPermissions.ensureDefaults(appUserId: id("memberUser"), db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE appUserId = ?", arguments: [id("memberUser")])
        }
        XCTAssertEqual(try iPhone(Self.member, isMember: true), .readOnly, "View everywhere: her iPhone only reads")
    }

    /// The mode follows a pull (Task 5): the Mac turns her Property to View, every other area already at View; once her
    /// iPad pulls it, the decided mode changes to read-only and the engine is made again. Before that pull nothing
    /// changes, and a device that may not write (`canWrite` false) never changes from read-only.
    func testModeFollowsPermissionChange() async throws {
        let h = try TwoPersonHousehold.make(memberMode: TwoPersonHousehold.memberTabletMode)
        let memberUser = try await h.adminMac.db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [h.fixture.personB])!
        }
        try await h.adminMac.db.write { db in
            try MemberPermissions.ensureDefaults(appUserId: memberUser, db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE appUserId = ?", arguments: [memberUser])
            try db.execute(sql: "UPDATE memberPermission SET level = 'edit' WHERE appUserId = ? AND area = 'property'", arguments: [memberUser])
        }
        try await h.syncAll()
        let tablet = TwoPersonHousehold.memberTabletMode
        func changed(from current: SyncWriteMode, canWrite: Bool) throws -> SyncWriteMode? {
            try h.memberDevice.db.read { db in
                try DeviceWriteMode.changed(from: current, recordName: TwoPersonHousehold.memberICloudUser, isMember: true, canWrite: canWrite, db: db)
            }
        }
        XCTAssertNil(try changed(from: tablet, canWrite: true), "Edit on Property: her iPad keeps writing")
        XCTAssertEqual(try changed(from: .readOnly, canWrite: true), tablet, "a read-only engine made before she was named starts writing")
        XCTAssertNil(try changed(from: .readOnly, canWrite: false), "a device that may not write stays read-only")

        try await h.adminMac.db.write { db in
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE appUserId = ? AND area = 'property'", arguments: [memberUser])
        }
        try await h.adminMac.engine.pushPending()
        XCTAssertNil(try changed(from: tablet, canWrite: true), "not pulled yet")
        try await h.memberDevice.engine.pull()

        XCTAssertEqual(try changed(from: tablet, canWrite: true), .readOnly, "View everywhere: her iPad stops writing")
        XCTAssertNil(try changed(from: .readOnly, canWrite: true))
        XCTAssertNil(try changed(from: .readOnly, canWrite: false), "a device that may not write stays read-only")
        let canEdit = await DeviceWriter(db: h.memberDevice.db, viewer: { .iCloudUser(recordName: TwoPersonHousehold.memberICloudUser) },
                                         afterWrite: {}).canEdit(.property)
        XCTAssertFalse(canEdit, "and offers no edit")
    }

    // MARK: Copy

    func testCopyStrings() {
        XCTAssertEqual(DeviceWriteCopy.notLinkedYet, "Mango hasn't linked this device to you yet. Sync, then try again.")
        XCTAssertEqual(DeviceWriteCopy.filedYear(years: ["2023/24"]),
                       "Not saved: this would change the filed 2023/24 return. To change it anyway, use the Mac.")
        XCTAssertEqual(DeviceWriteCopy.filedYear(years: ["2022/23", "2023/24"]),
                       "Not saved: this would change the filed 2022/23 and 2023/24 returns. To change it anyway, use the Mac.")
        XCTAssertEqual(DeviceWriteCopy.filedYear(years: ["2022/23", "2023/24", "2024/25"]),
                       "Not saved: this would change the filed 2022/23, 2023/24 and 2024/25 returns. To change it anyway, use the Mac.")
        XCTAssertEqual(DeviceWriteCopy.viewOnly(.budgetAndAccounts), "View only: you don't have Edit on Budget & accounts.")
        XCTAssertEqual(DeviceWriteCopy.viewOnly(.property), "View only: you don't have Edit on Property.")
        XCTAssertEqual(DeviceWriteRefusal.notLinkedYet.errorDescription, DeviceWriteCopy.notLinkedYet)
        let question = FiledYearEditCheck.Question(edit: "Edit transaction", years: [
            .init(startYear: 2022, isPaid: false, people: ["Person A"], lines: []),
            .init(startYear: 2023, isPaid: false, people: ["Person A"], lines: []),
        ], markYears: [2022])
        XCTAssertEqual(DeviceWriteRefusal.filedYear(question).errorDescription,
                       "Not saved: this would change the filed 2022/23 and 2023/24 returns. To change it anyway, use the Mac.")
        // The others keep their own copy.
        XCTAssertEqual(AccessDenied(area: .property).errorDescription, "You can't change Property in this household.")
        XCTAssertEqual(EvidenceLinkGuard.Failure.changesFiledYear(years: ["2022/23"]).errorDescription,
                       "Links not changed: this would change the filed 2022/23 return.")
    }
}
