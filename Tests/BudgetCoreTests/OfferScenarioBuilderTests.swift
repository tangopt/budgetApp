import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import TestSupport

/// A job offer as a scenario (spec 2026-10-28-step14-job-offer-forecast-design.md): the salary entry's copy
/// ends before the start month and the offer's take-home follows, the pension becomes the offer's, one-offs
/// are added, the inputs are stored with the scenario and "Edit offer…" rebuilds it in place.
final class OfferScenarioBuilderTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private struct Fixture {
        let manager: DatabaseManager
        var salaryCategoryId: Int64 = 0
        var pensionCategoryId: Int64 = 0
        var salaryEntryId: Int64 = 0
        var pensionEntryId: Int64 = 0
        var groupId: Int64 = 0
        var accountId: Int64 = 0
    }

    private let current = SalaryInputs(grossAnnual: 3_200_000, taxYearStart: 2026, pension: .percentOfGross(basisPoints: 500),
                                       employerPension: .percentOfGross(basisPoints: 300))
    private let offer = SalaryInputs(grossAnnual: 4_200_000, taxYearStart: 2026, pension: .percentOfGross(basisPoints: 500),
                                     employerPension: .percentOfGross(basisPoints: 400))

    /// Budget: "Salary" income £2,000.00 monthly from 1 Jan 2026 (no end, paid into an account), "Pension"
    /// expense -£150.00 monthly from 1 Jan 2026, both in a "Regular" group.
    private func fixture(salaryStart: Date? = nil, salaryEnd: Date? = nil, withPension: Bool = true) throws -> Fixture {
        var f = Fixture(manager: try TestDatabase.migratedManager())
        try f.manager.dbQueue.write { db in
            var salary = Category(name: "Salary", type: .income)
            try salary.insert(db)
            var pension = Category(name: "Pension", type: .expense)
            try pension.insert(db)
            var group = ForecastGroup(name: "Regular", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            f.salaryCategoryId = salary.id!
            f.pensionCategoryId = pension.id!
            f.groupId = group.id!
            f.accountId = account.id!
            var s = ForecastEntry(groupId: group.id!, categoryId: salary.id!, amountMinorUnits: 200_000, frequency: .monthly, interval: 1,
                                  startDate: salaryStart ?? utc(2026, 1, 1), endDate: salaryEnd, isEnabled: true, status: .confirmed,
                                  note: nil, accountId: account.id!)
            try s.insert(db)
            f.salaryEntryId = s.id!
            if withPension {
                var p = ForecastEntry(groupId: group.id!, categoryId: pension.id!, amountMinorUnits: -15_000, frequency: .monthly, interval: 1,
                                      startDate: utc(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil)
                try p.insert(db)
                f.pensionEntryId = p.id!
            }
        }
        return f
    }

    private func spec(_ f: Fixture, gap: Int = 0, oneOffs: [OfferOneOff] = [], salary: Bool = true, pension: Bool = true,
                      newIncomeCategoryId: Int64? = nil, offer: SalaryInputs? = nil) -> OfferScenarioSpec {
        OfferScenarioSpec(current: current, offer: offer ?? self.offer, salaryEntryId: salary ? f.salaryEntryId : nil,
                          pensionEntryId: pension && f.pensionEntryId != 0 ? f.pensionEntryId : nil,
                          startMonth: utc(2026, 4, 1), noticeGapMonths: gap, oneOffs: oneOffs, newIncomeCategoryId: newIncomeCategoryId)
    }

    private func create(_ f: Fixture, _ spec: OfferScenarioSpec, name: String = "New job") throws -> Scenario {
        try f.manager.dbQueue.write { db in try OfferScenarioBuilder.create(db: db, name: name, spec: spec, now: self.utc(2026, 10, 28)) }
    }

    private func entries(_ f: Fixture, _ scenario: Scenario) throws -> [ForecastEntry] {
        try f.manager.dbQueue.read { db in try ForecastEntry.inScenario(db, id: scenario.id!) }
    }

    private func budget(_ f: Fixture) throws -> [ForecastEntry] {
        try f.manager.dbQueue.read { db in try ForecastEntry.budget(db) }
    }

    private var takeHome: Int { SalaryCalculator.calculate(offer).takeHomeMonthly }

    // MARK: - Salary

    func testReplacesSalaryFromStartMonth() throws {
        let f = try fixture()
        let before = try budget(f)
        let scenario = try create(f, spec(f))
        let all = try entries(f, scenario)
        let copy = try XCTUnwrap(all.first { $0.sourceEntryId == f.salaryEntryId })
        XCTAssertEqual(copy.endDate, utc(2026, 3, 31))
        XCTAssertEqual(copy.scenarioChange, .changed)
        XCTAssertEqual(copy.amountMinorUnits, 200_000)
        let added = try XCTUnwrap(all.first { $0.scenarioChange == .added && $0.categoryId == f.salaryCategoryId })
        XCTAssertEqual(added.startDate, utc(2026, 4, 1))
        XCTAssertNil(added.endDate)
        XCTAssertEqual(added.frequency, .monthly)
        XCTAssertEqual(added.amountMinorUnits, takeHome)
        XCTAssertGreaterThan(takeHome, 200_000)
        XCTAssertEqual(added.groupId, f.groupId)
        XCTAssertEqual(added.accountId, f.accountId)
        XCTAssertEqual(added.status, .confirmed)
        XCTAssertEqual(added.note, "Offer: salary")
        // The base forecast is untouched.
        XCTAssertEqual(try budget(f), before)
    }

    func testStartBeforeEntryStart() throws {
        let f = try fixture(salaryStart: utc(2026, 6, 1))
        let scenario = try create(f, spec(f))
        let all = try entries(f, scenario)
        let copy = try XCTUnwrap(all.first { $0.sourceEntryId == f.salaryEntryId })
        XCTAssertEqual(copy.scenarioChange, .removed)
        XCTAssertFalse(copy.isEnabled)
        let added = try XCTUnwrap(all.first { $0.scenarioChange == .added && $0.categoryId == f.salaryCategoryId })
        XCTAssertEqual(added.startDate, utc(2026, 4, 1))
        XCTAssertEqual(added.amountMinorUnits, takeHome)
    }

    func testStartAfterEntryEndRefused() throws {
        let f = try fixture(salaryEnd: utc(2026, 3, 15))
        XCTAssertThrowsError(try create(f, spec(f))) { XCTAssertEqual($0 as? OfferScenarioError, .startAfterSalaryEnds) }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Scenario.fetchCount(db) }, 0)
        XCTAssertEqual(try f.manager.dbQueue.read { db in try ForecastEntry.filter(Column("scenarioId") != nil).fetchCount(db) }, 0)
        XCTAssertNotNil(OfferScenarioError.startAfterSalaryEnds.errorDescription)
    }

    func testNoticeGapMonths() throws {
        let f = try fixture()
        let scenario = try create(f, spec(f, gap: 2))
        let all = try entries(f, scenario)
        XCTAssertEqual(all.first { $0.sourceEntryId == f.salaryEntryId }?.endDate, utc(2026, 3, 31))
        let added = try XCTUnwrap(all.first { $0.scenarioChange == .added && $0.categoryId == f.salaryCategoryId })
        XCTAssertEqual(added.startDate, utc(2026, 6, 1))
        // No salary in April or May.
        let period = PayPeriod(startDate: utc(2026, 4, 1), endDate: utc(2026, 5, 31), type: .projected)
        let salaryInGap = all.filter { $0.categoryId == f.salaryCategoryId && $0.isEnabled }
            .flatMap { FrequencyExpander.occurrences(for: $0, in: period) }
        XCTAssertEqual(salaryInGap, [])
    }

    func testMissingSalaryEntryAddsNewIncome() throws {
        let f = try fixture()
        // Neither a salary entry nor a category: refused, nothing created.
        XCTAssertThrowsError(try create(f, spec(f, salary: false))) {
            XCTAssertEqual($0 as? OfferScenarioError, .noSalaryEntryOrNewIncomeCategory)
        }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Scenario.fetchCount(db) }, 0)

        let scenario = try create(f, spec(f, salary: false, newIncomeCategoryId: f.salaryCategoryId))
        let all = try entries(f, scenario)
        // The budget's salary copy is left as it is; the offer is added as new income.
        XCTAssertNil(all.first { $0.sourceEntryId == f.salaryEntryId }?.scenarioChange)
        let added = try XCTUnwrap(all.first { $0.scenarioChange == .added && $0.categoryId == f.salaryCategoryId })
        XCTAssertEqual(added.startDate, utc(2026, 4, 1))
        XCTAssertEqual(added.amountMinorUnits, takeHome)
        XCTAssertEqual(added.note, "Offer: salary")

        // A spec whose salary entry has since left the budget: "Edit offer…" keeps the offer where it was.
        try f.manager.dbQueue.write { db in
            _ = try ForecastEntry.deleteOne(db, key: f.salaryEntryId)
            var later = try XCTUnwrap(try OfferScenarioBuilder.spec(db: db, scenarioId: scenario.id!))
            later.newIncomeCategoryId = nil
            later.salaryEntryId = f.salaryEntryId
            try OfferScenarioBuilder.rebuild(db: db, scenarioId: scenario.id!, spec: later)
        }
        let rebuilt = try entries(f, scenario).filter { $0.scenarioChange == .added && $0.categoryId == f.salaryCategoryId }
        XCTAssertEqual(rebuilt.count, 1)
    }

    // MARK: - Pension

    /// A pension expense moves by what the employee pays in: the employer's share isn't the person's spending.
    func testPensionExpenseChangesByEmployeeDifference() throws {
        let f = try fixture()
        let scenario = try create(f, spec(f))
        let all = try entries(f, scenario)
        let change = SalaryCalculator.roundHalfUp(SalaryCalculator.calculate(offer).employeePension, 12)
            - SalaryCalculator.roundHalfUp(SalaryCalculator.calculate(current).employeePension, 12)
        XCTAssertEqual(change, 4_167)   // 5% of £42,000 against 5% of £32,000, a month
        let expected = -15_000 - change
        let copy = try XCTUnwrap(all.first { $0.sourceEntryId == f.pensionEntryId })
        XCTAssertEqual(copy.scenarioChange, .changed)
        XCTAssertEqual(copy.endDate, utc(2026, 3, 31))
        XCTAssertEqual(copy.amountMinorUnits, -15_000)
        let next = try XCTUnwrap(all.first { $0.scenarioChange == .added && $0.categoryId == f.pensionCategoryId })
        XCTAssertEqual(next.startDate, utc(2026, 4, 1))
        XCTAssertEqual(next.amountMinorUnits, expected)
        XCTAssertEqual(next.groupId, f.groupId)
        XCTAssertEqual(next.note, "Offer: pension")
    }

    /// A transfer into a pension account becomes the offer's employee plus employer contributions.
    func testPensionTransferIsEmployeePlusEmployer() throws {
        var f = try fixture(withPension: false)
        try f.manager.dbQueue.write { db in
            var account = Account(name: "Workplace Pension", currency: .gbp, kind: .investment, trackingMode: .manual)
            try account.insert(db)
            var category = Category(name: "Transfer: Workplace Pension", type: .transfer, transferAccountId: account.id!)
            try category.insert(db)
            var p = ForecastEntry(groupId: f.groupId, categoryId: category.id!, amountMinorUnits: -15_000, frequency: .monthly, interval: 1,
                                  startDate: self.utc(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil)
            try p.insert(db)
            f.pensionEntryId = p.id!
            f.pensionCategoryId = category.id!
        }
        let scenario = try create(f, spec(f))
        let result = SalaryCalculator.calculate(offer)
        let expected = -SalaryCalculator.roundHalfUp(result.employeePension + result.employerPension, 12)
        XCTAssertEqual(expected, -31_500)   // 5% + 4% of £42,000 a year
        let next = try XCTUnwrap(try entries(f, scenario).first { $0.scenarioChange == .added && $0.categoryId == f.pensionCategoryId })
        XCTAssertEqual(next.amountMinorUnits, expected)
        XCTAssertEqual(next.startDate, utc(2026, 4, 1))
    }

    /// Candidates: pension expenses (the sheet narrows them to the salary's group or account) and transfers into an
    /// account named "pension"; never another outgoing, an income, a disabled or a scenario entry.
    func testPensionCandidates() throws {
        let f = try fixture()
        let (transferId, otherGroupId) = try f.manager.dbQueue.write { db -> (Int64, Int64) in
            var account = Account(name: "SIPP pension", currency: .gbp, kind: .investment, trackingMode: .manual)
            try account.insert(db)
            var savings = Account(name: "Savings", currency: .gbp, kind: .cash, trackingMode: .manual)
            try savings.insert(db)
            var toPension = Category(name: "Transfer: SIPP", type: .transfer, transferAccountId: account.id!)
            try toPension.insert(db)
            var toSavings = Category(name: "Transfer: Savings", type: .transfer, transferAccountId: savings.id!)
            try toSavings.insert(db)
            var rent = Category(name: "Rent", type: .expense)
            try rent.insert(db)
            var group = ForecastGroup(name: "Other", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            func add(_ category: Int64, group: Int64, amount: Int = -5_000, enabled: Bool = true) throws -> Int64 {
                var e = ForecastEntry(groupId: group, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1,
                                      startDate: self.utc(2026, 2, 1), endDate: nil, isEnabled: enabled, status: .manual, note: nil)
                try e.insert(db)
                return e.id!
            }
            let transfer = try add(toPension.id!, group: group.id!)
            _ = try add(toSavings.id!, group: f.groupId)
            _ = try add(rent.id!, group: f.groupId)
            _ = try add(f.pensionCategoryId, group: f.groupId, enabled: false)
            let other = try add(f.pensionCategoryId, group: group.id!)
            _ = try Scenarios.create(db: db, name: "Copy")
            return (transfer, other)
        }
        let candidates = try f.manager.dbQueue.read { db in try OfferScenarioBuilder.pensionCandidates(db: db) }
        XCTAssertEqual(Set(candidates.map(\.id)), [f.pensionEntryId, transferId, otherGroupId])
        let salary = try XCTUnwrap(try f.manager.dbQueue.read { db in try ForecastEntry.fetchOne(db, key: f.salaryEntryId) })
        XCTAssertEqual(Set(candidates.filter { $0.fits(salary: salary) }.map(\.id)), [f.pensionEntryId, transferId])
        XCTAssertEqual(candidates.first { $0.id == transferId }?.isTransfer, true)
        XCTAssertEqual(candidates.first { $0.id == f.pensionEntryId }?.isTransfer, false)
        // No salary (new income): only transfers fit.
        XCTAssertEqual(candidates.filter { $0.fits(salary: nil) }.map(\.id), [transferId])
    }

    func testNoPensionEntryLeavesPensionAlone() throws {
        let f = try fixture()
        let scenario = try create(f, spec(f, pension: false))
        let all = try entries(f, scenario)
        XCTAssertNil(all.first { $0.sourceEntryId == f.pensionEntryId }?.scenarioChange)
        XCTAssertFalse(all.contains { $0.categoryId == f.pensionCategoryId && $0.scenarioChange == .added })

        let none = try fixture(withPension: false)
        let other = try create(none, spec(none))
        XCTAssertFalse(try entries(none, other).contains { $0.categoryId == none.pensionCategoryId })
    }

    // MARK: - One-offs, inputs

    func testOneOffsAdded() throws {
        let f = try fixture()
        let bonus = OfferOneOff(label: "Signing bonus", amountMinorUnits: 300_000, month: utc(2026, 4, 1))
        let scenario = try create(f, spec(f, oneOffs: [bonus]))
        let once = try entries(f, scenario).filter { $0.frequency == .once }
        XCTAssertEqual(once.count, 1)
        XCTAssertEqual(once.first?.amountMinorUnits, 300_000)
        XCTAssertEqual(once.first?.startDate, utc(2026, 4, 1))
        XCTAssertEqual(once.first?.categoryId, f.salaryCategoryId)
        XCTAssertEqual(once.first?.scenarioChange, .added)
        XCTAssertEqual(once.first?.note, "Offer: Signing bonus")
        XCTAssertFalse(try budget(f).contains { $0.frequency == .once })
    }

    func testInputsStoredAndRead() throws {
        let f = try fixture()
        let bonus = OfferOneOff(label: "Signing bonus", amountMinorUnits: 300_000, month: utc(2026, 5, 1))
        let input = spec(f, gap: 1, oneOffs: [bonus])
        let scenario = try create(f, input)
        let stored = try XCTUnwrap(try f.manager.dbQueue.read { db in try OfferScenarioBuilder.spec(db: db, scenarioId: scenario.id!) })
        XCTAssertEqual(stored.inputs, input)
        // The entries it added: the salary, the pension and the bonus, all in the scenario.
        let added = try entries(f, scenario).filter { $0.scenarioChange == .added }
        XCTAssertEqual(Set(stored.addedEntryIds), Set(added.compactMap(\.id)))
        XCTAssertEqual(stored.addedEntryIds.count, 3)
        let text = try XCTUnwrap(try f.manager.dbQueue.read { db in try Scenario.fetchOne(db, key: scenario.id!)?.offerInputs })
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["startMonth"] as? String, "2026-04-01T00:00:00Z")
        XCTAssertEqual((object["salaryEntryId"] as? NSNumber)?.int64Value, f.salaryEntryId)
        // A plain scenario has none.
        let plain = try f.manager.dbQueue.write { db in try Scenarios.create(db: db, name: "Plain") }
        XCTAssertNil(try f.manager.dbQueue.read { db in try OfferScenarioBuilder.spec(db: db, scenarioId: plain.id!) })
    }

    // MARK: - Rebuild, delete, names

    func testRebuildReplacesOnlyOfferEntries() throws {
        let f = try fixture()
        let bonus = OfferOneOff(label: "Signing bonus", amountMinorUnits: 300_000, month: utc(2026, 4, 1))
        let scenario = try create(f, spec(f, oneOffs: [bonus]))
        // A manual edit of the scenario, unrelated to the offer.
        let manual = try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, categoryId: f.pensionCategoryId, amountMinorUnits: -9_900, frequency: .monthly, interval: 1,
                                 startDate: self.utc(2026, 7, 1), endDate: nil, scenarioId: scenario.id!)
        }
        // A scenario entry the person added with a note like the builder's: not the offer's, so it stays.
        let lookalike = try f.manager.dbQueue.write { db in
            var e = try PlannedItems.add(db: db, categoryId: f.salaryCategoryId, amountMinorUnits: 1_000, frequency: .once, interval: 1,
                                         startDate: self.utc(2026, 8, 1), endDate: nil, scenarioId: scenario.id!)
            e.note = "Offer: my own note"
            try e.update(db)
            return e
        }
        let countBefore = try entries(f, scenario).count

        var richer = offer
        richer.grossAnnual = 6_000_000
        let newSpec = spec(f, gap: 1, offer: richer)
        try f.manager.dbQueue.write { db in try OfferScenarioBuilder.rebuild(db: db, scenarioId: scenario.id!, spec: newSpec) }

        let all = try entries(f, scenario)
        let after = try f.manager.dbQueue.read { db in try Scenario.fetchAll(db) }
        XCTAssertEqual(after.map(\.id), [scenario.id])
        XCTAssertEqual(after.map(\.name), ["New job"])
        XCTAssertEqual(try f.manager.dbQueue.read { db in try OfferScenarioBuilder.spec(db: db, scenarioId: scenario.id!) }?.inputs, newSpec)
        XCTAssertTrue(all.contains { $0.id == manual.id && $0.amountMinorUnits == -9_900 })
        XCTAssertTrue(all.contains { $0.id == lookalike.id })
        let salaries = all.filter { $0.scenarioChange == .added && $0.categoryId == f.salaryCategoryId && $0.frequency == .monthly }
        XCTAssertEqual(salaries.map(\.amountMinorUnits), [SalaryCalculator.calculate(richer).takeHomeMonthly])
        XCTAssertEqual(salaries.map(\.startDate), [utc(2026, 5, 1)])
        XCTAssertEqual(all.filter { $0.frequency == .once }.map(\.id), [lookalike.id])   // the bonus is gone with the old spec
        // One copy per budget entry, still ended before the start month; no orphans.
        XCTAssertEqual(all.filter { $0.sourceEntryId == f.salaryEntryId }.map(\.endDate), [utc(2026, 3, 31)])
        XCTAssertEqual(all.filter { $0.sourceEntryId == f.pensionEntryId }.count, 1)
        XCTAssertEqual(all.filter { $0.scenarioChange == .added && $0.categoryId == f.pensionCategoryId && $0.id != manual.id }.count, 1)
        XCTAssertEqual(all.count, countBefore - 1)   // the bonus
    }

    func testDeleteScenarioRemovesOfferEntries() throws {
        let f = try fixture()
        let before = try budget(f)
        let bonus = OfferOneOff(label: "Signing bonus", amountMinorUnits: 300_000, month: utc(2026, 4, 1))
        let scenario = try create(f, spec(f, oneOffs: [bonus]))
        try f.manager.dbQueue.write { db in try Scenarios.delete(db: db, scenarioId: scenario.id!) }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try ForecastEntry.filter(Column("scenarioId") != nil).fetchCount(db) }, 0)
        XCTAssertEqual(try budget(f), before)
    }

    func testDuplicateNameThrowsScenarioError() throws {
        let f = try fixture()
        _ = try create(f, spec(f))
        XCTAssertThrowsError(try create(f, spec(f))) { XCTAssertEqual($0 as? ScenarioError, .duplicateName) }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Scenario.fetchCount(db) }, 1)
    }

    func testSalaryCandidates() throws {
        let f = try fixture()
        try f.manager.dbQueue.write { db in
            var newer = ForecastEntry(groupId: f.groupId, categoryId: f.salaryCategoryId, amountMinorUnits: 10_000, frequency: .monthly, interval: 1,
                                      startDate: self.utc(2026, 3, 1), endDate: nil, isEnabled: true, status: .manual, note: nil)
            try newer.insert(db)
            var disabled = newer
            disabled.id = nil
            disabled.isEnabled = false
            try disabled.insert(db)
            var once = newer
            once.id = nil
            once.frequency = .once
            try once.insert(db)
            _ = try Scenarios.create(db: db, name: "Copy")
        }
        let candidates = try f.manager.dbQueue.read { db in try OfferScenarioBuilder.salaryCandidates(db: db) }
        XCTAssertEqual(candidates.map(\.startDate), [utc(2026, 3, 1), utc(2026, 1, 1)])
        XCTAssertTrue(candidates.allSatisfy { $0.scenarioId == nil })
    }

    // MARK: - Migration

    func testMigrationAddsColumnAndOldRowsReadNil() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "createScenarios")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO scenario (name, createdAt) VALUES ('Old', '2026-01-01 00:00:00.000')")
        }
        try manager.migrate()
        try manager.dbQueue.read { db in
            XCTAssertTrue(try db.columns(in: "scenario").map(\.name).contains("offerInputs"))
            let old = try XCTUnwrap(try Scenario.fetchOne(db))
            XCTAssertEqual(old.name, "Old")
            XCTAssertNil(old.offerInputs)
        }
    }

    // MARK: - Bonus

    /// A bonus paid once a year: a normal month's take-home monthly, and the bonus's net once a year in its month.
    func testYearlyBonusIsAnAnnualEntryInItsMonth() throws {
        let f = try fixture()
        var withBonus = offer
        withBonus.bonusAnnual = 500_000
        withBonus.bonusPayment = .yearly(month: 3)
        let result = SalaryCalculator.calculate(withBonus)
        let normal = try XCTUnwrap(result.normalMonth), bonusMonth = try XCTUnwrap(result.bonusMonth)
        let scenario = try create(f, spec(f, offer: withBonus))
        let added = try entries(f, scenario).filter { $0.scenarioChange == .added && $0.categoryId == f.salaryCategoryId }
        let monthly = try XCTUnwrap(added.first { $0.frequency == .monthly })
        XCTAssertEqual(monthly.amountMinorUnits, normal.takeHome)
        XCTAssertEqual(monthly.note, "Offer: salary")
        let yearly = try XCTUnwrap(added.first { $0.frequency == .annually })
        // A March bonus: nothing to even out after it, so it's the bonus month less a normal month.
        XCTAssertEqual(yearly.amountMinorUnits, bonusMonth.takeHome - normal.takeHome)
        XCTAssertEqual(yearly.amountMinorUnits, try XCTUnwrap(result.payslipsTakeHome) - 12 * normal.takeHome)
        XCTAssertEqual(yearly.startDate, utc(2027, 3, 1), "the first March from the April start")
        XCTAssertEqual(yearly.note, "Offer: bonus")
        XCTAssertEqual(yearly.accountId, f.accountId)

        // Spread monthly: today's behaviour, a twelfth of the year a month and no yearly entry.
        withBonus.bonusPayment = .monthly
        try f.manager.dbQueue.write { db in try OfferScenarioBuilder.rebuild(db: db, scenarioId: scenario.id!, spec: self.spec(f, offer: withBonus)) }
        let rebuilt = try entries(f, scenario).filter { $0.scenarioChange == .added && $0.categoryId == f.salaryCategoryId }
        XCTAssertEqual(rebuilt.map(\.frequency), [.monthly], "the rebuild took the yearly entry away")
        XCTAssertEqual(rebuilt.first?.amountMinorUnits, SalaryCalculator.roundHalfUp(SalaryCalculator.calculate(withBonus).takeHomeAnnual, 12))
    }

    func testYearlyBonusStartsInTheStartMonthWhenItIsTheBonusMonth() throws {
        let f = try fixture()
        var withBonus = offer
        withBonus.bonusAnnual = 500_000
        withBonus.bonusPayment = .yearly(month: 4)
        let scenario = try create(f, spec(f, offer: withBonus))
        let yearly = try XCTUnwrap(try entries(f, scenario).first { $0.frequency == .annually })
        XCTAssertEqual(yearly.startDate, utc(2026, 4, 1))
    }

    // MARK: - Combined (step 17)

    /// Two offers both change the salary and the pension: combined, the later offer's whole
    /// package is used (never both salaries), with a notice for each item.
    func testTwoOffersCombinedUseTheLaterOfferOnly() throws {
        let f = try fixture()
        let other = SalaryInputs(grossAnnual: 4_600_000, taxYearStart: 2026, pension: .percentOfGross(basisPoints: 500),
                                 employerPension: .percentOfGross(basisPoints: 400))
        let first = try create(f, spec(f), name: "200")
        let second = try create(f, spec(f, gap: 1, offer: other), name: "220")
        let (combined, plans) = try f.manager.dbQueue.read { db -> (CombinedPlan, [ScenarioPlan]) in
            let groups = try ForecastGroup.fetchAll(db)
            func plan(_ entries: [ForecastEntry]) -> PlanInput { PlanInput(entries: entries, exceptions: [], groups: groups) }
            let plans = [ScenarioPlan(id: first.id!, name: "200", plan: plan(try ForecastEntry.inScenario(db, id: first.id!))),
                         ScenarioPlan(id: second.id!, name: "220", plan: plan(try ForecastEntry.inScenario(db, id: second.id!)))]
            return (ScenarioCombinator.combine(budget: plan(try ForecastEntry.budget(db)), scenarios: plans), plans)
        }
        let secondEntries = Set(plans[1].plan.entries.filter { $0.scenarioChange != nil }.compactMap(\.id))
        XCTAssertEqual(Set(combined.contributions.keys), secondEntries)
        let salaries = combined.plan.entries.filter { $0.categoryId == f.salaryCategoryId }
        XCTAssertEqual(salaries.count, 2) // the budget salary's copy, ended, and 220's take-home after it
        XCTAssertEqual(salaries.last?.amountMinorUnits, SalaryCalculator.calculate(other).takeHomeMonthly)
        XCTAssertEqual(salaries.last?.startDate, utc(2026, 5, 1))
        XCTAssertEqual(combined.overlaps.map(\.sourceEntryId).sorted(), [f.salaryEntryId, f.pensionEntryId].sorted())
        XCTAssertTrue(combined.overlaps.allSatisfy { $0.earlierScenarioId == first.id && $0.laterScenarioId == second.id })

        // Saved as a scenario, it holds the same: one offer salary.
        let saved = try f.manager.dbQueue.write { db in try Scenarios.createCombined(db: db, name: "Both", from: [first.id!, second.id!]) }
        let savedSalaries = try entries(f, saved).filter { $0.categoryId == f.salaryCategoryId && $0.scenarioChange == .added }
        XCTAssertEqual(savedSalaries.map(\.amountMinorUnits), [SalaryCalculator.calculate(other).takeHomeMonthly])
    }
}
