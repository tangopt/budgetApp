// Tests/BudgetCoreTests/OnDeviceCategorizerTests.swift
import XCTest
@testable import BudgetCore

final class StubGenerativeSession: GenerativeSession {
    var stubbedSuggestion: CategorySuggestion?
    var stubbedBatchSuggestions: [CategorySuggestion?]?
    var stubbedError: Error?
    private(set) var lastDescription: String?
    private(set) var lastCandidates: [String]?
    private(set) var lastBatchDescriptions: [String]?
    private(set) var lastBatchCandidates: [String]?

    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? {
        lastDescription = description
        lastCandidates = candidateCategoryNames
        if let stubbedError { throw stubbedError }
        return stubbedSuggestion
    }

    func suggestCategories(descriptions: [String], candidateCategoryNames: [String]) async throws -> [CategorySuggestion?] {
        lastBatchDescriptions = descriptions
        lastBatchCandidates = candidateCategoryNames
        if let stubbedError { throw stubbedError }
        return stubbedBatchSuggestions ?? descriptions.map { _ in stubbedSuggestion }
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

    func testBatchReturnsNilsForEveryDescriptionWhenModelUnavailable() async throws {
        let session = StubGenerativeSession()
        session.stubbedBatchSuggestions = [CategorySuggestion(categoryName: "Groceries", confidence: 0.9), nil]
        let categorizer = OnDeviceCategorizer(session: session, isAvailable: { false })

        let result = try await categorizer.suggestCategories(descriptions: ["SAINSBURYS", "UNKNOWN"], candidateCategoryNames: ["Groceries"])

        XCTAssertEqual(result, [nil, nil])
        XCTAssertNil(session.lastBatchDescriptions, "session must never be invoked when unavailable")
    }

    func testBatchReturnsSessionSuggestionsInOrderWhenAvailable() async throws {
        let session = StubGenerativeSession()
        session.stubbedBatchSuggestions = [
            CategorySuggestion(categoryName: "Groceries", confidence: 0.9),
            nil,
            CategorySuggestion(categoryName: "Eating Out", confidence: 0.6),
        ]
        let categorizer = OnDeviceCategorizer(session: session, isAvailable: { true })

        let result = try await categorizer.suggestCategories(
            descriptions: ["SAINSBURYS", "MYSTERY SHOP", "NANDOS"],
            candidateCategoryNames: ["Groceries", "Eating Out"]
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0]?.categoryName, "Groceries")
        XCTAssertNil(result[1])
        XCTAssertEqual(result[2]?.categoryName, "Eating Out")
        XCTAssertEqual(session.lastBatchDescriptions, ["SAINSBURYS", "MYSTERY SHOP", "NANDOS"])
        XCTAssertEqual(session.lastBatchCandidates, ["Groceries", "Eating Out"])
    }

    func testBatchPropagatesSessionErrors() async {
        let session = StubGenerativeSession()
        session.stubbedError = NSError(domain: "test", code: 1)
        let categorizer = OnDeviceCategorizer(session: session, isAvailable: { true })

        do {
            _ = try await categorizer.suggestCategories(descriptions: ["X"], candidateCategoryNames: ["Y"])
            XCTFail("expected the session's error to propagate")
        } catch {
            // expected
        }
    }
}
