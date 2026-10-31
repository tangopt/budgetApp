import Foundation
import BudgetCore

/// The iPad sidebar's destinations (step 8, Task 6; step 10, Task 3; redesign step 4), in sidebar order: four ungrouped
/// (Home, Month, Accounts, Search), the Property group (This month, Bills & recharges, Tenancies, Property details) and
/// "Everything else" (Documents, Calendar, Salary calculator): 11 in all. Property details holds Money, Costs and Profile as
/// segments, Documents holds Missing, Library and Downloads (`PropertyDetailsSegment`, `DocumentsSegment`).
public enum PadSection: Hashable, CaseIterable, Sendable {
    case home, month, accounts, search
    case thisMonth, billsAndRecharges, tenancies, propertyDetails
    case documents, calendar, salary

    /// The section a widget's link opens.
    public init(link: PhoneTabLink) {
        switch link {
        case .home: self = .home
        case .month: self = .month
        }
    }

    public var title: String {
        switch self {
        case .home: "Home"
        case .month: "Month"
        case .accounts: "Accounts"
        case .search: "Search"
        case .thisMonth: "This month"
        case .billsAndRecharges: "Bills & recharges"
        case .tenancies: "Tenancies"
        case .propertyDetails: "Property details"
        case .calendar: "Calendar"
        case .documents: "Documents"
        case .salary: "Salary calculator"
        }
    }

    public var systemImage: String {
        switch self {
        case .home: "house"
        case .month: "calendar"
        case .accounts: "building.columns"
        case .search: "magnifyingglass"
        case .thisMonth: "building.2"
        case .billsAndRecharges: "doc.text"
        case .tenancies: "person.2"
        case .propertyDetails: "list.bullet.rectangle"
        case .calendar: "calendar.badge.clock"
        case .documents: "folder"
        case .salary: "percent"
        }
    }

    /// The Property group's sections: hidden, with the group, when there is no property.
    public var requiresProperty: Bool {
        Self.propertySections.contains(self)
    }

    static let propertySections: Set<PadSection> = [.thisMonth, .billsAndRecharges, .tenancies, .propertyDetails]

    /// A sidebar group: its header (nil for the first, ungrouped one) and its sections.
    public struct Group: Equatable, Sendable {
        public let title: String?
        public let sections: [PadSection]
    }

    /// The sidebar's groups; the Property group is left out when there is no property.
    public static func groups(hasProperty: Bool) -> [Group] {
        var groups = [Group(title: nil, sections: [.home, .month, .accounts, .search])]
        if hasProperty {
            groups.append(Group(title: "Property", sections: [.thisMonth, .billsAndRecharges, .tenancies, .propertyDetails]))
        }
        groups.append(Group(title: "Everything else", sections: [.documents, .calendar, .salary]))
        return groups
    }
}

/// The sidebar's collapsed state (kept per scene by `PadRootView`'s `@SceneStorage`): the full list, or a narrow icon rail.
public struct PadSidebarState: Equatable, Sendable {
    public var isCollapsed: Bool
    public init(isCollapsed: Bool = false) { self.isCollapsed = isCollapsed }

    public static let expandedWidth: CGFloat = 264
    public static let railWidth: CGFloat = 72
    public var width: CGFloat { isCollapsed ? Self.railWidth : Self.expandedWidth }

    public mutating func toggle() { isCollapsed.toggle() }

    /// Portrait on an 11-inch iPad with a document panel open: the rail makes room for the panel (the person's own
    /// choice to collapse always holds).
    public func effective(width: CGFloat, height: CGFloat, panelOpen: Bool) -> PadSidebarState {
        PadSidebarState(isCollapsed: isCollapsed || (panelOpen && height > width && width < 900))
    }
}

/// Property details' segments (design review D5): the Money, Costs and Profile pages that were three sidebar entries.
public enum PropertyDetailsSegment: String, CaseIterable, Identifiable, Sendable {
    case money = "Money", costs = "Costs", profile = "Profile"
    public var id: String { rawValue }
}

/// Documents' segments (design review D3, D4): what is missing (the tax year's evidence and the centre's other rows), the
/// library, and the downloads tray with the saved sites.
public enum DocumentsSegment: String, CaseIterable, Identifiable, Sendable {
    case missing = "Missing", library = "Library", downloads = "Downloads"
    public var id: String { rawValue }
}
