import Foundation

/// Fetches the current EUR→GBP rate from a free, no-API-key source (Frankfurter.app,
/// backed by ECB reference rates) — no dependency on the on-device categorizer or any
/// paid API. Never throws: every failure mode (offline, non-200, malformed JSON) just
/// returns nil, so the caller falls back to the last saved rate.
public protocol ExchangeRateSource {
    func fetchEURToGBPRate() async -> Double?
}

public final class FrankfurterExchangeRateSource: ExchangeRateSource {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchEURToGBPRate() async -> Double? {
        guard let url = URL(string: "https://api.frankfurter.app/latest?from=EUR&to=GBP") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = envelope["rates"] as? [String: Any],
                  let gbp = (rates["GBP"] as? NSNumber)?.doubleValue else { return nil }
            return gbp
        } catch {
            return nil
        }
    }
}

public enum ExchangeRateFetcher {
    /// True when the two rates round to different values at 2 decimal places — the
    /// granularity the app displays and stores rates at, so anything finer is noise.
    public static func hasChanged(fetchedRate: Double, previousRate: Double) -> Bool {
        (fetchedRate * 100).rounded() != (previousRate * 100).rounded()
    }

    /// Net worth computed with `newRate` minus net worth computed with `oldRate`, holding
    /// every other input (accounts, snapshots, transactions) fixed — isolates exactly the
    /// effect of the rate change, for the launch-time impact banner.
    public static func netWorthImpact(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], oldRate: ExchangeRateSetting, newRate: ExchangeRateSetting) -> Int {
        let oldNetWorth = NetWorthCalculator.netWorth(balances: NetWorthCalculator.accountBalances(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: oldRate))
        let newNetWorth = NetWorthCalculator.netWorth(balances: NetWorthCalculator.accountBalances(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: newRate))
        return newNetWorth - oldNetWorth
    }
}
