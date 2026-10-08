import XCTest
@testable import BudgetCore

final class CSVColumnMappingTests: XCTestCase {
    func testStartsAllIgnored() {
        let m = CSVColumnMapping(columnCount: 3)
        XCTAssertEqual(m.roles, [.ignore, .ignore, .ignore])
    }

    func testAssigningDateMovesIt() {
        var m = CSVColumnMapping(columnCount: 3)
        m.assign(.date, toColumn: 0)
        m.assign(.date, toColumn: 2)
        XCTAssertEqual(m.roles, [.ignore, .ignore, .date])
    }

    func testAmountClearsMoneyOutAndIn() {
        var m = CSVColumnMapping(columnCount: 4)
        m.assign(.moneyOut, toColumn: 1)
        m.assign(.moneyIn, toColumn: 2)
        m.assign(.amount, toColumn: 3)
        XCTAssertEqual(m.roles, [.ignore, .ignore, .ignore, .amount])
    }

    func testMoneyOutClearsAmount() {
        var m = CSVColumnMapping(columnCount: 3)
        m.assign(.amount, toColumn: 1)
        m.assign(.moneyOut, toColumn: 2)
        XCTAssertEqual(m.roles, [.ignore, .ignore, .moneyOut])
        m.assign(.amount, toColumn: 0)
        m.assign(.moneyIn, toColumn: 1)
        XCTAssertEqual(m.roles, [.ignore, .moneyIn, .ignore])
    }

    func testMissingRoles() {
        var m = CSVColumnMapping(columnCount: 4)
        XCTAssertEqual(m.missingRoles, [.date, .description, .amount])
        m.assign(.date, toColumn: 0)
        m.assign(.description, toColumn: 1)
        m.assign(.moneyOut, toColumn: 2)
        XCTAssertEqual(m.missingRoles, [.moneyIn])
        m.assign(.moneyIn, toColumn: 3)
        XCTAssertEqual(m.missingRoles, [])
    }

    func testMissingMoneyOutWhenOnlyMoneyIn() {
        var m = CSVColumnMapping(columnCount: 3)
        m.assign(.date, toColumn: 0)
        m.assign(.description, toColumn: 1)
        m.assign(.moneyIn, toColumn: 2)
        XCTAssertEqual(m.missingRoles, [.moneyOut])
    }

    func testProfileNilWhileMissing() {
        var m = CSVColumnMapping(columnCount: 3)
        m.assign(.date, toColumn: 0)
        XCTAssertNil(m.profile(accountId: 1, dateFormat: "dd/MM/yyyy", negateAmounts: false, allowBalance: true))
    }

    func testSingleAmountProfileWithNegate() throws {
        var m = CSVColumnMapping(columnCount: 4)
        m.assign(.date, toColumn: 0)
        m.assign(.description, toColumn: 1)
        m.assign(.amount, toColumn: 2)
        m.assign(.balance, toColumn: 3)
        let p = try XCTUnwrap(m.profile(accountId: 7, dateFormat: "yyyy-MM-dd", negateAmounts: true, allowBalance: true))
        XCTAssertEqual(p.accountId, 7)
        XCTAssertEqual(p.format, .csv)
        XCTAssertEqual(p.csvDateColumnIndex, 0)
        XCTAssertEqual(p.csvDescriptionColumnIndex, 1)
        XCTAssertEqual(p.csvAmountColumnIndex, 2)
        XCTAssertNil(p.csvCreditAmountColumnIndex)
        XCTAssertEqual(p.csvBalanceColumnIndex, 3)
        XCTAssertEqual(p.csvDateFormat, "yyyy-MM-dd")
        XCTAssertTrue(p.csvNegateAmounts)
        XCTAssertEqual(CSVColumnMapping(columnCount: 4, profile: p).roles, m.roles)
    }

    func testSplitProfileAndBalanceDropped() throws {
        var m = CSVColumnMapping(columnCount: 5)
        m.assign(.date, toColumn: 0)
        m.assign(.description, toColumn: 1)
        m.assign(.moneyIn, toColumn: 2)
        m.assign(.moneyOut, toColumn: 3)
        m.assign(.balance, toColumn: 4)
        let p = try XCTUnwrap(m.profile(accountId: 1, dateFormat: "dd/MM/yyyy", negateAmounts: true, allowBalance: false))
        XCTAssertEqual(p.csvAmountColumnIndex, 3)
        XCTAssertEqual(p.csvCreditAmountColumnIndex, 2)
        XCTAssertNil(p.csvBalanceColumnIndex)
        let back = CSVColumnMapping(columnCount: 5, profile: p)
        XCTAssertEqual(back.roles, [.date, .description, .moneyIn, .moneyOut, .ignore])
    }

    func testInitFromSuggestion() {
        let s = CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 1, amountColumn: 3, creditColumn: 2, balanceColumn: 4)
        let m = CSVColumnMapping(columnCount: 5, suggestion: s)
        XCTAssertEqual(m.roles, [.date, .description, .moneyIn, .moneyOut, .balance])
        let single = CSVColumnMapping(columnCount: 3, suggestion: CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 1, amountColumn: 2))
        XCTAssertEqual(single.roles, [.date, .description, .amount])
    }
}
