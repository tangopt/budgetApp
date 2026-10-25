import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 task 4: the zone router (levels, the §10 property exception, closure, documents, stubs) and the
/// household guard. Synthetic data only (`SharingFixture`, the demo).
final class SyncZoneRouterTests: XCTestCase {
    private typealias Rule = SyncZoneRouter.Rule

    /// Every synced table's routing rule. A table added to `SyncSchema` without a line here fails
    /// `testEveryTableHasARoutingRule`, so its routing is decided on purpose.
    private static let expectedRules: [String: Rule] = [
        "person": .followsReferences, "appUser": .followsReferences,
        "personSharing": .shared, "memberPermission": .shared,
        "account": .account,
        "categoryGroup": .followsReferences, "category": .followsReferences,
        "accountBalancePoint": .shared, "accountSummaryMonth": .shared,
        "importRun": .importRun, "importWaitingFile": .followsReferences, "importBatch": .accountRecord,
        "importChange": .followsReferences, "customDocumentKind": .followsReferences, "document": .document,
        "importRunFile": .followsReferences, "importProfile": .accountRecord, "importRule": .followsReferences,
        "transaction_": .accountRecord, "transferLink": .followsReferences, "rule": .followsReferences,
        "payPeriod": .followsReferences, "payMonthClose": .followsReferences, "scenario": .followsReferences,
        "forecastGroup": .followsReferences, "forecastEntry": .accountRecord,
        "plannedOccurrenceException": .followsReferences, "scenarioApplication": .followsReferences,
        "balanceSnapshot": .accountRecord, "balanceSnapshotArchive": .accountRecord,
        "exchangeRateSetting": .followsReferences, "documentLink": .followsReferences,
        "evidenceRequirement": .followsReferences, "evidenceWaiver": .followsReferences,
        "property": .followsReferences, "propertyAccount": .followsReferences, "propertyCategoryGroup": .followsReferences,
        "propertyMortgageTerms": .followsReferences, "propertyOwner": .followsReferences,
        "mortgageRateOverride": .followsReferences, "interestIndexValue": .followsReferences,
        "propertyCheckDecision": .followsReferences, "tenancy": .followsReferences, "tenancyRent": .followsReferences,
        "rentReceipt": .followsReferences, "rentReceiptPayment": .shared, "utilityProvider": .followsReferences,
        "utilityInvoice": .shared, "rechargeStatement": .followsReferences, "rechargeLine": .shared,
        "rechargePayment": .shared, "rechargeEmailTemplate": .followsReferences, "rechargeNettingRule": .followsReferences,
        "employment": .shared, "employmentIncome": .shared, "benefitInKind": .shared, "otherIncome": .shared,
        "pensionContribution": .shared, "hmrcPayment": .shared, "hmrcRate": .shared, "taxYear": .shared,
        "taxFiledBox": .shared, "taxYearSplit": .shared, "taxAttributionRule": .shared, "taxExpenseTypeMap": .shared,
        "taxManualItem": .shared, "taxPolicyReceipt": .shared, "taxNotClaimed": .shared, "taxTransactionOwner": .shared,
    ]

    private let household = SyncZones.household

    // MARK: The rule table

    func testEveryTableHasARoutingRule() throws {
        let tables = SyncSchema.tables.map(\.name)
        XCTAssertEqual(Set(Self.expectedRules.keys), Set(tables), "every synced table needs a line in expectedRules")
        for table in tables {
            XCTAssertEqual(SyncZoneRouter.rules[table], Self.expectedRules[table], table)
        }
        XCTAssertEqual(SyncZoneRouter.documentReferrers.map { "\($0.table).\($0.column)" },
                       ["importRunFile.documentId", "documentLink.documentId", "utilityInvoice.documentId", "rechargeLine.documentId"])
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            _ = try SharingFixture.build(db)
            let router = try SyncZoneRouter(db: db)
            XCTAssertThrowsError(try router.assignment(table: "syncRecord", localId: 1)) {
                XCTAssertEqual($0 as? SyncZoneRouterError, .unknownTable("syncRecord"))
            }
            XCTAssertThrowsError(try router.assignment(table: "account", localId: 9_999)) {
                XCTAssertEqual($0 as? SyncZoneRouterError, .noSuchRow(table: "account", localId: 9_999))
            }
        }
    }

    func testZoneNames() {
        XCTAssertEqual(SyncZones.household, "household")
        XCTAssertEqual(SyncRecordStore.householdZone, SyncZones.household)
        XCTAssertEqual(SyncZones.privateZone(personUuid: "abc"), "private-abc")
        XCTAssertEqual(SyncZones.personUuid(ofPrivateZone: "private-abc"), "abc")
        XCTAssertNil(SyncZones.personUuid(ofPrivateZone: "household"))
        XCTAssertNil(SyncZones.personUuid(ofPrivateZone: "private-"))
    }

    // MARK: Refusals

    func testNothingRoutesBeforeOwnershipIsConfirmed() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person A')")
            var admin = AppUser(personId: db.lastInsertedRowID, displayName: "A", isAdmin: true, createdAt: Date(timeIntervalSince1970: 0))
            try admin.insert(db)
            try AccountEditing.add(db: db, name: "Synthetic", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: Date())
            XCTAssertThrowsError(try SyncZoneRouter(db: db)) { XCTAssertEqual($0 as? SyncZoneRouterError, .ownershipNotConfirmed) }
        }
    }

    func testAnOwnerlessAccountBelowEverythingIsRefused() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            try db.execute(sql: "UPDATE account SET sharingLevel = 'balanceOnly' WHERE id = ?", arguments: [f.joint])
            let router = try SyncZoneRouter(db: db)
            XCTAssertThrowsError(try router.assignment(table: "account", localId: f.joint)) {
                XCTAssertEqual($0 as? SyncZoneRouterError, .noOwner(accountId: f.joint))
            }
            XCTAssertThrowsError(try router.assignment(table: "transaction_", localId: f.jointTransaction))
        }
    }

    func testRoutingWritesNothing() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            // Give every row an identity first: the router must not need to create one.
            try SyncRecordStore.backfill(db: db)
            let before = try Int.fetchOne(db, sql: "SELECT total_changes()")
            let router = try SyncZoneRouter(db: db)
            for table in SyncSchema.tables {
                for id in try ids(table, db) { _ = try router.assignment(table: table.name, localId: id) }
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT total_changes()"), before)
            XCTAssertEqual(try router.assignment(table: "account", localId: f.privateAccount).companion?.zone, f.privateZone)
        }
    }

    // MARK: Levels

    func testAccountsRouteByLevel() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            var router = try SyncZoneRouter(db: db)
            for account in [f.shared, f.joint, f.lisbon] {
                XCTAssertEqual(try router.assignment(table: "account", localId: account), .household)
            }
            let stub = ZoneAssignment(zone: household, omittedFields: SyncZoneRouter.privateAccountColumns,
                                      companion: .init(recordType: "accountDetails", zone: f.privateZone, fields: SyncZoneRouter.privateAccountColumns))
            XCTAssertEqual(try router.assignment(table: "account", localId: f.privateAccount), stub)
            XCTAssertEqual(try router.assignment(table: "account", localId: f.totals), stub)
            XCTAssertEqual(f.privateZone, "private-\(f.personAUuid)")

            _ = try SharingLevels.set(.hidden, accountId: f.totals, actor: f.admin, db: db)
            router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "account", localId: f.totals), ZoneAssignment(zone: f.privateZone))
        }
    }

    func testPrivateTransactionsGoPrivateAndPropertyOnesStayShared() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let router = try SyncZoneRouter(db: db)
            let privateOnly = ZoneAssignment(zone: f.privateZone)
            for transaction in [f.sharedTransaction, f.jointTransaction, f.lisbonTransaction] {
                XCTAssertEqual(try router.assignment(table: "transaction_", localId: transaction), .household)
            }
            XCTAssertEqual(try router.assignment(table: "transaction_", localId: f.privateTransaction), privateOnly)
            XCTAssertEqual(try router.assignment(table: "transaction_", localId: f.totalsTransaction), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importBatch", localId: f.privateBatch), privateOnly)

            // §10: a property-category transaction and one a tax row pins stay shared, without their batch.
            let propertyMoney = ZoneAssignment(zone: household, omittedFields: ["importBatchId"])
            XCTAssertEqual(try router.assignment(table: "transaction_", localId: f.privatePropertyTransaction), propertyMoney)
            XCTAssertEqual(try router.assignment(table: "transaction_", localId: f.privatePinnedTransaction), propertyMoney)
            XCTAssertEqual(try router.assignment(table: "rentReceiptPayment", localId: f.rentReceiptPayment), .household)
            XCTAssertEqual(try router.assignment(table: "taxTransactionOwner", localId: f.taxTransactionOwner), .household)

            // The private batch's run follows it; the other run stays shared.
            XCTAssertEqual(try router.assignment(table: "importRun", localId: f.privateRun), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importRun", localId: f.sharedRun), .household)
        }
    }

    func testPropertyMoneyOfAHiddenAccountStaysPrivateWithEverythingNamingIt() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            // Hidden is blocked by these rows in the app; set by hand, the most private answer wins.
            try db.execute(sql: "UPDATE account SET sharingLevel = 'hidden' WHERE id = ?", arguments: [f.privateAccount])
            let router = try SyncZoneRouter(db: db)
            let privateOnly = ZoneAssignment(zone: f.privateZone)
            XCTAssertEqual(try router.assignment(table: "transaction_", localId: f.privatePropertyTransaction), privateOnly)
            XCTAssertEqual(try router.assignment(table: "transaction_", localId: f.privatePinnedTransaction), privateOnly)
            XCTAssertEqual(try router.assignment(table: "rentReceiptPayment", localId: f.rentReceiptPayment), privateOnly)
            XCTAssertEqual(try router.assignment(table: "taxTransactionOwner", localId: f.taxTransactionOwner), privateOnly)
            XCTAssertEqual(try router.assignment(table: "propertyAccount", localId: 1), .household, "the Lisbon link")
        }
    }

    func testTransferBetweenPrivateAndSharedIsPrivate() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "transaction_", localId: f.transferOut), .household)
            XCTAssertEqual(try router.assignment(table: "transaction_", localId: f.transferIn), ZoneAssignment(zone: f.privateZone))
            XCTAssertEqual(try router.assignment(table: "transferLink", localId: f.transferLink), ZoneAssignment(zone: f.privateZone))
        }
    }

    func testDocumentFollowsItsLinks() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            var router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "document", localId: f.privateOnlyDocument), ZoneAssignment(zone: f.privateZone))
            XCTAssertEqual(try router.assignment(table: "document", localId: f.sharedDocument), .household, "a household referrer keeps it shared")
            let links = try Row.fetchAll(db, sql: "SELECT id, documentId, entityId FROM documentLink ORDER BY id")
            for link in links {
                let expected = link["entityId"] == f.privateTransaction ? ZoneAssignment(zone: f.privateZone) : .household
                XCTAssertEqual(try router.assignment(table: "documentLink", localId: link["id"]), expected)
            }

            // An unlinked document is shared; one linked only to a shared record too.
            try db.execute(sql: """
                INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt) VALUES (?, 'x', 'synthetic.pdf', 1, ?)
                """, arguments: [String(repeating: "3", count: 64), Date()])
            let loose = db.lastInsertedRowID
            router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "document", localId: loose), .household)

            // Raising Private to Everything brings its documents back.
            _ = try SharingLevels.set(.everything, accountId: f.privateAccount, actor: f.admin, db: db)
            router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "document", localId: f.privateOnlyDocument), .household)
        }
    }

    // MARK: Every table, every row

    func testEveryTableRoutesWithoutThrowing() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            try prepareDemo(db)
            let started = Date()
            let router = try SyncZoneRouter(db: db)
            var routed = 0
            var zones: [String: Int] = [:]
            for table in SyncSchema.tables {
                for id in try ids(table, db) {
                    zones[try router.assignment(table: table.name, localId: id).zone, default: 0] += 1
                    routed += 1
                }
            }
            let seconds = Date().timeIntervalSince(started)
            print("SyncZoneRouterTests: routed \(routed) demo records in \(String(format: "%.3f", seconds)) s")
            XCTAssertLessThan(seconds, 1)
            XCTAssertGreaterThan(routed, 1_000)
            XCTAssertEqual(zones.count, 2, "household and the admin's private zone")
        }
    }

    func testHouseholdNeverReferencesAPrivateRecord() throws {
        for demo in [false, true] {
            let queue = demo ? try TestDatabase.demo() : try TestDatabase.migrated()
            try queue.write { db in
                if demo { try prepareDemo(db) } else { _ = try SharingFixture.build(db) }
                try SyncRecordStore.backfill(db: db)
                let router = try SyncZoneRouter(db: db)
                var payloads: [SyncPayload] = []
                var household = 0
                for table in SyncSchema.tables {
                    for id in try ids(table, db) {
                        let assignment = try router.assignment(table: table.name, localId: id)
                        payloads += try routedPayloads(table.name, id, assignment, db)
                        guard assignment.zone == SyncZones.household else { continue }
                        household += 1
                        // Read the row as the router does, and resolve each reference independently of it.
                        let fields = try localFields(table, id, db).filter { !assignment.omittedFields.contains($0.key) }
                        for reference in try SyncRowReferences.list(table: table.name, fields: fields, form: .local) {
                            guard case .local(let target) = reference.key, try exists(reference.table, target, db) else { continue }
                            let zone = try router.assignment(table: reference.table, localId: target).zone
                            XCTAssertEqual(zone, SyncZones.household,
                                           "\(table.name) \(id).\(reference.column) → \(reference.table) \(target) (demo: \(demo))")
                        }
                    }
                }
                XCTAssertGreaterThan(household, 10)
                // The same, as payloads through the guard (references as UUIDs, stubs and companions).
                XCTAssertNoThrow(try SyncZoneGuard.check(payloads, router: router, db: db), "demo: \(demo)")
            }
        }
    }

    // MARK: The guard

    func testGuardRejectsAPrivateRecordInAHouseholdBatch() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let router = try SyncZoneRouter(db: db)
            let shared = try payload("transaction_", f.sharedTransaction, db)
            var leaked = try payload("transaction_", f.privateTransaction, db)
            XCTAssertEqual(leaked.zone, SyncZones.household, "syncRecord.zone is still household: the push would send it there")
            XCTAssertThrowsError(try SyncZoneGuard.check([shared, leaked], router: router, db: db)) { error in
                let violation = error as? SyncZoneGuard.Violation
                XCTAssertEqual(violation?.recordType, "transaction_")
                XCTAssertEqual(violation?.recordName, leaked.recordName)
                XCTAssertEqual(violation?.expected, f.privateZone)
                XCTAssertEqual(violation?.actual, SyncZones.household)
            }
            leaked.zone = f.privateZone
            XCTAssertNoThrow(try SyncZoneGuard.check([shared, leaked], router: router, db: db))

            // A shared record sent to a private zone is refused too.
            var misplaced = shared
            misplaced.zone = f.privateZone
            XCTAssertThrowsError(try SyncZoneGuard.check([misplaced], router: router, db: db))
            // So is a record the router can't place.
            var unknown = shared
            unknown.recordType = "syncRecord"
            XCTAssertThrowsError(try SyncZoneGuard.check([unknown], router: router, db: db))
        }
    }

    func testGuardRejectsAnOmittedFieldInAHouseholdPayload() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let router = try SyncZoneRouter(db: db)
            let full = try payload("account", f.privateAccount, db)
            XCTAssertThrowsError(try SyncZoneGuard.check([full], router: router, db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "carries sortCode, which stays private")
            }
            var stub = full
            for column in SyncZoneRouter.privateAccountColumns { stub.fields[column] = nil }
            XCTAssertNoThrow(try SyncZoneGuard.check([stub], router: router, db: db))

            // The property transaction with its private batch named.
            let property = try payload("transaction_", f.privatePropertyTransaction, db)
            XCTAssertThrowsError(try SyncZoneGuard.check([property], router: router, db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "carries importBatchId, which stays private")
            }
            var withoutBatch = property
            withoutBatch.fields["importBatchId"] = nil
            XCTAssertNoThrow(try SyncZoneGuard.check([withoutBatch], router: router, db: db))
            // ...but not with the private run's batch tag.
            withoutBatch.importRunUuid = try SyncRecordStore.uuid(for: "importRun", localId: f.privateRun, db: db)
            XCTAssertThrowsError(try SyncZoneGuard.check([withoutBatch], router: router, db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "importRunUuid references a private importRun record")
            }

            // The companion: in the owner's zone, with the private columns only.
            let accountUuid = full.recordName
            var details = SyncPayload(recordType: "accountDetails", recordName: accountUuid, zone: f.privateZone,
                                      fields: ["sortCode": full.fields["sortCode"]!])
            XCTAssertNoThrow(try SyncZoneGuard.check([details], router: router, db: db))
            details.zone = SyncZones.household
            XCTAssertThrowsError(try SyncZoneGuard.check([details], router: router, db: db))
            details.zone = f.privateZone
            details.fields["name"] = .string("x")
            XCTAssertThrowsError(try SyncZoneGuard.check([details], router: router, db: db))
            let sharedUuid = try SyncRecordStore.uuid(for: "account", localId: f.shared, db: db)
            XCTAssertThrowsError(try SyncZoneGuard.check([SyncPayload(recordType: "accountDetails", recordName: sharedUuid, zone: f.privateZone, fields: [:])],
                                                         router: router, db: db), "an Everything account has no details record")
        }
    }

    func testGuardRejectsAHouseholdReferenceToAPrivateRecord() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let router = try SyncZoneRouter(db: db)
            let privateUuid = try SyncRecordStore.uuid(for: "transaction_", localId: f.privateTransaction, db: db)

            // Foreign key: a household transfer link (its zone forced) naming the private side.
            var link = try payload("transferLink", f.transferLink, db)
            XCTAssertThrowsError(try SyncZoneGuard.check([link], router: router, db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "zone differs from its routing")
            }
            // A shared record edited to point at a private one, as a tampered or stale payload would.
            var rent = try payload("rentReceiptPayment", f.rentReceiptPayment, db)
            rent.fields["transactionId"] = .string(privateUuid)
            XCTAssertThrowsError(try SyncZoneGuard.check([rent], router: router, db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "transactionId references a private transaction_ record")
            }
            // Polymorphic: the shared document's link to the shared transaction, repointed.
            let sharedLink = try Int64.fetchOne(db, sql: "SELECT id FROM documentLink WHERE documentId = ? AND entityId = ?",
                                                arguments: [f.sharedDocument, f.sharedTransaction])!
            var documentLink = try payload("documentLink", sharedLink, db)
            documentLink.fields["entityId"] = .string(privateUuid)
            XCTAssertThrowsError(try SyncZoneGuard.check([documentLink], router: router, db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "entityId references a private transaction_ record")
            }
            // JSON: an evidence requirement naming the private-only document's transaction.
            try db.execute(sql: """
                INSERT INTO evidenceRequirement(name, scope, kinds, direction, createdAt) VALUES ('Synthetic', ?, '[]', 'any', ?)
                """, arguments: ["{\"single\":{\"entity\":{\"type\":\"transaction\",\"id\":\(f.sharedTransaction)}}}", Date()])
            let requirement = db.lastInsertedRowID
            var evidence = try payload("evidenceRequirement", requirement, db)
            XCTAssertNoThrow(try SyncZoneGuard.check([evidence], router: router, db: db))
            evidence.fields["scope"] = .string("{\"single\":{\"entity\":{\"type\":\"transaction\",\"id\":\"\(privateUuid)\"}}}")
            XCTAssertThrowsError(try SyncZoneGuard.check([evidence], router: router, db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "scope references a private transaction_ record")
            }
            // A reference to nothing this device knows is refused.
            link = try payload("rentReceiptPayment", f.rentReceiptPayment, db)
            link.fields["transactionId"] = .string(UUID().uuidString.lowercased())
            XCTAssertThrowsError(try SyncZoneGuard.check([link], router: router, db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "transactionId names an unknown transaction_ record")
            }
        }
    }

    func testGuardErrorCarriesNoValues() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let secret = "SyntheticSecretDescription-7731"
            try db.execute(sql: "UPDATE transaction_ SET rawDescription = ?, amountMinorUnits = 987654 WHERE id = ?",
                           arguments: [secret, f.privateTransaction])
            try db.execute(sql: "UPDATE account SET sortCode = '445566', accountNumber = '99887766' WHERE id = ?", arguments: [f.privateAccount])
            let router = try SyncZoneRouter(db: db)
            for leaked in [try payload("transaction_", f.privateTransaction, db), try payload("account", f.privateAccount, db)] {
                XCTAssertThrowsError(try SyncZoneGuard.check([leaked], router: router, db: db)) { error in
                    let text = String(describing: error) + String(reflecting: error) + error.localizedDescription
                    for value in [secret, "987654", "445566", "99887766"] {
                        XCTAssertFalse(text.contains(value), "the error shows \(value)")
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func ids(_ table: SyncTableSchema, _ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT \(table.localIdColumn) FROM \(table.name) ORDER BY 1")
    }

    private func exists(_ table: String, _ id: Int64, _ db: Database) throws -> Bool {
        let schema = SyncSchema.table(table)!
        return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(table) WHERE \(schema.localIdColumn) = ?)", arguments: [id]) ?? false
    }

    private func localFields(_ table: SyncTableSchema, _ id: Int64, _ db: Database) throws -> [String: SyncValue] {
        let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table.name) WHERE \(table.localIdColumn) = ?", arguments: [id])!
        var fields: [String: SyncValue] = [:]
        for column in table.syncedColumns where row.hasColumn(column) {
            fields[column] = SyncValue(row[column] as DatabaseValue, declaredType: "")
        }
        return fields
    }

    /// The row's payload as the translator makes it (zone from `syncRecord`, every field).
    private func payload(_ table: String, _ id: Int64, _ db: Database) throws -> SyncPayload {
        let uuid = try SyncRecordStore.uuid(for: table, localId: id, db: db)
        return try XCTUnwrap(SyncTranslator.outgoing(PendingChange(table: table, localId: id, uuid: uuid, kind: .update), db: db))
    }

    /// What a routed push would send for the row (as Task 5 builds it): its zone, without its omitted fields
    /// (and without a batch tag when it leaves its batch out), plus a stub's companion.
    private func routedPayloads(_ table: String, _ id: Int64, _ assignment: ZoneAssignment, _ db: Database) throws -> [SyncPayload] {
        var sent = try payload(table, id, db)
        sent.zone = assignment.zone
        for field in assignment.omittedFields { sent.fields[field] = nil }
        if assignment.omittedFields.contains("importBatchId") { sent.importRunUuid = nil }
        guard let companion = assignment.companion else { return [sent] }
        let full = try payload(table, id, db)
        let details = SyncPayload(recordType: companion.recordType, recordName: sent.recordName, zone: companion.zone,
                                  fields: full.fields.filter { companion.fields.contains($0.key) })
        return [sent, details]
    }

    /// The demo with an admin (the first person), every account owned by them at the fixture's levels in turn
    /// (property-linked ones at Everything, one joint), and ownership confirmed, by hand.
    private func prepareDemo(_ db: Database) throws {
        let personA = try Int64.fetchOne(db, sql: "SELECT id FROM person ORDER BY id LIMIT 1")!
        if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appUser WHERE isAdmin = 1") == 0 {
            var admin = AppUser(personId: personA, displayName: "A", isAdmin: true, createdAt: Date(timeIntervalSince1970: 0))
            try admin.insert(db)
        }
        let admin = try Int64.fetchOne(db, sql: "SELECT personId FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1")!
        let linked = Set(try Int64.fetchAll(db, sql: "SELECT accountId FROM propertyAccount"))
        let levels: [SharingLevel] = [.balanceOnly, .categoryTotals, .everything, .hidden]
        for (index, account) in try Int64.fetchAll(db, sql: "SELECT id FROM account ORDER BY id").enumerated() {
            let joint = index == 0
            let level = joint || linked.contains(account) ? .everything : levels[index % levels.count]
            try db.execute(sql: "UPDATE account SET ownerPersonId = ?, sharingLevel = ? WHERE id = ?",
                           arguments: [joint ? nil : admin, level.rawValue, account])
        }
        try db.execute(sql: """
            INSERT INTO personSharing(personId, taxIncomeLevel, ownershipConfirmedAt) VALUES (?, 'everything', ?)
            ON CONFLICT(personId) DO UPDATE SET ownershipConfirmedAt = excluded.ownershipConfirmedAt
            """, arguments: [admin, Date(timeIntervalSince1970: 0)])
        try SyncRecordStore.backfill(db: db)
    }
}
