// Tests/BudgetCoreTests/ReviewPartitioningTests.swift
import XCTest
@testable import BudgetCore

final class ReviewPartitioningTests: XCTestCase {
    func makeParsed(_ description: String = "X") -> ParsedTransaction {
        ParsedTransaction(date: Date(), rawDescription: description, amountMinorUnits: -100)
    }

    func testRuleMatchIsReady() {
        let staged = StagedTransaction(parsed: makeParsed(), suggestedCategoryId: 1, source: .rule, confidence: 1.0, fingerprint: "a")
        let (ready, needsAttention) = ReviewPartitioning.partition([staged])
        XCTAssertEqual(ready.map(\.id), [staged.id])
        XCTAssertTrue(needsAttention.isEmpty)
    }

    func testHighConfidenceLLMIsReady() {
        let staged = StagedTransaction(parsed: makeParsed(), suggestedCategoryId: 1, source: .llm, confidence: 0.6, fingerprint: "a")
        let (ready, needsAttention) = ReviewPartitioning.partition([staged])
        XCTAssertEqual(ready.map(\.id), [staged.id])
        XCTAssertTrue(needsAttention.isEmpty)
    }

    func testLowConfidenceLLMNeedsAttention() {
        let staged = StagedTransaction(parsed: makeParsed(), suggestedCategoryId: 1, source: .llm, confidence: 0.59, fingerprint: "a")
        let (ready, needsAttention) = ReviewPartitioning.partition([staged])
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(needsAttention.map(\.id), [staged.id])
    }

    func testNoSuggestionNeedsAttention() {
        let staged = StagedTransaction(parsed: makeParsed(), suggestedCategoryId: nil, source: .none, confidence: 0.0, fingerprint: "a")
        let (ready, needsAttention) = ReviewPartitioning.partition([staged])
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(needsAttention.map(\.id), [staged.id])
    }

    func testPreservesOriginalOrderWithinEachGroup() {
        let a = StagedTransaction(parsed: makeParsed("A"), suggestedCategoryId: 1, source: .rule, confidence: 1.0, fingerprint: "a")
        let b = StagedTransaction(parsed: makeParsed("B"), suggestedCategoryId: nil, source: .none, confidence: 0.0, fingerprint: "b")
        let c = StagedTransaction(parsed: makeParsed("C"), suggestedCategoryId: 2, source: .rule, confidence: 1.0, fingerprint: "c")
        let (ready, needsAttention) = ReviewPartitioning.partition([a, b, c])
        XCTAssertEqual(ready.map(\.id), [a.id, c.id])
        XCTAssertEqual(needsAttention.map(\.id), [b.id])
    }
}
