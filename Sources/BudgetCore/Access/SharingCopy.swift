import Foundation

/// Every sharing string the Mac and iPhone show (sharing spec 2026-10-25). Names come from the app's data,
/// never from here.
public enum SharingCopy {
    // MARK: Ownership sheet

    public static let sheetTitle = "Who owns each account?"
    public static let sheetNote = "Every account is yours unless you mark it Joint. Joint accounts are always shared in full."
    public static let jointChoice = "Joint"
    /// Add account's choice: added as joint (both people's) rather than the person adding it.
    public static let addJointLabel = "Joint account"
    public static let addJointNote = "Shared by both of you, in full. Otherwise the account is yours, shown to the other person as its balance only."

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

    // MARK: Settings ▸ Sharing (Mac)

    public static let paneTitle = "Sharing"
    public static let setupExplanation = "Before anything is shared, say who owns each account. You do this once. Afterwards each owner chooses how much of their accounts the other person sees, one account at a time."
    public static let setOwnersButton = "Set owners…"
    /// A member before the admin has saved the ownership sheet.
    public static let waitingForOwners = "The admin hasn't said who owns each account yet. Once they have, your accounts and their levels show here."
    public static let myAccounts = "My accounts"
    public static let myAccountsNote = "How much of each of your accounts the other person sees."
    public static let noOwnAccounts = "You don't own any accounts in Mango yet."
    public static let jointAccounts = "Joint accounts"
    public static let jointAccountsNote = "Joint accounts are always shared in full."
    public static let taxAndIncome = "My tax years and income"
    public static let taxAndIncomeNote = "Your tax years, employment and payroll documents and HMRC pages. Taxes stay shared in full for now."
    public static let badgeHelp = "How much of this account the other person sees. Change it in Settings ▸ Sharing."
    /// Sign-in refused: this database holds another person's private accounts (`SharingSignIn`).
    public static let otherPersonsMacUser = "This Mac user holds someone else's private accounts. Sign in on your own Mac user."
    /// Settings ▸ Sharing while locked, and before sign-in is set up.
    public static let needsSignIn = "Sign in to Mango to see how your accounts are shared."
    public static let needsSignInSetUp = "Sharing starts once sign-in is set up, in Settings ▸ Sign-in."
    /// When the household has nobody else yet.
    public static let otherPersonFallback = "The other person"

    // MARK: The ownership sheet's table

    public static let accountColumn = "Account"
    public static let bankColumn = "Bank"
    public static let ownerColumn = "Owner"
    public static let levelColumn = "Shared as"

    // MARK: Changing a level

    public static func changeTitle(account: String) -> String { "Change sharing for \(account)?" }
    public static func changeSummary(from: SharingLevel, to: SharingLevel) -> String { "From \(from.title) to \(to.title)." }
    public static let changeButton = "Change"
    public static let counting = "Counting the records to move…"
    public static let changing = "Changing the level…"
    public static func blockedTitle(account: String) -> String { "\(account) can't be hidden yet" }
    public static let blockedNote = "Hidden shares nothing, and these still need the account shared. Change or remove them first."

    /// Why a sharing change was refused, as the Mac shows it.
    public static func error(_ error: SharingError) -> String {
        switch error {
        case .notAdmin: return "Only the admin says who owns each account."
        case .alreadyConfirmed: return "The owners have already been set."
        case .ownershipNotConfirmed: return "Set the owners first."
        case .rowsDoNotMatchAccounts: return "The accounts changed while the sheet was open. Close it and open it again."
        case .accountAlreadyOwned: return "An account on the sheet already has an owner. Close it and open it again."
        case .ownerMustBeAdminOrJoint: return "Each account is yours or Joint."
        case .notOwner: return "Only the account's owner changes how much of it is shared."
        case .jointMustBeEverything: return "Joint accounts are always shared in full."
        case .blocked(let blockers): return "Hidden isn't possible yet: " + blockers.map(blocker).joined(separator: "; ") + "."
        case .notAvailableYet: return hiddenNotAvailable
        case .accountNotFound: return "That account no longer exists."
        }
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
