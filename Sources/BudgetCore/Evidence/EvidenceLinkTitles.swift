import Foundation
import GRDB

/// What a document's link is called wherever links are listed (the iPad's Documents, the Mac's Missing evidence
/// rules): a transaction by its date, description and amount ("5 Mar 2023 · DEMO PWR DD 123 · −€100.00"), an
/// account or category by its name, a property or tax record by its title. Never "Transaction #12".
public enum EvidenceLinkTitles {
    /// A link's title, and the kind of record it is (nil for a transaction: the title says it).
    public struct Line: Equatable, Sendable {
        public var title: String
        public var subtitle: String?

        public init(title: String, subtitle: String?) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// "5 Mar 2023 · DEMO PWR DD 123 · −€100.00".
    public static func transaction(_ transaction: Transaction, currency: Currency) -> String {
        [day(transaction.date), transaction.rawDescription, Money.format(transaction.amountMinorUnits, currency: currency)]
            .joined(separator: " · ")
    }

    /// The record's title; nil when it no longer exists.
    public static func title(db: Database, entity: EvidenceEntity) throws -> String? {
        switch entity.type {
        case .transaction:
            guard let transaction = try Transaction.fetchOne(db, key: entity.id) else { return nil }
            return Self.transaction(transaction, currency: try Account.fetchOne(db, key: transaction.accountId)?.currency ?? .eur)
        case .account:
            return try Account.fetchOne(db, key: entity.id)?.displayName
        case .category:
            return try Category.fetchOne(db, key: entity.id)?.name
        case .property, .person, .tenancy, .rentReceipt:
            return try PropertyEvidence.title(db: db, entity: entity)
        case .taxYear, .taxManualItem, .employment, .employmentIncome, .hmrcPayment, .otherIncome, .pensionContribution, .taxPolicyReceipt:
            return try TaxEvidence.title(db: db, entity: entity)
        case .other:
            return "\(entity.type.displayName) #\(entity.id)"
        }
    }

    /// The line a link shows: its record's title ("Account no longer exists" when gone) and the record's kind.
    public static func line(db: Database, entity: EvidenceEntity) throws -> Line {
        let kind = entity.type.displayName
        let title = try title(db: db, entity: entity) ?? "\(kind) no longer exists"
        switch entity.type {
        case .transaction, .other: return Line(title: title, subtitle: nil)
        default: return Line(title: title, subtitle: kind)
        }
    }

    /// "5 Mar 2023" (UTC, as every stored day).
    static func day(_ date: Date) -> String {
        let parts = UKTaxYear.utcCalendar.dateComponents([.year, .month, .day], from: date)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(parts.day!) \(months[parts.month! - 1]) \(parts.year!)"
    }
}
