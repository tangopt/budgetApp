import XCTest
@testable import BudgetCore

final class TransactionSearchTests: XCTestCase {
    private let utc = MonthRange.calendar
    private let utcZone = TimeZone(identifier: "UTC")!

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private let groceries = Category(id: 1, name: "Groceries", type: .expense, groupId: 10)
    private let eatingOut = Category(id: 2, name: "Eating out", type: .expense, groupId: 10)
    private let salary = Category(id: 3, name: "Salary", type: .income)
    private let transfer = Category(id: 4, name: "Transfer: Savings", type: .transfer)
    private let food = CategoryGroup(id: 10, name: "Food", type: .expense)
    private let current = Account(id: 100, name: "Lloyds Current Account", currency: .gbp, kind: .cash, trackingMode: .imported)
    private let euro = Account(id: 200, name: "Revolut EUR", currency: .eur, kind: .cash, trackingMode: .imported)

    private func tx(_ id: Int64, _ description: String, _ amount: Int, date: Date? = nil, category: Int64? = nil, account: Int64 = 100,
                    status: TransactionStatus = .confirmed, note: String? = nil, manual: Bool = false) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: date ?? day(2026, 10, 1), rawDescription: description,
                    amountMinorUnits: amount, categoryId: category, status: status, categorizedBy: category == nil ? .none : .manual,
                    fingerprint: "f\(id)", note: note, isManual: manual)
    }

    private func input(_ transactions: [Transaction], links: [TransferLink] = [], rate: Double = 0.5) -> TransactionSearch.Input {
        TransactionSearch.Input(transactions: transactions, categories: [groceries, eatingOut, salary, transfer],
                                accounts: [current, euro], links: links, eurToGbpRate: rate)
    }

    private let now = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!

    private func ids(_ input: TransactionSearch.Input, _ criteria: TransactionSearch.Criteria) -> [Int64] {
        TransactionSearch.rows(input, criteria: criteria, now: now, timeZone: utcZone).compactMap(\.transaction.id).sorted()
    }

    // MARK: Text

    func testEmptyCriteriaMatchesEverything() {
        let data = input([tx(1, "TESCO", -100), tx(2, "PAY", 5000, category: 3)])
        XCTAssertEqual(ids(data, .init()), [1, 2])
    }

    func testTextMatchesDescriptionCaseInsensitively() {
        let data = input([tx(1, "TESCO STORES 123", -100), tx(2, "Amazon", -200)])
        XCTAssertEqual(ids(data, .init(text: "tesco")), [1])
    }

    func testTextMatchesNoteAndCategoryName() {
        let data = input([tx(1, "X", -100, note: "Birthday present"), tx(2, "Y", -200, category: 1), tx(3, "Z", -300)])
        XCTAssertEqual(ids(data, .init(text: "birthday")), [1])
        XCTAssertEqual(ids(data, .init(text: "grocer")), [2])
    }

    func testEveryWordMustMatchSomewhere() {
        let data = input([tx(1, "TESCO", -100, category: 1), tx(2, "TESCO", -100, category: 2)])
        XCTAssertEqual(ids(data, .init(text: "tesco groceries")), [1])
    }

    func testNumericTokenMatchesAbsoluteAmountExactly() {
        let data = input([tx(1, "A", -1299), tx(2, "B", 1299), tx(3, "C", -12990), tx(4, "D 12.99 ref", -1)])
        XCTAssertEqual(ids(data, .init(text: "12.99")), [1, 2, 4])
        XCTAssertEqual(ids(data, .init(text: "£12.99")), [1, 2])
        XCTAssertEqual(ids(data, .init(text: "-12.99")), [1, 2])
        XCTAssertEqual(ids(data, .init(text: "-£12.99")), [1, 2])
    }

    func testAmountTokenParsing() {
        XCTAssertEqual(TransactionSearch.amountToken("12.99"), 1299)
        XCTAssertEqual(TransactionSearch.amountToken("£12.99"), 1299)
        XCTAssertEqual(TransactionSearch.amountToken("-12.99"), 1299)
        XCTAssertEqual(TransactionSearch.amountToken("€1,200"), 120000)
        XCTAssertEqual(TransactionSearch.amountToken("12"), 1200)
        XCTAssertNil(TransactionSearch.amountToken("tesco"))
        XCTAssertNil(TransactionSearch.amountToken("12abc"))
        XCTAssertNil(TransactionSearch.amountToken("£"))
    }

    // MARK: Dates

    func testDateFilters() {
        let data = input([
            tx(1, "A", -1, date: day(2026, 10, 1)),
            tx(2, "B", -1, date: day(2026, 10, 31)),
            tx(3, "C", -1, date: day(2026, 9, 30)),
            tx(4, "D", -1, date: day(2026, 1, 1)),
            tx(5, "E", -1, date: day(2025, 10, 16)),
            tx(6, "F", -1, date: day(2025, 10, 14)),
        ])
        XCTAssertEqual(ids(data, .init(date: .thisMonth)), [1, 2])
        XCTAssertEqual(ids(data, .init(date: .thisYear)), [1, 2, 3, 4])
        XCTAssertEqual(ids(data, .init(date: .last12Months)), [1, 3, 4, 5])
        XCTAssertEqual(ids(data, .init(date: .allTime)), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(ids(data, .init(date: .custom(from: day(2026, 9, 30), to: day(2026, 10, 1)))), [1, 3])
    }

    func testCustomRangeWithEndBeforeStartIsSwapped() {
        let data = input([tx(1, "A", -1, date: day(2026, 10, 1)), tx(2, "B", -1, date: day(2026, 8, 1))])
        XCTAssertEqual(ids(data, .init(date: .custom(from: day(2026, 10, 1), to: day(2026, 9, 1)))), [1])
    }

    // MARK: Amounts

    func testAmountRangeOnAbsoluteValueAndDirection() {
        let data = input([tx(1, "A", -500), tx(2, "B", 1500), tx(3, "C", -2500), tx(4, "D", 900)])
        XCTAssertEqual(ids(data, .init(minAmountMinorUnits: 900)), [2, 3, 4])
        XCTAssertEqual(ids(data, .init(maxAmountMinorUnits: 1500)), [1, 2, 4])
        XCTAssertEqual(ids(data, .init(minAmountMinorUnits: 600, maxAmountMinorUnits: 2000)), [2, 4])
        XCTAssertEqual(ids(data, .init(direction: .moneyIn)), [2, 4])
        XCTAssertEqual(ids(data, .init(direction: .moneyOut)), [1, 3])
        XCTAssertEqual(ids(data, .init(minAmountMinorUnits: 1000, direction: .moneyOut)), [3])
    }

    // MARK: Accounts and categories

    func testAccountFilter() {
        let data = input([tx(1, "A", -1), tx(2, "B", -1, account: 200)])
        XCTAssertEqual(ids(data, .init(accountIds: [200])), [2])
        XCTAssertEqual(ids(data, .init(accountIds: [100, 200])), [1, 2])
    }

    func testCategoryFilterAndUncategorised() {
        let data = input([tx(1, "A", -1, category: 1), tx(2, "B", -1, category: 2), tx(3, "C", -1)])
        XCTAssertEqual(ids(data, .init(categoryIds: [1])), [1])
        XCTAssertEqual(ids(data, .init(includesUncategorised: true)), [3])
        XCTAssertEqual(ids(data, .init(categoryIds: [2], includesUncategorised: true)), [2, 3])
    }

    func testGroupSelectsAllMembers() {
        let members = TransactionSearch.memberIds(ofGroupId: 10, categories: [groceries, eatingOut, salary])
        XCTAssertEqual(members, [1, 2])
        let data = input([tx(1, "A", -1, category: 1), tx(2, "B", -1, category: 2), tx(3, "C", 1, category: 3)])
        XCTAssertEqual(ids(data, .init(categoryIds: members)), [1, 2])
    }

    // MARK: Flags

    func testFlags() {
        let links = [TransferLink(id: 1, outTransactionId: 3, inTransactionId: 4, origin: .auto),
                     TransferLink(id: 2, outTransactionId: 5, inTransactionId: 6, origin: .auto, isDismissed: true)]
        let data = input([
            tx(1, "A", -1, status: .pendingReview),
            tx(2, "B", -1, note: "hi", manual: true),
            tx(3, "C", -1, category: 4),
            tx(4, "D", 1, category: 4, account: 200),
            tx(5, "E", -1),
            tx(6, "F", 1),
        ], links: links)
        XCTAssertEqual(ids(data, .init(flags: [.unreviewed])), [1])
        XCTAssertEqual(ids(data, .init(flags: [.manual])), [2])
        XCTAssertEqual(ids(data, .init(flags: [.hasNote])), [2])
        XCTAssertEqual(ids(data, .init(flags: [.linkedTransfer])), [3, 4])
        XCTAssertEqual(ids(data, .init(flags: [.manual, .hasNote])), [2])
        XCTAssertEqual(ids(data, .init(flags: [.manual, .unreviewed])), [])
    }

    func testLinkedIncomingLegsAreSearchable() {
        let links = [TransferLink(id: 1, outTransactionId: 1, inTransactionId: 2, origin: .auto)]
        let data = input([tx(1, "To savings", -100), tx(2, "From current", 100, account: 200)], links: links)
        XCTAssertEqual(ids(data, .init(text: "from current")), [2])
        let row = TransactionSearch.rows(data, criteria: .init(text: "from current"), now: now, timeZone: utcZone)[0]
        XCTAssertTrue(row.isLinkedTransfer)
    }

    // MARK: Combinations

    func testCriteriaCombine() {
        let data = input([
            tx(1, "TESCO", -1299, date: day(2026, 10, 2), category: 1),
            tx(2, "TESCO", -1299, date: day(2026, 10, 2), category: 1, account: 200),
            tx(3, "TESCO", -1299, date: day(2025, 1, 2), category: 1),
            tx(4, "TESCO", -500, date: day(2026, 10, 2), category: 1),
        ])
        let criteria = TransactionSearch.Criteria(text: "tesco", date: .thisMonth, minAmountMinorUnits: 1000, accountIds: [100], categoryIds: [1])
        XCTAssertEqual(ids(data, criteria), [1])
    }

    func testIsDefault() {
        XCTAssertTrue(TransactionSearch.Criteria().isDefault)
        XCTAssertTrue(TransactionSearch.Criteria(text: "  ").isDefault)
        XCTAssertFalse(TransactionSearch.Criteria(flags: [.manual]).isDefault)
        XCTAssertFalse(TransactionSearch.Criteria(includesUncategorised: true).isDefault)
    }

    // MARK: Rows and sorting

    func testRowsCarryCategoryAndAccountNames() {
        let data = input([tx(1, "A", -1, category: 1), tx(2, "B", -1, account: 200)])
        let rows = TransactionSearch.rows(data, criteria: .init(), now: now, timeZone: utcZone)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byId[1]?.categoryName, "Groceries")
        XCTAssertEqual(byId[1]?.category?.id, 1)
        XCTAssertEqual(byId[1]?.accountName, current.displayName)
        XCTAssertEqual(byId[2]?.categoryName, "")
        XCTAssertNil(byId[2]?.category)
        XCTAssertEqual(byId[2]?.currency, .eur)
    }

    func testDefaultSortIsNewestFirst() {
        let data = input([tx(1, "A", -1, date: day(2026, 1, 1)), tx(2, "B", -1, date: day(2026, 3, 1)), tx(3, "C", -1, date: day(2026, 2, 1))])
        XCTAssertEqual(TransactionSearch.rows(data, criteria: .init(), now: now, timeZone: utcZone).map(\.id), [2, 3, 1])
    }

    func testSortByEachColumn() {
        let data = input([
            tx(1, "beta", -300, date: day(2026, 1, 1), category: 2),
            tx(2, "Alpha", 100, date: day(2026, 3, 1), category: 1, account: 200),
            tx(3, "gamma", -50, date: day(2026, 2, 1)),
        ])
        let rows = TransactionSearch.rows(data, criteria: .init(), now: now, timeZone: utcZone)
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .date, ascending: true).map(\.id), [1, 3, 2])
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .description, ascending: true).map(\.id), [2, 1, 3])
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .category, ascending: true).map(\.id), [3, 1, 2])
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .account, ascending: true).map(\.id), [3, 1, 2])
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .amount, ascending: true).map(\.id), [1, 3, 2])
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .amount, ascending: false).map(\.id), [2, 3, 1])
    }

    func testTiesKeepNewestFirst() {
        let data = input([tx(1, "Same", -1, date: day(2026, 1, 1)), tx(2, "Same", -1, date: day(2026, 3, 1))])
        let rows = TransactionSearch.rows(data, criteria: .init(), now: now, timeZone: utcZone)
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .description, ascending: true).map(\.id), [2, 1])
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .description, ascending: false).map(\.id), [2, 1])
    }

    // MARK: Totals

    func testTotalsConvertEuroToSterling() {
        let data = input([tx(1, "A", 1000), tx(2, "B", -300), tx(3, "C", -400, account: 200), tx(4, "D", 201, account: 200)], rate: 0.5)
        let totals = TransactionSearch.totals(TransactionSearch.rows(data, criteria: .init(), now: now, timeZone: utcZone), eurToGbpRate: 0.5)
        XCTAssertEqual(totals.count, 4)
        XCTAssertEqual(totals.inMinorUnits, 1000 + 101)
        XCTAssertEqual(totals.outMinorUnits, -300 - 200)
        XCTAssertEqual(totals.netMinorUnits, 1101 - 500)
    }

    func testTotalsOfNothing() {
        let totals = TransactionSearch.totals([], eurToGbpRate: 1)
        XCTAssertEqual(totals, TransactionSearch.Totals(count: 0, inMinorUnits: 0, outMinorUnits: 0))
    }

    // MARK: Review fixes

    func testTextIgnoresAccents() {
        let data = input([tx(1, "CAFÉ NERO", -100), tx(2, "Cafe", -100, note: "crème brûlée")])
        XCTAssertEqual(ids(data, .init(text: "cafe")), [1, 2])
        XCTAssertEqual(ids(data, .init(text: "brulee")), [2])
    }

    func testAWordNeverSpansTwoFields() {
        let data = input([tx(1, "TESCO", -100, note: "EXTRA")])
        XCTAssertEqual(ids(data, .init(text: "tescoextra")), [])
    }

    func testIndexIsReusableAcrossCriteria() {
        let index = TransactionSearch.Index(input([tx(1, "TESCO", -100), tx(2, "AMAZON", -200)]))
        XCTAssertEqual(TransactionSearch.rows(index, criteria: .init(text: "tesco"), now: now, timeZone: utcZone).map(\.id), [1])
        XCTAssertEqual(TransactionSearch.rows(index, criteria: .init(text: "amazon"), now: now, timeZone: utcZone).map(\.id), [2])
    }

    func testRelativeDatesFollowTheLocalDay() {
        // 23:30 UTC on 31 Oct is already 1 Nov in Paris (UTC+1).
        let lateOctober = utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 30))!
        let paris = TimeZone(identifier: "Europe/Paris")!
        let data = input([tx(1, "Oct", -1, date: day(2026, 10, 31)), tx(2, "Nov", -1, date: day(2026, 11, 1)),
                          tx(3, "Year ago", -1, date: day(2025, 11, 1)), tx(4, "Older", -1, date: day(2025, 10, 31))])
        let thisMonth = TransactionSearch.rows(data, criteria: .init(date: .thisMonth), now: lateOctober, timeZone: paris)
        XCTAssertEqual(thisMonth.map(\.id), [2])
        let last12 = TransactionSearch.rows(data, criteria: .init(date: .last12Months), now: lateOctober, timeZone: paris)
        XCTAssertEqual(last12.map(\.id).sorted(), [1, 2, 3])
        let utcMonth = TransactionSearch.rows(data, criteria: .init(date: .thisMonth), now: lateOctober, timeZone: utcZone)
        XCTAssertEqual(utcMonth.map(\.id), [1])
    }

    func testDateAscendingBreaksTiesByEarlierId() {
        let data = input([tx(5, "A", -1, date: day(2026, 1, 1)), tx(3, "B", -1, date: day(2026, 1, 1)), tx(4, "C", -1, date: day(2026, 1, 1))])
        let rows = TransactionSearch.rows(data, criteria: .init(), now: now, timeZone: utcZone)
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .date, ascending: true).map(\.id), [3, 4, 5])
        XCTAssertEqual(TransactionSearch.sorted(rows, by: .date, ascending: false).map(\.id), [5, 4, 3])
    }

    func testIncomingLegKnowsItsOutgoingLeg() {
        let links = [TransferLink(id: 1, outTransactionId: 1, inTransactionId: 2, origin: .auto),
                     TransferLink(id: 2, outTransactionId: 3, inTransactionId: 4, origin: .auto, isDismissed: true)]
        let data = input([tx(1, "Out", -100), tx(2, "In", 100), tx(3, "Out2", -1), tx(4, "In2", 1)], links: links)
        let byId = Dictionary(uniqueKeysWithValues: TransactionSearch.rows(data, criteria: .init(), now: now, timeZone: utcZone).map { ($0.id, $0) })
        XCTAssertEqual(byId[2]?.outgoingTransactionId, 1)
        XCTAssertTrue(byId[2]?.isIncomingTransferLeg == true)
        XCTAssertNil(byId[1]?.outgoingTransactionId)
        XCTAssertNil(byId[4]?.outgoingTransactionId)
    }

    func testTotalsCountALinkedTransferOnce() {
        let links = [TransferLink(id: 1, outTransactionId: 1, inTransactionId: 2, origin: .auto)]
        let data = input([tx(1, "Out", -10000), tx(2, "In", 10000, account: 200), tx(3, "Pay", 5000)], links: links, rate: 1)
        let rows = TransactionSearch.rows(data, criteria: .init(), now: now, timeZone: utcZone)
        let once = TransactionSearch.totals(rows, eurToGbpRate: 1, countsTransfersOnce: true)
        XCTAssertEqual(once, TransactionSearch.Totals(count: 3, inMinorUnits: 5000, outMinorUnits: -10000, excludedTransferLegCount: 1))
        let raw = TransactionSearch.totals(rows, eurToGbpRate: 1, countsTransfersOnce: false)
        XCTAssertEqual(raw, TransactionSearch.Totals(count: 3, inMinorUnits: 15000, outMinorUnits: -10000))
    }
}
