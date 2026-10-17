import GRDB
import Foundation

/// Saves a P60, P45 or P11D the user has confirmed (from `PayrollFormReader`, or typed in for
/// an unreadable scan) into the person's employment records, and links the document: a P60 or
/// P45 to the pay-and-tax row it gave, a P11D to the employment (plan phase 4 Task 1).
public enum PayrollFormImport {
    /// The figures as the user confirmed them.
    public struct Confirmed: Equatable, Sendable {
        public var kind: PayrollFormKind
        public var personId: Int64
        public var startYear: Int?
        public var employerName: String?
        public var payeReference: String?
        public var taxCode: String?
        public var payMinorUnits: Int?
        public var taxDeductedMinorUnits: Int?
        public var leavingDate: Date?
        public var benefits: [PayrollFormExtraction.Benefit]
        public var entryMethod: IncomeEntryMethod

        public init(kind: PayrollFormKind, personId: Int64, startYear: Int?, employerName: String?, payeReference: String? = nil,
                    taxCode: String? = nil, payMinorUnits: Int? = nil, taxDeductedMinorUnits: Int? = nil, leavingDate: Date? = nil,
                    benefits: [PayrollFormExtraction.Benefit] = [], entryMethod: IncomeEntryMethod = .manual) {
            self.kind = kind
            self.personId = personId
            self.startYear = startYear
            self.employerName = employerName
            self.payeReference = payeReference
            self.taxCode = taxCode
            self.payMinorUnits = payMinorUnits
            self.taxDeductedMinorUnits = taxDeductedMinorUnits
            self.leavingDate = leavingDate
            self.benefits = benefits
            self.entryMethod = entryMethod
        }

        /// The reader's proposal for `personId` (the user edits it before saving).
        public init(_ extraction: PayrollFormExtraction, kind: PayrollFormKind, personId: Int64) {
            self.init(kind: kind, personId: personId, startYear: extraction.startYear, employerName: extraction.employerName,
                      payeReference: extraction.payeReference, taxCode: extraction.taxCode, payMinorUnits: extraction.payMinorUnits,
                      taxDeductedMinorUnits: extraction.taxDeductedMinorUnits, leavingDate: extraction.leavingDate,
                      benefits: extraction.benefits, entryMethod: extraction.entryMethod)
        }
    }

    public enum Problem: Equatable, Sendable {
        case missingTaxYear
        case missingEmployer
        /// A P60 or P45 needs its pay and tax.
        case missingPayOrTax
        /// A P45 needs the leaving date.
        case missingLeavingDate
        /// The leaving date isn't in the tax year.
        case leavingDateOutsideYear
        /// The PAYE reference isn't "123/AB456".
        case invalidPAYEReference
    }

    public struct Result: Equatable, Sendable {
        public var employment: Employment
        public var createdEmployment: Bool
        /// The P60 / P45 row (created or replaced).
        public var income: EmploymentIncome?
        /// The P11D's benefits as saved (replacing those of an earlier import; typed-in ones stay).
        public var benefits: [BenefitInKind]
        public var replacedBenefits: Int
        public var linkedDocument: Bool
    }

    /// What stops `confirmed` from being saved (empty: it can be).
    public static func problems(_ confirmed: Confirmed) -> [Problem] {
        var problems: [Problem] = []
        if confirmed.startYear == nil { problems.append(.missingTaxYear) }
        if Transaction.normalizedNote(confirmed.employerName) == nil { problems.append(.missingEmployer) }
        do { _ = try Employments.normalizedPAYEReference(confirmed.payeReference) } catch { problems.append(.invalidPAYEReference) }
        if confirmed.kind != .p11d, confirmed.payMinorUnits == nil || confirmed.taxDeductedMinorUnits == nil { problems.append(.missingPayOrTax) }
        if confirmed.kind == .p45 {
            if let leaving = confirmed.leavingDate {
                if let year = confirmed.startYear, UKTaxYear.containing(leaving).startYear != year { problems.append(.leavingDateOutsideYear) }
            } else {
                problems.append(.missingLeavingDate)
            }
        }
        return problems
    }

    public enum ImportError: Error, Equatable {
        case incomplete([Problem])
    }

    /// Saves the form: finds the person's employment in the year by PAYE reference (else by
    /// employer name) or creates it, filling a missing reference and, from a P45, the end
    /// date; replaces the employment's row from the same form (P60, P45) or the benefits an
    /// earlier P11D import saved (benefits typed in by hand stay); links `documentId` (role: the form's name) and gives an unclassified document
    /// the form's kind.
    @discardableResult
    public static func apply(db: Database, _ confirmed: Confirmed, documentId: Int64? = nil) throws -> Result {
        let problems = problems(confirmed)
        guard problems.isEmpty, let startYear = confirmed.startYear, let employerName = confirmed.employerName else {
            throw ImportError.incomplete(problems)
        }
        guard try Person.exists(db, key: confirmed.personId) else { throw PersonalIncomeError.personNotFound }
        let reference = try Employments.normalizedPAYEReference(confirmed.payeReference)

        var employment: Employment
        var created = false
        if let existing = try Employments.find(db: db, startYear: startYear, personId: confirmed.personId, payeReference: reference,
                                               employerName: employerName) {
            employment = existing
            if employment.payeReference == nil { employment.payeReference = reference }
        } else {
            employment = Employment(startYear: startYear, personId: confirmed.personId, employerName: employerName, payeReference: reference)
            created = true
        }
        if confirmed.kind == .p45, let leaving = confirmed.leavingDate { employment.endDate = leaving }
        try Employments.save(db: db, &employment)

        var income: EmploymentIncome?
        var benefits: [BenefitInKind] = []
        var replaced = 0
        if let source = confirmed.kind.incomeSource, let pay = confirmed.payMinorUnits, let tax = confirmed.taxDeductedMinorUnits {
            var row = try EmploymentIncome.filter(Column("employmentId") == employment.id! && Column("source") == source.rawValue)
                .order(Column("id")).fetchOne(db)
                ?? EmploymentIncome(employmentId: employment.id!, source: source, payMinorUnits: pay, taxDeductedMinorUnits: tax)
            row.payMinorUnits = pay
            row.taxDeductedMinorUnits = tax
            row.taxCode = confirmed.taxCode
            row.periodEnd = confirmed.kind == .p45 ? confirmed.leavingDate : nil
            row.entryMethod = confirmed.entryMethod
            try Employments.save(db: db, &row)
            income = row
        }
        if confirmed.kind == .p11d {
            replaced = try BenefitInKind.filter(Column("employmentId") == employment.id! && Column("isFromP11DImport") == true).deleteAll(db)
            for benefit in confirmed.benefits where benefit.cashEquivalentMinorUnits > 0 {
                var row = BenefitInKind(employmentId: employment.id!, kind: benefit.kind, sa102Box: benefit.sa102Box,
                                        cashEquivalentMinorUnits: benefit.cashEquivalentMinorUnits, entryMethod: confirmed.entryMethod,
                                        isFromP11DImport: true)
                try Employments.save(db: db, &row)
                benefits.append(row)
            }
        }

        var linked = false
        if let documentId {
            let entity: EvidenceEntity = income.map { .employmentIncome($0.id!) } ?? .employment(employment.id!)
            try EvidenceLinks.link(db: db, documentId: documentId, to: entity, role: confirmed.kind.displayName)
            if var document = try EvidenceDocument.fetchOne(db, key: documentId), document.kind == .other {
                document.kind = confirmed.kind.documentKind
                try document.update(db)
            }
            linked = true
        }
        return Result(employment: employment, createdEmployment: created, income: income, benefits: benefits, replacedBenefits: replaced,
                      linkedDocument: linked)
    }

    /// The person whose UK National Insurance number the form shows, when one matches.
    public static func suggestedPersonId(db: Database, nationalInsuranceNumber: String?) throws -> Int64? {
        guard let number = nationalInsuranceNumber.map(normalizedNINO), !number.isEmpty else { return nil }
        return try Person.fetchAll(db).first { $0.ukNino.map(normalizedNINO) == number }?.id
    }

    static func normalizedNINO(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
