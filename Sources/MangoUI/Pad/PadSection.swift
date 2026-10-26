import Foundation

/// The iPad sidebar's destinations (step 8, Task 6), in sidebar order.
public enum PadSection: Hashable, CaseIterable, Sendable {
    case home, month, accounts, propertyOverview, bills, recharges, rentReceipts, tenancies, documents, missingEvidence, search

    public var title: String {
        switch self {
        case .home: "Home"
        case .month: "Month"
        case .accounts: "Accounts"
        case .propertyOverview: "Overview"
        case .bills: "Bills"
        case .recharges: "Recharges"
        case .rentReceipts: "Rent receipts"
        case .tenancies: "Tenancies"
        case .documents: "Documents"
        case .missingEvidence: "Missing evidence"
        case .search: "Search"
        }
    }

    public var systemImage: String {
        switch self {
        case .home: "house"
        case .month: "calendar"
        case .accounts: "building.columns"
        case .propertyOverview: "building.2"
        case .bills: "doc.text"
        case .recharges: "arrow.left.arrow.right"
        case .rentReceipts: "receipt"
        case .tenancies: "person.2"
        case .documents: "folder"
        case .missingEvidence: "exclamationmark.magnifyingglass"
        case .search: "magnifyingglass"
        }
    }

    /// A sidebar group: its header (nil for the first, ungrouped one) and its sections.
    public struct Group: Equatable, Sendable {
        public let title: String?
        public let sections: [PadSection]
    }

    /// The sidebar's groups; the Property group is left out when there is no property.
    public static func groups(hasProperty: Bool) -> [Group] {
        var groups = [Group(title: nil, sections: [.home, .month, .accounts, .search])]
        if hasProperty {
            groups.append(Group(title: "Property", sections: [.propertyOverview, .bills, .recharges, .rentReceipts, .tenancies]))
        }
        groups.append(Group(title: "Documents", sections: [.documents, .missingEvidence]))
        return groups
    }
}
