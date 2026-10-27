import XCTest
import GRDB
import PDFKit
@testable import BudgetCore
import TestSupport

/// Step 10 Task 12: the recharge email the iPad prepares — the Mac's draft text, the statement PDF and the bills' PDFs,
/// what's missing listed (never thrown), nothing written by building it, and Mark as sent only once the person confirms,
/// through the device writer. Synthetic data: admin Person A ("_admin") owns Property A; member Person B ("_member");
/// tenancy "Room Contract AB" let to "Tenant Example".
final class RechargeEmailPackageTests: XCTestCase {
    private var manager: DatabaseManager!
    private var queue: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var ids: [String: Int64] = [:]

    private static let admin = "_admin"
    private static let member = "_member"
    private static let tenant = "Tenant Example"

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("RechargeEmailPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: queue)
        let pdf = EvidenceTestPDFs.textPDF(["Example Power", "Amount due 60,00 EUR"], name: "fatura-luz.pdf")
        let document = try library.add(pdf).document
        ids["document"] = document.id!
        ids.merge(try queue.write { db in
            var ids: [String: Int64] = [:]
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            var admin = AppUser(personId: a.id!, displayName: "A", cloudKitUserRecordName: Self.admin, isAdmin: true, createdAt: Self.day(2026, 1, 1))
            try admin.insert(db)
            var member = AppUser(personId: b.id!, displayName: "B", cloudKitUserRecordName: Self.member, isAdmin: false, createdAt: Self.day(2026, 1, 1))
            try member.insert(db)
            ids["memberUser"] = member.id!
            var property = Property(name: "Property A", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: a.id!, shareBasisPoints: 10_000)
            ])
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Room Contract AB", contractNumber: "3001",
                                  tenantName: Self.tenant, startDate: Self.day(2025, 9, 1), tenantEmail: "tenant@example.test")
            try Tenancies.save(db: db, &tenancy)
            ids["tenancy"] = tenancy.id!
            var power = UtilityProvider(propertyId: property.id!, name: "Example Power", kind: .electricity)
            try Recharges.saveProvider(db: db, &power)
            var water = UtilityProvider(propertyId: property.id!, name: "Example Water", kind: .water)
            try Recharges.saveProvider(db: db, &water)
            var powerInvoice = UtilityInvoice(providerId: power.id!, invoiceNumber: "P-1", issueDate: Self.day(2026, 9, 5),
                                              amountMinorUnits: 6_000, documentId: document.id!)
            try Recharges.saveInvoice(db: db, &powerInvoice)
            var waterInvoice = UtilityInvoice(providerId: water.id!, invoiceNumber: "W-1", issueDate: Self.day(2026, 9, 20), amountMinorUnits: 1_550)
            try Recharges.saveInvoice(db: db, &waterInvoice)
            let statement = try Recharges.draftStatement(db: db, tenancyId: tenancy.id!, month: Self.day(2026, 9, 1), addPending: false)
            try Recharges.setLine(db: db, statementId: statement.id!, invoiceId: powerInvoice.id!)
            try Recharges.setLine(db: db, statementId: statement.id!, invoiceId: waterInvoice.id!)
            ids["statement"] = statement.id!
            return ids
        }) { $1 }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func id(_ key: String) -> Int64 { ids[key]! }

    private func writer(_ recordName: String = RechargeEmailPackageTests.admin) -> DeviceWriter {
        DeviceWriter(db: queue, viewer: { .iCloudUser(recordName: recordName) }, afterWrite: {})
    }

    /// The library as the iPad has it: every document's file here, unless `absent`.
    private func emailLibrary(absent: Set<Int64> = []) -> RechargeEmailPackage.Library {
        let library = library!
        return RechargeEmailPackage.Library(folder: folder.appendingPathComponent("Email", isDirectory: true)) { document in
            absent.contains(document.id!) ? nil : library.fileURL(for: document)
        }
    }

    private func build(language: RechargeEmailLanguage = .portuguese, absent: Set<Int64> = []) throws -> RechargeEmailPackage {
        let library = emailLibrary(absent: absent)
        return try queue.read { db in try RechargeEmailPackage.build(db: db, statementId: self.id("statement"), language: language, library: library) }
    }

    private func statementNow() throws -> RechargeStatement? {
        try queue.read { db in try RechargeStatement.fetchOne(db, key: self.id("statement")) }
    }

    private func addLateCharge() throws {
        try queue.write { db in
            _ = try Recharges.saveManualLine(db: db, statementId: self.id("statement"), description: "Late charge", amountMinorUnits: 100)
        }
    }

    private func status() throws -> RechargeStatementStatus? {
        try queue.read { db in try RechargeStatement.fetchOne(db, key: self.id("statement"))?.status }
    }

    private func setMemberLevel(_ level: PermissionLevel, _ area: AccessArea) throws {
        try queue.write { db in
            try MemberPermissions.ensureDefaults(appUserId: self.id("memberUser"), db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                           arguments: [level.rawValue, self.id("memberUser"), area.storageKey])
        }
    }

    // MARK: Package

    func testPackageMatchesMacDraftSubjectAndBody() throws {
        for language in RechargeEmailLanguage.allCases {
            let draft = try queue.read { db in try RechargeEmail.draft(db: db, statementId: self.id("statement"), language: language) }
            let package = try build(language: language)
            XCTAssertEqual(package.subject, draft.subject)
            XCTAssertEqual(package.body, draft.body)
            XCTAssertEqual(package.to, ["tenant@example.test"])
        }
        let package = try build(language: .english)
        XCTAssertEqual(package.subject, "Utilities for September 2026 — Property A")
        XCTAssertTrue(package.body.contains("Total to add to the next rent transfer: €75.50"), "the lines' total: \(package.body)")
        XCTAssertTrue(package.body.contains("Electricity (Example Power) — invoice of 05/09/2026"))
    }

    func testAttachmentsAreStatementPlusBillPDFs() throws {
        let package = try build()
        XCTAssertEqual(package.attachments.map(\.fileName), ["Extrato de despesas - setembro de 2026.pdf", "fatura-luz.pdf"])
        for attachment in package.attachments {
            XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.url.path), attachment.fileName)
            XCTAssertEqual(attachment.url.lastPathComponent, attachment.fileName)
        }
        let statement = try XCTUnwrap(PDFDocument(url: package.attachments[0].url)?.string)
        XCTAssertTrue(statement.contains("Property A"))
        XCTAssertTrue(statement.contains("Example Power"))
        XCTAssertTrue(statement.contains("Example Water"))
        XCTAssertTrue(statement.contains("75,50"), "the total in Portuguese: \(statement)")
        let english = try build(language: .english)
        XCTAssertEqual(english.attachments.first?.fileName, "Utilities statement - September 2026.pdf")
        XCTAssertEqual(try Data(contentsOf: package.attachments[1].url),
                       try Data(contentsOf: library.fileURL(for: try queue.read { db in try EvidenceDocument.fetchOne(db, key: self.id("document"))! })))
        XCTAssertTrue(package.isReady)
    }

    func testMissingPDFAndNoRecipientListedNotThrown() throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE tenancy SET tenantEmail = NULL WHERE id = ?", arguments: [self.id("tenancy")])
        }
        let package = try build(language: .english)
        XCTAssertEqual(package.to, [])
        XCTAssertEqual(package.missing, [RechargeEmailPackage.noRecipient,
                                         RechargeEmailPackage.noPDF("Water (Example Water) invoice of 20/09/2026")])
        XCTAssertTrue(package.isReady, "a missing recipient or invoice PDF is the person's call")

        let offline = try build(absent: [id("document")])
        XCTAssertEqual(offline.attachments.count, 1, "the statement only")
        XCTAssertEqual(offline.unavailable, ["fatura-luz.pdf"])
        XCTAssertTrue(offline.missing.contains(RechargeEmailPackage.notHere("fatura-luz.pdf")))
        XCTAssertFalse(offline.isReady, "a library file not here yet: not opened until it is")
    }

    func testTenantNameOnlyInEmailText() throws {
        let package = try build(language: .english)
        XCTAssertTrue(package.body.contains("Hi \(Self.tenant),"))
        XCTAssertFalse(package.subject.contains(Self.tenant))
        XCTAssertFalse(package.attachments.contains { $0.fileName.contains(Self.tenant) })
        XCTAssertFalse(package.missing.joined().contains(Self.tenant))
        let statement = try XCTUnwrap(PDFDocument(url: package.attachments[0].url)?.string)
        XCTAssertFalse(statement.contains(Self.tenant), "the statement PDF names no one")
    }

    /// An attachment's copy never lands hidden or outside the folder, whatever the document is named; ordinary names
    /// are as the Mac writes them.
    func testAttachmentTargetStaysInsideFolder() throws {
        func target(_ name: String) -> URL {
            let document = EvidenceDocument(sha256: "x", storedRelativePath: "a/b.pdf", originalFileName: name, byteCount: 1, kind: .other,
                                            docDate: nil, amountMinorUnits: nil, currency: nil, addedAt: Date())
            return RechargeEmail.attachmentTarget(for: document, in: folder)
        }
        XCTAssertEqual(target("Water bill.pdf").lastPathComponent, "Water bill.pdf")
        XCTAssertEqual(target("2026/10 water.pdf").lastPathComponent, "2026-10 water.pdf")
        XCTAssertEqual(target("notes").lastPathComponent, "notes.pdf")
        XCTAssertEqual(target(".hidden.pdf").lastPathComponent, "hidden.pdf")
        XCTAssertEqual(target("..").lastPathComponent, "Invoice.pdf")
        XCTAssertEqual(target("../../escape.pdf").lastPathComponent, "-..-escape.pdf")
        for name in ["..", "../x.pdf", ".", "./.pdf", "...pdf"] {
            let url = target(name)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path, name)
            XCTAssertFalse(url.lastPathComponent.hasPrefix("."), name)
        }
    }

    func testBuildWritesNothing() throws {
        func counts() throws -> [String: Int] {
            try queue.read { db in
                var counts: [String: Int] = [:]
                for table in ["rechargeStatement", "rechargeLine", "utilityInvoice", "document", "documentLink"] {
                    counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")!
                }
                counts["pending"] = try SyncChangeTracker.pending(db: db).count
                return counts
            }
        }
        let before = try counts()
        let statement = try queue.read { db in try RechargeStatement.fetchOne(db, key: self.id("statement")) }
        _ = try build()
        _ = try build(language: .english, absent: [id("document")])
        XCTAssertEqual(try counts(), before)
        XCTAssertEqual(try queue.read { db in try RechargeStatement.fetchOne(db, key: self.id("statement")) }, statement)
        XCTAssertEqual(try status(), .draft)
    }

    // MARK: Mark as sent

    func testMarkSentOnlyAfterConfirmedOutcome() async throws {
        for outcome in [RechargeEmailFlow.Outcome.cancelled, .failed, .saved] {
            var flow = RechargeEmailFlow()
            flow.open()
            XCTAssertEqual(flow.stage, .composing)
            flow.finished(outcome)
            XCTAssertEqual(flow.stage, .preview, "\(outcome)")
            XCTAssertFalse(flow.confirm(), "\(outcome): nothing to confirm")
            XCTAssertNotNil(flow.note)
        }
        XCTAssertEqual(try status(), .draft)

        var flow = RechargeEmailFlow()
        flow.open()
        flow.finished(.sent)
        XCTAssertEqual(flow.stage, .confirming, "sent asks; never marks by itself")
        XCTAssertEqual(flow.note, RechargeEmailFlow.sentNote)
        XCTAssertEqual(try status(), .draft)
        flow.decline()
        XCTAssertEqual(flow.stage, .preview)
        XCTAssertFalse(flow.confirm())

        flow.askToMarkSent()
        XCTAssertEqual(flow.stage, .confirming)
        XCTAssertTrue(flow.confirm())
        XCTAssertEqual(flow.stage, .marking)
        try await RechargeEmailPackage.markSent(statementId: id("statement"), writer: writer(), at: Self.day(2026, 10, 3))
        flow.marked(saved: true)
        XCTAssertEqual(flow.stage, .markedSent)
        let statement = try XCTUnwrap(try statementNow())
        XCTAssertEqual(statement.status, .sent)
        XCTAssertEqual(statement.sentAt, Self.day(2026, 10, 3))

        // Sent: its lines are fixed, and it can't be marked again.
        do {
            try await RechargeEmailPackage.markSent(statementId: id("statement"), writer: writer(), at: Self.day(2026, 10, 4))
            XCTFail("a sent statement isn't marked again")
        } catch {
            XCTAssertEqual(error as? RechargeError, .statementNotDraft)
        }
        XCTAssertThrowsError(try addLateCharge())
    }

    func testMarkSentRefusedForViewOnlyMember() async throws {
        try setMemberLevel(.view, .property)
        do {
            try await RechargeEmailPackage.markSent(statementId: id("statement"), writer: writer(Self.member), at: Self.day(2026, 10, 3))
            XCTFail("a view-only member can't mark it sent")
        } catch {
            XCTAssertTrue(error is AccessDenied, "\(error)")
        }
        XCTAssertEqual(try status(), .draft)

        // Members have Edit on Property by default: hers goes through.
        try setMemberLevel(.edit, .property)
        try await RechargeEmailPackage.markSent(statementId: id("statement"), writer: writer(Self.member), at: Self.day(2026, 10, 3))
        XCTAssertEqual(try status(), .sent)
    }
}
