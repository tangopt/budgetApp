import Foundation
import GRDB

/// The areas the iPad's Evidence groups a tax year's items by (step 10, Task 14), in the order it shows them.
public enum EvidenceAreaKind: String, CaseIterable, Sendable {
    /// P60, P45, P11D, payslips: each employment's pay and tax.
    case employmentIncome
    /// HMRC's statements, payments and letters.
    case ukTax
    /// Pension contributions and gifts.
    case pensionGifts
    /// The let property: rent receipts, IMI, condomínio, insurance, repairs, the mortgage's interest.
    case lisbonFlat

    /// The heading; the property's own name stands in for "Lisbon flat" (`EvidenceArea.title`).
    public var title: String {
        switch self {
        case .employmentIncome: "Employment & income"
        case .ukTax: "UK tax"
        case .pensionGifts: "Pension & gifts"
        case .lisbonFlat: "Property"
        }
    }
}

/// One thing the tax year needs a document for, as Evidence shows it: the checklist's item, why it's needed, where it
/// usually comes from and the saved-site kind that fetches it, and whether the viewer may link a document to it.
public struct EvidenceItem: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        /// A linked document counts for it, or it is marked not available.
        case have
        case missing
    }

    public var item: MissingEvidence.Item
    public var why: String
    public var state: State
    /// The kind of saved site its documents are fetched from ("Open site"); nil when no site serves it.
    public var suggestedSiteKind: SavedSiteKind?
    /// Edit on Documents (the link's own area).
    public var canLink: Bool

    public var id: String { item.id }
    public var requirement: EvidenceRequirement { item.requirement }
    /// "Portal das Finanças", "Employer": the rule's usual source.
    public var source: String? { item.usualSource }
}

/// An area's items, missing first.
public struct EvidenceArea: Equatable, Identifiable, Sendable {
    public var area: EvidenceAreaKind
    /// The heading: the area's title, the property's name for the property's area (one property).
    public var title: String
    public var items: [EvidenceItem]

    public var id: EvidenceAreaKind { area }
    public var missingCount: Int { items.filter { $0.state == .missing }.count }
}

/// The iPad's Evidence (step 10, Task 14): the whole UK tax year's evidence, not just the flat's, grouped by area. Built
/// on the checklist with the tax-figures filter (`MissingEvidence.checklist(taxFiguresOnly:)`), and utility bills are
/// never evidence: they belong to Bills & recharges only, so any item asking for a utility invoice, or in a utility
/// category, is left out. A member sees only what her permissions show: the property's items with Property, each
/// person's own items with View on that person's Tax (and, for the other person, while their tax and income is shared),
/// and no item of an account kept private from her. Reads only.
public enum TaxYearEvidence {
    /// The one line Evidence keeps about utility bills.
    public static let utilityPointer = "Utility bills are tracked in Bills & recharges."

    /// `areas` as a device's screen reads them (`DeviceWriter.readScope`): `.nothing` (her user not known yet, or not
    /// readable) shows no area.
    public static func areas(db: Database, taxYear: UKTaxYear, scope: DeviceReadScope) throws -> [EvidenceArea] {
        guard scope != .nothing else { return [] }
        return try areas(db: db, taxYear: taxYear, viewer: scope.viewer)
    }

    /// The areas of `taxYear` that `viewer` may see (nil: everything, the Mac and demo data), in `EvidenceAreaKind` order,
    /// each with its items (missing first, then the checklist's order). An area shows even when empty, while the viewer
    /// may see it: the personal areas with View on some person's Tax, the property's while there is one and she has
    /// Property. Without View on Documents nothing is shown.
    public static func areas(db: Database, taxYear: UKTaxYear, viewer: AccessActor? = nil) throws -> [EvidenceArea] {
        let visibility = try Visibility(db: db, viewer: viewer)
        guard visibility.documents else { return [] }
        let items = try MissingEvidence.checklist(db: db, period: taxYear.interval, taxFiguresOnly: true)
        let properties = try Property.order(Column("id")).fetchAll(db)
        var grouped: [EvidenceAreaKind: [EvidenceItem]] = [:]
        for item in items where !isUtilityBill(item) {
            let kind = try area(of: item, db: db)
            guard try visibility.canSee(item, area: kind, db: db) else { continue }
            grouped[kind, default: []].append(EvidenceItem(item: item, why: why(item, area: kind), state: item.isDone ? .have : .missing,
                                                           suggestedSiteKind: siteKind(item, area: kind), canLink: visibility.canLink))
        }
        return EvidenceAreaKind.allCases.compactMap { kind in
            let shown = kind == .lisbonFlat ? visibility.property && !properties.isEmpty : visibility.anyTax
            guard shown || grouped[kind] != nil else { return nil }
            let title = kind == .lisbonFlat && properties.count == 1 ? properties[0].name : kind.title
            let ordered = (grouped[kind] ?? []).enumerated().sorted { a, b in
                (a.element.state == .missing ? 0 : 1, a.offset) < (b.element.state == .missing ? 0 : 1, b.offset)
            }.map(\.element)
            return EvidenceArea(area: kind, title: title, items: ordered)
        }
    }

    /// Done and total over every area.
    public static func progress(_ areas: [EvidenceArea]) -> MissingEvidence.Progress {
        MissingEvidence.progress(areas.flatMap(\.items).map(\.item))
    }

    // MARK: Utility bills

    /// A utility bill: an item that asks only for utility invoices, or a transaction in a utility category. Not evidence.
    public static func isUtilityBill(_ item: MissingEvidence.Item) -> Bool {
        if !item.expectedKindRefs.isEmpty, item.expectedKindRefs.allSatisfy({ $0 == .builtIn(.utilityInvoice) }) { return true }
        if item.isForRecharges { return true }
        return item.categoryName.map(RechargeNetting.isUtilityName) ?? false
    }

    // MARK: Areas

    /// Which area an item belongs to: by its record (an employment, an HMRC payment, a pension contribution, the property's
    /// records), else by the kinds it expects (P60s and HMRC's documents are personal), else the property's (the rules on
    /// transactions are the property's).
    public static func area(of item: MissingEvidence.Item, db: Database) throws -> EvidenceAreaKind {
        switch item.target.entity.type {
        case .employment, .employmentIncome, .otherIncome: return .employmentIncome
        case .hmrcPayment, .taxYear: return .ukTax
        case .pensionContribution: return .pensionGifts
        case .property, .tenancy, .rentReceipt, .taxPolicyReceipt: return .lisbonFlat
        case .taxManualItem:
            let propertyId = try Int64.fetchOne(db, sql: "SELECT propertyId FROM taxManualItem WHERE id = ?", arguments: [item.target.entity.id])
            return propertyId == nil ? .ukTax : .lisbonFlat
        case .transaction, .account, .category, .person, .other:
            return area(ofKinds: item.expectedKinds) ?? .lisbonFlat
        }
    }

    static func area(ofKinds kinds: [DocumentKind]) -> EvidenceAreaKind? {
        if kinds.contains(where: { [.p60, .p45, .p11d, .taxCodeNotice].contains($0) }) { return .employmentIncome }
        if kinds.contains(where: { [.hmrcPaymentProof, .sa302, .taxReturn, .hmrcLetter].contains($0) }) { return .ukTax }
        return nil
    }

    // MARK: Why and where

    /// Why the return needs it, in a sentence: by the first kind it expects, else by its record.
    public static func why(_ item: MissingEvidence.Item, area: EvidenceAreaKind) -> String {
        for kind in item.expectedKinds where kind != .other {
            if let text = why(kind) { return text }
        }
        switch item.target.entity.type {
        case .tenancy: return "The contract shows the rent and the dates the flat was let."
        case .rentReceipt: return "One PDF per rent receipt, as proof of the rental income declared."
        case .pensionContribution: return "Pension contributions can lower the tax due; the provider's statement proves them."
        case .employment, .employmentIncome, .otherIncome: return "Proves the income and the tax already paid on it."
        default: break
        }
        switch area {
        case .lisbonFlat: return "A cost of letting the flat: the document proves what was paid."
        case .employmentIncome: return "Proves the income and the tax already paid on it."
        case .ukTax: return "HMRC's own record of the year's tax."
        case .pensionGifts: return "Needed to claim the relief on the return."
        }
    }

    static func why(_ kind: DocumentKind) -> String? {
        switch kind {
        case .p60: "Year-end pay and tax from each employer: the figures on the return's employment page."
        case .p45: "Pay and tax up to the day the job ended, for that employment's figures."
        case .p11d: "Benefits from the employer are taxed through the return; the P11D gives their value."
        case .taxCodeNotice: "Shows how HMRC collected the year's tax through pay."
        case .hmrcPaymentProof: "Proves a payment to HMRC (or a refund) counted against the year's bill."
        case .sa302, .taxReturn, .hmrcLetter: "HMRC's own record of the year's tax."
        case .rentReceipt: "One PDF per rent receipt, as proof of the rental income declared."
        case .rentContract, .tenancyAddendum: "The contract shows the rent and the dates the flat was let."
        case .imiNotice, .imiPayment: "Property tax is a cost of the flat; the notice is the proof."
        case .condominioReceipt: "The building's charges are a cost of the flat; each receipt proves one."
        case .insuranceReceipt, .insurancePolicy: "Insurance is a cost of the flat; the receipt or policy proves it."
        case .repairInvoice: "Repairs are a cost of the flat; the bill proves what was done and paid."
        case .mortgageNotice, .mortgageReceipt, .mortgageInterestStatement: "Mortgage interest is claimed against the rent; the bank's notice shows it."
        case .ptIRSDeclaration, .ptIRSAssessment, .ptIRSPaymentNote, .ptIRSPaymentProof:
            "Portuguese tax on the rent is credited against UK tax; this proves it."
        case .stampDuty: "Stamp duty is a cost of the flat; the document proves it."
        case .accountantInvoice, .legalInvoice, .courtFee, .lettingAgentFee: "A cost of letting the flat; the invoice proves it."
        case .bankStatement, .bankDebitAdvice, .bankTransferProof: "The bank's own record of the charge."
        default: nil
        }
    }

    /// The saved-site kind its documents come from: the tax portals (Portal das Finanças, HMRC), the bank, the condomínio's
    /// administrator; any other usual source (an employer, an insurer) its own site. Nil with no usual source.
    public static func siteKind(_ item: MissingEvidence.Item, area: EvidenceAreaKind) -> SavedSiteKind? {
        let kinds = Set(item.expectedKinds)
        if !kinds.isDisjoint(with: [.imiNotice, .imiPayment, .rentReceipt, .stampDuty, .ptIRSAssessment, .ptIRSDeclaration,
                                    .ptIRSPaymentNote, .ptIRSPaymentProof, .hmrcPaymentProof, .sa302, .taxCodeNotice]) {
            return .tax
        }
        guard let source = item.usualSource?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) else {
            return item.target.entity.type == .rentReceipt ? .tax : nil
        }
        if source.contains("financas") || source.contains("hmrc") { return .tax }
        if source.contains("condominio") { return .condominium }
        if source.contains("bbva") || source.contains("bank") { return .bank }
        return .other
    }

    // MARK: Visibility

    /// What the viewer may see and do, read once.
    struct Visibility {
        var viewer: AccessActor?
        var documents = true
        var property = true
        var canLink = true
        /// View on some person's Tax.
        var anyTax = true
        /// Per person: View on their Tax (and, for another person, their tax and income shared).
        var taxByPerson: [Int64: Bool] = [:]

        init(db: Database, viewer: AccessActor?) throws {
            self.viewer = viewer
            guard let viewer else { return }
            documents = try AccessPolicy.can(viewer, .view, .documents, db: db)
            canLink = try AccessPolicy.can(viewer, .edit, .documents, db: db)
            property = try AccessPolicy.can(viewer, .view, .property, db: db)
            for personId in try Int64.fetchAll(db, sql: "SELECT id FROM person ORDER BY id") {
                taxByPerson[personId] = try Self.seesTax(of: personId, viewer: viewer, db: db)
            }
            anyTax = taxByPerson.values.contains(true)
        }

        static func seesTax(of personId: Int64, viewer: AccessActor, db: Database) throws -> Bool {
            guard try AccessPolicy.can(viewer, .view, try AccessArea.tax(ofPerson: personId, db: db), db: db) else { return false }
            guard personId != viewer.personId, !viewer.isAdmin else { return true }
            let level = try PersonSharing.filter(Column("personId") == personId).fetchOne(db)?.taxIncomeLevel ?? SharingDefaults.taxIncomeLevel
            return level == .everything
        }

        func canSee(_ item: MissingEvidence.Item, area: EvidenceAreaKind, db: Database) throws -> Bool {
            guard let viewer else { return true }
            if item.target.entity.type == .transaction, !viewer.isAdmin {
                let row = try Row.fetchOne(db, sql: """
                    SELECT a.ownerPersonId, a.sharingLevel FROM transaction_ t JOIN account a ON a.id = t.accountId WHERE t.id = ?
                    """, arguments: [item.target.entity.id])
                if let row, let owner = row["ownerPersonId"] as Int64?, owner != viewer.personId,
                   (SharingLevel(rawValue: row["sharingLevel"] ?? "") ?? .hidden) < .everything {
                    return false
                }
            }
            switch area {
            case .lisbonFlat:
                return property
            case .employmentIncome, .ukTax, .pensionGifts:
                let personId = try TaxYearEvidence.person(of: item.target.entity, db: db) ?? viewer.personId
                return taxByPerson[personId] ?? false
            }
        }
    }

    /// The person a personal record is about (nil for a record of no one: a transaction, the property's).
    static func person(of entity: EvidenceEntity, db: Database) throws -> Int64? {
        let sql: String
        switch entity.type {
        case .person: return entity.id
        case .employment, .otherIncome, .pensionContribution, .hmrcPayment, .taxYear, .taxManualItem:
            sql = "SELECT personId FROM \(entity.type.rawValue) WHERE id = ?"
        case .employmentIncome:
            sql = "SELECT e.personId FROM employmentIncome i JOIN employment e ON e.id = i.employmentId WHERE i.id = ?"
        default:
            return nil
        }
        return try Int64.fetchOne(db, sql: sql, arguments: [entity.id])
    }
}
