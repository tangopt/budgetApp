import Foundation
import GRDB

/// How much of an account the other person sees (sharing spec 2026-10-25 §2, sync spec §6.1), lowest
/// first. Records of an account below `.everything` live only in its owner's private zone; the household
/// zone gets the summaries the level allows.
public enum SharingLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case hidden, balanceOnly, categoryTotals, everything

    public var title: String {
        switch self {
        case .hidden: return "Hidden"
        case .balanceOnly: return "Balance only"
        case .categoryTotals: return "Category totals"
        case .everything: return "Everything"
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (lhs: SharingLevel, rhs: SharingLevel) -> Bool { lhs.rank < rhs.rank }
}

/// The level of a person's "tax years and income" area: shared in full or not at all.
public enum TaxIncomeLevel: String, Codable, CaseIterable, Sendable {
    case everything, hidden

    /// As the levels read: "Everything", "Hidden".
    public var title: String {
        switch self {
        case .everything: return SharingLevel.everything.title
        case .hidden: return SharingLevel.hidden.title
        }
    }
}

/// One person's sharing settings (synced, household zone). `ownershipConfirmedAt` is set on the
/// admin's row by the ownership sheet, once every account has its owner.
public struct PersonSharing: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var personId: Int64
    public var taxIncomeLevel: TaxIncomeLevel
    public var ownershipConfirmedAt: Date?

    public init(id: Int64? = nil, personId: Int64, taxIncomeLevel: TaxIncomeLevel = .everything, ownershipConfirmedAt: Date? = nil) {
        self.id = id
        self.personId = personId
        self.taxIncomeLevel = taxIncomeLevel
        self.ownershipConfirmedAt = ownershipConfirmedAt
    }

    public static let databaseTableName = "personSharing"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
