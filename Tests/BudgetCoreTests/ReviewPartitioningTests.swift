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

    func testHistorySuggestionIsReady() {
        let staged = StagedTransaction(parsed: makeParsed(), suggestedCategoryId: 1, source: .history, confidence: 0.8, fingerprint: "a", historyCount: 3)
        let (ready, needsAttention) = ReviewPartitioning.partition([staged])
        XCTAssertEqual(ready.map(\.id), [staged.id])
        XCTAssertTrue(needsAttention.isEmpty)
    }

    // Spec §1: model suggestions always need a look, however confident.
    func testModelSuggestionIsNeverReady() {
        for confidence in [0.59, 0.6, 0.95, 1.0] {
            let staged = StagedTransaction(parsed: makeParsed(), suggestedCategoryId: 1, source: .llm, confidence: confidence, fingerprint: "a")
            let (ready, needsAttention) = ReviewPartitioning.partition([staged])
            XCTAssertTrue(ready.isEmpty)
            XCTAssertEqual(needsAttention.map(\.id), [staged.id])
        }
    }

    // Spec §1: a group is ready only when every row in it is.
    func testAGroupWithOneUnsureRowNeedsAttentionAsAWhole() {
        let a = StagedTransaction(parsed: makeParsed("SAINSBURYS S/MKTS"), suggestedCategoryId: 1, source: .rule, confidence: 1.0, fingerprint: "a")
        let b = StagedTransaction(parsed: makeParsed("TFL TRAVEL CH"), suggestedCategoryId: 2, source: .rule, confidence: 1.0, fingerprint: "b")
        let c = StagedTransaction(parsed: makeParsed("SAINSBURYS S/MKT"), suggestedCategoryId: 1, source: .llm, confidence: 0.9, fingerprint: "c")
        let (ready, needsAttention) = ReviewPartitioning.partition([a, b, c])
        XCTAssertEqual(ready.map(\.id), [b.id])
        XCTAssertEqual(needsAttention.map(\.id), [a.id, c.id])
    }

    func testPartitionAcceptsPrecomputedGroupKeys() {
        let a = StagedTransaction(parsed: makeParsed("A"), suggestedCategoryId: 1, source: .rule, confidence: 1.0, fingerprint: "a")
        let b = StagedTransaction(parsed: makeParsed("B"), suggestedCategoryId: nil, source: .none, confidence: 0.0, fingerprint: "b")
        let (ready, needsAttention) = ReviewPartitioning.partition([a, b], groupKeys: ["K", "K"])
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(needsAttention.map(\.id), [a.id, b.id])
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
