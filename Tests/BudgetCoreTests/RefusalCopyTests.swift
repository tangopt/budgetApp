import XCTest
@testable import BudgetCore

final class RefusalCopyTests: XCTestCase {
    func testRechargeRefusalsKeepTheMacWording() {
        XCTAssertEqual(RechargeError.duplicateName.userMessage, "There's already a provider with that name.")
        XCTAssertEqual(RechargeError.invalidPattern("(").userMessage, "“(” isn't a valid regular expression.")
        XCTAssertEqual(RechargeError.laterStatementExists.userMessage,
                       "A later month's statement exists: prepare the months in order.")
        XCTAssertEqual(RechargeError.invoiceOnSentStatement.userMessage,
                       "That invoice is on a sent statement: its amount and period can't change.")
        XCTAssertTrue(RechargeError.statementNotDraft.userMessage.hasPrefix("Couldn't save"))
    }

    func testEveryRentPaymentRefusalHasCopy() {
        let all: [RentPaymentError] = [.receiptNotFound, .transactionNotFound, .notACredit, .negativeAmount,
                                       .nothingAllocated, .overAllocated, .exceedsReceipt, .receiptCancelled]
        for error in all { XCTAssertFalse(error.userMessage.isEmpty) }
        XCTAssertEqual(RentPaymentError.exceedsReceipt.userMessage, "That's more rent than the receipt received.")
    }
}
