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
        "importRun": .importRun, "importWaitingFile": .importWaitingFile, "importBatch": .accountRecord,
        "importChange": .importChange, "customDocumentKind": .followsReferences, "document": .document,
        "importRunFile": .importRunFile, "importProfile": .accountRecord, "importRule": .importRule,
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

            // Hidden needs the account's transfer category detached first (a blocker).
            try db.execute(sql: "UPDATE category SET transferAccountId = NULL WHERE transferAccountId = ?", arguments: [f.totals])
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
            // The most private referrer wins: linked to a private and a shared transaction, it is private, and so
            // are both its links.
            XCTAssertEqual(try router.assignment(table: "document", localId: f.sharedDocument), ZoneAssignment(zone: f.privateZone))
            let links = try Int64.fetchAll(db, sql: "SELECT id FROM documentLink ORDER BY id")
            for link in links {
                XCTAssertEqual(try router.assignment(table: "documentLink", localId: link), ZoneAssignment(zone: f.privateZone))
            }
            // A document linked to shared records only is shared.
            let shop = try addDocument(db, "4")
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'transaction', ?, ?)",
                           arguments: [shop, f.sharedTransaction, Date()])
            router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "document", localId: shop), .household)

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
                        // The closure's consistency: every reference of a household row resolves to a household record.
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
                XCTAssertNoThrow(try SyncZoneGuard.check(payloads, db: db), "demo: \(demo)")
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
            XCTAssertThrowsError(try SyncZoneGuard.check([shared, leaked], db: db)) { error in
                let violation = error as? SyncZoneGuard.Violation
                XCTAssertEqual(violation?.recordType, "transaction_")
                XCTAssertEqual(violation?.recordName, leaked.recordName)
                XCTAssertEqual(violation?.expected, f.privateZone)
                XCTAssertEqual(violation?.reason, "a private record")
                XCTAssertEqual(violation?.actual, SyncZones.household)
            }
            leaked.zone = f.privateZone
            XCTAssertNoThrow(try SyncZoneGuard.check([shared, leaked], db: db))

            // A shared record in a private zone leaks nothing: the guard leaves placement there to the router.
            var misplaced = shared
            misplaced.zone = f.privateZone
            XCTAssertNoThrow(try SyncZoneGuard.check([misplaced], db: db))
            misplaced.zone = "private-unknown"
            XCTAssertThrowsError(try SyncZoneGuard.check([misplaced], db: db), "not a zone of this household")
            // So is a record the router can't place.
            var unknown = shared
            unknown.recordType = "syncRecord"
            XCTAssertThrowsError(try SyncZoneGuard.check([unknown], db: db))
        }
    }

    func testGuardRejectsAnOmittedFieldInAHouseholdPayload() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let router = try SyncZoneRouter(db: db)
            let full = try payload("account", f.privateAccount, db)
            XCTAssertThrowsError(try SyncZoneGuard.check([full], db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "carries sortCode, which stays private")
            }
            var stub = full
            for column in SyncZoneRouter.privateAccountColumns { stub.fields[column] = nil }
            XCTAssertNoThrow(try SyncZoneGuard.check([stub], db: db))

            // The property transaction with its private batch named.
            let property = try payload("transaction_", f.privatePropertyTransaction, db)
            XCTAssertThrowsError(try SyncZoneGuard.check([property], db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "importBatchId names a private record")
            }
            var withoutBatch = property
            withoutBatch.fields["importBatchId"] = nil
            XCTAssertNoThrow(try SyncZoneGuard.check([withoutBatch], db: db))
            // ...but not with the private run's batch tag.
            withoutBatch.importRunUuid = try SyncRecordStore.uuid(for: "importRun", localId: f.privateRun, db: db)
            XCTAssertThrowsError(try SyncZoneGuard.check([withoutBatch], db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "importRunUuid names a private record")
            }

            // The companion: in the owner's zone, with the private columns only.
            let accountUuid = full.recordName
            var details = SyncPayload(recordType: "accountDetails", recordName: accountUuid, zone: f.privateZone,
                                      fields: ["sortCode": full.fields["sortCode"]!])
            XCTAssertNoThrow(try SyncZoneGuard.check([details], db: db))
            details.zone = SyncZones.household
            XCTAssertThrowsError(try SyncZoneGuard.check([details], db: db))
            details.zone = f.privateZone
            details.fields["name"] = .string("x")
            XCTAssertThrowsError(try SyncZoneGuard.check([details], db: db))
            let sharedUuid = try SyncRecordStore.uuid(for: "account", localId: f.shared, db: db)
            XCTAssertThrowsError(try SyncZoneGuard.check([SyncPayload(recordType: "accountDetails", recordName: sharedUuid, zone: f.privateZone, fields: [:])],
                                                         db: db), "an Everything account has no details record")
        }
    }

    func testGuardRejectsAHouseholdReferenceToAPrivateRecord() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let router = try SyncZoneRouter(db: db)
            let privateUuid = try SyncRecordStore.uuid(for: "transaction_", localId: f.privateTransaction, db: db)

            // Foreign key: a household transfer link (its zone forced) naming the private side.
            let link = try payload("transferLink", f.transferLink, db)
            XCTAssertThrowsError(try SyncZoneGuard.check([link], db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "inTransactionId names a private record")
            }
            // A shared record edited to point at a private one, as a tampered or stale payload would.
            var rent = try payload("rentReceiptPayment", f.rentReceiptPayment, db)
            rent.fields["transactionId"] = .string(privateUuid)
            XCTAssertThrowsError(try SyncZoneGuard.check([rent], db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "transactionId names a private record")
            }
            // Polymorphic: the shared document's link to the shared transaction, repointed.
            let sharedLink = try Int64.fetchOne(db, sql: "SELECT id FROM documentLink WHERE documentId = ? AND entityId = ?",
                                                arguments: [f.sharedDocument, f.sharedTransaction])!
            var documentLink = try payload("documentLink", sharedLink, db)
            documentLink.fields["entityId"] = .string(privateUuid)
            XCTAssertThrowsError(try SyncZoneGuard.check([documentLink], db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "entityId names a private record")
            }
            // JSON: an evidence requirement naming the private-only document's transaction.
            try db.execute(sql: """
                INSERT INTO evidenceRequirement(name, scope, kinds, direction, createdAt) VALUES ('Synthetic', ?, '[]', 'any', ?)
                """, arguments: ["{\"single\":{\"entity\":{\"type\":\"transaction\",\"id\":\(f.sharedTransaction)}}}", Date()])
            let requirement = db.lastInsertedRowID
            var evidence = try payload("evidenceRequirement", requirement, db)
            XCTAssertNoThrow(try SyncZoneGuard.check([evidence], db: db))
            evidence.fields["scope"] = .string("{\"single\":{\"entity\":{\"type\":\"transaction\",\"id\":\"\(privateUuid)\"}}}")
            XCTAssertThrowsError(try SyncZoneGuard.check([evidence], db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "scope names a private record")
            }
            // The private account itself, named where a stub may not be: a statement-account rule's action.
            var rule = rent
            rule.recordType = "importRule"
            rule.fields = ["kind": .string("statementAccount"), "matchKey": .string("csv:x"),
                           "actionJSON": .string("{\"accountId\":\"\(try SyncRecordStore.uuid(for: "account", localId: f.privateAccount, db: db))\"}")]
            XCTAssertThrowsError(try SyncZoneGuard.check([rule], db: db)) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "actionJSON names an account below Everything")
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
                XCTAssertThrowsError(try SyncZoneGuard.check([leaked], db: db)) { error in
                    let text = String(describing: error) + String(reflecting: error) + error.localizedDescription
                    for value in [secret, "987654", "445566", "99887766"] {
                        XCTAssertFalse(text.contains(value), "the error shows \(value)")
                    }
                }
            }
        }
    }

    // MARK: Fix round 1 (review probes and rulings)

    /// C-1: a run that touched an account below Everything is private, file, statement and summary included;
    /// the Everything account's batch in it stays shared without its run, and its transactions with it.
    func testAMixedRunIsPrivateAndItsSharedBatchLeavesItsRunOut() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            // The private statement filed in the shared run, alongside the Everything accounts' files.
            try db.execute(sql: "INSERT INTO importBatch(accountId, sourceFileName, importedAt, importRunId) VALUES (?, 'Private statement.pdf', ?, ?)",
                           arguments: [f.privateAccount, Date(), f.sharedRun])
            let document = try addDocument(db, "8")
            try db.execute(sql: """
                INSERT INTO importRunFile(runId, fileName, sha256, documentId, outcome, detail)
                VALUES (?, 'Private statement.pdf', 'h', ?, 'imported', 'Synthetic private: 12 transactions')
                """, arguments: [f.sharedRun, document])
            let file = db.lastInsertedRowID
            let sharedBatch = try Int64.fetchOne(db, sql: "SELECT importBatchId FROM transaction_ WHERE id = ?", arguments: [f.sharedTransaction])!
            let router = try SyncZoneRouter(db: db)
            let privateOnly = ZoneAssignment(zone: f.privateZone)
            XCTAssertEqual(try router.assignment(table: "importRun", localId: f.sharedRun), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importRunFile", localId: file), privateOnly)
            XCTAssertEqual(try router.assignment(table: "document", localId: document), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importBatch", localId: sharedBatch),
                           ZoneAssignment(zone: SyncZones.household, omittedFields: ["importRunId"]))
            XCTAssertEqual(try router.assignment(table: "transaction_", localId: f.sharedTransaction), .household)
        }
    }

    /// C-1/rule 8: in a shared run, a file that produced no batch and whose document is linked nowhere else
    /// can't be told apart: private (the admin's).
    func testARunFileThatCantBeToldApartIsPrivate() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            try db.execute(sql: "INSERT INTO importRunFile(runId, fileName, sha256, outcome, detail) VALUES (?, 'Unknown.pdf', 'h', 'skipped', 'x')",
                           arguments: [f.sharedRun])
            let loose = db.lastInsertedRowID
            // N-2: a file named like a shared batch's file proves nothing.
            try db.execute(sql: "INSERT INTO importRunFile(runId, fileName, sha256, outcome, detail) VALUES (?, 'synthetic.csv', 'h2', 'imported', 'x')",
                           arguments: [f.sharedRun])
            let sameName = db.lastInsertedRowID
            // A file whose document is placed: shared when every referrer is.
            let receipt = try addDocument(db, "c")
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'transaction', ?, ?)",
                           arguments: [receipt, f.sharedTransaction, Date()])
            try db.execute(sql: "INSERT INTO importRunFile(runId, fileName, sha256, documentId, outcome, detail) VALUES (?, 'r.pdf', 'h3', ?, 'imported', 'x')",
                           arguments: [f.sharedRun, receipt])
            let placed = db.lastInsertedRowID
            // A document only shared runs' files name: not placed.
            let unplaced = try addDocument(db, "d")
            try db.execute(sql: "INSERT INTO importRunFile(runId, fileName, sha256, documentId, outcome, detail) VALUES (?, 'u.pdf', 'h4', ?, 'imported', 'x')",
                           arguments: [f.sharedRun, unplaced])
            let unplacedFile = db.lastInsertedRowID
            let router = try SyncZoneRouter(db: db)
            let privateOnly = ZoneAssignment(zone: f.privateZone)
            XCTAssertEqual(try router.assignment(table: "importRunFile", localId: loose), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importRunFile", localId: sameName), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importRunFile", localId: placed), .household)
            XCTAssertEqual(try router.assignment(table: "document", localId: receipt), .household)
            XCTAssertEqual(try router.assignment(table: "importRunFile", localId: unplacedFile), privateOnly)
            XCTAssertEqual(try router.assignment(table: "document", localId: unplaced), privateOnly)
        }
    }

    /// N-1 (review probe R1): a letter linked to the private account and filed by an import in a shared run is
    /// private, and so is the run's file of it.
    func testALetterAboutAPrivateAccountFiledInASharedRunIsPrivate() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let letter = try addProbeLetter(db, f)
            let router = try SyncZoneRouter(db: db)
            let privateOnly = ZoneAssignment(zone: f.privateZone)
            XCTAssertEqual(try router.assignment(table: "document", localId: letter.document), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importRunFile", localId: letter.file), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importRun", localId: f.sharedRun), .household)
            var household = try payload("document", letter.document, db)
            household.zone = SyncZones.household
            XCTAssertNoThrow(try SyncZoneGuard(db: db).check([household]), "the guard can't see a document's referrers: routing must")
        }
    }

    /// N-2 (probe R2): a private statement re-imported (all duplicates) in a shared run, under a shared file's name.
    func testAStatementReimportedInASharedRunStaysPrivate() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let statement = try addProbeReimport(db, f)
            let router = try SyncZoneRouter(db: db)
            let privateOnly = ZoneAssignment(zone: f.privateZone)
            XCTAssertEqual(try router.assignment(table: "importRunFile", localId: statement.sharedRunFile), privateOnly)
            XCTAssertEqual(try router.assignment(table: "document", localId: statement.document), privateOnly)
        }
    }

    /// O-1 (probe R3): a kept file is never shared: the keeper's private zone, else the admin's.
    func testWaitingFilesAreTheKeepersPrivateFiles() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let unknown = try addProbeWaitingFile(db, "5")
            // Kept on the member's device.
            let memberUser = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [f.personB])!
            let memberUuid = try SyncRecordStore.uuid(for: "appUser", localId: memberUser, db: db)
            let memberZone = SyncZones.privateZone(personUuid: try SyncRecordStore.uuid(for: "person", localId: f.personB, db: db))
            let kept = try addProbeWaitingFile(db, "4")
            _ = try SyncRecordStore.uuid(for: "importWaitingFile", localId: kept, db: db)
            try db.execute(sql: "UPDATE importWaitingFile SET keptByAppUserId = ? WHERE id = ?", arguments: [memberUser, kept])
            // Whoever wrote it last doesn't matter (the admin, here): the keeper does.
            try db.execute(sql: "UPDATE syncRecord SET modifiedBy = ? WHERE tableName = 'importWaitingFile' AND localId = ?",
                           arguments: [try SyncRecordStore.uuid(for: "appUser", localId: f.admin.appUserId, db: db), kept])
            _ = memberUuid
            let router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "importWaitingFile", localId: unknown), ZoneAssignment(zone: f.privateZone))
            XCTAssertEqual(try router.assignment(table: "importWaitingFile", localId: kept), ZoneAssignment(zone: memberZone))
            var household = try payload("importWaitingFile", unknown, db)
            household.zone = SyncZones.household
            XCTAssertThrowsError(try SyncZoneGuard(db: db).check([household])) {
                XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "a kept file, which is never shared")
            }
        }
    }

    /// N-3: the router keeps private what the guard would refuse, and both let the shared account's own
    /// statement text and plain numbers through (probes R4, R5).
    func testRouterAndGuardAgreeOnQuotedDetails() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let probes = try addProbeQuotes(db, f)
            let router = try SyncZoneRouter(db: db)
            let guardian = try SyncZoneGuard(db: db)
            for (table, id) in [("transaction_", f.sharedTransaction), ("importChange", probes.amountChange), ("importChange", probes.descriptionChange)] {
                XCTAssertEqual(try router.assignment(table: table, localId: id), .household, "\(table) \(id)")
                var sent = try payload(table, id, db)
                sent.zone = SyncZones.household
                XCTAssertTrue(guardian.review([sent]).isClear, "\(table) \(id)")
            }
            for id in [probes.spacedRule, probes.bbvaRule, probes.sortCodeRule] {
                XCTAssertEqual(try router.assignment(table: "importRule", localId: id), ZoneAssignment(zone: f.privateZone), "rule \(id)")
                var sent = try payload("importRule", id, db)
                sent.zone = SyncZones.household
                let review = guardian.review([sent])
                XCTAssertEqual(review.violations.map(\.reason), ["matchKey contains an account's private details"])
                XCTAssertEqual(review.haltedZones, [SyncZones.household])
            }
            // A sort code in free text identifies nothing (too short to tell from other numbers).
            XCTAssertEqual(try router.assignment(table: "importRule", localId: probes.sortCodeInText), .household)
        }
    }

    /// The router's whole output, routed payloads and all, passes the guard with no refusal: the demo, and the
    /// fixture with every review probe added.
    func testTheGuardRefusesNothingTheRouterSends() throws {
        for demo in [false, true] {
            let queue = demo ? try TestDatabase.demo() : try TestDatabase.migrated()
            try queue.write { db in
                if demo {
                    try prepareDemo(db)
                } else {
                    let f = try SharingFixture.build(db)
                    _ = try addProbeLetter(db, f)
                    _ = try addProbeReimport(db, f)
                    _ = try addProbeWaitingFile(db, "5")
                    _ = try addProbeQuotes(db, f)
                }
                try SyncRecordStore.backfill(db: db)
                let router = try SyncZoneRouter(db: db)
                var payloads: [SyncPayload] = []
                for table in SyncSchema.tables {
                    for id in try ids(table, db) {
                        payloads += try routedPayloads(table.name, id, try router.assignment(table: table.name, localId: id), db)
                    }
                }
                let review = try SyncZoneGuard(db: db).review(payloads)
                XCTAssertEqual(review.violations, [], "demo: \(demo)")
            }
        }
    }

    /// C-2: references to a stub account are private outside the allowed places.
    func testRecordsNamingAPrivateAccountArePrivate() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            try db.execute(sql: """
                INSERT INTO importRule(kind, matchKey, matchLabel, actionJSON, actionLabel, createdAt)
                VALUES ('statementAccount', 'bbva:81234567', 'BBVA statement of account …4567', ?, 'Account: Synthetic private', ?)
                """, arguments: ["{\"accountId\":\(f.privateAccount)}", Date()])
            let rule = db.lastInsertedRowID
            let letter = try addDocument(db, "7")
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'account', ?, ?)",
                           arguments: [letter, f.privateAccount, Date()])
            let letterLink = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO propertyCheckDecision(propertyId, categoryId, accountId, seriesKey, lastSeenDate, decision, createdAt)
                VALUES (?, ?, ?, 'SYNTHETIC MERCHANT', ?, 'ignore', ?)
                """, arguments: [f.propertyId, f.plainCategory, f.privateAccount, Date(), Date()])
            let decision = db.lastInsertedRowID
            func summary(_ account: Int64) throws -> (point: Int64, month: Int64) {
                try db.execute(sql: "INSERT INTO accountBalancePoint(accountId, payMonth, date, balanceMinorUnits) VALUES (?, '2026-09', ?, 1)",
                               arguments: [account, Date()])
                let point = db.lastInsertedRowID
                try db.execute(sql: "INSERT INTO accountSummaryMonth(accountId, payMonth, categoryId, amountMinorUnits, transactionCount) VALUES (?, '2026-09', ?, 1, 1)",
                               arguments: [account, f.plainCategory])
                return (point, db.lastInsertedRowID)
            }
            let balanceOnly = try summary(f.privateAccount)
            let totals = try summary(f.totals)
            let transferCategory = try Int64.fetchOne(db, sql: "SELECT id FROM category WHERE transferAccountId = ?", arguments: [f.privateAccount])!
            let router = try SyncZoneRouter(db: db)
            let privateOnly = ZoneAssignment(zone: f.privateZone)
            XCTAssertEqual(try router.assignment(table: "importRule", localId: rule), privateOnly)
            XCTAssertEqual(try router.assignment(table: "documentLink", localId: letterLink), privateOnly)
            XCTAssertEqual(try router.assignment(table: "document", localId: letter), privateOnly)
            XCTAssertEqual(try router.assignment(table: "propertyCheckDecision", localId: decision), privateOnly)
            // The summaries the level allows stay shared, the others don't.
            XCTAssertEqual(try router.assignment(table: "accountBalancePoint", localId: balanceOnly.point), .household)
            XCTAssertEqual(try router.assignment(table: "accountSummaryMonth", localId: balanceOnly.month), privateOnly)
            XCTAssertEqual(try router.assignment(table: "accountBalancePoint", localId: totals.point), .household)
            XCTAssertEqual(try router.assignment(table: "accountSummaryMonth", localId: totals.month), .household)
            // Its transfer category and property-money transactions name it and stay shared.
            XCTAssertEqual(try router.assignment(table: "category", localId: transferCategory), .household)
        }
    }

    /// I-1: an import change goes with the account its recorded row names, even a row since deleted; one that
    /// names no account is the admin's.
    func testImportChangesFollowTheAccountTheyRecord() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            try SyncRecordStore.backfill(db: db)
            func change(_ run: Int64, _ table: String, _ row: Int64, _ op: String, before: String?, after: String?) throws -> Int64 {
                let seq = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM importChange") ?? 0) + 1
                try db.execute(sql: "INSERT INTO importChange(runId, seq, tableName, rowId, operation, beforeJSON, afterJSON) VALUES (?, ?, ?, ?, ?, ?, ?)",
                               arguments: [run, seq, table, row, op, before, after])
                return db.lastInsertedRowID
            }
            try db.execute(sql: "INSERT INTO importRun(confirmedAt, entryPoint, summary) VALUES (?, 'documents', 'Synthetic')", arguments: [Date()])
            let batchless = db.lastInsertedRowID
            let accountDetails = try change(batchless, "account", f.privateAccount, "update", before: "{\"id\":\(f.privateAccount)}",
                                            after: "{\"id\":\(f.privateAccount),\"statementMismatchMinorUnits\":123}")
            let shared = try change(batchless, "transaction_", f.sharedTransaction, "update", before: "{\"id\":\(f.sharedTransaction),\"accountId\":\(f.shared)}",
                                    after: "{\"id\":\(f.sharedTransaction),\"accountId\":\(f.shared),\"note\":\"x\"}")
            let unnamed = try change(batchless, "categoryGroup", 1, "insert", before: nil, after: "{\"id\":1,\"name\":\"x\"}")
            // A private transaction recorded, then deleted.
            try db.execute(sql: """
                INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, status, categorizedBy, fingerprint)
                VALUES (?, ?, ?, 'Synthetic payee', -999, 'confirmed', 'rule', 'fp-gone')
                """, arguments: [f.privateBatch, f.privateAccount, Date()])
            let gone = db.lastInsertedRowID
            let deleted = try change(f.sharedRun, "transaction_", gone, "delete",
                                     before: "{\"id\":\(gone),\"accountId\":\(f.privateAccount),\"rawDescription\":\"Synthetic payee\",\"importBatchId\":null}", after: nil)
            try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [gone])

            let router = try SyncZoneRouter(db: db)
            let privateOnly = ZoneAssignment(zone: f.privateZone)
            XCTAssertEqual(try router.assignment(table: "importChange", localId: accountDetails), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importChange", localId: deleted), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importChange", localId: unnamed), privateOnly, "the admin's")
            // The batchless run touched the private account through its change: private, and so its shared change.
            XCTAssertEqual(try router.assignment(table: "importRun", localId: batchless), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importChange", localId: shared), privateOnly)
            XCTAssertEqual(try router.assignment(table: "importRun", localId: f.sharedRun), privateOnly, "it recorded a private transaction")
        }
    }

    /// I-4: a learnt merchant link follows the account it was learnt from; unknown → the admin's.
    func testMerchantLinkRulesFollowTheirSourceAccount() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            func rule(_ key: String, _ action: LinkAction) throws -> Int64 {
                try ImportRuleStore.learn(db: db, kind: .link, key: key, matchLabel: "Synthetic", action: action, actionLabel: "Paid by", now: Date()).id!
            }
            let fromPrivate = try rule("a#transaction", LinkAction(descriptionKey: "synthetic payee", sourceAccountId: f.privateAccount))
            let fromShared = try rule("b#transaction", LinkAction(descriptionKey: "synthetic shop", sourceAccountId: f.shared))
            let unknown = try rule("c#transaction", LinkAction(descriptionKey: "synthetic old"))
            let router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "importRule", localId: fromPrivate), ZoneAssignment(zone: f.privateZone))
            XCTAssertEqual(try router.assignment(table: "importRule", localId: fromShared), .household)
            XCTAssertEqual(try router.assignment(table: "importRule", localId: unknown), ZoneAssignment(zone: f.privateZone))

            // Learning records the account of the payment it learnt from.
            let file = ImportFile(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/a.pdf"), fileName: "a.pdf", sha256: UUID().uuidString,
                                  byteCount: 1, fileExtension: "pdf", text: "Synthetic Seguros", textStatus: .glyph, usedOCR: false)
            let item = ImportItem(file: file, recognition: ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "test"),
                                  title: "x")
            let drafts = ImportLearning.drafts(for: item, resolution: .chooseLink(.transaction(f.privateTransaction)),
                                               issuer: IssuerKey(key: "synthetic-seguros", label: "Synthetic Seguros"),
                                               transactionDescriptions: [f.privateTransaction: "DEMO SEGUROS 77"],
                                               transactionAccounts: [f.privateTransaction: f.privateAccount])
            XCTAssertEqual(drafts.compactMap { ImportLearning.decode(LinkAction.self, $0.actionJSON)?.sourceAccountId }, [f.privateAccount])
        }
    }

    /// M-1/M-2: a record belonging to two people's private zones is refused, never shared.
    func testRecordsSpanningTwoPeoplesPrivateZonesAreRefused() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            _ = try SyncRecordStore.uuid(for: "person", localId: f.personB, db: db)
            // Person B's own account below Everything, set by hand (no flow makes one yet).
            let other = try AccountEditing.add(db: db, name: "Synthetic B private", currency: .gbp, kind: .cash, openingBalanceEntered: nil,
                                               asOf: Date()).id!
            try db.execute(sql: "UPDATE account SET ownerPersonId = ?, sharingLevel = 'balanceOnly' WHERE id = ?", arguments: [f.personB, other])
            try db.execute(sql: "INSERT INTO importBatch(accountId, sourceFileName, importedAt) VALUES (?, 'b.csv', ?)", arguments: [other, Date()])
            let batch = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, status, categorizedBy, fingerprint)
                VALUES (?, ?, ?, 'Synthetic', 1, 'confirmed', 'rule', 'fp-b')
                """, arguments: [batch, other, Date()])
            let theirs = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO transferLink(outTransactionId, inTransactionId, origin) VALUES (?, ?, 'auto')",
                           arguments: [f.privateTransaction, theirs])
            let link = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'transaction', ?, ?)",
                           arguments: [f.privateOnlyDocument, theirs, Date()])
            let router = try SyncZoneRouter(db: db)
            XCTAssertThrowsError(try router.assignment(table: "transferLink", localId: link)) {
                XCTAssertEqual($0 as? SyncZoneRouterError, .spansPrivateZones(table: "transferLink", localId: link))
            }
            XCTAssertThrowsError(try router.assignment(table: "document", localId: f.privateOnlyDocument)) {
                XCTAssertEqual($0 as? SyncZoneRouterError, .spansPrivateZones(table: "document", localId: f.privateOnlyDocument))
            }
        }
    }

    /// I-3: the guard catches private content by itself, whatever the router says, and never asks it.
    func testGuardFindsPrivateContentWithoutTheRouter() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            try db.execute(sql: "UPDATE account SET iban = 'ES76 0049 1234 5612 3456 7890' WHERE id = ?", arguments: [f.privateAccount])
            let guardian = try SyncZoneGuard(db: db)
            var rule = try payload("rule", try addRule(db, "synthetic"), db)
            XCTAssertNoThrow(try guardian.check([rule]))
            let refused = ["Paid from 81234567", "acct 8123 4567", "acct 81.23.45.67", "bbva:00491234561234567890",
                           "0049-1234-56-1234567890", "ES7600491234561234567890", "40-12-34"]
            let accepted = ["sort code 401234 in text", "2026-10-05 12:34", "ref 812345678", "81234567890"]
            for text in refused {
                rule.fields["matchPattern"] = .string(text)
                XCTAssertThrowsError(try guardian.check([rule]), text) {
                    XCTAssertEqual(($0 as? SyncZoneGuard.Violation)?.reason, "matchPattern contains an account's private details")
                }
            }
            for text in accepted {
                rule.fields["matchPattern"] = .string(text)
                XCTAssertNoThrow(try guardian.check([rule]), text)
            }
            // The shared account's own statement text may quote the number; another account's may not.
            var shared = try payload("transaction_", f.sharedTransaction, db)
            shared.fields["rawDescription"] = .string("TRANSFER TO 81234567")
            XCTAssertNoThrow(try guardian.check([shared]))
            // A sort code an Everything account shares identifies nothing.
            try db.execute(sql: "UPDATE account SET sortCode = '401234' WHERE id = ?", arguments: [f.shared])
            rule.fields["matchPattern"] = .string("40-12-34")
            XCTAssertNoThrow(try SyncZoneGuard(db: db).check([rule]))
            // Not before ownership is confirmed.
            try db.execute(sql: "UPDATE personSharing SET ownershipConfirmedAt = NULL")
            XCTAssertThrowsError(try SyncZoneGuard(db: db)) { XCTAssertEqual($0 as? SyncZoneRouterError, .ownershipNotConfirmed) }
        }
    }

    // MARK: Review probes (fix round 2)

    private func addRule(_ db: Database, _ pattern: String) throws -> Int64 {
        try db.execute(sql: "INSERT INTO rule(matchPattern, matchType, categoryId, priority) VALUES (?, 'contains', (SELECT MIN(id) FROM category), 0)", arguments: [pattern])
        return db.lastInsertedRowID
    }

    /// R1: a letter linked to the private account, filed by an import in the shared run.
    private func addProbeLetter(_ db: Database, _ f: SharingFixture) throws -> (document: Int64, file: Int64) {
        let document = try addDocument(db, "7")
        try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'account', ?, ?)",
                       arguments: [document, f.privateAccount, Date()])
        try db.execute(sql: """
            INSERT INTO importRunFile(runId, fileName, sha256, documentId, outcome, detail)
            VALUES (?, 'Private account letter.pdf', 'h7', ?, 'imported', 'Letter about Synthetic private')
            """, arguments: [f.sharedRun, document])
        return (document, db.lastInsertedRowID)
    }

    /// R2: a private statement imported in the private run, then again (all duplicates) in the shared run.
    private func addProbeReimport(_ db: Database, _ f: SharingFixture) throws -> (document: Int64, sharedRunFile: Int64) {
        let document = try addDocument(db, "6")
        try db.execute(sql: "INSERT INTO importRunFile(runId, fileName, sha256, documentId, outcome, detail) VALUES (?, 'synthetic.csv', 'h6', ?, 'imported', 'first')",
                       arguments: [f.privateRun, document])
        try db.execute(sql: "INSERT INTO importRunFile(runId, fileName, sha256, documentId, outcome, detail) VALUES (?, 'synthetic.csv', 'h6', ?, 'duplicate', 'again')",
                       arguments: [f.sharedRun, document])
        return (document, db.lastInsertedRowID)
    }

    /// R3: a private statement kept for later.
    private func addProbeWaitingFile(_ db: Database, _ digit: String) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO importWaitingFile(sha256, originalFileName, byteCount, storedRelativePath, reason, recognisedAs, keptAt)
            VALUES (?, 'Synthetic statement.pdf', 1, ?, 'Import discarded', 'Bank statement', ?)
            """, arguments: [String(repeating: digit, count: 64), "w/\(digit).pdf", Date()])
        return db.lastInsertedRowID
    }

    /// R4, R5: quoted details. A shared transaction quoting the private number in its own description, a change of
    /// it recording that text and an amount equal to the sort code's digits; rules quoting the number with
    /// separators, the 20-digit BBVA number and the bare sort code, and one with a sort code in free text.
    private func addProbeQuotes(_ db: Database, _ f: SharingFixture) throws
        -> (amountChange: Int64, descriptionChange: Int64, spacedRule: Int64, bbvaRule: Int64, sortCodeRule: Int64, sortCodeInText: Int64) {
        try db.execute(sql: "UPDATE account SET iban = 'ES76 0049 1234 5612 3456 7890' WHERE id = ?", arguments: [f.privateAccount])
        try db.execute(sql: "UPDATE transaction_ SET rawDescription = 'TRANSFER TO 81234567' WHERE id = ?", arguments: [f.sharedTransaction])
        func change(_ seq: Int, _ after: String) throws -> Int64 {
            try db.execute(sql: "INSERT INTO importChange(runId, seq, tableName, rowId, operation, afterJSON) VALUES (?, ?, 'transaction_', ?, 'update', ?)",
                           arguments: [f.sharedRun, seq, f.sharedTransaction, after])
            return db.lastInsertedRowID
        }
        let amount = try change(91, "{\"id\":\(f.sharedTransaction),\"accountId\":\(f.shared),\"amountMinorUnits\":401234}")
        let description = try change(92, "{\"id\":\(f.sharedTransaction),\"accountId\":\(f.shared),\"rawDescription\":\"TRANSFER TO 81234567\"}")
        func rule(_ key: String, _ label: String) throws -> Int64 {
            try db.execute(sql: "INSERT INTO importRule(kind, matchKey, matchLabel, actionJSON, actionLabel, createdAt) VALUES ('issuer', ?, ?, '{}', 'x', ?)",
                           arguments: [key, label, Date()])
            return db.lastInsertedRowID
        }
        return (amount, description, try rule("acct 8123 4567", "Synthetic"), try rule("bbva:00491234561234567890", "Synthetic"),
                try rule("40-12-34", "Synthetic"), try rule("synthetic-issuer", "Ref 40-12-34"))
    }

    // MARK: Helpers

    private func addDocument(_ db: Database, _ digit: String) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt) VALUES (?, ?, 'synthetic.pdf', 1, ?)
            """, arguments: [String(repeating: digit, count: 64), "x\(digit)", Date()])
        return db.lastInsertedRowID
    }

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
        // Task 5 strips the batch tag where the private batch or run is left out (N-5).
        if assignment.omittedFields.contains("importBatchId") || assignment.omittedFields.contains("importRunId") { sent.importRunUuid = nil }
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
