import Foundation

/// The iPad's write refusals (step 8). `AccessDenied` and `EvidenceLinkGuard.Failure` keep their own copy.
public enum DeviceWriteCopy {
    /// No app user here is bound to this iPad's iCloud user yet (before the household pull names her).
    public static let notLinkedYet = "Mango hasn't linked this iPad to you yet. Sync, then try again."

    /// An edit that would move a figure on a filed or paid return: the iPad doesn't ask, the Mac does.
    public static func filedYear(years: [String]) -> String {
        let returns = years.count == 1 ? "the filed \(years[0]) return" : "the filed \(FiledYearEditCheck.list(years)) returns"
        return "Not saved: this would change \(returns). To change it anyway, use the Mac."
    }

    /// Shown in place of an edit control in an area the user only views.
    public static func viewOnly(_ area: AccessArea) -> String {
        "View only: you don't have Edit on \(area.title)."
    }

    /// Edits made here that can't go up any more: the user lost Edit before they were sent (they stay on this iPad
    /// only, until the Mac's version replaces them).
    public static func notSent(_ count: Int) -> String {
        "\(count) change\(count == 1 ? "" : "s") not sent — you can no longer change this"
    }

    /// A refusal with no copy of its own (a statement already sent, an amount that no longer fits).
    public static let notSaved = "Not saved: this can't change here any more. Sync, then try again, or use the Mac."
}
