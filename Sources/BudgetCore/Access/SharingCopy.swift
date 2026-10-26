import Foundation

/// Every sharing string the Mac and iPhone show (sharing spec 2026-10-25). Names come from the app's data,
/// never from here.
public enum SharingCopy {
    // MARK: Ownership sheet

    public static let sheetTitle = "Who owns each account?"
    public static let sheetNote = "Every account is yours unless you mark it Joint. Joint accounts are always shared in full."
    public static let jointChoice = "Joint"

    /// The sheet's owner picker: the admin's display name, then Joint.
    public static func ownerChoices(adminName: String) -> [String] { [adminName, jointChoice] }

    public static func ownerChoice(_ owner: SharingSetup.Owner, adminName: String) -> String {
        switch owner {
        case .person: return adminName
        case .joint: return jointChoice
        }
    }

    // MARK: Levels

    /// The badge beside an account below Everything; nil at Everything.
    public static func badge(_ level: SharingLevel) -> String? {
        switch level {
        case .categoryTotals: return "Shared as category totals"
        case .balanceOnly: return "Shared as balance only"
        case .hidden: return "Not shared"
        case .everything: return nil
        }
    }

    public static func lowerWarning(otherName: String) -> String {
        "Lowering the level stops sharing from now on. \(otherName) may already have a copy of this account's transactions on their devices or in their backups, and Mango can't recall it."
    }

    public static func raiseNote(otherName: String) -> String {
        "\(otherName) will see this account's transactions and documents."
    }

    /// Tax years and income's Hidden choice in the picker.
    public static let hiddenNotAvailable = "Hidden (not available yet)"

    // MARK: Elsewhere

    /// A private account in the other person's lists: "Card (Name) · 7 transactions · details private".
    public static func privateLine(account: String, owner: String, count: Int) -> String {
        "\(account) (\(owner)) · \(count) \(count == 1 ? "transaction" : "transactions") · details private"
    }

    public static let netWorthNote = "Includes everything you can see"

    /// The level-change warning's count (`SharingLevels.affectedCount`): "Moves 1 record", "Moves 1,204 records".
    public static func moves(count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_GB")
        let number = formatter.string(from: NSNumber(value: count)) ?? String(count)
        return "Moves \(number) \(count == 1 ? "record" : "records")"
    }

    // MARK: What blocks Hidden

    public static func blocker(_ blocker: SharingLevels.Blocker) -> String {
        switch blocker {
        case .propertyLink(let name):
            return "Linked to the property \(name)"
        case .propertyOrTaxRows(let count):
            return count == 1 ? "1 property or tax record points at its transactions"
                : "\(count) property or tax records point at its transactions"
        case .referencedBy(let table, let count):
            return "Named by \(count) \(tableDescription(table, count: count))"
        case .transferCategory(let name):
            return "Named by the transfer category “\(name)”"
        }
    }

    private static func tableDescription(_ table: String, count: Int) -> String {
        let singular: String
        switch table {
        case ImportRule.databaseTableName: singular = "import rule"
        case EvidenceRequirement.databaseTableName: singular = "evidence requirement"
        default: singular = "record"
        }
        return count == 1 ? singular : singular + "s"
    }
}
