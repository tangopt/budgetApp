import GRDB
import Foundation

// What the property screens read, prepared in BudgetCore so any client (macOS, iOS) shows
// the same thing.

/// A credit paying a receipt, with the transaction.
public struct RentReceiptPaymentInfo: Equatable, Sendable {
    public var payment: RentReceiptPayment
    public var transaction: Transaction
}

/// A receipt as the Tenancies tab lists it.
public struct TenancyReceiptRow: Equatable, Identifiable, Sendable {
    public var receipt: RentReceipt
    public var payments: [RentReceiptPaymentInfo]
    /// Linked documents (the receipt PDF).
    public var documentCount: Int

    public var id: Int64 { receipt.id ?? -1 }
    /// Rent covered by the linked credits.
    public var paidMinorUnits: Int { payments.reduce(0) { $0 + $1.payment.rentMinorUnits } }
    /// Issued and fully paid by linked credits.
    public var isPaid: Bool { receipt.status == .issued && paidMinorUnits >= receipt.amountReceivedMinorUnits }
}

/// The transactions behind a figure of the money summary.
public enum PropertyDrillDown: Hashable, Sendable {
    /// The rent credits (rent received and recharges).
    case rentCredits
    /// Every transaction in the property's income categories.
    case income
    /// The property's expense transactions, or one category's.
    case costs(categoryId: Int64?)
    /// Rows on the mortgage accounts (instalment legs and interest).
    case mortgage
    /// Only the interest rows on the mortgage accounts (their expense rows).
    case mortgageInterest
    /// The interest rows filed outside the property's expense categories (`interestOutsideCosts`).
    case mortgageInterestOutsideCosts
}

public enum PropertyPage {
    /// The tenancy's receipts (cancelled included), by rent period, with their credits and
    /// document counts.
    public static func receiptRows(db: Database, tenancyId: Int64) throws -> [TenancyReceiptRow] {
        let receipts = try RentReceipts.receipts(db: db, tenancyId: tenancyId, includeCancelled: true)
        let counts = try EvidenceLinks.linkCounts(db: db, .rentReceipt)
        return try receipts.map { receipt in
            let payments = try RentReceiptMatching.payments(db: db, receiptId: receipt.id!)
            let transactions = Dictionary(uniqueKeysWithValues: try Transaction.filter(payments.map(\.transactionId).contains(Column("id")))
                .fetchAll(db).map { ($0.id!, $0) })
            return TenancyReceiptRow(receipt: receipt,
                                     payments: payments.compactMap { p in transactions[p.transactionId].map { RentReceiptPaymentInfo(payment: p, transaction: $0) } },
                                     documentCount: counts[receipt.id!] ?? 0)
        }
    }

    /// The transactions behind a money figure for `period`, oldest first.
    public static func transactions(db: Database, propertyId: Int64, period: DateInterval, drillDown: PropertyDrillDown) throws -> [Transaction] {
        let groupIds = try Properties.categoryGroupIds(db: db, propertyId: propertyId)
        let categories = try Category.filter(groupIds.contains(Column("groupId"))).fetchAll(db)
        let inPeriod = Column("date") >= period.start && Column("date") < period.end
        switch drillDown {
        case .rentCredits:
            return try RentReceiptMatching.candidateCredits(db: db, propertyId: propertyId).filter { $0.date >= period.start && $0.date < period.end }
        case .income:
            let ids = categories.filter { $0.type == .income }.compactMap(\.id)
            return try Transaction.filter(ids.contains(Column("categoryId")) && inPeriod).order(Column("date"), Column("id")).fetchAll(db)
        case let .costs(categoryId):
            let ids = categoryId.map { [$0] } ?? categories.filter { $0.type == .expense }.compactMap(\.id)
            return try Transaction.filter(ids.contains(Column("categoryId")) && inPeriod).order(Column("date"), Column("id")).fetchAll(db)
        case .mortgage:
            let ids = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
            return try Transaction.filter(ids.contains(Column("accountId")) && inPeriod).order(Column("date"), Column("id")).fetchAll(db)
        case .mortgageInterestOutsideCosts:
            let inside = Set(categories.filter { $0.type == .expense }.compactMap(\.id))
            return try transactions(db: db, propertyId: propertyId, period: period, drillDown: .mortgageInterest)
                .filter { !inside.contains($0.categoryId ?? -1) }
        case .mortgageInterest:
            let ids = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
            return try Transaction.fetchAll(db, sql: """
                SELECT * FROM transaction_ WHERE accountId IN (\(ids.map { _ in "?" }.joined(separator: ",").nilIfEmpty ?? "NULL"))
                AND date >= ? AND date < ?
                AND categoryId IN (SELECT id FROM category WHERE type = ? AND builtInRole IS NULL) ORDER BY date, id
                """, arguments: StatementArguments(ids.map { $0 as any DatabaseValueConvertible }
                                                     + [period.start, period.end, CategoryType.expense.rawValue]))
        }
    }
}

extension PropertyEvidence {
    /// Display titles of the property records evidence can link to: "Property A", "Person A",
    /// "Room Contract AB (Property A)", "Rent receipt 12 · Room Contract AB".
    public static func entityTitles(db: Database) throws -> [EvidenceEntity: String] {
        var titles: [EvidenceEntity: String] = [:]
        let properties = Dictionary(uniqueKeysWithValues: try Property.fetchAll(db).map { ($0.id!, $0) })
        for property in properties.values { titles[.property(property.id!)] = property.name }
        for person in try Person.fetchAll(db) { titles[.person(person.id!)] = person.name }
        let tenancies = Dictionary(uniqueKeysWithValues: try Tenancy.fetchAll(db).map { ($0.id!, $0) })
        for tenancy in tenancies.values {
            let property = properties[tenancy.propertyId]?.name
            titles[.tenancy(tenancy.id!)] = property.map { "\(tenancy.referenceLabel) (\($0))" } ?? tenancy.referenceLabel
        }
        for receipt in try RentReceipt.fetchAll(db) {
            let label = tenancies[receipt.tenancyId]?.referenceLabel
            titles[.rentReceipt(receipt.id!)] = ["Rent receipt \(receipt.receiptNumber)", label].compactMap { $0 }.joined(separator: " · ")
        }
        return titles
    }

    /// The title of one property record; `nil` for other types or a record that no longer exists.
    public static func title(db: Database, entity: EvidenceEntity) throws -> String? {
        switch entity.type {
        case .property, .person, .tenancy, .rentReceipt: return try entityTitles(db: db)[entity]
        default: return nil
        }
    }

    /// The evidence requirements that concern the property: its record rules, rules on its
    /// category groups and their categories, on its accounts (and their transfer categories),
    /// and periodic or single rules on the property, its tenancies, receipts, accounts,
    /// categories and owners. For "Missing evidence filtered to the property".
    public static func relatedRequirementIds(db: Database, propertyId: Int64) throws -> Set<Int64> {
        let groupIds = Set(try Properties.categoryGroupIds(db: db, propertyId: propertyId))
        let categoryIds = Set(try Category.filter(Array(groupIds).contains(Column("groupId"))).fetchAll(db).compactMap(\.id))
        let accountIds = Set(try Properties.accounts(db: db, propertyId: propertyId).map(\.accountId))
        let transferCategoryIds = Set(try Category.filter(Array(accountIds).contains(Column("transferAccountId"))).fetchAll(db).compactMap(\.id))
        let tenancyIds = Set(try Tenancies.all(db: db, propertyId: propertyId).compactMap(\.id))
        let receiptIds = Set(try RentReceipt.filter(Array(tenancyIds).contains(Column("tenancyId"))).fetchAll(db).compactMap(\.id))
        let ownerIds = Set(try Properties.owners(db: db, propertyId: propertyId).map(\.personId))
        func related(_ entity: EvidenceEntity) -> Bool {
            switch entity.type {
            case .property: return entity.id == propertyId
            case .tenancy: return tenancyIds.contains(entity.id)
            case .rentReceipt: return receiptIds.contains(entity.id)
            case .account: return accountIds.contains(entity.id)
            case .category: return categoryIds.contains(entity.id)
            case .person: return ownerIds.contains(entity.id)
            case .transaction, .taxYear, .taxManualItem, .employment, .employmentIncome, .hmrcPayment, .otherIncome,
                 .pensionContribution, .taxPolicyReceipt, .other: return false
            }
        }
        var ids: Set<Int64> = []
        for requirement in try EvidenceRequirement.fetchAll(db) {
            let isRelated: Bool
            switch requirement.scope {
            case let .recordsOfProperty(id, _): isRelated = id == propertyId
            case .personalIncomeRecords: isRelated = false
            case let .transactionsInCategoryGroup(groupId): isRelated = groupIds.contains(groupId)
            case let .transactionsInCategory(categoryId): isRelated = categoryIds.contains(categoryId)
            case let .transactionsMatching(categories, accounts, _):
                isRelated = categories.contains { categoryIds.contains($0) || transferCategoryIds.contains($0) }
                    || accounts.contains(where: accountIds.contains)
            case let .periodic(entity, _), let .single(entity):
                isRelated = related(entity)
            }
            if isRelated, let id = requirement.id { ids.insert(id) }
        }
        return ids
    }
}

extension EvidenceEntityType {
    /// "Transaction", "Rent receipt", "Tax year"…
    public var displayName: String {
        switch self {
        case .transaction: return "Transaction"
        case .account: return "Account"
        case .category: return "Category"
        case .property: return "Property"
        case .taxYear: return "Tax year"
        case .person: return "Person"
        case .other: return "Other"
        case .tenancy: return "Tenancy"
        case .rentReceipt: return "Rent receipt"
        case .taxManualItem: return "Tax item"
        case .employment: return "Employment"
        case .employmentIncome: return "Pay and tax"
        case .hmrcPayment: return "HMRC payment"
        case .otherIncome: return "Other income"
        case .pensionContribution: return "Pension contribution"
        case .taxPolicyReceipt: return "Insurance receipt"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
