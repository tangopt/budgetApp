import XCTest
@testable import BudgetCore

final class StubURLProtocol: URLProtocol {
    static var responseData: Data?
    static var statusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = Self.responseData { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ExchangeRateFetcherTests: XCTestCase {
    func testHasChangedDetectsA2DecimalDifference() {
        XCTAssertTrue(ExchangeRateFetcher.hasChanged(fetchedRate: 0.86, previousRate: 0.87))
    }

    func testHasChangedIgnoresNoiseBeyond2Decimals() {
        XCTAssertFalse(ExchangeRateFetcher.hasChanged(fetchedRate: 0.870001, previousRate: 0.87))
    }

    func testHasChangedFalseWhenIdentical() {
        XCTAssertFalse(ExchangeRateFetcher.hasChanged(fetchedRate: 0.87, previousRate: 0.87))
    }

    func testNetWorthImpactReflectsOnlyTheEURConversionChange() {
        let eurAccount = Account(id: 1, name: "BBVA", currency: .eur, kind: .cash, trackingMode: .manual)
        let snapshot = BalanceSnapshot(id: 1, accountId: 1, date: Date(), balanceMinorUnits: 100000, note: nil)
        let oldRate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let newRate = ExchangeRateSetting(eurToGbpRate: 0.86, updatedAt: Date())

        let impact = ExchangeRateFetcher.netWorthImpact(accounts: [eurAccount], snapshots: [snapshot], transactions: [], oldRate: oldRate, newRate: newRate)

        // €1000 at 0.87 = £870.00 (87000), at 0.86 = £860.00 (86000) — a £10 drop.
        XCTAssertEqual(impact, -1000)
    }

    func testFrankfurterSourceParsesGBPRate() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        StubURLProtocol.responseData = Data(#"{"amount":1.0,"base":"EUR","date":"2026-01-01","rates":{"GBP":0.86}}"#.utf8)
        StubURLProtocol.statusCode = 200

        let source = FrankfurterExchangeRateSource(session: session)
        let rate = await source.fetchEURToGBPRate()

        XCTAssertEqual(rate, 0.86)
    }

    func testFrankfurterSourceReturnsNilOnNon200() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        StubURLProtocol.responseData = nil
        StubURLProtocol.statusCode = 503

        let source = FrankfurterExchangeRateSource(session: session)
        let rate = await source.fetchEURToGBPRate()

        XCTAssertNil(rate)
    }

    func testFrankfurterSourceReturnsNilOnMalformedJSON() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        StubURLProtocol.responseData = Data("not json".utf8)
        StubURLProtocol.statusCode = 200

        let source = FrankfurterExchangeRateSource(session: session)
        let rate = await source.fetchEURToGBPRate()

        XCTAssertNil(rate)
    }
}
