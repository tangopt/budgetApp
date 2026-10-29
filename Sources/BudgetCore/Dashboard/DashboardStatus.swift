import Foundation

/// The one-line status at the right of the Dashboard's title: whether the data is up to date, or the one thing that
/// most needs doing (files waiting to import, data behind, balances out of date) and where to do it.
public struct DashboardStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case upToDate, warning }
    public enum Destination: Equatable, Sendable { case imports, accounts }

    public var kind: Kind
    /// "Up to date", "Imports waiting (2)", "2 balances out of date", "Data is 3 days behind".
    public var message: String
    /// Shown after the message when set ("Up to date · 15 Oct"): the day the transactions go up to.
    public var date: Date?
    /// Where clicking it goes.
    public var destination: Destination

    public init(kind: Kind, message: String, date: Date? = nil, destination: Destination) {
        self.kind = kind
        self.message = message
        self.date = date
        self.destination = destination
    }

    /// The status for the data's freshness, the files waiting for the Mac to import and the stale balances. Files
    /// waiting come first, then data behind, then balances out of date; otherwise it is up to date.
    public static func make(freshness: DataFreshness, importsWaiting: Int, staleBalances: Int) -> DashboardStatus {
        if importsWaiting > 0 {
            return DashboardStatus(kind: .warning, message: "Imports waiting (\(importsWaiting))", destination: .imports)
        }
        switch freshness.status {
        case .noData:
            return DashboardStatus(kind: .warning, message: "Nothing imported yet", destination: .imports)
        case .behind(let months, let days):
            let message = months >= 1 ? "Data is \(months) month\(months == 1 ? "" : "s") behind" : "Data is \(days) day\(days == 1 ? "" : "s") behind"
            return DashboardStatus(kind: .warning, message: message, date: freshness.dataThrough, destination: .imports)
        case .upToDate:
            if staleBalances > 0 {
                return DashboardStatus(kind: .warning, message: "\(staleBalances) balance\(staleBalances == 1 ? "" : "s") out of date", destination: .accounts)
            }
            return DashboardStatus(kind: .upToDate, message: "Up to date", date: freshness.dataThrough ?? freshness.lastImportAt, destination: .imports)
        }
    }
}
