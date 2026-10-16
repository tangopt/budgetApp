import XCTest
import GRDB
@testable import BudgetCore

/// The property area's records (spec 2026-10-16 §1, §2): people, properties with owners by
/// date range, linked accounts and category groups, tenancies with rent history, rent receipts.
/// Synthetic names only.
final class PropertyModelTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func person(_ name: String) throws -> Int64 {
        try db.write { db in
            var person = Person(name: name)
            try People.save(db: db, &person)
            return person.id!
        }
    }

    private func property(_ name: String = "Property A") throws -> Int64 {
        try db.write { db in
            var property = Property(name: name, country: "pt")
            try Properties.save(db: db, &property)
            return property.id!
        }
    }

    private func tenancy(_ propertyId: Int64, contract: String? = "1001", start: Date = date(2023, 3, 1), end: Date? = nil) throws -> Int64 {
        try db.write { db in
            var tenancy = Tenancy(propertyId: propertyId, referenceLabel: "Room Contract AB", contractNumber: contract,
                                  tenantName: "Tenant B", startDate: start, endDate: end, advanceRentMonths: 2, depositMonths: 2)
            try Tenancies.save(db: db, &tenancy)
            return tenancy.id!
        }
    }

    @discardableResult
    private func receipt(_ tenancyId: Int64, _ number: String, month: Int, year: Int = 2025, status: RentReceiptStatus = .issued) throws -> RentReceipt {
        try db.write { db in
            let (start, _) = MonthRange.of(year: year, month: month)
            let end = MonthRange.calendar.date(byAdding: .day, value: -1, to: MonthRange.calendar.date(byAdding: .month, value: 1, to: start)!)!
            var receipt = RentReceipt(tenancyId: tenancyId, receiptNumber: number, periodStart: start, periodEnd: end,
                                      receiptDate: start, amountMinorUnits: 110_000, withholdingMinorUnits: 0, status: status)
            try RentReceipts.save(db: db, &receipt)
            return receipt
        }
    }

    private func linkDocument(to entity: EvidenceEntity) throws -> Int64 {
        try db.write { db in
            let sha = UUID().uuidString
            var document = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha.prefix(2))/\(sha).pdf", originalFileName: "doc.pdf",
                                            byteCount: 1, canonicalName: "Doc", kind: .rentReceipt, addedAt: Date())
            try document.insert(db)
            try EvidenceLinks.link(db: db, documentId: document.id!, to: entity)
            return document.id!
        }
    }

    private func setOwners(_ propertyId: Int64, _ owners: [PropertyOwner]) throws {
        try db.write { db in _ = try Properties.setOwners(db: db, propertyId: propertyId, owners) }
    }

    // MARK: People

    func testPeopleSaveTrimsAndRejectsBlankOrDuplicateNames() throws {
        try db.write { db in
            var a = Person(name: "  Person A ", shortName: " ", ukUtr: " 1234567890 ", ptNif: "")
            try People.save(db: db, &a)
            XCTAssertEqual(a.name, "Person A")
            XCTAssertNil(a.shortName)
            XCTAssertEqual(a.ukUtr, "1234567890")
            XCTAssertNil(a.ptNif)
            XCTAssertEqual(a.displayShortName, "Person A")

            var blank = Person(name: "  ")
            XCTAssertThrowsError(try People.save(db: db, &blank)) { XCTAssertEqual($0 as? PropertyError, .blankName) }
            var duplicate = Person(name: "person a")
            XCTAssertThrowsError(try People.save(db: db, &duplicate)) { XCTAssertEqual($0 as? PropertyError, .duplicateName) }

            a.shortName = "A"
            try People.save(db: db, &a) // updating keeps its own name
            var b = Person(name: "Person B")
            try People.save(db: db, &b)
            XCTAssertEqual(try People.all(db: db).map(\.displayShortName), ["A", "Person B"])
        }
    }

    func testDeletingAPersonWhoOwnsIsRefused() throws {
        let a = try person("Person A")
        let p = try property()
        try setOwners(p, [PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 10_000)])
        try db.write { db in
            XCTAssertThrowsError(try People.delete(db: db, id: a)) { XCTAssertEqual($0 as? PropertyError, .personIsOwner) }
            _ = try Properties.setOwners(db: db, propertyId: p, [])
            XCTAssertTrue(try People.delete(db: db, id: a))
            XCTAssertFalse(try People.delete(db: db, id: a))
        }
    }

    // MARK: Properties

    func testPropertySaveNormalisesAndValidates() throws {
        try db.write { db in
            var property = Property(name: " Property A ", country: " pt ", matrixArticle: " U-1234 ", purchasePriceMinorUnits: 25_000_000,
                                    purchaseDate: Self.date(2015, 6, 1, hour: 15))
            try Properties.save(db: db, &property)
            XCTAssertEqual(property.name, "Property A")
            XCTAssertEqual(property.country, "PT")
            XCTAssertEqual(property.currency, .eur)
            XCTAssertEqual(property.matrixArticle, "U-1234")
            XCTAssertEqual(property.purchaseDate, Self.date(2015, 6, 1))
            XCTAssertEqual(try Property.fetchOne(db, key: property.id!), property)

            var badCountry = Property(name: "Property B", country: "Portugal")
            XCTAssertThrowsError(try Properties.save(db: db, &badCountry)) { XCTAssertEqual($0 as? PropertyError, .invalidCountry) }
            var duplicate = Property(name: "PROPERTY A", country: "GB")
            XCTAssertThrowsError(try Properties.save(db: db, &duplicate)) { XCTAssertEqual($0 as? PropertyError, .duplicateName) }
            var negative = Property(name: "Property C", country: "GB", purchasePriceMinorUnits: -1)
            XCTAssertThrowsError(try Properties.save(db: db, &negative)) { XCTAssertEqual($0 as? PropertyError, .negativeAmount) }
        }
    }

    // MARK: Ownership

    func testSharesAtADateFollowTheRanges() throws {
        let a = try person("Person A")
        let b = try person("Person B")
        let p = try property()
        // A owns 100% from 2015 to the end of 2019; then A and B 50/50.
        try setOwners(p, [
            PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 10_000, fromDate: Self.date(2015, 6, 1), toDate: Self.date(2019, 12, 31)),
            PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 5_000, fromDate: Self.date(2020, 1, 1)),
            PropertyOwner(propertyId: p, personId: b, shareBasisPoints: 5_000, fromDate: Self.date(2020, 1, 1))
        ])
        try db.read { db in
            XCTAssertEqual(try Properties.shares(db: db, propertyId: p, at: Self.date(2015, 5, 31)), [])
            XCTAssertEqual(try Properties.shares(db: db, propertyId: p, at: Self.date(2019, 12, 31, hour: 18)),
                           [PropertyShare(personId: a, shareBasisPoints: 10_000)])
            XCTAssertEqual(try Properties.shares(db: db, propertyId: p, at: Self.date(2020, 1, 1)),
                           [PropertyShare(personId: a, shareBasisPoints: 5_000), PropertyShare(personId: b, shareBasisPoints: 5_000)])
            XCTAssertEqual(try Properties.share(db: db, propertyId: p, personId: b, at: Self.date(2018, 1, 1)), 0)
            XCTAssertEqual(try Properties.share(db: db, propertyId: p, personId: b, at: Self.date(2030, 1, 1)), 5_000)
            XCTAssertEqual(try Properties.shares(db: db, propertyId: p, at: Self.date(2030, 1, 1)).map(\.fraction), [0.5, 0.5])
            XCTAssertEqual(try Properties.owners(db: db, propertyId: p).count, 3)
        }
    }

    func testOwnershipMustSumToWholeAtEveryDate() throws {
        let a = try person("Person A")
        let b = try person("Person B")
        let p = try property()
        func expect(_ owners: [PropertyOwner], _ error: PropertyError, line: UInt = #line) {
            XCTAssertThrowsError(try setOwners(p, owners), line: line) { XCTAssertEqual($0 as? PropertyError, error, line: line) }
        }
        expect([PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 6_000),
                PropertyOwner(propertyId: p, personId: b, shareBasisPoints: 5_000)],
               .sharesDoNotSumToWhole(date: nil, totalBasisPoints: 11_000))
        // B joins a year after A: A's 50% alone in 2015.
        expect([PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 5_000, fromDate: Self.date(2015, 1, 1)),
                PropertyOwner(propertyId: p, personId: b, shareBasisPoints: 5_000, fromDate: Self.date(2016, 1, 1))],
               .sharesDoNotSumToWhole(date: Self.date(2015, 1, 1), totalBasisPoints: 5_000))
        // B leaves before A: A's 50% alone from the day after B's last day.
        expect([PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 5_000),
                PropertyOwner(propertyId: p, personId: b, shareBasisPoints: 5_000, toDate: Self.date(2020, 6, 30))],
               .sharesDoNotSumToWhole(date: Self.date(2020, 7, 1), totalBasisPoints: 5_000))
        expect([PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 0)], .invalidShare)
        expect([PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 10_001)], .invalidShare)
        expect([PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 10_000, fromDate: Self.date(2020, 1, 2), toDate: Self.date(2020, 1, 1))],
               .invalidDateRange)
        expect([PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 5_000, toDate: Self.date(2020, 1, 1)),
                PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 5_000, fromDate: Self.date(2020, 1, 1))],
               .overlappingOwnership(personId: a))
        expect([PropertyOwner(propertyId: p, personId: 999, shareBasisPoints: 10_000)], .personNotFound)
        XCTAssertThrowsError(try db.write { db in try Properties.setOwners(db: db, propertyId: 999, []) }) {
            XCTAssertEqual($0 as? PropertyError, .propertyNotFound)
        }

        // Valid: a sale ends ownership (a gap with no owners is fine), thirds may round.
        let c = try person("Person C")
        try setOwners(p, [
            PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 3_334, fromDate: Self.date(2015, 1, 1), toDate: Self.date(2020, 12, 31)),
            PropertyOwner(propertyId: p, personId: b, shareBasisPoints: 3_333, fromDate: Self.date(2015, 1, 1), toDate: Self.date(2020, 12, 31)),
            PropertyOwner(propertyId: p, personId: c, shareBasisPoints: 3_333, fromDate: Self.date(2015, 1, 1), toDate: Self.date(2020, 12, 31))
        ])
        // A failed replacement keeps the saved history.
        expect([PropertyOwner(propertyId: p, personId: a, shareBasisPoints: 1)], .sharesDoNotSumToWhole(date: nil, totalBasisPoints: 1))
        try db.read { db in
            XCTAssertEqual(try Properties.owners(db: db, propertyId: p).map(\.shareBasisPoints), [3_334, 3_333, 3_333])
            XCTAssertEqual(try Properties.shares(db: db, propertyId: p, at: Self.date(2021, 1, 1)), [])
        }
    }

    // MARK: Accounts and category groups

    func testAccountsByRoleAndCategoryGroups() throws {
        let p = try property()
        let (current, mortgage, group) = try db.write { db -> (Int64, Int64, Int64) in
            var current = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try current.insert(db)
            var mortgage = Account(name: "Bank A mortgage", currency: .eur, kind: .cash, trackingMode: .imported)
            try mortgage.insert(db)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            return (current.id!, mortgage.id!, group.id!)
        }
        try db.write { db in
            try Properties.setAccount(db: db, propertyId: p, accountId: mortgage, role: .mortgage)
            try Properties.setAccount(db: db, propertyId: p, accountId: current, role: .other)
            let changed = try Properties.setAccount(db: db, propertyId: p, accountId: current, role: .current)
            XCTAssertEqual(changed.role, .current)
            XCTAssertEqual(try Properties.accounts(db: db, propertyId: p).map(\.accountId), [current, mortgage])
            XCTAssertEqual(try Properties.accounts(db: db, propertyId: p, role: .mortgage).map(\.accountId), [mortgage])
            XCTAssertEqual(try Properties.properties(db: db, accountId: current).map(\.propertyId), [p])
            XCTAssertThrowsError(try Properties.setAccount(db: db, propertyId: p, accountId: 999, role: .other)) {
                XCTAssertEqual($0 as? PropertyError, .accountNotFound)
            }
            XCTAssertTrue(try Properties.removeAccount(db: db, propertyId: p, accountId: mortgage))
            XCTAssertFalse(try Properties.removeAccount(db: db, propertyId: p, accountId: mortgage))

            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group)
            XCTAssertEqual(try Properties.categoryGroupIds(db: db, propertyId: p), [group])
            XCTAssertThrowsError(try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: 999)) {
                XCTAssertEqual($0 as? PropertyError, .categoryGroupNotFound)
            }
            // Deleting the account or group drops the link.
            _ = try Account.deleteOne(db, key: current)
            _ = try CategoryGroup.deleteOne(db, key: group)
            XCTAssertEqual(try Properties.accounts(db: db, propertyId: p), [])
            XCTAssertEqual(try Properties.categoryGroupIds(db: db, propertyId: p), [])
        }
    }

    // MARK: Tenancies

    func testTenancySaveValidatesAndContractNumbersAreUniquePerProperty() throws {
        let p = try property()
        let q = try property("Property B")
        let first = try tenancy(p, contract: " 1001 ", start: Self.date(2022, 1, 1), end: Self.date(2023, 2, 28))
        let second = try tenancy(p, contract: "1002", start: Self.date(2023, 3, 1))
        _ = try tenancy(q, contract: "1001") // another property may reuse the number
        _ = try tenancy(p, contract: nil)
        _ = try tenancy(p, contract: "  ") // blank = none
        try db.write { db in
            XCTAssertEqual(try Tenancies.tenancy(db: db, propertyId: p, contractNumber: "1001")?.id, first)
            XCTAssertNil(try Tenancies.tenancy(db: db, propertyId: p, contractNumber: "9999"))
            var duplicate = Tenancy(propertyId: p, referenceLabel: "Other", contractNumber: "1002", startDate: Self.date(2025, 1, 1))
            XCTAssertThrowsError(try Tenancies.save(db: db, &duplicate)) { XCTAssertEqual($0 as? PropertyError, .duplicateContractNumber) }
            var blank = Tenancy(propertyId: p, referenceLabel: " ", startDate: Self.date(2025, 1, 1))
            XCTAssertThrowsError(try Tenancies.save(db: db, &blank)) { XCTAssertEqual($0 as? PropertyError, .blankReference) }
            var backwards = Tenancy(propertyId: p, referenceLabel: "X", startDate: Self.date(2025, 1, 2), endDate: Self.date(2025, 1, 1))
            XCTAssertThrowsError(try Tenancies.save(db: db, &backwards)) { XCTAssertEqual($0 as? PropertyError, .invalidDateRange) }
            var negative = Tenancy(propertyId: p, referenceLabel: "X", startDate: Self.date(2025, 1, 1), depositMonths: -1)
            XCTAssertThrowsError(try Tenancies.save(db: db, &negative)) { XCTAssertEqual($0 as? PropertyError, .negativeMonths) }
            var orphan = Tenancy(propertyId: 999, referenceLabel: "X", startDate: Self.date(2025, 1, 1))
            XCTAssertThrowsError(try Tenancies.save(db: db, &orphan)) { XCTAssertEqual($0 as? PropertyError, .propertyNotFound) }

            let all = try Tenancies.all(db: db, propertyId: p)
            XCTAssertEqual(all.first?.id, first)
            XCTAssertEqual(all.first?.contractNumber, "1001")
            XCTAssertEqual(all.count, 4)
            XCTAssertEqual(try Tenancies.active(db: db, propertyId: p, at: Self.date(2023, 2, 28, hour: 20)).map(\.id), [first])
            XCTAssertTrue(try Tenancies.active(db: db, propertyId: p, at: Self.date(2025, 1, 1)).map(\.id).contains(second))
            XCTAssertFalse(try Tenancies.active(db: db, propertyId: p, at: Self.date(2025, 1, 1)).map(\.id).contains(first))
        }
    }

    func testRentAtADateFollowsTheHistoryWithinTheTenancy() throws {
        let p = try property()
        let t = try tenancy(p, start: Self.date(2021, 3, 1), end: Self.date(2025, 2, 28))
        try db.write { db in
            try Tenancies.setRents(db: db, tenancyId: t, [
                TenancyRent(tenancyId: 0, fromDate: Self.date(2023, 3, 1), monthlyAmountMinorUnits: 110_000),
                TenancyRent(tenancyId: 0, fromDate: Self.date(2021, 3, 1), monthlyAmountMinorUnits: 100_000)
            ])
            XCTAssertEqual(try Tenancies.rents(db: db, tenancyId: t).map(\.monthlyAmountMinorUnits), [100_000, 110_000])
            XCTAssertNil(try Tenancies.rent(db: db, tenancyId: t, at: Self.date(2021, 2, 28)))
            XCTAssertEqual(try Tenancies.rent(db: db, tenancyId: t, at: Self.date(2021, 3, 1)), 100_000)
            XCTAssertEqual(try Tenancies.rent(db: db, tenancyId: t, at: Self.date(2023, 2, 28, hour: 12)), 100_000)
            XCTAssertEqual(try Tenancies.rent(db: db, tenancyId: t, at: Self.date(2023, 3, 1)), 110_000)
            XCTAssertEqual(try Tenancies.rent(db: db, tenancyId: t, at: Self.date(2025, 2, 28)), 110_000)
            XCTAssertNil(try Tenancies.rent(db: db, tenancyId: t, at: Self.date(2025, 3, 1)))

            try Tenancies.setRent(db: db, tenancyId: t, from: Self.date(2023, 3, 1, hour: 9), monthlyAmountMinorUnits: 115_000)
            XCTAssertEqual(try Tenancies.rents(db: db, tenancyId: t).map(\.monthlyAmountMinorUnits), [100_000, 115_000])

            XCTAssertThrowsError(try Tenancies.setRents(db: db, tenancyId: t, [
                TenancyRent(tenancyId: t, fromDate: Self.date(2024, 1, 1), monthlyAmountMinorUnits: 1),
                TenancyRent(tenancyId: t, fromDate: Self.date(2024, 1, 1, hour: 5), monthlyAmountMinorUnits: 2)
            ])) { XCTAssertEqual($0 as? PropertyError, .duplicateRentDate) }
            XCTAssertThrowsError(try Tenancies.setRent(db: db, tenancyId: t, from: Self.date(2025, 1, 1), monthlyAmountMinorUnits: -1)) {
                XCTAssertEqual($0 as? PropertyError, .negativeAmount)
            }
            XCTAssertThrowsError(try Tenancies.rent(db: db, tenancyId: 999, at: Date())) { XCTAssertEqual($0 as? PropertyError, .tenancyNotFound) }
        }
    }

    // MARK: Receipts

    func testReceiptsValidateAndAreUniquePerTenancy() throws {
        let p = try property()
        let t = try tenancy(p)
        let other = try tenancy(p, contract: "1002")
        let saved = try receipt(t, " 7 ", month: 1)
        XCTAssertEqual(saved.receiptNumber, "7")
        XCTAssertEqual(saved.amountReceivedMinorUnits, 110_000)
        _ = try receipt(other, "7", month: 1) // another contract may reuse the number
        XCTAssertThrowsError(try receipt(t, "7", month: 2)) { XCTAssertEqual($0 as? PropertyError, .duplicateReceiptNumber) }
        try db.write { db in
            var withheld = RentReceipt(tenancyId: t, receiptNumber: "8", periodStart: Self.date(2025, 2, 1), periodEnd: Self.date(2025, 2, 28),
                                       receiptDate: Self.date(2025, 2, 3, hour: 10), amountMinorUnits: 100_000, withholdingMinorUnits: 25_000)
            try RentReceipts.save(db: db, &withheld)
            XCTAssertEqual(withheld.amountReceivedMinorUnits, 75_000)
            XCTAssertEqual(withheld.receiptDate, Self.date(2025, 2, 3))
            XCTAssertEqual(try RentReceipts.receipt(db: db, tenancyId: t, receiptNumber: "8"), withheld)

            // Re-saving (e.g. the portal cancelled it) updates in place.
            withheld.status = .cancelled
            try RentReceipts.save(db: db, &withheld)
            XCTAssertEqual(try RentReceipt.fetchCount(db), 3)

            var backwards = RentReceipt(tenancyId: t, receiptNumber: "9", periodStart: Self.date(2025, 3, 2), periodEnd: Self.date(2025, 3, 1),
                                        receiptDate: Self.date(2025, 3, 1), amountMinorUnits: 1)
            XCTAssertThrowsError(try RentReceipts.save(db: db, &backwards)) { XCTAssertEqual($0 as? PropertyError, .invalidDateRange) }
            var tooMuch = RentReceipt(tenancyId: t, receiptNumber: "9", periodStart: Self.date(2025, 3, 1), periodEnd: Self.date(2025, 3, 31),
                                      receiptDate: Self.date(2025, 3, 1), amountMinorUnits: 1, withholdingMinorUnits: 2, amountReceivedMinorUnits: 0)
            XCTAssertThrowsError(try RentReceipts.save(db: db, &tooMuch)) { XCTAssertEqual($0 as? PropertyError, .invalidWithholding) }
            var blank = RentReceipt(tenancyId: t, receiptNumber: " ", periodStart: Self.date(2025, 3, 1), periodEnd: Self.date(2025, 3, 31),
                                    receiptDate: Self.date(2025, 3, 1), amountMinorUnits: 1)
            XCTAssertThrowsError(try RentReceipts.save(db: db, &blank)) { XCTAssertEqual($0 as? PropertyError, .blankReceiptNumber) }
            var orphan = RentReceipt(tenancyId: 999, receiptNumber: "1", periodStart: Self.date(2025, 3, 1), periodEnd: Self.date(2025, 3, 31),
                                     receiptDate: Self.date(2025, 3, 1), amountMinorUnits: 1)
            XCTAssertThrowsError(try RentReceipts.save(db: db, &orphan)) { XCTAssertEqual($0 as? PropertyError, .tenancyNotFound) }
        }
        // The database enforces one number per tenancy too.
        try db.write { db in
            var raw = saved
            raw.id = nil
            XCTAssertThrowsError(try raw.insert(db))
        }
    }

    func testReceiptsForAPeriodByRentPeriodOverlap() throws {
        let p = try property()
        let t = try tenancy(p)
        let u = try tenancy(p, contract: "1002")
        try receipt(t, "1", month: 3)
        try receipt(t, "2", month: 4)
        try receipt(t, "3", month: 5, status: .cancelled)
        try receipt(u, "1", month: 4)
        try receipt(t, "4", month: 6)
        // The UK tax year 2025/26 starts 6 April: March's receipt is out, April's in.
        let taxYear = UKTaxYear(startYear: 2025).interval
        try db.read { db in
            XCTAssertEqual(try RentReceipts.receipts(db: db, propertyId: p, overlapping: taxYear).map(\.receiptNumber), ["2", "1", "4"])
            XCTAssertEqual(try RentReceipts.receipts(db: db, propertyId: p, overlapping: taxYear, includeCancelled: true).map(\.receiptNumber),
                           ["2", "1", "3", "4"])
            let april = DateInterval(start: Self.date(2025, 4, 1), end: Self.date(2025, 5, 1))
            XCTAssertEqual(try RentReceipts.receipts(db: db, tenancyId: t, overlapping: april).map(\.receiptNumber), ["2"])
            // A period starting on a receipt's last day (31 Mar) still meets it.
            let fromLastDay = DateInterval(start: Self.date(2025, 3, 31, hour: 12), end: Self.date(2025, 4, 1))
            XCTAssertEqual(try RentReceipts.receipts(db: db, tenancyId: t, overlapping: fromLastDay).map(\.receiptNumber), ["1"])
            XCTAssertEqual(try RentReceipts.receipts(db: db, tenancyId: t).map(\.receiptNumber), ["1", "2", "4"])
            XCTAssertEqual(try RentReceipts.receipts(db: db, tenancyId: t, includeCancelled: true).count, 4)
        }
    }

    // MARK: Evidence

    func testEvidenceLinksRequireTheRecordAndGoWithIt() throws {
        let a = try person("Person A")
        let p = try property()
        let t = try tenancy(p)
        let r = try receipt(t, "1", month: 1).id!
        XCTAssertThrowsError(try linkDocument(to: .tenancy(999))) { XCTAssertEqual($0 as? EvidenceLibraryError, .entityNotFound) }
        XCTAssertThrowsError(try linkDocument(to: .rentReceipt(999)))
        XCTAssertThrowsError(try linkDocument(to: .property(999)))
        XCTAssertThrowsError(try linkDocument(to: .person(999)))
        for entity in [EvidenceEntity.person(a), .property(p), .tenancy(t), .rentReceipt(r)] { _ = try linkDocument(to: entity) }

        try db.write { db in
            // Requirements and waivers on the records.
            var contract = EvidenceRequirement(name: "Contract", scope: .single(entity: .tenancy(t)), kinds: [.other])
            try EvidenceRequirements.save(db: db, &contract)
            var receipts = EvidenceRequirement(name: "Receipts", scope: .periodic(entity: .tenancy(t), every: .month), kinds: [.rentReceipt])
            try EvidenceRequirements.save(db: db, &receipts)
            var deed = EvidenceRequirement(name: "Deed", scope: .single(entity: .property(p)), kinds: [.propertyDeed])
            try EvidenceRequirements.save(db: db, &deed)
            var categoryRule = EvidenceRequirement(name: "Category", scope: .transactionsInCategoryGroup(groupId: t), kinds: [])
            try EvidenceRequirements.save(db: db, &categoryRule)
            // The waiver sits on a requirement that survives, so only the receipt's trigger removes it.
            try EvidenceRequirements.waive(db: db, requirementId: categoryRule.id!, target: .init(entity: .rentReceipt(r)))
            XCTAssertEqual(try EvidenceWaiver.fetchCount(db), 1)

            // Deleting the property cascades to the tenancy and receipt: every link, waiver
            // and record-scoped requirement of all three goes; the person's link stays.
            XCTAssertTrue(try Properties.delete(db: db, id: p))
            XCTAssertEqual(try Tenancy.fetchCount(db), 0)
            XCTAssertEqual(try RentReceipt.fetchCount(db), 0)
            XCTAssertEqual(try DocumentLink.fetchAll(db).map(\.entity), [.person(a)])
            XCTAssertEqual(try EvidenceWaiver.fetchCount(db), 0)
            XCTAssertEqual(try EvidenceRequirements.all(db: db).map(\.name), ["Category"])

            XCTAssertTrue(try People.delete(db: db, id: a))
            XCTAssertEqual(try DocumentLink.fetchCount(db), 0)
        }
    }

    func testDeletingAReceiptOrTenancyDropsItsLinksOnly() throws {
        let p = try property()
        let t = try tenancy(p)
        let r1 = try receipt(t, "1", month: 1).id!
        let r2 = try receipt(t, "2", month: 2).id!
        _ = try linkDocument(to: .rentReceipt(r1))
        _ = try linkDocument(to: .rentReceipt(r2))
        _ = try linkDocument(to: .tenancy(t))
        _ = try linkDocument(to: .property(p))
        try db.write { db in
            XCTAssertTrue(try RentReceipts.delete(db: db, id: r1))
            XCTAssertEqual(Set(try DocumentLink.fetchAll(db).map(\.entity)), [.rentReceipt(r2), .tenancy(t), .property(p)])
            XCTAssertTrue(try Tenancies.delete(db: db, id: t))
            XCTAssertEqual(try DocumentLink.fetchAll(db).map(\.entity), [.property(p)])
            // Documents themselves stay in the library.
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 4)
        }
    }
}
