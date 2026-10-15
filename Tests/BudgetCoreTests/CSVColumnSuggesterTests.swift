// Tests/BudgetCoreTests/CSVColumnSuggesterTests.swift
import XCTest
@testable import BudgetCore

final class CSVColumnSuggesterTests: XCTestCase {
    func testSuggestsLloydsDebitCreditLayout() {
        let header = ["Transaction Date", "Transaction Type", "Sort Code", "Account Number",
                      "Transaction Description", "Debit Amount", "Credit Amount", "Balance"]
        XCTAssertEqual(
            CSVColumnSuggester.suggest(header: header),
            CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 4, amountColumn: 5, creditColumn: 6, balanceColumn: 7,
                                sortCodeColumn: 2, accountNumberColumn: 3)
        )
    }

    func testSuggestsSingleAmountLayout() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Date", "Description", "Amount"])
        XCTAssertEqual(suggestion, CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 1, amountColumn: 2, creditColumn: nil, balanceColumn: nil))
        XCTAssertFalse(suggestion.hasSeparateDebitCredit)
    }

    func testSuggestsPaidInPaidOutLayout() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Date", "Details", "Paid out", "Paid in", "Balance"])
        XCTAssertEqual(suggestion, CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 1, amountColumn: 2, creditColumn: 3, balanceColumn: 4))
        XCTAssertTrue(suggestion.hasSeparateDebitCredit)
    }

    func testLoneCreditColumnIsIgnored() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Date", "Description", "Credit", "Notes"])
        XCTAssertNil(suggestion.amountColumn)
        XCTAssertNil(suggestion.creditColumn)
    }

    func testPrefersTransactionDateOverOtherDateColumns() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Posting Date", "Transaction Date", "Description", "Amount"])
        XCTAssertEqual(suggestion.dateColumn, 1)
    }

    func testDescriptionKeywordPriority() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Date", "Reference", "Payee", "Narrative", "Amount"])
        XCTAssertEqual(suggestion.descriptionColumn, 3)
    }

    func testUnknownHeaderYieldsNoSuggestions() {
        XCTAssertEqual(CSVColumnSuggester.suggest(header: ["A", "B", "C"]), CSVColumnSuggestion())
    }

    func testMatchingIsCaseInsensitive() {
        let suggestion = CSVColumnSuggester.suggest(header: ["DATE", "DESCRIPTION", "AMOUNT", "RUNNING BALANCE"])
        XCTAssertEqual(suggestion, CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 1, amountColumn: 2, creditColumn: nil, balanceColumn: 3))
    }

    func testTwoDateColumnsPickTheFirst() {
        XCTAssertEqual(CSVColumnSuggester.suggest(header: ["Type", "Started Date", "Completed Date", "Description", "Amount"]).dateColumn, 1)
    }

    func testFeeAndStatusColumns() {
        let s = CSVColumnSuggester.suggest(header: ["Started Date", "Description", "Amount", "Fee", "Currency", "State", "Balance"])
        XCTAssertEqual(s.feeColumn, 3)
        XCTAssertEqual(s.statusColumn, 5)
        XCTAssertEqual(s.amountColumn, 2)
        XCTAssertEqual(s.balanceColumn, 6)
        let other = CSVColumnSuggester.suggest(header: ["Date", "Details", "Amount", "FEES", "Status"])
        XCTAssertEqual(other.feeColumn, 3)
        XCTAssertEqual(other.statusColumn, 4)
    }

    func testFeeAndStatusMatchWholeWordsOnly() {
        let s = CSVColumnSuggester.suggest(header: ["Date", "Coffee Notes", "Amount", "Statement Ref", "Feedback"])
        XCTAssertNil(s.feeColumn)
        XCTAssertNil(s.statusColumn)
    }
}
