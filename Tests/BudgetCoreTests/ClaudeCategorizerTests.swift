import XCTest
@testable import BudgetCore

final class StubAPIKeyStore: APIKeyStoring {
    var key: String?
    func getAPIKey() -> String? { key }
    func setAPIKey(_ key: String) throws { self.key = key }
}

final class StubURLProtocol: URLProtocol {
    static var responseData: Data?
    static var statusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = Self.responseData {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClaudeCategorizerTests: XCTestCase {
    func testReturnsNilWhenNoAPIKeyConfigured() async throws {
        let store = StubAPIKeyStore()
        let categorizer = ClaudeCategorizer(apiKeyStore: store, session: .shared)
        let suggestion = try await categorizer.suggestCategory(description: "SAINSBURYS", candidateCategoryNames: ["Groceries"])
        XCTAssertNil(suggestion)
    }

    func testParsesSuggestionFromClaudeResponse() async throws {
        let store = StubAPIKeyStore()
        store.key = "test-key"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let responseJSON = """
        {"content":[{"type":"text","text":"{\\"categoryName\\":\\"Groceries\\",\\"confidence\\":0.92}"}]}
        """
        StubURLProtocol.responseData = Data(responseJSON.utf8)
        StubURLProtocol.statusCode = 200

        let categorizer = ClaudeCategorizer(apiKeyStore: store, session: session)
        let suggestion = try await categorizer.suggestCategory(description: "SAINSBURYS LONDON", candidateCategoryNames: ["Groceries", "Eating Out"])
        let unwrapped = try XCTUnwrap(suggestion)
        XCTAssertEqual(unwrapped.categoryName, "Groceries")
        XCTAssertEqual(unwrapped.confidence, 0.92, accuracy: 0.001)
    }

    // I7: with adaptive thinking, a `thinking` block precedes the `text` block.
    func testParsesTextBlockThatFollowsAThinkingBlock() async throws {
        let store = StubAPIKeyStore()
        store.key = "test-key"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        StubURLProtocol.responseData = Data("""
        {"content":[{"type":"thinking","thinking":"","signature":"abc"},{"type":"text","text":"{\\"categoryName\\":\\"Eating Out\\",\\"confidence\\":0.8}"}],"stop_reason":"end_turn"}
        """.utf8)
        StubURLProtocol.statusCode = 200

        let suggestion = try await ClaudeCategorizer(apiKeyStore: store, session: session)
            .suggestCategory(description: "NANDOS", candidateCategoryNames: ["Groceries", "Eating Out"])
        XCTAssertEqual(suggestion?.categoryName, "Eating Out")
    }

    func testParsesJSONWrappedInMarkdownCodeFence() {
        let body = """
        {"content":[{"type":"redacted_thinking","data":"xyz"},{"type":"text","text":"```json\\n{\\"categoryName\\": \\"Groceries\\", \\"confidence\\": 1}\\n```"}]}
        """
        let suggestion = ClaudeCategorizer.parseSuggestion(fromResponseData: Data(body.utf8))
        XCTAssertEqual(suggestion?.categoryName, "Groceries")
        XCTAssertEqual(suggestion?.confidence, 1.0)
    }

    func testParsesJSONSurroundedByProse() {
        XCTAssertEqual(ClaudeCategorizer.jsonObject(inModelText: "Sure: {\"categoryName\": \"Rent\", \"confidence\": 0.5} hope that helps")?["categoryName"] as? String, "Rent")
        XCTAssertEqual(ClaudeCategorizer.jsonObject(inModelText: "```\n{\"categoryName\": \"Rent\", \"confidence\": 0.5}\n```")?["categoryName"] as? String, "Rent")
    }

    func testResponseWithoutTextBlockIsUnparsable() {
        let body = #"{"content":[{"type":"thinking","thinking":"","signature":"abc"}],"stop_reason":"max_tokens"}"#
        XCTAssertNil(ClaudeCategorizer.parseSuggestion(fromResponseData: Data(body.utf8)))
    }
}
