import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI
import struct BudgetCore.Transaction

/// Step 10 Task 16: Profile — the mortgage terms form saved through the writer only on Save, refused inline (nothing saved)
/// when it would move a filed return, read-only for a member who views Property; and the Profile edits as the Mac makes them.
/// Demo data.
@MainActor
final class PadProfileModelTests: XCTestCase {
    private var db: DatabaseQueue!
    private let today = DemoDatabase.defaultAsOf

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        db = try DatabaseQueue(path: path)
    }

    private func tabs(_ viewer: PhoneViewer = .demoAdmin) async -> PhoneTabsModel {
        let today = today
        let writer = DeviceWriter(db: db, viewer: { viewer }, afterWrite: {})
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer)
        await tabs.padProperty.reload()
        await tabs.padWrite.refresh()
        await tabs.padProfile.reload()
        return tabs
    }

    private func storedTerms() async throws -> (Row?, [Row]) {
        try await db.read { db in
            (try Row.fetchOne(db, sql: "SELECT * FROM propertyMortgageTerms"), try Row.fetchAll(db, sql: "SELECT * FROM mortgageRateOverride ORDER BY id"))
        }
    }

    func testMortgageSaveThroughWriter() async throws {
        let tabs = await tabs()
        let model = tabs.padProfile
        XCTAssertEqual(model.actions(for: .mortgage), [.editMortgageTerms])
        var form = try XCTUnwrap(model.mortgageForm())
        form.index = .euribor6M
        form.spreadText = "1.150"
        form.totalText = "420"
        let saved = await model.saveMortgage(form)
        XCTAssertTrue(saved)
        XCTAssertNil(model.mortgageFormMessage)
        XCTAssertEqual(model.snapshot.terms?.rateIndex, .euribor6M)
        XCTAssertEqual(model.snapshot.terms?.spreadPercent, 1.15)
        XCTAssertEqual(model.snapshot.terms?.totalInstalments, 420)
        // Stamped as the signed-in user's edit, in Property.
        let stamped = try await db.read { try Row.fetchOne($0, sql: "SELECT * FROM propertyMortgageTerms") }
        XCTAssertNotNil(stamped)
        // A form that doesn't read is refused inside the form, nothing saved.
        var bad = try XCTUnwrap(model.mortgageForm())
        bad.spreadText = "one"
        let before = try await storedTerms()
        let refused = await model.saveMortgage(bad)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.mortgageFormMessage, "“one” isn't a spread: enter a percentage such as 1.000.")
        let after = try await storedTerms()
        XCTAssertEqual(after.0, before.0)
    }

    func testMortgageEditChangingFiledYearFigureRefusedNothingSaved() async throws {
        // As in BudgetCore's test: a trigger stands in for a figure that follows the loan's rules, so this save would move
        // the filed 2024/25 return. Refused inside the form with the filed-year words; neither the terms, the rates given
        // nor the cost change.
        let costId = try await filedYearCostId()
        for event in ["INSERT", "UPDATE"] {
            try await db.write { db in
                try db.execute(sql: """
                    CREATE TEMP TRIGGER mortgageMovesFiledYear\(event) AFTER \(event) ON propertyMortgageTerms
                    BEGIN UPDATE transaction_ SET amountMinorUnits = amountMinorUnits - 50000 WHERE id = \(costId); END
                    """)
            }
        }
        let tabs = await tabs()
        let model = tabs.padProfile
        let before = try await storedTerms()
        let amount = try await db.read { try Transaction.fetchOne($0, key: costId)?.amountMinorUnits }
        var form = try XCTUnwrap(model.mortgageForm())
        form.index = .fixed
        form.fixedRateText = "4.5"
        XCTAssertNil(form.addOverride(start: try XCTUnwrap(form.overrideChoices(today: today).first), text: "4.0"))
        let saved = await model.saveMortgage(form)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.mortgageFormMessage, DeviceWriteCopy.filedYear(years: ["2024/25"]))
        let after = try await storedTerms()
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        let still = try await db.read { try Transaction.fetchOne($0, key: costId)?.amountMinorUnits }
        XCTAssertEqual(still, amount)
    }

    func testCancelLeavesTermsUntouched() async throws {
        // The form is a copy: changing it (and closing it with Cancel, which only dismisses) saves nothing.
        let tabs = await tabs()
        let model = tabs.padProfile
        let before = try await storedTerms()
        let shown = model.snapshot.terms
        var form = try XCTUnwrap(model.mortgageForm())
        form.index = .fixed
        form.fixedRateText = "9.9"
        form.months = [2]
        _ = form.addOverride(start: try XCTUnwrap(form.overrideChoices(today: today).first), text: "5.0")
        await model.reload()
        let after = try await storedTerms()
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(model.snapshot.terms, shown)
        XCTAssertEqual(model.mortgageForm(), MortgageTermsEditing.Form(terms: shown!, overrides: model.snapshot.rateOverrides))
    }

    func testMemberViewOnlySeesTermsReadOnly() async throws {
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
        let model = tabs.padProfile
        XCTAssertFalse(tabs.padWrite.canEdit)
        // The terms are shown; no Edit control is offered on any card.
        XCTAssertNotNil(model.snapshot.terms)
        XCTAssertFalse(model.mortgage.rate.isEmpty)
        XCTAssertEqual(model.actions(for: .mortgage), [], "no Edit terms")
        for card in [PadProfileModel.Card.details, .address, .map, .owners, .accounts, .groups, .documents] {
            XCTAssertEqual(model.actions(for: card).filter(\.edits), [], "\(card) offers no edit")
        }
        XCTAssertEqual(model.actions(for: .documents), [.viewDocument])
        // Nothing is written even if asked.
        let before = try await storedTerms()
        var form = try XCTUnwrap(model.mortgageForm())
        form.spreadText = "2.0"
        let saved = await model.saveMortgage(form)
        XCTAssertFalse(saved)
        let after = try await storedTerms()
        XCTAssertEqual(after.0, before.0)
    }

    func testProfileEditsAsTheMacMakesThem() async throws {
        let tabs = await tabs()
        let model = tabs.padProfile
        // Details: a price that doesn't read is refused under the card; a good one saves.
        var draft = try XCTUnwrap(model.detailsDraft())
        draft.priceText = "12x"
        let refused = await model.save(draft)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.message(for: .details), MortgageTermsEditing.invalidAmount("12x"))
        draft.priceText = "250000"
        draft.matrixArticle = "U-1234"
        let saved = await model.save(draft)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.snapshot.property?.purchasePriceMinorUnits, 25_000_000)
        XCTAssertEqual(model.snapshot.property?.matrixArticle, "U-1234")
        // Owners: shares not adding up to 100% are refused in the Mac's words, nothing saved.
        var owners = try XCTUnwrap(model.ownersDraft())
        let ownersBefore = model.snapshot.owners
        owners.rows[0].shareText = "10"
        let badOwners = await model.save(owners)
        XCTAssertFalse(badOwners)
        XCTAssertNotNil(model.message(for: .owners))
        XCTAssertEqual(model.snapshot.owners, ownersBefore)
        // Groups: an empty group added then removed; one whose costs would move the filed 2024/25 return is refused under
        // the card, nothing added.
        let emptyId = try await db.write { db -> Int64 in
            var group = CategoryGroup(name: "Group Empty", type: .expense)
            try group.insert(db)
            return group.id!
        }
        await model.reload()
        let added = await model.addGroup(emptyId)
        XCTAssertTrue(added)
        XCTAssertTrue(model.snapshot.groupIds.contains(emptyId))
        let removed = await model.removeGroup(emptyId)
        XCTAssertTrue(removed)
        XCTAssertFalse(model.snapshot.groupIds.contains(emptyId))
        let own = Set(model.snapshot.groupIds)
        let filed = try await db.read { db -> Int64? in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT category.groupId FROM transaction_ JOIN category ON category.id = transaction_.categoryId
                WHERE category.type = 'expense' AND transaction_.date >= ? AND transaction_.date < ?
                """, arguments: [Self.day(2024, 4, 6), Self.day(2025, 4, 6)])
            return ids.first { !own.contains($0) }
        }
        if let filed {
            let refused = await model.addGroup(filed)
            XCTAssertFalse(refused)
            XCTAssertEqual(model.message(for: .groups), DeviceWriteCopy.filedYear(years: ["2023/24", "2024/25"]))
            XCTAssertFalse(model.snapshot.groupIds.contains(filed))
        }
        // Documents: a library document linked, then unlinked (it stays in the library).
        let candidates = await model.documentCandidates()
        let candidate = try XCTUnwrap(candidates.first?.id)
        let linked = await model.linkDocument(candidate)
        XCTAssertTrue(linked)
        XCTAssertTrue(model.snapshot.documents.contains { $0.id == candidate })
        let unlinked = await model.unlinkDocument(candidate)
        XCTAssertTrue(unlinked)
        XCTAssertFalse(model.snapshot.documents.contains { $0.id == candidate })
        // Address and the pin placed by hand.
        let address = PropertyAddress(lines: "Rua Exemplo 1", postcode: "1000-001", city: "Lisboa", country: model.snapshot.property!.country)
        let addressSaved = await model.saveAddress(address, clearingLocation: false)
        XCTAssertTrue(addressSaved)
        XCTAssertEqual(model.snapshot.property?.city, "Lisboa")
        let pinned = await model.setLocation(PropertyCoordinate(latitude: 38.72, longitude: -9.14), source: .adjusted)
        XCTAssertTrue(pinned)
        XCTAssertEqual(model.snapshot.property?.locationSource, .adjusted)
    }

    /// A cost in one of the property's expense categories dated in the filed 2024/25 tax year.
    private func filedYearCostId() async throws -> Int64 {
        try await db.read { db in
            let propertyId = try XCTUnwrap(Property.order(Column("name")).fetchOne(db)?.id)
            let groups = try Properties.categoryGroupIds(db: db, propertyId: propertyId)
            let categories = try Category.filter(groups.contains(Column("groupId")) && Column("type") == CategoryType.expense.rawValue)
                .fetchAll(db).compactMap(\.id)
            let cost = try Transaction.filter(categories.contains(Column("categoryId")) && Column("date") >= Self.day(2024, 6, 1)
                                              && Column("date") < Self.day(2025, 3, 1)).fetchOne(db)
            return try XCTUnwrap(cost?.id)
        }
    }

    private nonisolated static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
