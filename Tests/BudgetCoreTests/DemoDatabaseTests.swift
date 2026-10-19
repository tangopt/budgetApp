import XCTest
import GRDB
import PDFKit
@testable import BudgetCore
@testable import BudgetDemo

/// The synthetic demo database (`DemoDatabase`, the UI snapshot harness's data): it builds,
/// it's deterministic, and the screens' main computations run on it without the warnings that
/// mean broken data (unconfirmed tax types, unmatched rent, missing rates or shares).
final class DemoDatabaseTests: XCTestCase {
    private var manager: DatabaseManager!
    private var evidence: URL!
    private var db: DatabaseQueue { manager.dbQueue }

    override func setUpWithError() throws {
        (manager, evidence) = try Self.build()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: evidence)
    }

    private static func build() throws -> (DatabaseManager, URL) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("DemoEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: evidence)
        return (manager, evidence)
    }

    private func ids() throws -> (property: Int64, a: Int64, b: Int64) {
        try db.read { db in
            let property = try Property.filter(Column("name") == DemoDatabase.propertyName).fetchOne(db)!.id!
            let a = try Person.filter(Column("name") == DemoDatabase.personA).fetchOne(db)!.id!
            let b = try Person.filter(Column("name") == DemoDatabase.personB).fetchOne(db)!.id!
            return (property, a, b)
        }
    }

    /// The timing harness's long tenancy (`--long-tenancy`): every receipt with its PDF and
    /// its credit; the ordinary demo has none of it.
    func testLongTenancyForTiming() throws {
        XCTAssertEqual(try db.read { db in try Tenancy.filter(Column("referenceLabel") == "Tenancy L").fetchCount(db) }, 0)
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("DemoEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: evidence, longTenancyReceipts: 62)
        try manager.dbQueue.read { db in
            let tenancy = try XCTUnwrap(try Tenancy.filter(Column("referenceLabel") == "Tenancy L").fetchOne(db)?.id)
            let receipts = try Int64.fetchAll(db, sql: "SELECT id FROM rentReceipt WHERE tenancyId = ?", arguments: [tenancy])
            XCTAssertEqual(receipts.count, 62)
            let withPDF = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT entityId) FROM documentLink WHERE entityType = ? AND entityId IN (SELECT id FROM rentReceipt WHERE tenancyId = ?)
                """, arguments: [EvidenceEntityType.rentReceipt.rawValue, tenancy])
            XCTAssertEqual(withPDF, 62)
            let paid = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT rentReceiptId) FROM rentReceiptPayment WHERE rentReceiptId IN (SELECT id FROM rentReceipt WHERE tenancyId = ?)
                """, arguments: [tenancy])
            XCTAssertEqual(paid, 62)
        }
    }

    func testBuildsEveryKindOfRecord() throws {
        try db.read { db in
            XCTAssertEqual(try Account.fetchCount(db), 8)
            XCTAssertEqual(try Account.filter(Column("includeInNetWorth") == false).fetchCount(db), 1)
            XCTAssertEqual(Set(try Account.fetchAll(db).map(\.currency)), [.gbp, .eur])
            XCTAssertGreaterThan(try Transaction.fetchCount(db), 1_000)
            XCTAssertGreaterThan(try TransferLink.fetchCount(db), 100)
            XCTAssertGreaterThan(try CategoryGroup.fetchCount(db), 5)
            XCTAssertGreaterThan(try ForecastEntry.filter(Column("scenarioId") == nil).fetchCount(db), 20)
            XCTAssertEqual(try Scenario.fetchCount(db), 2)
            XCTAssertEqual(try Tenancy.fetchCount(db), 2)
            XCTAssertGreaterThan(try RentReceipt.fetchCount(db), 30)
            XCTAssertEqual(try UtilityProvider.fetchCount(db), 3)
            XCTAssertGreaterThan(try UtilityInvoice.fetchCount(db), 40)
            let statuses = Set(try RechargeStatement.fetchAll(db).map(\.status))
            XCTAssertEqual(statuses, Set(RechargeStatementStatus.allCases), "a statement in each status")
            XCTAssertGreaterThan(try EvidenceDocument.fetchCount(db), 100)
            XCTAssertGreaterThan(try DocumentLink.fetchCount(db), 150)
            XCTAssertGreaterThan(try EvidenceRequirement.fetchCount(db), 10)
            XCTAssertEqual(Set(try TaxYear.fetchAll(db).map(\.status)), [.preparing, .ready, .filed, .paid])
            XCTAssertEqual(try HMRCRate.fetchCount(db), 3)
            XCTAssertEqual(try UncategorizedTransactions.count(db: db), 5)
        }
        // Every document's file is in the library.
        let library = EvidenceLibrary(root: evidence, database: db)
        let documents = try db.read { db in try EvidenceDocument.fetchAll(db) }
        for document in documents {
            XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: document).path), document.originalFileName)
        }
        // The generated PDFs open and have a text layer (WinAnsi, euro sign included).
        let receipt = try XCTUnwrap(documents.first { $0.kind == .rentReceipt })
        let text = try XCTUnwrap(PDFDocument(url: library.fileURL(for: receipt))?.string)
        XCTAssertTrue(text.contains("Rent receipt"), text)
        XCTAssertTrue(text.contains("€1,000.00"), text)
    }

    func testAFileDatabaseIsMarkedAsTheDemo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DemoFile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("demo.sqlite").path
        let evidence = folder.appendingPathComponent("Evidence", isDirectory: true)
        try DemoDatabase.build(at: path, evidenceRoot: evidence)
        XCTAssertTrue(DemoMarker.isDemoDatabase(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent(DemoMarker.evidenceFileName).path))
        // Any other database isn't.
        let other = folder.appendingPathComponent("other.sqlite").path
        let manager = try DatabaseManager(path: other)
        try manager.migrate()
        XCTAssertFalse(DemoMarker.isDemoDatabase(atPath: other))
        XCTAssertFalse(DemoMarker.isDemoDatabase(atPath: folder.appendingPathComponent("missing.sqlite").path))
    }

    func testIsDeterministic() throws {
        let (other, otherEvidence) = try Self.build()
        defer { try? FileManager.default.removeItem(at: otherEvidence) }
        func digest(_ queue: DatabaseQueue) throws -> [String] {
            try queue.read { db in
                [
                    try String.fetchOne(db, sql: "SELECT group_concat(date || '|' || rawDescription || '|' || amountMinorUnits, ';') FROM (SELECT * FROM transaction_ ORDER BY id)") ?? "",
                    try String.fetchOne(db, sql: "SELECT group_concat(sha256, ';') FROM (SELECT sha256 FROM document ORDER BY id)") ?? "",
                    try String.fetchOne(db, sql: "SELECT group_concat(totalMinorUnits || status, ';') FROM (SELECT * FROM rechargeStatement ORDER BY id)") ?? ""
                ]
            }
        }
        XCTAssertEqual(try digest(db), try digest(other.dbQueue))
    }

    func testRentIsMatchedExceptTheLateCredit() throws {
        let (property, _, _) = try ids()
        try db.read { db in
            XCTAssertEqual(try RentReceiptMatching.unmatchedReceipts(db: db, propertyId: property).count, 0)
            let credits = try RentReceiptMatching.unmatchedCredits(db: db, propertyId: property)
            XCTAssertEqual(credits.map(\.date), [DemoDatabase.date(2026, 10, 12)], "only October 2026's rent, which has no receipt yet")
        }
    }

    func testRentalAccountsHaveNoDataWarnings() throws {
        let (property, a, b) = try ids()
        try db.read { db in
            for person in [a, b] {
                for startYear in [2024, 2025] {
                    let result = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: startYear), personId: person, propertyId: property)
                    XCTAssertEqual(result.warnings, [], "\(startYear) person \(person)")
                    XCTAssertNotNil(result.rate)
                    XCTAssertGreaterThan(result.totals.income.native, 0)
                    XCTAssertGreaterThan(result.totals.expenses.native, 0)
                    XCTAssertGreaterThan(result.totals.financeCosts.native, 0)
                    XCTAssertGreaterThan(result.totals.foreignTax.native, 0)
                }
            }
        }
    }

    func testSelfAssessmentComputes() throws {
        let (_, a, b) = try ids()
        try db.read { db in
            for (person, startYear) in [(a, 2024), (a, 2025), (b, 2025)] {
                let result = try SelfAssessment.compute(db: db, startYear: startYear, personId: person)
                // Savings income (Person A's interest) notes a box list the app doesn't have yet.
                let warnings = result.warnings.filter { !$0.contains("boxes aren't listed yet") }
                XCTAssertEqual(warnings, [], "\(startYear) person \(person)")
                XCTAssertFalse(SelfAssessmentFiling.steps(result).isEmpty)
            }
        }
    }

    func testPropertySummaryAndChecks() throws {
        let (property, _, _) = try ids()
        try db.read { db in
            let summary = try PropertyFinance.summary(db: db, propertyId: property, period: .calendarYear(2025), today: DemoDatabase.defaultAsOf)
            XCTAssertGreaterThan(summary.totals.rentReceived.native, 1_000_000)
            XCTAssertGreaterThan(summary.totals.costs.native, 0)
            XCTAssertGreaterThan(summary.outstandingLoan.native, 10_000_000)
            XCTAssertEqual(summary.depositHeld.native, 230_000)
            XCTAssertEqual(summary.months.count, 12)
            XCTAssertNotNil(summary.grossYield)
            let year = PropertyPeriod.calendarYear(2026).interval
            let checks = try PropertyChecks.run(db: db, propertyId: property, period: year, today: DemoDatabase.defaultAsOf)
            XCTAssertGreaterThan(checks.issueCount, 0, "the demo has something for Checks to show")
        }
    }

    func testMissingEvidenceHasBothSatisfiedAndMissingItems() throws {
        try db.read { db in
            let items = try MissingEvidence.items(db: db, taxYear: UKTaxYear(startYear: 2025))
            let progress = MissingEvidence.progress(items)
            XCTAssertGreaterThan(progress.satisfied, 20)
            XCTAssertLessThan(progress.satisfied, progress.total)
        }
    }

    func testTaxYearsListBothPeople() throws {
        try db.read { db in
            let rows = try TaxOverview.rows(db: db, now: DemoDatabase.defaultAsOf)
            XCTAssertEqual(Set(rows.map(\.person.name)), [DemoDatabase.personA, DemoDatabase.personB])
            XCTAssertTrue(rows.contains { $0.status == .filed })
            XCTAssertTrue(rows.contains { $0.status == .preparing })
        }
    }
}

/// The guard the snapshot harness and `MakeDemoDatabase` use: the app's data folders under any
/// home, the real home's included (`TaxRegression.isAppData`).
final class AppDataGuardTests: XCTestCase {
    func testFoldersUnderAnotherHomeAreRefused() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("FakeHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: home) }
        let app = home.appendingPathComponent("Library/Application Support/Budget", isDirectory: true)
        let container = home.appendingPathComponent("Library/Containers/com.example.budget/Data/Library/Application Support/Budget", isDirectory: true)
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        try manager.createDirectory(at: container, withIntermediateDirectories: true)
        let real = app.appendingPathComponent("budget.sqlite")
        try Data("db".utf8).write(to: real)
        let elsewhere = home.appendingPathComponent("Elsewhere", isDirectory: true)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let hardLink = elsewhere.appendingPathComponent("linked.sqlite")
        try manager.linkItem(at: real, to: hardLink)

        let folders = TaxRegression.appDataFolders(home: home)
        XCTAssertEqual(folders.count, 2, "the app folder and the container's")
        XCTAssertTrue(TaxRegression.isAppDatabase(real.path, folders: folders))
        XCTAssertTrue(TaxRegression.isAppDatabase(container.appendingPathComponent("budget.sqlite").path, folders: folders))
        XCTAssertTrue(TaxRegression.isAppDatabase(hardLink.path, folders: folders))
        XCTAssertFalse(TaxRegression.isAppDatabase(elsewhere.appendingPathComponent("demo.sqlite").path, folders: folders))
    }

    func testPathsThatDontExistYetResolveThroughLinks() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let app = root.appendingPathComponent("Library/Application Support/Budget", isDirectory: true)
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = elsewhere.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: app)
        let folders = [app]
        // A file two levels below a link to the app folder, neither level existing yet.
        XCTAssertTrue(TaxRegression.isAppDatabase(link.appendingPathComponent("sub/x.sqlite").path, folders: folders))
        XCTAssertTrue(TaxRegression.isAppDatabase(elsewhere.path + "/nothing/../link/budget.sqlite", folders: folders))
        XCTAssertFalse(TaxRegression.isAppDatabase(elsewhere.appendingPathComponent("sub/x.sqlite").path, folders: folders))
        let resolved = TaxRegression.resolvedPath(link.appendingPathComponent("sub/x.sqlite").path)
        XCTAssertEqual(resolved, TaxRegression.resolvedPath(app.path) + "/sub/x.sqlite")
    }

    func testDanglingAndChainedLinksResolve() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let app = root.appendingPathComponent("Library/Application Support/Budget", isDirectory: true)
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        // A dangling link into the app folder (its target doesn't exist yet).
        let dangling = elsewhere.appendingPathComponent("dangling")
        try manager.createSymbolicLink(atPath: dangling.path, withDestinationPath: app.appendingPathComponent("new/folder").path)
        XCTAssertTrue(TaxRegression.isAppDatabase(dangling.appendingPathComponent("x.sqlite").path, folders: [app]))
        XCTAssertEqual(TaxRegression.resolvedPath(dangling.path), TaxRegression.resolvedPath(app.path) + "/new/folder")
        // A relative link to a link.
        let first = elsewhere.appendingPathComponent("first")
        try manager.createSymbolicLink(atPath: first.path, withDestinationPath: "dangling")
        XCTAssertEqual(TaxRegression.resolvedPath(first.path + "/budget.sqlite"),
                       TaxRegression.resolvedPath(app.path) + "/new/folder/budget.sqlite")
        // A loop stops after the hop limit instead of spinning.
        let loopA = elsewhere.appendingPathComponent("loopA"), loopB = elsewhere.appendingPathComponent("loopB")
        try manager.createSymbolicLink(atPath: loopA.path, withDestinationPath: "loopB")
        try manager.createSymbolicLink(atPath: loopB.path, withDestinationPath: "loopA")
        XCTAssertFalse(TaxRegression.resolvedPath(loopA.path + "/x").isEmpty)
    }

    func testTheRealHomesFolderIsCovered() throws {
        // Paths only: nothing in the app's folder is opened.
        let home = try XCTUnwrap(TaxRegression.realHomeDirectory)
        let folders = TaxRegression.appDataFolders(home: home)
        XCTAssertEqual(folders.first?.path, home.appendingPathComponent("Library/Application Support/Budget").path)
        XCTAssertFalse(TaxRegression.isAppData(FileManager.default.temporaryDirectory.appendingPathComponent("demo.sqlite").path))
    }

    /// The Recharges panel's figures reconcile: a statement's charges add up to its total, its
    /// credits to what's linked, its outstanding to `Recharges.outstanding`; a month's
    /// statements and invoices to the chart's bars (as the tab computes them).
    func testRechargeDetailsReconcile() throws {
        let today = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("DemoEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: evidence)
        try manager.dbQueue.read { db in
            let tenancies = try Tenancy.fetchAll(db)
            var statementsChecked = 0, monthsWithBoth = 0
            for tenancy in tenancies {
                let rows = try Recharges.overview(db: db, tenancyId: tenancy.id!)
                for row in rows {
                    let detail = try RechargeDetails.statement(db: db, statementId: row.id)
                    XCTAssertEqual(detail.chargesTotal, row.statement.totalMinorUnits, "statement \(row.id)")
                    XCTAssertEqual(detail.paid, row.payments.reduce(0) { $0 + $1.amountMinorUnits })
                    if row.statement.status != .draft { XCTAssertEqual(detail.outstanding, row.outstandingMinorUnits) }
                    XCTAssertTrue(detail.charges.filter { $0.detail.invoice != nil }.allSatisfy { $0.rechargeDate != nil })
                    statementsChecked += 1
                }
                // The chart's months, as RechargesModel counts them.
                var charged: [(Date, Int)] = []
                for row in rows {
                    for detail in try Recharges.lineDetails(db: db, statementId: row.id) {
                        guard let invoice = detail.invoice else { continue }
                        charged.append((try Recharges.rechargeDate(db: db, invoice), detail.line.amountMinorUnits))
                    }
                }
                for line in try Recharges.pendingLines(db: db, tenancyId: tenancy.id!, through: today) {
                    charged.append((line.rechargeDate, line.amountMinorUnits))
                }
                for year in 2024...2026 {
                    for month in 1...12 {
                        let range = MonthRange.of(year: year, month: month)
                        let detail = try RechargeDetails.month(db: db, tenancyId: tenancy.id!, month: range.start, today: today)
                        let recharged = rows.filter { $0.statement.status != .draft && $0.statement.month >= range.start && $0.statement.month <= range.end }
                            .reduce(0) { $0 + $1.statement.totalMinorUnits }
                        let paid = charged.filter { $0.0 >= range.start && $0.0 <= range.end }.reduce(0) { $0 + $1.1 }
                        XCTAssertEqual(detail.recharged, recharged, "\(year)-\(month)")
                        XCTAssertEqual(detail.paid, paid, "\(year)-\(month)")
                        XCTAssertTrue(detail.credits.allSatisfy { $0.transaction.date >= range.start && $0.transaction.date <= range.end })
                        if detail.recharged != 0 && detail.paid != 0 { monthsWithBoth += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(statementsChecked, 20)
            XCTAssertGreaterThan(monthsWithBoth, 10)
        }
    }
}
