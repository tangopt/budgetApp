import Foundation

/// The iPad's check-and-link wording (step 10 Task 7): what holds a downloaded file back, and what Save did.
/// Filed-year refusals keep `DeviceWriteCopy`'s; `AccessDenied` and `EvidenceLinkGuard.Failure` their own.
public enum CheckAndLinkCopy {
    /// The edit named in a filed-year question and its notes ("Checked and saved Invoice FT 1/23 of Demo Power").
    public static func edit(_ title: String) -> String { "Checked and saved \(title)" }

    /// Something still needs an answer before Save: the first reason, and how many more.
    public static func needsAnswer(_ reasons: [String]) -> String {
        guard let first = reasons.first else { return "Not saved: something still needs checking." }
        let more = reasons.count - 1
        return "Not saved: \(first)" + (more > 0 ? " (and \(more) more to answer)" : "")
    }

    /// The file, or every row of the statement, is in Mango already: nothing to save; discard it from the downloads.
    public static func alreadyInMango(_ of: String) -> String {
        "Already in Mango: \(of). Nothing to save; discard it from the downloads."
    }

    /// What Mango read since the file was checked changed (a record gone, an invoice recorded on the Mac).
    public static func outdated(_ detail: String) -> String {
        "Not saved: \(detail). Check the file again."
    }

    /// A file the iPad doesn't save (a payroll form, a rent receipts export).
    public static func macOnly(_ kind: String) -> String {
        "Not saved: a \(kind.lowercased()) is imported on the Mac. Keep it in the downloads, or share it to the Mac."
    }

    /// A file the tray no longer holds (discarded, or the downloads cleared).
    public static let notInTray = "Not saved: this download is no longer in the tray."

    /// A bank statement saved on the iPad: kept for the Mac, which imports it.
    public static let sentToMac = "Sent to the Mac to import"

    /// Why the statement is on the waiting list (its row's reason, shown on the Mac).
    public static let sentReason = "Sent from the iPad to import"

    /// A statement on a member's iPad: her kept files don't reach the Mac's import.
    public static let statementNeedsAdmin = "Not sent: statements are imported on the Mac. Share it to the Mac to import it there."

    /// After Save: the file is a normal document, linked or recorded.
    public static func saved(_ title: String) -> String { "Saved \(title)" }

    /// A utility bill's tenant share line: "€42.10 for Flat A" ("17 of 60 days in the tenancy" after it when prorated).
    public static func tenantShare(amount: String, tenancy: String, note: String?) -> String {
        "\(amount) for \(tenancy)" + (note.map { " (\($0))" } ?? "")
    }

    /// The recharge statement a bill joins: the tenancy's draft, else a new one for the bill's month.
    public static func joinsStatement(month: String, isNew: Bool) -> String {
        isNew ? "Goes on a new \(month) statement" : "Joins the \(month) statement (draft)"
    }

    /// A statement's closing balance against what Mango holds for the account.
    public static let balanceMatches = "Closing balance matches the account"
}
