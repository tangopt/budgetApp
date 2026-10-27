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
}
