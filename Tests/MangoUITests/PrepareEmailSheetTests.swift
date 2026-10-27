import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI

/// Step 10 Task 12: Prepare email on the iPad — Mail, else the share sheet; the package built from the library's files
/// (downloaded when not here, a file that can't be got named and blocking); Mark as sent only once the person confirms,
/// and only with Edit on Property. Demo data (the admin), its draft statement.
@MainActor
final class PrepareEmailSheetTests: XCTestCase {
    private var db: DatabaseQueue!
    private var evidence: URL!
    private let today = DemoDatabase.defaultAsOf

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-email-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        evidence = folder.appendingPathComponent("Evidence")
        try DemoDatabase.build(at: path, evidenceRoot: evidence)
        db = try DatabaseQueue(path: path)
        // The demo's draft bill has no PDF yet: give it the previous month's, so there is a file to attach.
        try await db.write { db in
            let invoiceId = try XCTUnwrap(try Int64.fetchOne(db, sql: """
                SELECT l.invoiceId FROM rechargeLine l JOIN rechargeStatement s ON s.id = l.statementId
                WHERE s.status = 'draft' AND l.invoiceId IS NOT NULL ORDER BY l.id LIMIT 1
                """))
            let documentId = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT documentId FROM utilityInvoice WHERE documentId IS NOT NULL ORDER BY id DESC LIMIT 1"))
            try db.execute(sql: "UPDATE utilityInvoice SET documentId = ? WHERE id = ?", arguments: [documentId, invoiceId])
        }
    }

    private func tabs(_ viewer: PhoneViewer = .demoAdmin) async -> PhoneTabsModel {
        let today = today
        let writer = DeviceWriter(db: db, viewer: { viewer }, afterWrite: {})
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer)
        await tabs.padProperty.reload()
        await tabs.padWrite.refresh()
        await tabs.padBills.reload()
        return tabs
    }

    /// The library's files as the iPad gets them: from the demo's evidence folder.
    private var download: @Sendable (String) async throws -> URL {
        let root = evidence!
        return { path in root.appendingPathComponent(path) }
    }

    private func draft(_ tabs: PhoneTabsModel) throws -> PadBillsAndRechargesModel.Statement {
        try XCTUnwrap(tabs.padBills.statements.first { $0.statement.status == .draft })
    }

    private func status(_ id: Int64) async throws -> RechargeStatementStatus? {
        try await db.read { db in try RechargeStatement.fetchOne(db, key: id)?.status }
    }

    func testNoMailFallsBackToShareSheet() async throws {
        XCTAssertEqual(MailComposer.route(canSendMail: true), .mail)
        XCTAssertEqual(MailComposer.route(canSendMail: false), .shareSheet)
        let tabs = await tabs()
        let model = tabs.padBills.prepareEmailModel(statementId: try draft(tabs).id, open: download)
        XCTAssertEqual(model.route(canSendMail: false), .shareSheet)
        XCTAssertEqual(model.route(canSendMail: true), .mail)
        // The share sheet's result, as Mail's: only Mail's own share counts as sent (and even that only asks).
        XCTAssertEqual(MailComposer.outcome(completed: true, isMail: true, failed: false), .sent)
        XCTAssertEqual(MailComposer.outcome(completed: true, isMail: false, failed: false), .saved)
        XCTAssertEqual(MailComposer.outcome(completed: false, isMail: false, failed: false), .cancelled)
        XCTAssertEqual(MailComposer.outcome(completed: false, isMail: true, failed: true), .failed)
    }

    func testPackageFromTheLibraryAndMarkSentOnlyOnConfirm() async throws {
        let tabs = await tabs()
        let statement = try draft(tabs)
        let model = tabs.padBills.prepareEmailModel(statementId: statement.id, open: download)
        await model.reload()
        let package = try XCTUnwrap(model.package)
        XCTAssertTrue(package.isReady)
        XCTAssertEqual(Set(statement.lines.compactMap(\.documentId)).count, 1)
        XCTAssertEqual(package.attachments.count, 2, "the statement PDF and the bill's")
        for attachment in package.attachments { XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.url.path)) }
        XCTAssertEqual(model.monthName, RechargeEmail.monthName(statement.statement.month, language: .english))

        for outcome in [MailComposer.Outcome.cancelled, .failed, .saved] {
            model.opened()
            model.finished(outcome)
            XCTAssertEqual(model.flow.stage, .preview)
        }
        let confirmedEarly = await model.confirmMarkSent()
        XCTAssertFalse(confirmedEarly, "nothing asked: nothing marked")
        let stillDraft = try await status(statement.id)
        XCTAssertEqual(stillDraft, .draft)

        model.opened()
        model.finished(.sent)
        XCTAssertEqual(model.flow.stage, .confirming)
        let notYet = try await status(statement.id)
        XCTAssertEqual(notYet, .draft, "Mail's sent only asks")
        let marked = await model.confirmMarkSent()
        XCTAssertTrue(marked)
        XCTAssertEqual(model.flow.stage, .markedSent)
        let sent = try await status(statement.id)
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(tabs.padBills.statements.first { $0.id == statement.id }?.statement.status, .sent, "the screen read again")
    }

    func testFileNotOnThisIPadIsNamedAndBlocks() async throws {
        let tabs = await tabs()
        let statement = try draft(tabs)
        let model = tabs.padBills.prepareEmailModel(statementId: statement.id, open: { _ in throw PadDocumentNotOnDevice() })
        await model.reload()
        let package = try XCTUnwrap(model.package)
        XCTAssertFalse(package.isReady)
        XCTAssertFalse(package.unavailable.isEmpty)
        XCTAssertEqual(package.attachments.count, 1, "the statement PDF only")
    }

    func testMarkAsSentHiddenForViewOnlyMember() async throws {
        let member = try await db.write { db -> String in
            var person = Person(name: "Person V", shortName: "V")
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "V", cloudKitUserRecordName: "_viewer", isAdmin: false,
                               createdAt: Date(timeIntervalSince1970: 0))
            try user.insert(db)
            _ = try SyncRecordStore.uuid(for: "appUser", localId: user.id!, db: db)
            try MemberPermissions.ensureDefaults(appUserId: user.id!, db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                           arguments: [PermissionLevel.view.rawValue, user.id!, AccessArea.property.storageKey])
            return "_viewer"
        }
        let tabs = await tabs(.iCloudUser(recordName: member))
        let statement = try draft(tabs)
        let model = tabs.padBills.prepareEmailModel(statementId: statement.id, open: download)
        model.askToMarkSent()
        XCTAssertEqual(model.flow.stage, .preview, "not offered without Edit")
        model.opened()
        model.finished(.sent)
        let marked = await model.confirmMarkSent()
        XCTAssertFalse(marked)
        let after = try await status(statement.id)
        XCTAssertEqual(after, .draft)
    }
}
