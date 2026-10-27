import Foundation

/// The words for a refused recharge or rent-payment action, shared by the Mac and the iPad.
extension RechargeError {
    public var userMessage: String {
        switch self {
        case .duplicateInvoiceNumber: return "An invoice with that number is already recorded for this provider."
        case .duplicateInvoice: return "That invoice is already recorded for this provider (a copy of the same bill)."
        case .invoiceForPeriodRecorded:
            return "An invoice for that period is already recorded for this provider: correct that one instead of adding a second."
        case .duplicateName: return "There's already a provider with that name."
        case .invalidPeriod: return "The period's end is before its start."
        case .invoiceOnSentStatement: return "That invoice is on a sent statement: its amount and period can't change."
        case .transactionOnAnotherInvoice: return "That bank movement already settles another invoice."
        case let .invalidPattern(pattern): return "“\(pattern)” isn't a valid regular expression."
        case .laterStatementExists: return "A later month's statement exists: prepare the months in order."
        default: return "Couldn't save (\(self))."
        }
    }
}

extension RentPaymentError {
    public var userMessage: String {
        switch self {
        case .receiptNotFound: return "The receipt no longer exists."
        case .transactionNotFound: return "The transaction no longer exists."
        case .notACredit: return "Only credits pay rent."
        case .negativeAmount: return "Amounts can't be negative."
        case .nothingAllocated: return "Nothing would be linked."
        case .overAllocated: return "That's more than is left of the credit."
        case .exceedsReceipt: return "That's more rent than the receipt received."
        case .receiptCancelled: return "Cancelled receipts take no payments."
        }
    }
}
