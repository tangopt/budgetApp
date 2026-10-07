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

    // MARK: - monthlyBalance

    private static func month(_ year: Int, _ month: Int, day: Int = 1) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testMonthlyBalanceCarriesForwardTheLatestPriorSnapshot() {
        let account = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .manual)
        let januarySnapshot = BalanceSnapshot(id: 1, accountId: 1, date: Self.month(2026, 1), balanceMinorUnits: 100000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let result = NetWorthCalculator.monthlyBalance(account: account, snapshots: [januarySnapshot], transactions: [], rate: rate, monthStart: Self.month(2026, 3), monthEnd: Self.month(2026, 3, day: 31))
        XCTAssertEqual(result?.nativeBalanceMinorUnits, 100000)
        XCTAssertEqual(result?.isCarriedForward, true)
    }

    func testMonthlyBalanceIsNotCarriedForwardWhenSnapshotFallsInThatMonth() {
        let account = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .manual)
        let snapshot = BalanceSnapshot(id: 1, accountId: 1, date: Self.month(2026, 2, day: 15), balanceMinorUnits: 150000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let result = NetWorthCalculator.monthlyBalance(account: account, snapshots: [snapshot], transactions: [], rate: rate, monthStart: Self.month(2026, 2), monthEnd: Self.month(2026, 2, day: 28))
        XCTAssertEqual(result?.nativeBalanceMinorUnits, 150000)
        XCTAssertEqual(result?.isCarriedForward, false)
    }

    func testMonthlyBalanceReturnsNilBeforeTheFirstSnapshot() {
        let account = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .manual)
        let firstSnapshot = BalanceSnapshot(id: 1, accountId: 1, date: Self.month(2026, 3), balanceMinorUnits: 100000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let result = NetWorthCalculator.monthlyBalance(account: account, snapshots: [firstSnapshot], transactions: [], rate: rate, monthStart: Self.month(2026, 1), monthEnd: Self.month(2026, 1, day: 31))
        XCTAssertNil(result)
    }

    func testMonthlyBalanceConvertsEURToGBP() {
        let account = Account(id: 1, name: "Lloyds International EUR", currency: .eur, kind: .cash, trackingMode: .manual)
        let snapshot = BalanceSnapshot(id: 1, accountId: 1, date: Self.month(2026, 1), balanceMinorUnits: 100000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let result = NetWorthCalculator.monthlyBalance(account: account, snapshots: [snapshot], transactions: [], rate: rate, monthStart: Self.month(2026, 1), monthEnd: Self.month(2026, 1, day: 31))
        XCTAssertEqual(result?.nativeBalanceMinorUnits, 100000)
        XCTAssertEqual(result?.gbpBalanceMinorUnits, 87000)
    }

    func testMonthlyBalanceForImportedAccountIncludesTransactionsWithinTheMonthAndIsNotCarriedForward() {
        let account = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        let snapshot = BalanceSnapshot(id: 1, accountId: 1, date: Self.month(2026, 1), balanceMinorUnits: 100000, note: nil)
        let transaction = Transaction(id: 1, importBatchId: 1, accountId: 1, date: Self.month(2026, 2, day: 10), rawDescription: "X", amountMinorUnits: -5000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "a")
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let result = NetWorthCalculator.monthlyBalance(account: account, snapshots: [snapshot], transactions: [transaction], rate: rate, monthStart: Self.month(2026, 2), monthEnd: Self.month(2026, 2, day: 28))
        XCTAssertEqual(result?.nativeBalanceMinorUnits, 95000)
        XCTAssertEqual(result?.isCarriedForward, false)
    }

    func testMonthlyBalanceExcludesTransactionsAfterTheQueriedMonth() {
        let account = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        let snapshot = BalanceSnapshot(id: 1, accountId: 1, date: Self.month(2026, 1), balanceMinorUnits: 100000, note: nil)
        let futureTransaction = Transaction(id: 1, importBatchId: 1, accountId: 1, date: Self.month(2026, 3, day: 10), rawDescription: "X", amountMinorUnits: -5000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "a")
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let result = NetWorthCalculator.monthlyBalance(account: account, snapshots: [snapshot], transactions: [futureTransaction], rate: rate, monthStart: Self.month(2026, 2), monthEnd: Self.month(2026, 2, day: 28))
        XCTAssertEqual(result?.nativeBalanceMinorUnits, 100000)
        XCTAssertEqual(result?.isCarriedForward, true)
    }

    // MARK: - monthEndNetWorth

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // Must equal the sum of each account's monthlyBalance — the formula BudgetGridViewModel
    // and ForecastViewModel each used to carry their own copy of.
    func testMonthEndNetWorthSumsCarriedForwardAccountBalances() {
        let gbp = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        let eur = Account(id: 2, name: "EUR", currency: .eur, kind: .cash, trackingMode: .imported)
        let snapshots = [
            BalanceSnapshot(id: 1, accountId: 1, date: utc(2026, 1, 1), balanceMinorUnits: 100_000, note: nil),
            BalanceSnapshot(id: 2, accountId: 1, date: utc(2026, 3, 1), balanceMinorUnits: 150_000, note: nil),
            BalanceSnapshot(id: 3, accountId: 2, date: utc(2026, 2, 1), balanceMinorUnits: 200_000, note: nil)
        ]
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 2, date: utc(2026, 2, 10), rawDescription: "X", amountMinorUnits: -10_000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "x")
        ]
        let rate = ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: utc(2026, 1, 1))

        // Feb 2026: GBP carried forward from Jan (100_000); EUR imported = 200_000 - 10_000 = 190_000 EUR → 95_000 GBP.
        XCTAssertEqual(NetWorthCalculator.monthEndNetWorth(accounts: [gbp, eur], snapshots: snapshots, transactions: transactions, rate: rate, year: 2026, month: 2), 195_000)
        // Mar 2026: GBP picks up its new snapshot (150_000); EUR carries 190_000 → 95_000.
        XCTAssertEqual(NetWorthCalculator.monthEndNetWorth(accounts: [gbp, eur], snapshots: snapshots, transactions: transactions, rate: rate, year: 2026, month: 3), 245_000)
    }

    // Legacy snapshots typed in the old Net Worth screen were stamped with `Date()`, a real time of day.
    // The month window ends at the month's LAST MOMENT, so a snapshot taken at noon on the
    // last day belongs to that month (and not to the previous one).
    func testMonthEndNetWorthIncludesASnapshotLaterThanMidnightOnTheLastDayOfTheMonth() {
        let account = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        let snapshots = [BalanceSnapshot(id: 1, accountId: 1, date: utc(2026, 3, 31).addingTimeInterval(12 * 3600), balanceMinorUnits: 100_000, note: nil)]
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: utc(2026, 1, 1))

        XCTAssertEqual(NetWorthCalculator.monthEndNetWorth(accounts: [account], snapshots: snapshots, transactions: [], rate: rate, year: 2026, month: 3), 100_000)
        XCTAssertNil(NetWorthCalculator.monthEndNetWorth(accounts: [account], snapshots: snapshots, transactions: [], rate: rate, year: 2026, month: 2))
    }

    func testMonthEndNetWorthIsNilBeforeAnyAccountHasData() {
        let gbp = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        let snapshots = [BalanceSnapshot(id: 1, accountId: 1, date: utc(2026, 3, 1), balanceMinorUnits: 100_000, note: nil)]
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: utc(2026, 1, 1))
        XCTAssertNil(NetWorthCalculator.monthEndNetWorth(accounts: [gbp], snapshots: snapshots, transactions: [], rate: rate, year: 2026, month: 2))
    }

    // Several snapshots can share a date (00:00 UTC on the picked day): the higher id wins.
    func testSameDaySnapshotsPickTheHigherIdInAccountBalancesAndMonthlyBalance() {
        let account = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        let snapshots = [
            BalanceSnapshot(id: 7, accountId: 1, date: utc(2026, 3, 10), balanceMinorUnits: 200_000, note: nil),
            BalanceSnapshot(id: 3, accountId: 1, date: utc(2026, 3, 10), balanceMinorUnits: 100_000, note: nil)
        ]
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: utc(2026, 1, 1))
        for ordering in [snapshots, Array(snapshots.reversed())] {
            XCTAssertEqual(NetWorthCalculator.accountBalances(accounts: [account], snapshots: ordering, transactions: [], rate: rate)[0].nativeBalanceMinorUnits, 200_000)
            let range = MonthRange.of(year: 2026, month: 3)
            XCTAssertEqual(NetWorthCalculator.monthlyBalance(account: account, snapshots: ordering, transactions: [], rate: rate, monthStart: range.start, monthEnd: range.end)?.nativeBalanceMinorUnits, 200_000)
        }
    }
}
