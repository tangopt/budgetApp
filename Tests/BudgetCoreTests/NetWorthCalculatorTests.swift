import XCTest
@testable import BudgetCore

final class NetWorthCalculatorTests: XCTestCase {
    func testRunningBalanceIsSnapshotPlusTransactionsSince() {
        let snapshot = BalanceSnapshot(id: 1, accountId: 1, date: Date(timeIntervalSince1970: 0), balanceMinorUnits: 100000, note: nil)
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: Date(timeIntervalSince1970: 1000), rawDescription: "A", amountMinorUnits: -5000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "a"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: Date(timeIntervalSince1970: 2000), rawDescription: "B", amountMinorUnits: 2000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "b")
        ]
        let account = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        let balance = NetWorthCalculator.runningBalance(account: account, latestSnapshot: snapshot, transactionsSinceSnapshot: transactions)
        XCTAssertEqual(balance, 97000)
    }

    func testManualAccountUsesLatestSnapshotOnly() {
        let snapshot = BalanceSnapshot(id: 1, accountId: 2, date: Date(), balanceMinorUnits: 500000, note: nil)
        let account = Account(id: 2, name: "Lloyds Investment ISA", currency: .gbp, kind: .investment, trackingMode: .manual)
        let balance = NetWorthCalculator.runningBalance(account: account, latestSnapshot: snapshot, transactionsSinceSnapshot: [])
        XCTAssertEqual(balance, 500000)
    }

    func testEURAccountConvertsToGBPUsingRate() {
        let account = Account(id: 3, name: "BBVA Portugal", currency: .eur, kind: .cash, trackingMode: .manual)
        let snapshot = BalanceSnapshot(id: 2, accountId: 3, date: Date(), balanceMinorUnits: 100000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let balances = NetWorthCalculator.accountBalances(accounts: [account], snapshots: [snapshot], transactions: [], rate: rate)
        XCTAssertEqual(balances[0].nativeBalanceMinorUnits, 100000)
        XCTAssertEqual(balances[0].gbpBalanceMinorUnits, 87000)
    }

    func testCreditAccountIsALiabilitySubtractedFromNetWorth() {
        let cash = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        let credit = Account(id: 4, name: "AMEX", currency: .gbp, kind: .credit, trackingMode: .imported)
        let cashSnapshot = BalanceSnapshot(id: 1, accountId: 1, date: Date(), balanceMinorUnits: 200000, note: nil)
        // £300 owed is stored signed, as -30000 (see NetWorthCalculator's sign convention).
        let creditSnapshot = BalanceSnapshot(id: 2, accountId: 4, date: Date(), balanceMinorUnits: -30000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let balances = NetWorthCalculator.accountBalances(accounts: [cash, credit], snapshots: [cashSnapshot, creditSnapshot], transactions: [], rate: rate)
        let netWorth = NetWorthCalculator.netWorth(balances: balances)
        XCTAssertEqual(netWorth, 170000)
    }

    // C7 probe: owing £300 plus a new £50 charge must be £350 owed, not £250.
    func testCreditCardChargeIncreasesAmountOwedAndReducesNetWorth() {
        let cash = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        let amex = Account(id: 4, name: "AMEX", currency: .gbp, kind: .credit, trackingMode: .imported)
        let snapshotDate = Date(timeIntervalSince1970: 0)
        let cashSnapshot = BalanceSnapshot(id: 1, accountId: 1, date: snapshotDate, balanceMinorUnits: 200000, note: nil)
        let amexSnapshot = BalanceSnapshot(
            id: 2, accountId: 4, date: snapshotDate,
            balanceMinorUnits: NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: 30000, accountKind: .credit),
            note: nil
        )
        let charge = Transaction(id: 1, importBatchId: 1, accountId: 4, date: Date(timeIntervalSince1970: 1000), rawDescription: "RESTAURANT", amountMinorUnits: -5000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "a")
        let repayment = Transaction(id: 2, importBatchId: 1, accountId: 4, date: Date(timeIntervalSince1970: 2000), rawDescription: "PAYMENT RECEIVED", amountMinorUnits: 10000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "b")

        XCTAssertEqual(NetWorthCalculator.runningBalance(account: amex, latestSnapshot: amexSnapshot, transactionsSinceSnapshot: [charge]), -35000)
        XCTAssertEqual(NetWorthCalculator.runningBalance(account: amex, latestSnapshot: amexSnapshot, transactionsSinceSnapshot: [charge, repayment]), -25000)

        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let balances = NetWorthCalculator.accountBalances(accounts: [cash, amex], snapshots: [cashSnapshot, amexSnapshot], transactions: [charge], rate: rate)
        XCTAssertEqual(balances[1].nativeBalanceMinorUnits, -35000)
        XCTAssertEqual(NetWorthCalculator.enteredBalance(signedMinorUnits: balances[1].nativeBalanceMinorUnits, accountKind: .credit), 35000)
        XCTAssertEqual(NetWorthCalculator.netWorth(balances: balances), 200000 - 35000)
    }

    func testSignedSnapshotBalanceOnlyNegatesCreditAccounts() {
        XCTAssertEqual(NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: 30000, accountKind: .credit), -30000)
        XCTAssertEqual(NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: -1000, accountKind: .credit), 1000)
        XCTAssertEqual(NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: 30000, accountKind: .cash), 30000)
        XCTAssertEqual(NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: 30000, accountKind: .investment), 30000)
    }

    func testReconciliationOnCreditAccountUsesSignedBalances() {
        let amex = Account(id: 4, name: "AMEX", currency: .gbp, kind: .credit, trackingMode: .imported)
        let snapshot = BalanceSnapshot(id: 1, accountId: 4, date: Date(timeIntervalSince1970: 0), balanceMinorUnits: -30000, note: nil)
        let charge = Transaction(id: 1, importBatchId: 1, accountId: 4, date: Date(timeIntervalSince1970: 1000), rawDescription: "X", amountMinorUnits: -5000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "a")
        let computed = NetWorthCalculator.runningBalance(account: amex, latestSnapshot: snapshot, transactionsSinceSnapshot: [charge])
        // User checks the AMEX app and enters "£350 owed": no drift.
        let entered = NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: 35000, accountKind: .credit)
        XCTAssertEqual(NetWorthCalculator.reconciliationDrift(computedNativeBalanceMinorUnits: computed, actualNativeBalanceMinorUnits: entered), 0)
    }

    func testReconciliationDriftIsNilWhenNoActualBalanceProvided() {
        let account = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        let snapshot = BalanceSnapshot(id: 1, accountId: 1, date: Date(), balanceMinorUnits: 100000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let balances = NetWorthCalculator.accountBalances(accounts: [account], snapshots: [snapshot], transactions: [], rate: rate)
        XCTAssertNil(balances[0].reconciliationDriftMinorUnits)
    }
}
