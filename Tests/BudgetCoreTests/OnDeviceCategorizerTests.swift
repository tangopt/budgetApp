// Tests/BudgetCoreTests/OnDeviceCategorizerTests.swift
import XCTest
@testable import BudgetCore

final class StubGenerativeSession: GenerativeSession {
    var stubbedSuggestion: CategorySuggestion?
    var stubbedError: Error?
    private(set) var lastDescription: String?
    private(set) var lastCandidates: [String]?

    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? {
        lastDescription = description
        lastCandidates = candidateCategoryNames
        if let stubbedError { throw stubbedError }
        return stubbedSuggestion
    }
}

final class OnDeviceCategorizerTests: XCTestCase {
    func testReturnsNilWhenModelUnavailable() async throws {
        let session = StubGenerativeSession()
        session.stubbedSuggestion = CategorySuggestion(categoryName: "Groceries", confidence: 0.9)
        let categorizer = OnDeviceCategorizer(session: session, isAvailable: { false })

        let result = try await categorizer.suggestCategory(description: "SAINSBURYS", candidateCategoryNames: ["Groceries"])

        XCTAssertNil(result)
        XCTAssertNil(session.lastDescription, "session must never be invoked when unavailable")
    }

    func testReturnsSessionSuggestionWhenAvailable() async throws {
        let session = StubGenerativeSession()
        session.stubbedSuggestion = CategorySuggestion(categoryName: "Groceries", confidence: 0.92)
        let categorizer = OnDeviceCategorizer(session: session, isAvailable: { true })

        let result = try await categorizer.suggestCategory(description: "SAINSBURYS LONDON", candidateCategoryNames: ["Groceries", "Eating Out"])

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.categoryName, "Groceries")
        XCTAssertEqual(unwrapped.confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(session.lastDescription, "SAINSBURYS LONDON")
        XCTAssertEqual(session.lastCandidates, ["Groceries", "Eating Out"])
    }

    func testPropagatesSessionErrors() async {
        let session = StubGenerativeSession()
        session.stubbedError = NSError(domain: "test", code: 1)
        let categorizer = OnDeviceCategorizer(session: session, isAvailable: { true })

        do {
            _ = try await categorizer.suggestCategory(description: "X", candidateCategoryNames: ["Y"])
            XCTFail("expected the session's error to propagate")
        } catch {
            // expected
        }
    }
}
