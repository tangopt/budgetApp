import XCTest
import GRDB
@testable import BudgetCore

/// A UK statement whose account or layout is unknown, settled inside the review: the account
/// chosen there is remembered for files like it (a learnt rule, written only at Confirm import,
/// undone by Undo), and a layout mapped there is saved only at Confirm import. Synthetic data only.
final class StatementAccountLearningTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    /// "Everyday Current": a saved CSV profile, no sort code or account number.
    private var everydayId: Int64!
    /// "New Bank": no saved profile.
    private var newBankId: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        (everydayId, newBankId) = try db.write { db -> (Int64, Int64) in
            try CategorySeeder.seedDefaults(db)
            var everyday = Account(name: "Everyday Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try everyday.insert(db)
            var newBank = Account(name: "New Bank", currency: .gbp, kind: .cash, trackingMode: .imported)
            try newBank.insert(db)
            return (everyday.id!, newBank.id!)
        }
        _ = try ImportProfileStore(dbQueue: db).save(Self.profile(accountId: everydayId))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("StatementAccountLearningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        pipeline.discardPlanningCopy()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private static func profile(accountId: Int64, accountColumns: Bool = false) -> ImportProfile {
        ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1,
                      csvAmountColumnIndex: 2, csvSortCodeColumnIndex: accountColumns ? 3 : nil,
                      csvAccountNumberColumnIndex: accountColumns ? 4 : nil, csvDateFormat: "dd/MM/yyyy")
    }

    private func csv(_ name: String, _ text: String) throws -> URL {
        let directory = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private let fileA = "Date,Description,Amount\n05/01/2026,SHOP A,-10.00\n06/01/2026,SHOP B,-5.00\n"
    private let fileB = "Date,Description,Amount\n05/02/2026,SHOP C,-7.00\n"

    private func item(_ name: String, in plan: ImportPlan) throws -> ImportItem {
        try XCTUnwrap(plan.items.first { $0.file.fileName == name && $0.parentId == nil }, "no \(name) in \(plan.items.map(\.file.fileName))")
    }

    private func uk(_ item: ImportItem) throws -> UKStatementEffect {
        guard case .ukStatement(let effect) = item.effect else {
            XCTFail("not a UK statement effect: \(item.effect)")
            throw CancellationError()
        }
        return effect
    }

    private func rules() throws -> [ImportRule] { try db.read { db in try ImportRuleStore.all(db: db) } }

    private func profiles(_ accountId: Int64) throws -> Int {
        try db.read { db in try ImportProfile.filter(Column("accountId") == accountId).fetchCount(db) }
    }

    private func saved(_ accountId: Int64) throws -> [String] {
        try db.read { db in try Transaction.filter(Column("accountId") == accountId).fetchAll(db).map(\.rawDescription).sorted() }
    }

    /// File A dropped without an intent, its account chosen in the review.
    private func chooseForFileA(_ accountId: Int64) async throws -> ImportPlan {
        let plan = try await pipeline.plan([try csv("a.csv", fileA)])
        let unknown = try item("a.csv", in: plan)
        return try await pipeline.resolve(plan, itemId: unknown.id, .chooseAccount(.current, accountId))
    }

    // MARK: Choosing and remembering the account

    func testUnknownAccountOffersTheExistingAccountsOnly() async throws {
        let plan = try await pipeline.plan([try csv("a.csv", fileA)])
        let unknown = try item("a.csv", in: plan)
        let issue = try XCTUnwrap(unknown.issues.first { $0.id == "unknownAccount" }, "\(unknown.issues)")
        XCTAssertEqual(issue.kind, .statement(.unknownAccount))
        XCTAssertEqual(issue.offers.count, 2, "\(issue.offers)")
        XCTAssertTrue(issue.offers.contains(.chooseAccount(.current, everydayId)) && issue.offers.contains(.chooseAccount(.current, newBankId)))
        do {
            _ = try await pipeline.resolve(plan, itemId: unknown.id, .chooseAccount(.current, 9_999))
            XCTFail("an account the issue doesn't offer is refused")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.chooseAccount(.current, 9_999)))
        }
        do {
            _ = try await pipeline.resolve(plan, itemId: unknown.id, .chooseAccount(.mortgage, everydayId))
            XCTFail("a UK statement has no mortgage")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.chooseAccount(.mortgage, everydayId)))
        }
    }

    func testChosenAccountIsRememberedForTheSameSignature() async throws {
        var plan = try await chooseForFileA(everydayId)
        let chosen = try item("a.csv", in: plan)
        XCTAssertEqual(chosen.section, .ready, "\(chosen.needsYouReasons)")
        let effect = try uk(chosen)
        XCTAssertEqual(effect.accountId, everydayId)
        XCTAssertEqual(effect.learnAccount?.key, "csv:date|description|amount")
        XCTAssertEqual(effect.learnAccount?.label, "CSV with columns Date, Description, Amount")
        XCTAssertEqual(effect.learnAccount?.accountId, everydayId)
        XCTAssertEqual(try rules().count, 0, "nothing is learnt before Confirm import")

        _ = try applier.apply(plan, entryPoint: "Test")
        let learnt = try rules()
        XCTAssertEqual(learnt.map(\.matchKey), ["csv:date|description|amount"])
        XCTAssertEqual(learnt.first?.kind, .statementAccount)
        XCTAssertEqual(learnt.first?.actionJSON, "{\"accountId\":\(everydayId!)}")
        XCTAssertEqual(learnt.first?.actionLabel, "Account: Everyday Current")
        XCTAssertEqual(learnt.first?.useCount, 0)
        pipeline.discardPlanningCopy()

        // File B: same header, other rows, no intent.
        plan = try await pipeline.plan([try csv("b.csv", fileB)])
        let remembered = try item("b.csv", in: plan)
        XCTAssertEqual(remembered.section, .ready, "\(remembered.needsYouReasons)")
        XCTAssertEqual(remembered.recognition.reason, "Remembered: CSV with columns Date, Description, Amount → Everyday Current")
        let reference = try XCTUnwrap(remembered.facts.first { $0.field == .reference })
        XCTAssertEqual(reference.value, .text("Everyday Current"))
        XCTAssertEqual(reference.source, .learntRule)
        XCTAssertEqual(reference.reason, "Remembered for files like this: Everyday Current")
        let again = try uk(remembered)
        XCTAssertEqual(again.accountId, everydayId)
        XCTAssertNil(again.learnAccount, "already remembered")
        XCTAssertEqual(again.rememberedRuleId, learnt.first?.id)

        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try saved(everydayId), ["SHOP A", "SHOP B", "SHOP C"])
        let used = try XCTUnwrap(try rules().first)
        XCTAssertEqual(used.useCount, 1, "marked used when applied")
        XCTAssertNotNil(used.lastUsedAt)
    }

    func testUndoForgetsTheLearntAccount() async throws {
        let plan = try await chooseForFileA(everydayId)
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try rules().count, 1)

        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try rules().count, 0, "the learnt choice goes with the run")
        XCTAssertEqual(try saved(everydayId), [])
        pipeline.discardPlanningCopy()
        let next = try await pipeline.plan([try csv("b.csv", fileB)])
        XCTAssertEqual(try item("b.csv", in: next).issues.map(\.kind), [.statement(.unknownAccount)])
    }

    func testARememberedAccountThatNoLongerExistsIsIgnored() async throws {
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "csv:date|description|amount",
                                      matchLabel: "CSV with columns Date, Description, Amount",
                                      action: StatementAccountAction(accountId: 9_999), actionLabel: "Account: Gone", now: Date())
        }
        let plan = try await pipeline.plan([try csv("b.csv", fileB)])
        let unknown = try item("b.csv", in: plan)
        XCTAssertEqual(unknown.issues.map(\.kind), [.statement(.unknownAccount)])
        XCTAssertEqual(unknown.section, .needsYou)
    }

    private let detailsHeader = "Date,Description,Amount,Sort Code,Account Number"
    private let detailsKey = "csv:date|description|amount|sort code|account number"

    /// "Bank Two" (11-22-33 / 11112222) with no profile; Everyday's profile reads the account columns.
    private func addBankTwoWithoutProfile() async throws -> Int64 {
        let everydayId = everydayId!
        return try await db.write { db -> Int64 in
            var other = Account(name: "Bank Two", currency: .gbp, kind: .cash, trackingMode: .imported, sortCode: "11-22-33", accountNumber: "11112222")
            try other.insert(db)
            _ = try ImportProfileStore.save(db: db, Self.profile(accountId: everydayId, accountColumns: true))
            return other.id!
        }
    }

    private func remember(_ key: String, label: String, accountId: Int64, name: String) async throws {
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .statementAccount, key: key, matchLabel: label,
                                      action: StatementAccountAction(accountId: accountId), actionLabel: "Account: \(name)", now: Date())
        }
    }

    func testARememberedAccountNeverTakesAnotherAccountsPrintedNumber() async throws {
        // Bank Two has no profile: the file's details are still its own.
        let otherId = try await addBankTwoWithoutProfile()
        try await remember(detailsKey, label: "CSV with columns Date, Description, Amount, Sort Code, Account Number",
                           accountId: everydayId, name: "Everyday Current")
        let plan = try await pipeline.plan([try csv("c.csv", "\(detailsHeader)\n05/03/2026,SHOP D,-3.00,11-22-33,11112222\n")])
        let statement = try item("c.csv", in: plan)
        XCTAssertEqual(statement.section, .needsYou)
        let text = "This statement's sort code and account number are Bank Two's, not Everyday Current's (remembered for files like this): "
            + "choose its account or leave it out of this import"
        XCTAssertTrue(statement.issues.contains { $0.id == "accountMismatch" && $0.kind == .readerProblem(text) && $0.reason == text },
                      "\(statement.issues)")
        let effect = try uk(statement)
        XCTAssertNotEqual(effect.accountId, otherId, "never silently moved")
        XCTAssertNil(effect.accountFill, "Bank Two's numbers are never copied to Everyday Current")
        XCTAssertFalse(plan.canConfirm)
        XCTAssertEqual(try saved(everydayId), [])
    }

    func testAChosenAccountNeverTakesAnotherAccountsPrintedNumber() async throws {
        _ = try await addBankTwoWithoutProfile()
        // The account number alone is Bank Two's.
        var plan = try await pipeline.plan([try csv("c.csv", "\(detailsHeader)\n05/03/2026,SHOP D,-3.00,,11112222\n")])
        let unknown = try item("c.csv", in: plan)
        XCTAssertEqual(unknown.issues.map(\.kind), [.statement(.unknownAccount)])
        plan = try await pipeline.resolve(plan, itemId: unknown.id, .chooseAccount(.current, everydayId))
        let chosen = try item("c.csv", in: plan)
        XCTAssertEqual(chosen.section, .needsYou)
        let text = "This statement's account number is Bank Two's, not Everyday Current's: choose its account or leave it out of this import"
        XCTAssertTrue(chosen.issues.contains { $0.id == "accountMismatch" && $0.kind == .readerProblem(text) && $0.reason == text },
                      "\(chosen.issues)")
        XCTAssertNil(try uk(chosen).accountFill)
        XCTAssertFalse(plan.canConfirm)
    }

    // MARK: How sure a remembered account is

    private func confirmIssue(_ item: ImportItem) -> ImportIssue? { item.issues.first { $0.id == "rememberedAccount" } }

    func testARememberedAccountOthersCouldCarryIsAskedWithItPreselected() async throws {
        try await remember("csv:date|description|amount", label: "CSV with columns Date, Description, Amount",
                           accountId: everydayId, name: "Everyday Current")
        // New Bank could carry CSV statements too (a profile of the format).
        _ = try ImportProfileStore(dbQueue: db).save(Self.profile(accountId: newBankId))
        var plan = try await pipeline.plan([try csv("b.csv", fileB)])
        let asked = try item("b.csv", in: plan)
        XCTAssertEqual(asked.section, .needsYou)
        XCTAssertEqual(asked.recognition.reason, "Remembered: CSV with columns Date, Description, Amount → Everyday Current")
        let issue = try XCTUnwrap(confirmIssue(asked), "\(asked.issues)")
        XCTAssertEqual(issue.kind, .statement(.unknownAccount))
        XCTAssertEqual(issue.reason, "Remembered for files like this: Everyday Current. Other accounts could have this statement too: "
                       + "confirm it or choose its account")
        XCTAssertEqual(issue.offers.first, .chooseAccount(.current, everydayId), "the remembered account first")
        XCTAssertTrue(issue.offers.contains(.chooseAccount(.current, newBankId)))
        XCTAssertEqual(try uk(asked).accountId, everydayId, "preselected")
        XCTAssertEqual(try uk(asked).staged.count, 1)

        plan = try await pipeline.resolve(plan, itemId: asked.id, .chooseAccount(.current, everydayId))
        let confirmed = try item("b.csv", in: plan)
        XCTAssertEqual(confirmed.section, .ready, "\(confirmed.needsYouReasons)")
        XCTAssertEqual(try uk(confirmed).accountId, everydayId)
    }

    func testARememberedAccountIsAskedWhenAnUnprofiledAccountHasStatementsOfTheFormat() async throws {
        try await remember("csv:date|description|amount", label: "CSV with columns Date, Description, Amount",
                           accountId: everydayId, name: "Everyday Current")
        let newBankId = newBankId!
        try await db.write { db in
            var batch = ImportBatch(accountId: newBankId, sourceFileName: "old-statement.csv", importedAt: Date())
            try batch.insert(db)
        }
        let plan = try await pipeline.plan([try csv("b.csv", fileB)])
        let asked = try item("b.csv", in: plan)
        XCTAssertEqual(asked.section, .needsYou)
        XCTAssertNotNil(confirmIssue(asked), "\(asked.issues)")
    }

    func testARememberedAccountTheFileCorroboratesIsReady() async throws {
        let everydayId = everydayId!
        try await db.write { db in
            var everyday = try Account.fetchOne(db, key: everydayId)!
            everyday.sortCode = "99-88-77"
            everyday.accountNumber = "99998888"
            try everyday.update(db)
            _ = try ImportProfileStore.save(db: db, Self.profile(accountId: everydayId, accountColumns: true))
        }
        _ = try ImportProfileStore(dbQueue: db).save(Self.profile(accountId: newBankId, accountColumns: true))
        try await remember(detailsKey, label: "CSV with columns Date, Description, Amount, Sort Code, Account Number",
                           accountId: everydayId, name: "Everyday Current")
        let plan = try await pipeline.plan([try csv("c.csv", "\(detailsHeader)\n05/03/2026,SHOP D,-3.00,99-88-77,99998888\n")])
        let statement = try item("c.csv", in: plan)
        XCTAssertEqual(statement.section, .ready, "\(statement.needsYouReasons)")
        XCTAssertEqual(statement.recognition.reason, "Remembered: CSV with columns Date, Description, Amount, Sort Code, Account Number → Everyday Current")
    }

    func testOverridingARememberedAccountRelearnsItAndUndoRestoresTheOldRule() async throws {
        try await remember("csv:date|description|amount", label: "CSV with columns Date, Description, Amount",
                           accountId: everydayId, name: "Everyday Current")
        _ = try ImportProfileStore(dbQueue: db).save(Self.profile(accountId: newBankId))
        var plan = try await pipeline.plan([try csv("b.csv", fileB)])
        plan = try await pipeline.resolve(plan, itemId: try item("b.csv", in: plan).id, .chooseTarget(.account, newBankId))
        let moved = try item("b.csv", in: plan)
        XCTAssertEqual(moved.section, .ready, "\(moved.needsYouReasons)")
        XCTAssertEqual(try uk(moved).accountId, newBankId)
        XCTAssertEqual(try uk(moved).learnAccount?.accountId, newBankId)

        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try rules().map(\.actionJSON), ["{\"accountId\":\(newBankId!)}"])
        XCTAssertEqual(try rules().map(\.actionLabel), ["Account: New Bank"])
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try rules().map(\.actionJSON), ["{\"accountId\":\(everydayId!)}"], "the replaced rule is back as it was")
        XCTAssertEqual(try rules().map(\.actionLabel), ["Account: Everyday Current"])
    }

    func testThePickerOffersPlausibleAccountsFirst() async throws {
        let newBankId = newBankId!
        let secondId = try await db.write { db -> Int64 in
            var newBank = try Account.fetchOne(db, key: newBankId)!
            newBank.currency = .eur
            try newBank.update(db)
            var card = Account(name: "Card", currency: .gbp, kind: .credit, trackingMode: .imported)
            try card.insert(db)
            var second = Account(name: "Second Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try second.insert(db)
            return second.id!
        }
        let plan = try await pipeline.plan([try csv("a.csv", fileA)])
        let issue = try XCTUnwrap(try item("a.csv", in: plan).issues.first { $0.id == "unknownAccount" })
        XCTAssertEqual(Array(issue.offers.prefix(2)), [.chooseAccount(.current, everydayId), .chooseAccount(.current, secondId)])
        XCTAssertEqual(issue.offers.count, 4, "every account stays available")
    }

    // MARK: Mapping the layout in the review

    func testSavedProfileIsWrittenOnlyAtConfirm() async throws {
        var plan = try await pipeline.plan([try csv("a.csv", fileA)], intent: ImportIntent(accountId: newBankId))
        let unmapped = try item("a.csv", in: plan)
        XCTAssertEqual(unmapped.issues.map(\.kind), [.statement(.noProfile(format: .csv, accountId: newBankId))])
        do {
            _ = try await pipeline.resolve(plan, itemId: unmapped.id, .saveProfile(Self.profile(accountId: everydayId)))
            XCTFail("a profile of another account is refused")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.saveProfile(Self.profile(accountId: everydayId))))
        }

        plan = try await pipeline.resolve(plan, itemId: unmapped.id, .saveProfile(Self.profile(accountId: newBankId)))
        let mapped = try item("a.csv", in: plan)
        XCTAssertEqual(mapped.section, .ready, "\(mapped.needsYouReasons)")
        let effect = try uk(mapped)
        XCTAssertEqual(effect.accountId, newBankId)
        XCTAssertEqual(effect.staged.map(\.parsed.rawDescription), ["SHOP A", "SHOP B"])
        XCTAssertEqual(effect.profileToSave, Self.profile(accountId: newBankId))
        XCTAssertEqual(try profiles(newBankId), 0, "nothing is saved before Confirm import")

        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try profiles(newBankId), 1)
        XCTAssertEqual(try saved(newBankId), ["SHOP A", "SHOP B"])

        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try profiles(newBankId), 0, "the mapping goes with the run")
    }

    func testAMappedLayoutIsSavedAsANewProfile() async throws {
        let everydayId = everydayId!
        let found = try await db.read { db in try ImportProfile.filter(Column("accountId") == everydayId).fetchOne(db) }
        let everydayProfile = try XCTUnwrap(found)
        var plan = try await pipeline.plan([try csv("a.csv", fileA)], intent: ImportIntent(accountId: newBankId))
        var mapping = Self.profile(accountId: newBankId)
        mapping.id = everydayProfile.id  // e.g. a mapping started from another account's profile
        plan = try await pipeline.resolve(plan, itemId: try item("a.csv", in: plan).id, .saveProfile(mapping))
        XCTAssertEqual(try uk(try item("a.csv", in: plan)).profileToSave?.id, nil)
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try profiles(newBankId), 1)
        XCTAssertEqual(try profiles(everydayId), 1, "Everyday Current's profile is untouched")
        let kept = try await db.read { db in try ImportProfile.fetchOne(db, key: everydayProfile.id) }
        XCTAssertEqual(kept?.accountId, everydayId)
    }

    func testChosenAccountWithoutAProfileIsMappedThenBothAreSavedAtConfirm() async throws {
        var plan = try await chooseForFileA(newBankId)
        let unmapped = try item("a.csv", in: plan)
        XCTAssertEqual(unmapped.issues.map(\.kind), [.statement(.noProfile(format: .csv, accountId: newBankId))])
        plan = try await pipeline.resolve(plan, itemId: unmapped.id, .saveProfile(Self.profile(accountId: newBankId)))
        let mapped = try item("a.csv", in: plan)
        XCTAssertEqual(mapped.section, .ready, "\(mapped.needsYouReasons)")
        XCTAssertEqual(try uk(mapped).learnAccount?.accountId, newBankId, "the choice is kept through the mapping")

        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try profiles(newBankId), 1)
        XCTAssertEqual(try rules().map(\.actionLabel), ["Account: New Bank"])
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try profiles(newBankId), 0)
        XCTAssertEqual(try rules().count, 0)
    }

    // MARK: Final review, round 2

    func testAFullyImportedLibraryStatementWithARememberedAccountToConfirmIsADuplicate() async throws {
        let chosen = try await chooseForFileA(everydayId)
        _ = try applier.apply(chosen, entryPoint: "Test")
        // New Bank could carry CSV statements too: the remembered account would be asked.
        _ = try ImportProfileStore(dbQueue: db).save(Self.profile(accountId: newBankId))
        pipeline.discardPlanningCopy()
        let again = try item("a.csv", in: try await pipeline.plan([try csv("a.csv", fileA)]))
        XCTAssertEqual(again.section, .duplicates, "\(again.needsYouReasons)")
        XCTAssertTrue(again.duplicate?.of.hasPrefix("Identical file: already in the library as") == true, "\(String(describing: again.duplicate))")
    }
}
