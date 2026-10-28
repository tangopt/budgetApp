import Foundation

/// Which of the Mac Dashboard's four review cards (step 12) this device shows. A per-device setting kept in
/// `UserDefaults` under `storageKey` (never synced); everything shows until a card is hidden. The legacy cards
/// (net worth, the year, the month, bills, accounts) are not part of it.
public struct DashboardCardVisibility: Equatable, Sendable {
    public enum Card: String, CaseIterable, Sendable {
        case taxYear, propertyMonth, evidence, mortgage

        public var title: String {
            switch self {
            case .taxYear: return "Tax year position"
            case .propertyMonth: return "Property month"
            case .evidence: return "Evidence and documents"
            case .mortgage: return "Mortgage"
            }
        }
    }

    public static let storageKey = "dashboardHiddenCards"

    public var hidden: Set<Card>

    /// From the stored ids; ids this version doesn't know are dropped. Nil: nothing hidden.
    public init(stored: [String]?) {
        hidden = Set((stored ?? []).compactMap(Card.init(rawValue:)))
    }

    /// From the comma-joined string `@AppStorage` keeps.
    public init(storedString: String) {
        self.init(stored: storedString.split(separator: ",").map(String.init))
    }

    /// The hidden cards' ids, in card order.
    public var stored: [String] { Card.allCases.filter(hidden.contains).map(\.rawValue) }

    /// `stored`, comma-joined, as `@AppStorage` keeps it.
    public var storedString: String { stored.joined(separator: ",") }

    public func shows(_ card: Card) -> Bool { !hidden.contains(card) }
}
