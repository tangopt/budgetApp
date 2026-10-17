import XCTest
import GRDB
@testable import BudgetCore

/// Employments, pay and tax, P11D benefits, other income, pensions and HMRC payments, and the
/// P60 / P45 / P11D reader and import (plan phase 4 Task 1). Synthetic people, employers and amounts.
final class PersonalIncomeTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var personA: Int64 = 0
    private var personB: Int64 = 0

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var a = Person(name: "Person A", shortName: "A", ukNino: "QQ 12 34 56 C")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            personA = a.id!; personB = b.id!
        }
    }

    private func addDocument(_ db: Database, sha: String = UUID().uuidString, kind: DocumentKind = .other) throws -> EvidenceDocument {
        var document = EvidenceDocument(sha256: sha, storedRelativePath: "aa/\(sha).pdf", originalFileName: "form.pdf", byteCount: 1, kind: kind, addedAt: Date())
        try document.insert(db)
        return document
    }

    // MARK: Records

    func testEmploymentSaveNormalisesAndValidates() throws {
        try db.write { db in
            var employment = Employment(startYear: 2024, personId: personA, employerName: "  Example Ltd ", payeReference: "123 / ab456",
                                        endDate: Self.date(2025, 3, 1))
            try Employments.save(db: db, &employment)
            XCTAssertEqual(employment.employerName, "Example Ltd")
            XCTAssertEqual(employment.payeReference, "123/AB456")

            var blank = Employment(startYear: 2024, personId: personA, employerName: " ")
            XCTAssertThrowsError(try Employments.save(db: db, &blank)) { XCTAssertEqual($0 as? PersonalIncomeError, .blankEmployer) }
            var badReference = Employment(startYear: 2024, personId: personA, employerName: "X", payeReference: "12/AB")
            XCTAssertThrowsError(try Employments.save(db: db, &badReference)) { XCTAssertEqual($0 as? PersonalIncomeError, .invalidPAYEReference) }
            var backwards = Employment(startYear: 2024, personId: personA, employerName: "X", startDate: Self.date(2024, 9, 1), endDate: Self.date(2024, 8, 1))
            XCTAssertThrowsError(try Employments.save(db: db, &backwards)) { XCTAssertEqual($0 as? PersonalIncomeError, .invalidDates) }
            var nobody = Employment(startYear: 2024, personId: 999, employerName: "X")
            XCTAssertThrowsError(try Employments.save(db: db, &nobody)) { XCTAssertEqual($0 as? PersonalIncomeError, .personNotFound) }
        }
    }

    func testFindByReferenceThenByName() throws {
        try db.write { db in
            var first = Employment(startYear: 2024, personId: personA, employerName: "Example Ltd", payeReference: "123/AB456")
            try Employments.save(db: db, &first)
            var second = Employment(startYear: 2024, personId: personA, employerName: "Other Company Limited")
            try Employments.save(db: db, &second)
            XCTAssertEqual(try Employments.find(db: db, startYear: 2024, personId: personA, payeReference: "123/ab456", employerName: "Renamed")?.id, first.id)
            XCTAssertEqual(try Employments.find(db: db, startYear: 2024, personId: personA, payeReference: nil, employerName: "EXAMPLE LTD.")?.id, first.id)
            // A different reference doesn't match a name whose employment has another reference.
            XCTAssertNil(try Employments.find(db: db, startYear: 2024, personId: personA, payeReference: "999/ZZ1", employerName: "Example Ltd"))
            XCTAssertEqual(try Employments.find(db: db, startYear: 2024, personId: personA, payeReference: "999/ZZ1", employerName: "other company limited")?.id, second.id)
            XCTAssertNil(try Employments.find(db: db, startYear: 2023, personId: personA, payeReference: "123/AB456", employerName: nil))
            XCTAssertNil(try Employments.find(db: db, startYear: 2024, personId: personB, payeReference: "123/AB456", employerName: nil))
        }
    }

    func testEffectiveIncomePrefersP60ThenP45ThenPayslips() throws {
        try db.write { db in
            var employment = Employment(startYear: 2024, personId: personA, employerName: "Example Ltd")
            try Employments.save(db: db, &employment)
            let id = employment.id!
            XCTAssertNil(try Employments.effectiveIncome(db: db, employmentId: id))
            for (pay, tax) in [(100_000, 20_000), (150_000, 30_000)] {
                var slip = EmploymentIncome(employmentId: id, source: .payslip, payMinorUnits: pay, taxDeductedMinorUnits: tax)
                try Employments.save(db: db, &slip)
            }
            XCTAssertEqual(try Employments.effectiveIncome(db: db, employmentId: id)?.payMinorUnits, 250_000)
            XCTAssertEqual(try Employments.effectiveIncome(db: db, employmentId: id)?.taxDeductedMinorUnits, 50_000)
            var p45 = EmploymentIncome(employmentId: id, source: .p45, payMinorUnits: 300_000, taxDeductedMinorUnits: 60_000, taxCode: " 1257 l ",
                                       periodEnd: Self.date(2024, 9, 30))
            try Employments.save(db: db, &p45)
            XCTAssertEqual(p45.taxCode, "1257L")
            XCTAssertEqual(try Employments.effectiveIncome(db: db, employmentId: id)?.source, .p45)
            var p60 = EmploymentIncome(employmentId: id, source: .p60, payMinorUnits: 400_000, taxDeductedMinorUnits: 80_000)
            try Employments.save(db: db, &p60)
            let effective = try Employments.effectiveIncome(db: db, employmentId: id)
            XCTAssertEqual(effective?.source, .p60)
            XCTAssertEqual(effective?.payMinorUnits, 400_000)
            XCTAssertEqual(try Employments.incomes(db: db, employmentId: id).map(\.source), [.p60, .p45, .payslip, .payslip])

            var negative = EmploymentIncome(employmentId: id, source: .other, payMinorUnits: -1, taxDeductedMinorUnits: 0)
            XCTAssertThrowsError(try Employments.save(db: db, &negative)) { XCTAssertEqual($0 as? PersonalIncomeError, .negativeAmount) }
            var orphan = EmploymentIncome(employmentId: 999, source: .p60, payMinorUnits: 1, taxDeductedMinorUnits: 0)
            XCTAssertThrowsError(try Employments.save(db: db, &orphan)) { XCTAssertEqual($0 as? PersonalIncomeError, .employmentNotFound) }
        }
    }

    func testBenefitKindsMapToSA102Boxes() {
        XCTAssertEqual(BenefitKind.car.sa102Box, 9)
        XCTAssertEqual(BenefitKind.vanFuel.sa102Box, 10)
        XCTAssertEqual(BenefitKind.medical.sa102Box, 11)
        XCTAssertEqual(BenefitKind.mileageAllowance.sa102Box, 12)
        XCTAssertEqual(BenefitKind.assetsAtDisposal.sa102Box, 13)
        XCTAssertEqual(BenefitKind.livingAccommodation.sa102Box, 14)
        XCTAssertEqual(BenefitKind.loans.sa102Box, 15)
        XCTAssertEqual(BenefitKind.expensesPayments.sa102Box, 16)
        XCTAssertEqual(BenefitKind.kind(p11dSection: "F", box: 10), .carFuel)
        XCTAssertEqual(BenefitKind.kind(p11dSection: "i", box: 11), .medical)
        XCTAssertNil(BenefitKind.kind(p11dSection: "Z", box: 15))
        for kind in BenefitKind.allCases where kind != .other {
            XCTAssertEqual(BenefitKind.kind(p11dSection: kind.p11dSection!, box: kind.sa102Box), kind)
        }
    }

    func testOtherIncomePensionsAndHMRCPayments() throws {
        try db.write { db in
            var interest = OtherIncome(startYear: 2025, personId: personA, kind: .ukInterest, payer: " Example Bank ", amountMinorUnits: 12_345)
            try OtherIncomes.save(db: db, &interest)
            XCTAssertEqual(interest.payer, "Example Bank")
            XCTAssertEqual(try OtherIncomes.incomes(db: db, startYear: 2025, personId: personA).count, 1)
            var pension = PensionContribution(startYear: 2025, personId: personA, kind: .reliefAtSource, paidMinorUnits: 80_000)
            try PensionContributions.save(db: db, &pension)
            XCTAssertEqual(try PensionContributions.contributions(db: db, startYear: 2025, personId: personA).map(\.paidMinorUnits), [80_000])

            var balancing = HMRCPayment(personId: personA, startYear: 2024, date: Self.date(2026, 1, 20), amountMinorUnits: 500_000, kind: .balancingPayment)
            try HMRCPayments.save(db: db, &balancing)
            var refund = HMRCPayment(personId: personA, startYear: 2024, date: Self.date(2026, 3, 1), amountMinorUnits: 20_000, kind: .refund)
            try HMRCPayments.save(db: db, &refund)
            var nextYear = HMRCPayment(personId: personA, startYear: 2025, date: Self.date(2026, 1, 20), amountMinorUnits: 250_000,
                                       kind: .firstPaymentOnAccount)
            try HMRCPayments.save(db: db, &nextYear)
            XCTAssertEqual(try HMRCPayments.netPaid(db: db, personId: personA, startYear: 2024), 480_000)
            XCTAssertEqual(try HMRCPayments.payments(db: db, personId: personA).count, 3)
            var negative = HMRCPayment(personId: personA, startYear: 2024, date: Self.date(2026, 1, 1), amountMinorUnits: -1, kind: .other)
            XCTAssertThrowsError(try HMRCPayments.save(db: db, &negative)) { XCTAssertEqual($0 as? PersonalIncomeError, .negativeAmount) }
        }
    }

    func testDocumentsLinkAndDeletingDropsLinksAndCascades() throws {
        try db.write { db in
            var employment = Employment(startYear: 2024, personId: personA, employerName: "Example Ltd")
            try Employments.save(db: db, &employment)
            var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: 1, taxDeductedMinorUnits: 0)
            try Employments.save(db: db, &income)
            var benefit = BenefitInKind(employmentId: employment.id!, kind: .medical, cashEquivalentMinorUnits: 100)
            try Employments.save(db: db, &benefit)
            var payment = HMRCPayment(personId: personA, startYear: 2024, date: Self.date(2026, 1, 20), amountMinorUnits: 1, kind: .balancingPayment)
            try HMRCPayments.save(db: db, &payment)
            let p60 = try addDocument(db), p11d = try addDocument(db), proof = try addDocument(db)
            try EvidenceLinks.link(db: db, documentId: p60.id!, to: .employmentIncome(income.id!), role: "P60")
            try EvidenceLinks.link(db: db, documentId: p11d.id!, to: .employment(employment.id!), role: "P11D")
            try EvidenceLinks.link(db: db, documentId: proof.id!, to: .hmrcPayment(payment.id!))
            XCTAssertThrowsError(try EvidenceLinks.link(db: db, documentId: proof.id!, to: .otherIncome(999)))

            XCTAssertEqual(try TaxEvidence.title(db: db, entity: .employment(employment.id!)), "Example Ltd · 2024/25 · A")
            XCTAssertEqual(try TaxEvidence.title(db: db, entity: .employmentIncome(income.id!)), "P60 · Example Ltd · 2024/25 · A")
            XCTAssertEqual(try TaxEvidence.title(db: db, entity: .hmrcPayment(payment.id!)), "Balancing payment · 2024/25 · A")
            XCTAssertEqual(EvidenceEntityType.employmentIncome.displayName, "Pay and tax")

            try Employments.delete(db: db, id: employment.id!)
            XCTAssertEqual(try EmploymentIncome.fetchCount(db), 0)
            XCTAssertEqual(try BenefitInKind.fetchCount(db), 0)
            XCTAssertEqual(try DocumentLink.filter(Column("entityType") == EvidenceEntityType.employmentIncome.rawValue).fetchCount(db), 0)
            XCTAssertEqual(try DocumentLink.filter(Column("entityType") == EvidenceEntityType.employment.rawValue).fetchCount(db), 0)
            try HMRCPayments.delete(db: db, id: payment.id!)
            XCTAssertEqual(try DocumentLink.fetchCount(db), 0)

            // Deleting the person removes everything of theirs.
            var again = Employment(startYear: 2024, personId: personB, employerName: "Example Ltd")
            try Employments.save(db: db, &again)
            _ = try Person.deleteOne(db, key: personB)
            XCTAssertEqual(try Employment.fetchCount(db), 0)
        }
    }

    // MARK: Reading forms

    func testReadsP60WithFiguresOnTheirRows() throws {
        let url = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60RowLayout, name: "p60-rows.pdf")
        let extraction = PayrollFormReader.read(url)
        XCTAssertEqual(extraction.kind, .p60)
        XCTAssertEqual(extraction.entryMethod, .textLayer)
        XCTAssertEqual(extraction.startYear, 2024)
        XCTAssertEqual(extraction.employerName, "Example Ltd")
        XCTAssertEqual(extraction.payeReference, "123/AB456")
        XCTAssertEqual(extraction.nationalInsuranceNumber, "QQ123456C")
        XCTAssertEqual(extraction.taxCode, "1257L")
        XCTAssertEqual(extraction.payMinorUnits, 4_567_890)
        XCTAssertEqual(extraction.taxDeductedMinorUnits, 654_321)
        XCTAssertEqual(extraction.previousPayMinorUnits, 0)
        XCTAssertEqual(extraction.totalPayMinorUnits, 4_567_890)
        XCTAssertEqual(extraction.totalTaxMinorUnits, 654_321)
        XCTAssertEqual(extraction.warnings, [])
    }

    func testReadsARefundMarkedR() throws {
        let items = PayrollFormTestPDFs.p60RowLayout + [PayrollFormTestPDFs.Item("R", 540, 620)]
        let extraction = PayrollFormReader.read(PayrollFormTestPDFs.textPDF(items, name: "p60-refund.pdf"))
        XCTAssertEqual(extraction.payMinorUnits, 4_567_890)
        XCTAssertEqual(extraction.taxDeductedMinorUnits, -654_321)
    }

    func testAStrayRFarFromTheAmountIsNotARefund() throws {
        let items = PayrollFormTestPDFs.p60RowLayout + [PayrollFormTestPDFs.Item("R", 585, 620, size: 6)]
        let extraction = PayrollFormReader.read(PayrollFormTestPDFs.textPDF(items, name: "p60-stray.pdf"))
        XCTAssertEqual(extraction.taxDeductedMinorUnits, 654_321)
    }

    func testMissingEvidenceAsksForEachFormAndPaymentProof() throws {
        try db.write { db in
            let rules = try PersonalIncomeEvidence.seedRules(db: db)
            XCTAssertEqual(rules.count, 4)
            XCTAssertEqual(try PersonalIncomeEvidence.seedRules(db: db).count, 0)

            var stayed = Employment(startYear: 2024, personId: personA, employerName: "Example Ltd")
            try Employments.save(db: db, &stayed)
            var left = Employment(startYear: 2024, personId: personB, employerName: "Other Ltd", endDate: Self.date(2024, 9, 30))
            try Employments.save(db: db, &left)
            var benefit = BenefitInKind(employmentId: stayed.id!, kind: .medical, cashEquivalentMinorUnits: 10_000)
            try Employments.save(db: db, &benefit)
            var payment = HMRCPayment(personId: personA, startYear: 2023, date: Self.date(2025, 1, 31), amountMinorUnits: 50_000, kind: .balancingPayment)
            try HMRCPayments.save(db: db, &payment)
            var elsewhere = Employment(startYear: 2023, personId: personA, employerName: "Earlier Ltd")
            try Employments.save(db: db, &elsewhere)

            var items = try MissingEvidence.items(db: db, taxYear: UKTaxYear(startYear: 2024))
            XCTAssertEqual(items.map(\.title).sorted(), ["Balancing payment · 2023/24 · A",
                                                          "P11D · Example Ltd · 2024/25 · A", "P45 · Other Ltd · 2024/25 · B",
                                                          "P60 · Example Ltd · 2024/25 · A"].sorted())
            XCTAssertTrue(items.allSatisfy { $0.status == .missing })

            // A P60 imported onto the pay-and-tax row satisfies the employment's item.
            var income = EmploymentIncome(employmentId: stayed.id!, source: .p60, payMinorUnits: 1, taxDeductedMinorUnits: 0)
            try Employments.save(db: db, &income)
            let p60 = try addDocument(db, kind: .p60)
            try EvidenceLinks.link(db: db, documentId: p60.id!, to: .employmentIncome(income.id!), role: "P60")
            items = try MissingEvidence.items(db: db, taxYear: UKTaxYear(startYear: 2024))
            XCTAssertEqual(items.first { $0.title.hasPrefix("P60") }?.status, .satisfied)
            XCTAssertEqual(items.first { $0.title.hasPrefix("P11D") }?.status, .missing)
        }
    }

    func testReadsP60WithTwoLineLabelsAndTheLabelRepeatedInTheNotes() throws {
        let url = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60ColumnLayout, name: "p60-columns.pdf")
        let extraction = PayrollFormReader.read(url)
        XCTAssertEqual(extraction.kind, .p60)
        XCTAssertEqual(extraction.startYear, 2024)
        XCTAssertEqual(extraction.employerName, "EXAMPLE LIMITED")
        XCTAssertEqual(extraction.payeReference, "321/ZX987")
        XCTAssertEqual(extraction.taxCode, "K100")
        XCTAssertEqual(extraction.payMinorUnits, 12_345_678)
        XCTAssertEqual(extraction.taxDeductedMinorUnits, 4_567_812)
        XCTAssertNil(extraction.previousPayMinorUnits)
        XCTAssertEqual(extraction.totalPayMinorUnits, 12_345_678)
        XCTAssertEqual(extraction.warnings, [])
    }

    func testReadsP45FiguresUnderTheirLabels() throws {
        let url = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p45, name: "p45.pdf")
        let extraction = PayrollFormReader.read(url)
        XCTAssertEqual(extraction.kind, .p45)
        XCTAssertEqual(extraction.leavingDate, Self.date(2025, 5, 31))
        XCTAssertEqual(extraction.startYear, 2025)
        XCTAssertEqual(extraction.employerName, "Example Ltd")
        XCTAssertEqual(extraction.payeReference, "123/AB456")
        XCTAssertEqual(extraction.taxCode, "1257L")
        XCTAssertEqual(extraction.totalPayMinorUnits, 1_234_567)
        XCTAssertEqual(extraction.totalTaxMinorUnits, 234_567)
        // Box 7 is empty: this employment's figures are those to date.
        XCTAssertEqual(extraction.payMinorUnits, 1_234_567)
        XCTAssertEqual(extraction.taxDeductedMinorUnits, 234_567)
        XCTAssertEqual(extraction.warnings.count, 1)
        XCTAssertTrue(extraction.warnings[0].hasPrefix("Box 7 (this employment) is empty"))
    }

    func testReadsP11DCashEquivalentsBySectionAndBox() throws {
        let url = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p11d, name: "p11d.pdf")
        let extraction = PayrollFormReader.read(url)
        XCTAssertEqual(extraction.kind, .p11d)
        XCTAssertEqual(extraction.startYear, 2024)
        XCTAssertEqual(extraction.employerName, "Example Ltd")
        XCTAssertEqual(extraction.payeReference, "123/AB456")
        XCTAssertEqual(extraction.benefits, [
            .init(kind: .car, cashEquivalentMinorUnits: 300_000),
            .init(kind: .medical, cashEquivalentMinorUnits: 123_456),
            .init(kind: .otherItems, cashEquivalentMinorUnits: 5_000)
        ])
    }

    func testReadsFilledInFormFields() throws {
        let items = [
            PayrollFormTestPDFs.Item("P60 End of Year Certificate", 20, 810, size: 12),
            PayrollFormTestPDFs.Item("Employer's name and address", 303, 510),
            PayrollFormTestPDFs.Item("Employer PAYE reference", 54, 490),
            PayrollFormTestPDFs.Item("In this employment", 40, 190),
            PayrollFormTestPDFs.Item("Total for year", 40, 165),
            PayrollFormTestPDFs.Item("Final tax code", 40, 140)
        ]
        let fields: [(String, String, CGRect)] = [
            ("TaxYear", "Tax Year to 5 April 2025", CGRect(x: 453, y: 790, width: 121, height: 15)),
            ("Employer", "Example Ltd", CGRect(x: 305, y: 494, width: 266, height: 12)),
            ("PAYERef", "123/AB456", CGRect(x: 54, y: 470, width: 95, height: 14)),
            ("ThisPay", "23456.78", CGRect(x: 193, y: 185, width: 100, height: 20)),
            ("ThisTax", "3456.78", CGRect(x: 302, y: 185, width: 99, height: 20)),
            ("TotalPay", "23456.78", CGRect(x: 193, y: 160, width: 100, height: 20)),
            ("TotalTax", "3456.78", CGRect(x: 302, y: 160, width: 99, height: 20)),
            ("TaxCode", "1257L", CGRect(x: 214, y: 135, width: 80, height: 20))
        ]
        let url = PayrollFormTestPDFs.formFieldPDF(items, fields: fields)
        let extraction = PayrollFormReader.read(url)
        XCTAssertEqual(extraction.kind, .p60)
        XCTAssertEqual(extraction.startYear, 2024)
        XCTAssertEqual(extraction.employerName, "Example Ltd")
        XCTAssertEqual(extraction.payeReference, "123/AB456")
        XCTAssertEqual(extraction.payMinorUnits, 2_345_678)
        XCTAssertEqual(extraction.taxDeductedMinorUnits, 345_678)
        XCTAssertEqual(extraction.taxCode, "1257L")
    }

    func testRecognisesTextOfAScannedP60() throws {
        let url = PayrollFormTestPDFs.scannedPDF(PayrollFormTestPDFs.p60RowLayout.map {
            var item = $0
            item.size = max(item.size, 11)
            return item
        })
        XCTAssertEqual(PayrollFormReader.textLayerWords(url).count, 0)
        // The fast recogniser: the accurate one takes a minute to load in a test run.
        let extraction = PayrollFormReader.read(url, accurateOCR: false)
        XCTAssertEqual(extraction.entryMethod, .ocr)
        XCTAssertEqual(extraction.kind, .p60)
        XCTAssertEqual(extraction.startYear, 2024)
        XCTAssertEqual(extraction.payMinorUnits, 4_567_890)
        XCTAssertEqual(extraction.taxDeductedMinorUnits, 654_321)
        XCTAssertEqual(extraction.warnings.first, "Read by text recognition: check every figure against the document.")

        let manual = PayrollFormReader.read(url, kind: .p60, allowOCR: false)
        XCTAssertEqual(manual.entryMethod, .manual)
        XCTAssertEqual(manual.kind, .p60)
        XCTAssertNil(manual.payMinorUnits)
    }

    func testAmountsAndFieldParsing() {
        XCTAssertEqual(PayrollFormReader.pence("1,234.56"), 123_456)
        XCTAssertEqual(PayrollFormReader.pence("£2,456"), 245_600)
        XCTAssertEqual(PayrollFormReader.pence("0.00"), 0)
        XCTAssertNil(PayrollFormReader.pence("2025"))
        XCTAssertNil(PayrollFormReader.pence("11"))
        XCTAssertNil(PayrollFormReader.pence("1,23.45"))
        XCTAssertEqual(PayrollFormReader.pence("-12.34"), -1_234)
        XCTAssertEqual(PayrollFormReader.pence("56.78R"), -5_678)
        XCTAssertNil(PayrollFormReader.pence("R"))
        XCTAssertEqual(PayrollFormReader.pence("£-12.34"), -1_234)
        XCTAssertEqual(PayrollFormReader.pence("-£12.34"), -1_234)
        XCTAssertTrue(PayrollFormReader.isTaxCode("1257L"))
        XCTAssertTrue(PayrollFormReader.isTaxCode("K475M1"))
        XCTAssertTrue(PayrollFormReader.isTaxCode("BR"))
        XCTAssertTrue(PayrollFormReader.isTaxCode("S1257L"))
        XCTAssertFalse(PayrollFormReader.isTaxCode("1257"))
        XCTAssertFalse(PayrollFormReader.isTaxCode("1A"))
        XCTAssertEqual(PayrollFormReader.payeReference(in: "ref 123 / ab456 on 05/04/2025"), "123/AB456")
        XCTAssertNil(PayrollFormReader.payeReference(in: "dated 012/2025"))
        XCTAssertEqual(PayrollFormReader.nationalInsuranceNumber(in: "NI QQ 12 34 56 C"), "QQ123456C")
    }

    // MARK: Importing

    func testImportP60CreatesEmploymentIncomeAndLinksTheDocument() throws {
        let extraction = PayrollFormReader.read(PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60RowLayout))
        try db.write { db in
            XCTAssertEqual(try PayrollFormImport.suggestedPersonId(db: db, nationalInsuranceNumber: extraction.nationalInsuranceNumber), personA)
            let document = try addDocument(db)
            let confirmed = PayrollFormImport.Confirmed(extraction, kind: .p60, personId: personA)
            let result = try PayrollFormImport.apply(db: db, confirmed, documentId: document.id!)
            XCTAssertTrue(result.createdEmployment)
            XCTAssertEqual(result.employment.payeReference, "123/AB456")
            XCTAssertEqual(result.income?.payMinorUnits, 4_567_890)
            XCTAssertEqual(result.income?.entryMethod, .textLayer)
            XCTAssertEqual(try EvidenceLinks.documents(db: db, for: .employmentIncome(result.income!.id!)).map(\.id), [document.id])
            XCTAssertEqual(try DocumentLink.fetchOne(db)?.role, "P60")
            XCTAssertEqual(try EvidenceDocument.fetchOne(db, key: document.id!)?.kind, .p60)

            // A corrected re-import replaces the P60 row; nothing is duplicated.
            var corrected = confirmed
            corrected.payMinorUnits = 4_600_000
            corrected.entryMethod = .manual
            let again = try PayrollFormImport.apply(db: db, corrected, documentId: document.id!)
            XCTAssertFalse(again.createdEmployment)
            XCTAssertEqual(again.income?.id, result.income?.id)
            XCTAssertEqual(try EmploymentIncome.fetchCount(db), 1)
            XCTAssertEqual(try EmploymentIncome.fetchOne(db)?.payMinorUnits, 4_600_000)
            XCTAssertEqual(try DocumentLink.fetchCount(db), 1)
        }
    }

    func testImportP45EndsTheEmploymentAndP11DReplacesBenefits() throws {
        try db.write { db in
            let p45 = PayrollFormImport.Confirmed(kind: .p45, personId: personB, startYear: 2025, employerName: "Example Ltd",
                                                  payeReference: "123/AB456", taxCode: "1257L", payMinorUnits: 1_234_567,
                                                  taxDeductedMinorUnits: 234_567, leavingDate: Self.date(2025, 5, 31))
            let left = try PayrollFormImport.apply(db: db, p45)
            XCTAssertEqual(left.employment.endDate, Self.date(2025, 5, 31))
            XCTAssertEqual(left.income?.periodEnd, Self.date(2025, 5, 31))
            XCTAssertFalse(left.linkedDocument)

            // The P11D names the employer differently but has the same reference.
            let document = try addDocument(db, kind: .p11d)
            var p11d = PayrollFormImport.Confirmed(kind: .p11d, personId: personB, startYear: 2025, employerName: "EXAMPLE LIMITED",
                                                   payeReference: "123 / AB456",
                                                   benefits: [.init(kind: .medical, cashEquivalentMinorUnits: 50_000),
                                                              .init(kind: .car, cashEquivalentMinorUnits: 0)])
            let first = try PayrollFormImport.apply(db: db, p11d, documentId: document.id!)
            XCTAssertEqual(first.employment.id, left.employment.id)
            XCTAssertEqual(first.employment.employerName, "Example Ltd")
            XCTAssertEqual(first.benefits.map(\.kind), [.medical])
            XCTAssertEqual(try EvidenceLinks.documents(db: db, for: .employment(left.employment.id!)).map(\.id), [document.id])

            XCTAssertEqual(first.benefits.map(\.isFromP11DImport), [true])
            // A benefit typed in by hand survives a re-import.
            var typed = BenefitInKind(employmentId: left.employment.id!, kind: .livingAccommodation, cashEquivalentMinorUnits: 7_000)
            try Employments.save(db: db, &typed)

            p11d.benefits = [.init(kind: .medical, cashEquivalentMinorUnits: 60_000), .init(kind: .otherItems, cashEquivalentMinorUnits: 1_000)]
            let second = try PayrollFormImport.apply(db: db, p11d, documentId: document.id!)
            XCTAssertEqual(second.replacedBenefits, 1)
            XCTAssertEqual(try Employments.benefits(db: db, employmentId: left.employment.id!).map(\.cashEquivalentMinorUnits), [60_000, 7_000, 1_000])
            XCTAssertEqual(try Employment.fetchCount(db), 1)
        }
    }

    func testImportRefusesIncompleteForms() throws {
        let missing = PayrollFormImport.Confirmed(kind: .p45, personId: personA, startYear: nil, employerName: " ", payMinorUnits: 1)
        XCTAssertEqual(PayrollFormImport.problems(missing), [.missingTaxYear, .missingEmployer, .missingPayOrTax, .missingLeavingDate])
        let wrongYear = PayrollFormImport.Confirmed(kind: .p45, personId: personA, startYear: 2024, employerName: "Example Ltd", payMinorUnits: 1,
                                                    taxDeductedMinorUnits: 0, leavingDate: Self.date(2025, 5, 31))
        XCTAssertEqual(PayrollFormImport.problems(wrongYear), [.leavingDateOutsideYear])
        var badReference = wrongYear
        badReference.leavingDate = Self.date(2024, 5, 31)
        badReference.payeReference = "12/AB"
        XCTAssertEqual(PayrollFormImport.problems(badReference), [.invalidPAYEReference])
        try db.write { db in
            XCTAssertThrowsError(try PayrollFormImport.apply(db: db, missing)) {
                XCTAssertEqual($0 as? PayrollFormImport.ImportError, .incomplete([.missingTaxYear, .missingEmployer, .missingPayOrTax, .missingLeavingDate]))
            }
            XCTAssertEqual(try Employment.fetchCount(db), 0)
        }
    }
}
