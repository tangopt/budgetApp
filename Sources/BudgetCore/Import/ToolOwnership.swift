import Foundation
import GRDB

/// What the one-off import tools ask before they write (step 7a F-2): the accounts they create are the household
/// admin's once ownership is confirmed, so the person at the keyboard says yes first.
public enum ToolOwnership {
    public static let declined = "Nothing imported."

    /// The admin the tool's accounts would belong to and the question to ask. nil when no admin exists or ownership
    /// isn't confirmed yet (the accounts are joint at Everything then, and there is nothing to confirm).
    public static func question(db: Database) throws -> (owner: AccessActor, prompt: String)? {
        guard try SharingSetup.isConfirmed(db: db), let owner = try? AccessActor.admin(db: db),
              let name = try AppUser.fetchOne(db, key: owner.appUserId)?.displayName else { return nil }
        return (owner, "Accounts this tool creates will be owned by \(name). Continue? [y/N] ")
    }

    /// Anything but `y` or `Y` declines.
    public static func isYes(_ answer: String?) -> Bool {
        guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return answer == "y" || answer == "Y"
    }
}
