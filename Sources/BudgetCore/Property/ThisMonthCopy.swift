import Foundation

/// The iPad's This-month checklist wording (step 10 Task 9). Named by the tenancy, never the tenant: the tenant's
/// personal name is only on Tenancies and in the recharge email.
public enum ThisMonthCopy {
    /// "September 2026".
    public static func month(_ date: Date) -> String { RechargeEmail.monthName(date, language: .english) }

    /// "5 Oct 2026".
    public static func day(_ date: Date) -> String { MortgageTerms.dayText(date) }

    // MARK: Step 1: last month's recharge paid

    public static func rechargePaidTitle(_ month: Date) -> String { "\(Self.month(month)) recharge paid" }
    public static let firstMonth = "The tenancy's first month: there is no recharge from last month."
    public static func nothingRecharged(_ month: Date) -> String { "Nothing was recharged for \(Self.month(month))." }
    public static func notSentYet(_ month: Date) -> String { "\(Self.month(month))'s statement isn't sent yet" }
    public static func paidBy(transfers: [(amount: String, day: Date)]) -> String {
        let parts = transfers.map { "\($0.amount) on \(day($0.day))" }
        return (parts.count == 1 ? "Tenant transfer of " : "Tenant transfers of ") + parts.joined(separator: " and ")
    }
    public static let paid = "Paid"
    public static func confirmMatch(transfer: String, day: Date, statement: String) -> String {
        "Transfer of \(transfer) on \(Self.day(day)) for a \(statement) statement: confirm it pays the recharge"
    }
    public static let notExact = "Not an exact match"
    public static let waitingForMac = "Waiting for the Mac to import"
    public static let waitingForTransfer = "Waiting for the tenant's transfer"
    public static func fetchStatement(_ since: Date) -> String { "No bank movements since \(day(since)) yet: fetch the BBVA statement." }
    public static func noTransferSeen(_ statement: String) -> String {
        "No tenant transfer of \(statement) seen in the bank statement. Received another way? Mark it received."
    }

    // MARK: Step 2: this month's bills

    public static func billsTitle(_ month: Date) -> String { "\(Self.month(month)) bills" }
    public static let noBillsExpected = "No utility bills expected this month."
    public static func billsChecked(_ checked: Int, of total: Int) -> String { "\(checked) of \(total) checked" }
    public static func billsDetail(fetched: Int, missing: Int) -> String? {
        var parts: [String] = []
        if fetched > 0 { parts.append("\(fetched) downloaded, to check") }
        if missing > 0 { parts.append("\(missing) to fetch") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Step 3: charges in the bills grid

    public static let chargesTitle = "Charges in the bills grid"
    public static let chargesAutomatic = "Added once this month's bills are checked."
    public static func chargesIn(_ count: Int) -> String { count == 1 ? "1 charge in the grid" : "\(count) charges in the grid" }

    // MARK: Step 4: email the tenant

    public static func emailTitle(_ tenancy: String) -> String { "Email the \(tenancy) statement" }
    public static func sentOn(_ day: Date?) -> String { day.map { "Sent on \(Self.day($0))" } ?? "Sent" }
    public static func readyToSend(_ total: String) -> String { "Ready to send: \(total)" }
    public static let afterSteps = "Available once last month's recharge and this month's bills are done."
    public static let noChargesYet = "Nothing on this month's statement yet."
    public static let nothingToRecharge = "Nothing to recharge this month."

    // MARK: Not running

    public static let notStarted = "The tenancy hasn't started yet."
    public static let ended = "The tenancy has ended."

    // MARK: Side column

    public static let rentReceiptIn = "This month's rent receipt is in"
    public static let fetchRentReceipt = "Fetch this month's rent receipt from Portal das Finanças"
    public static func condominiumPaid(_ day: Date) -> String { "Condomínio paid on \(Self.day(day))" }
    public static func condominiumDue(_ day: Date) -> String { "Condomínio due on \(Self.day(day))" }
}
