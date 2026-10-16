import XCTest
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// The Categories screen's Distribution panel (spec 2026-10-16 §C): budget-facing actuals in
/// a pay year, expenses by group (and each group's categories), income by category.
final class CategoryDistributionTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func s(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day, hour: 12))! }
    /// No salaries: pay months are calendar months.
    private var calendar: PayCalendar { PayCalendar(salaryDates: [], manualCloses: [], today: s(2026, 10, 12)) }

    private let groups = [CategoryGroup(id: 1, name: "Home", type: .expense), CategoryGroup(id: 2, name: "Fun", type: .expense)]
    private let categories = [
        Category(id: 10, name: "Rent", type: .expense, groupId: 1),
        Category(id: 11, name: "Energy", type: .expense, groupId: 1),
        Category(id: 12, name: "Cinema", type: .expense, groupId: 2),
        Category(id: 13, name: "Groceries", type: .expense),
        Category(id: 20, name: "Salary", type: .income),
        Category(id: 21, name: "Interest", type: .income, groupId: 1),
        Category(id: 30, name: "Transfer: Savings", type: .transfer),
        Category(id: 40, name: "Balance adjustment", type: .adjustment, builtInRole: .balanceAdjustment),
    ]

    private var nextId: Int64 = 100
    private func txn(_ date: Date, _ amount: Int, cat: Int64?, status: TransactionStatus = .confirmed, account: Int64 = 1) -> Transaction {
        nextId += 1
        return Transaction(id: nextId, importBatchId: 1, accountId: account, date: date, rawDescription: "t", amountMinorUnits: amount,
                           categoryId: cat, status: status, categorizedBy: .manual, fingerprint: "f\(nextId)")
    }

    private func compute(_ transactions: [Transaction], year: Int? = 2026, links: [TransferLink] = []) -> CategoryDistribution {
        CategoryDistribution.compute(year: year, transactions: transactions, links: links, categories: categories, groups: groups, calendar: calendar)
    }

    func testExpensesByGroupSumTheMembersAsPositiveOutflowsLargestFirst() {
        let result = compute([
            txn(s(2026, 1, 3), -100_000, cat: 10), txn(s(2026, 2, 3), -10_000, cat: 11),
            txn(s(2026, 3, 3), -2_000, cat: 12), txn(s(2026, 3, 4), -30_000, cat: 13),
        ])
        XCTAssertEqual(result.expensesByGroup.map(\.name), ["Home", "Ungrouped", "Fun"])
        XCTAssertEqual(result.expensesByGroup.map(\.amountMinorUnits), [110_000, 30_000, 2_000])
        XCTAssertEqual(result.expensesByGroup.map(\.groupId), [1, nil, 2])
        XCTAssertEqual(result.expenseTotal, 142_000)
    }

    func testEachGroupsCategoriesAreListedUnderTheGroup() {
        let result = compute([txn(s(2026, 1, 3), -100_000, cat: 10), txn(s(2026, 2, 3), -10_000, cat: 11), txn(s(2026, 3, 4), -30_000, cat: 13)])
        XCTAssertEqual(result.expenseCategories(inGroup: 1).map(\.name), ["Rent", "Energy"])
        XCTAssertEqual(result.expenseCategories(inGroup: 1).map(\.categoryId), [10, 11])
        XCTAssertEqual(result.expenseCategories(inGroup: nil).map(\.amountMinorUnits), [30_000])
        XCTAssertEqual(result.expenseCategories(inGroup: 2), [])
    }

    func testRefundsNetAndNetPositiveSlicesAreLeftOut() {
        // Cinema: £20 spent, £50 refunded → net inflow, no slice. Energy: £100 spent, £40 back.
        let result = compute([
            txn(s(2026, 1, 3), -2_000, cat: 12), txn(s(2026, 1, 9), 5_000, cat: 12),
            txn(s(2026, 2, 3), -10_000, cat: 11), txn(s(2026, 2, 9), 4_000, cat: 11),
        ])
        XCTAssertEqual(result.expensesByGroup.map(\.name), ["Home"])
        XCTAssertEqual(result.expensesByGroup.map(\.amountMinorUnits), [6_000])
        XCTAssertEqual(result.expenseCategories(inGroup: 1).map(\.amountMinorUnits), [6_000])
    }

    func testIncomeIsByCategoryWhateverTheGroup() {
        let result = compute([txn(s(2026, 1, 25), 300_000, cat: 20), txn(s(2026, 2, 25), 300_000, cat: 20), txn(s(2026, 3, 1), 1_234, cat: 21)])
        XCTAssertEqual(result.incomeByCategory.map(\.name), ["Salary", "Interest"])
        XCTAssertEqual(result.incomeByCategory.map(\.amountMinorUnits), [600_000, 1_234])
        XCTAssertEqual(result.incomeTotal, 601_234)
        XCTAssertEqual(result.expensesByGroup, [])
    }

    func testTransfersAdjustmentsUnconfirmedAndUncategorisedAreLeftOut() {
        let result = compute([
            txn(s(2026, 1, 3), -50_000, cat: 30), txn(s(2026, 1, 3), -7_000, cat: 40), txn(s(2026, 1, 4), 9_000, cat: 40),
            txn(s(2026, 1, 3), -800, cat: 13, status: .pendingReview), txn(s(2026, 1, 3), -900, cat: nil),
            txn(s(2026, 1, 5), -100, cat: 13),
        ])
        XCTAssertEqual(result.expensesByGroup.map(\.amountMinorUnits), [100])
        XCTAssertEqual(result.incomeByCategory, [])
    }

    func testALinkedTransfersIncomingLegCountsOnce() {
        // A refund-like incoming leg categorised as income is a linked transfer's other side: left out.
        let out = txn(s(2026, 4, 3), -20_000, cat: 30, account: 1)
        let inLeg = txn(s(2026, 4, 3), 20_000, cat: 20, account: 2)
        let link = TransferLink(id: 1, outTransactionId: out.id!, inTransactionId: inLeg.id!, origin: .auto)
        XCTAssertEqual(compute([out, inLeg], links: [link]).incomeByCategory, [])
        XCTAssertEqual(compute([out, inLeg]).incomeTotal, 20_000)
    }

    func testTheYearIsThePayYearAndNilIsAllYears() {
        // Paid on the 20th: 22 Dec 2025 is in pay month Jan 2026.
        let salaries = [s(2025, 11, 20), s(2025, 12, 20), s(2026, 1, 20)]
        let payCalendar = PayCalendar(salaryDates: salaries, manualCloses: [], today: s(2026, 1, 25))
        let transactions = [txn(s(2025, 12, 22), -1_000, cat: 13), txn(s(2025, 12, 10), -500, cat: 13)]
        let in2026 = CategoryDistribution.compute(year: 2026, transactions: transactions, categories: categories, groups: groups, calendar: payCalendar)
        let in2025 = CategoryDistribution.compute(year: 2025, transactions: transactions, categories: categories, groups: groups, calendar: payCalendar)
        let all = CategoryDistribution.compute(year: nil, transactions: transactions, categories: categories, groups: groups, calendar: payCalendar)
        XCTAssertEqual(in2026.expenseTotal, 1_000)
        XCTAssertEqual(in2025.expenseTotal, 500)
        XCTAssertEqual(all.expenseTotal, 1_500)
    }

    func testTiesSortByName() {
        let result = compute([txn(s(2026, 1, 3), -100, cat: 12), txn(s(2026, 1, 3), -100, cat: 10)])
        XCTAssertEqual(result.expensesByGroup.map(\.name), ["Fun", "Home"])
    }

    func testSliceIdsAreStableAndDistinct() {
        let result = compute([txn(s(2026, 1, 3), -100, cat: 12), txn(s(2026, 1, 3), -100, cat: 13), txn(s(2026, 1, 3), 100, cat: 20)])
        XCTAssertEqual(Set(result.expensesByGroup.map(\.id)), ["g-2", "g-ungrouped"])
        XCTAssertEqual(result.incomeByCategory.map(\.id), ["c-20"])
    }
}
