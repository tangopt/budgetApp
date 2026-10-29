import Foundation

/// Which of the Mac Dashboard's widgets this device shows. A per-device setting kept in `UserDefaults` under
/// `storageKey` (never synced); everything shows until a widget is hidden (a widget with nothing to show, such as the
/// property ones without a property, is simply not drawn whatever this says).
public struct DashboardCardVisibility: Equatable, Sendable {
    public enum Card: String, CaseIterable, Sendable {
        case netWorth, currentMonth, year, yearChange, topCategories, upcomingBills, accounts
        case propertyMonth, tenancyCashFlow, propertyReturn, mortgage
        case taxYear, evidence, importsWaiting, attention

        public var title: String {
            switch self {
            case .taxYear: return "Tax year position"
            case .mortgage: return "Mortgage"
            default: return DashboardTile.title(tileID)
            }
        }

        /// The tile's id in a saved layout (a mortgage's tile is `mortgage:<property>`; this is the prefix).
        public var tileID: String { self == .mortgage ? "mortgage" : rawValue }

        /// The Dashboard section the widget is in.
        public var section: DashboardLayout.Section {
            switch self {
            case .netWorth, .currentMonth, .year, .yearChange, .topCategories, .upcomingBills, .accounts: return .money
            case .propertyMonth, .tenancyCashFlow, .propertyReturn, .mortgage: return .property
            case .taxYear, .evidence, .importsWaiting, .attention: return .tax
            }
        }

        /// The widget a tile id (`DashboardTile`) belongs to.
        public init?(tileID: String) {
            if tileID.hasPrefix("mortgage:") { self = .mortgage; return }
            self.init(rawValue: tileID)
        }

        public static func cards(in section: DashboardLayout.Section) -> [Card] { allCases.filter { $0.section == section } }
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
