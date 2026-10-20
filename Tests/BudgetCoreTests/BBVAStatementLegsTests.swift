import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

/// The BBVA statement legs shared by the earlier-history import and the in-app statement reader
/// (`BBVAStatementLegs`): synthetic movements, receipts and fund movements only.
final class BBVAStatementLegsTests: XCTestCase {
    private typealias Legs = BBVAStatementLegs
    private typealias Parser = BBVAStatementParser

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func movement(_ date: Date, _ description: String, _ amount: Int) -> Parser.Movement {
        Parser.Movement(date: date, valueDate: date, description: description, amountMinorUnits: amount, balanceAfterMinorUnits: nil)
    }

    private func receipt(_ number: Int, on date: Date, total: Int, capital: Int, interest: Int, fees: Int = 0, late: Int = 0, taxes: Int = 0, owedAfter: Int = 900_000) -> Parser.LoanReceipt {
        Parser.LoanReceipt(number: number, of: 480, totalMinorUnits: total, valueDate: date, operationDate: date, capitalMinorUnits: capital,
                           interestMinorUnits: interest, feesMinorUnits: fees, lateInterestMinorUnits: late, taxesMinorUnits: taxes,
                           outstandingAfterMinorUnits: owedAfter, tan: 1.2)
    }

    private func fundMovement(_ date: Date, _ amount: Int) -> Parser.FundMovement {
        Parser.FundMovement(date: date, valueDate: date, description: "SUBSCRIÇÃO PERIÓDICA", units: 1, price: 50, amountMinorUnits: amount)
    }

    private func fund(_ movements: [Parser.FundMovement], opening: Int = 100_000, closing: Int = 110_000) -> Parser.Fund {
        Parser.Fund(account: "000/222222222", openingUnits: 10, openingPrice: 100, openingMinorUnits: opening,
                    closingUnits: 11, closingPrice: 100, closingMinorUnits: closing, movements: movements)
    }

    // MARK: Pure matching

    func testMatchInstalmentsPairsByOperationDayAndTotal() {
        let movements = [
            movement(day(2022, 11, 2), "TRF TENANT ONE", 150_000),
            movement(day(2022, 11, 30), "COBR. REC. TOT 000 00-000000-0", -30_000),
            movement(day(2022, 12, 30), "COBR. REC. TOT 000 00-000000-0", -31_000),
        ]
        let paired = receipt(10, on: day(2022, 11, 30), total: 30_000, capital: 20_000, interest: 10_000)
        let orphan = receipt(11, on: day(2022, 12, 31), total: 31_000, capital: 21_000, interest: 10_000)
        let result = Legs.matchInstalments(movements: movements, receipts: [paired, orphan])
        XCTAssertEqual(result.matches, [Legs.InstalmentMatch(movementIndex: 1, receipt: paired)])
        XCTAssertEqual(result.movementsWithoutReceipt, [2])
        XCTAssertEqual(result.receiptsWithoutMovement, [orphan])
    }

    func testPairFundMovementsTakesTheClosestDay() {
        let movements = [
            movement(day(2022, 11, 25), "SUBSCRIÇÃO PERI 100,0000", -5_000),
            movement(day(2022, 11, 29), "SUBSCRIÇÃO PERI 100,0000", -5_000),
            movement(day(2022, 11, 29), "MANUTENCAO CONTA", -5_000),
        ]
        let near = fundMovement(day(2022, 11, 30), 5_000)
        let far = fundMovement(day(2022, 12, 20), 5_000)
        let result = Legs.pairFundMovements(movements: movements, fund: fund([near, far]))
        XCTAssertEqual(result.pairs, [Legs.FundPair(movementIndex: 1, fundMovement: near)])
        XCTAssertEqual(result.unpairedSubscriptions, [0])
        XCTAssertEqual(result.unpairedFundMovements, [far])
        XCTAssertEqual(Legs.pairFundMovements(movements: movements, fund: nil).unpairedSubscriptions, [0, 1])
    }

    func testLookalikeAndReversedInstalmentsAreNotPaired() {
        // A lookalike debit isn't an instalment.
        XCTAssertFalse(Legs.isInstalment("COBR. REC. PARC 000 ELECTRICIDADE"))
        XCTAssertFalse(Legs.isInstalment("COBRANCA RECIBO TOTAL"))
        XCTAssertTrue(Legs.isInstalment("COBR. REC. TOT 000 00-000000-0"))
        // A positive COBR REC TOT row (a reversal) is a candidate but never pairs: it is left
        // without a receipt, and the receipt without a movement.
        let reversal = movement(day(2022, 11, 30), "COBR. REC. TOT 000 00-000000-0", 30_000)
        let lookalike = movement(day(2022, 11, 30), "COBR. REC. PARC 000 ELECTRICIDADE", -30_000)
        let settled = receipt(10, on: day(2022, 11, 30), total: 30_000, capital: 20_000, interest: 10_000)
        let result = Legs.matchInstalments(movements: [lookalike, reversal], receipts: [settled])
        XCTAssertEqual(result.matches, [])
        XCTAssertEqual(result.movementsWithoutReceipt, [1])
        XCTAssertEqual(result.receiptsWithoutMovement, [settled])
    }

    func testChargesAreInterestFeesLateInterestAndTaxes() {
        XCTAssertEqual(Legs.charges(receipt(1, on: day(2022, 1, 1), total: 31_000, capital: 20_000, interest: 9_000, fees: 1_000, late: 600, taxes: 400)), 11_000)
    }

    // MARK: Writes

    private func makeDB() throws -> (DatabaseManager, bbva: Int64, loan: Int64, fund: Int64, interest: Int64) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let ids = try manager.dbQueue.write { db -> (Int64, Int64, Int64, Int64) in
            let bbva = try AccountEditing.add(db: db, name: "Sample bank", currency: .eur, kind: .cash, openingBalanceEntered: 500_000, asOf: day(2022, 10, 31))
            let loan = try AccountEditing.add(db: db, name: "Sample loan", currency: .eur, kind: .credit, openingBalanceEntered: 920_000, asOf: day(2022, 10, 31))
            let fund = try AccountEditing.add(db: db, name: "Sample fund", currency: .eur, kind: .investment, openingBalanceEntered: 100_000, asOf: day(2022, 10, 31))
            let group = try CategoryGroups.create(db: db, name: "Home", type: .expense)
            let interest = try Categories.create(db: db, name: BBVAFundMortgageImport.interestCategoryName, type: .expense, groupId: group.id)
            return (bbva.id!, loan.id!, fund.id!, interest.id!)
        }
        return (manager, ids.0, ids.1, ids.2, ids.3)
    }

    private func balance(_ db: Database, _ accountId: Int64) throws -> Int {
        NetWorthCalculator.balance(accountId: accountId, at: nil, snapshots: try BalanceSnapshot.fetchAll(db), transactions: try Transaction.fetchAll(db))?.native ?? 0
    }

    func testAddInstalmentWritesTheLoanLegAndTheInterestRow() throws {
        let (manager, bbva, loan, _, interest) = try makeDB()
        let item = receipt(10, on: day(2022, 11, 30), total: 30_000, capital: 18_000, interest: 10_000, fees: 1_000, late: 500, taxes: 500)
        try manager.dbQueue.write { db in
            let debit = try ManualTransactions.add(db: db, accountId: bbva, date: day(2022, 11, 30), description: "COBR. REC. TOT 000 00-000000-0",
                                                   amountMinorUnits: -30_000, categoryId: nil, note: nil)
            let loanBefore = try balance(db, loan)
            let written = try Legs.addInstalment(db: db, instalmentRowId: debit.id!, receipt: item, loanAccountId: loan, interestCategoryId: interest)
            XCTAssertEqual(written.leg.accountId, loan)
            XCTAssertEqual(written.leg.amountMinorUnits, 30_000)
            XCTAssertEqual(try TransferLink.active.filter(Column("outTransactionId") == debit.id! && Column("inTransactionId") == written.leg.id!).fetchCount(db), 1)
            let row = try XCTUnwrap(written.interest)
            XCTAssertEqual(row.accountId, loan)
            XCTAssertEqual(row.amountMinorUnits, -12_000)
            XCTAssertEqual(row.categoryId, interest)
            XCTAssertEqual(row.date, day(2022, 11, 30))
            XCTAssertEqual(row.rawDescription, "Mortgage interest (instalment 10)")
            XCTAssertEqual(row.note, "Instalment 10, due 2022-11-30: capital €180.00, interest €105.00, fees €10.00, taxes €5.00 — total €300.00. Source: BBVA statement (COBRANÇAS EFECTUADAS) (TAN 1.200%).")
            XCTAssertEqual(try balance(db, loan) - loanBefore, 18_000)
        }
    }

    func testAddInstalmentWithoutChargesWritesOnlyTheLeg() throws {
        let (manager, bbva, loan, _, interest) = try makeDB()
        try manager.dbQueue.write { db in
            let debit = try ManualTransactions.add(db: db, accountId: bbva, date: day(2022, 11, 30), description: "COBR. REC. TOT", amountMinorUnits: -20_000, categoryId: nil, note: nil)
            let written = try Legs.addInstalment(db: db, instalmentRowId: debit.id!, receipt: receipt(10, on: day(2022, 11, 30), total: 20_000, capital: 20_000, interest: 0),
                                                 loanAccountId: loan, interestCategoryId: interest)
            XCTAssertNil(written.interest)
            XCTAssertEqual(written.leg.amountMinorUnits, 20_000)
        }
    }

    func testMarketMovementIsNilWhenTheBalanceAlreadyEqualsTheValue() throws {
        let (manager, _, _, fundId, _) = try makeDB()
        // The fund opened at €1,000.00 and the statement values it at €1,000.00: no movement.
        let statement = Parser.Statement(periodStart: day(2022, 11, 1), periodEnd: day(2022, 11, 30), currentAccount: "000/111111111", openingMinorUnits: 0,
                                         closingMinorUnits: 0, movements: [], fund: fund([], closing: 100_000),
                                         summary: [:], loanReceipts: [], unreadLines: [])
        try manager.dbQueue.write { db in
            XCTAssertNil(try Legs.marketMovement(db: db, fundAccountId: fundId, statement: statement, since: day(2022, 10, 31), openingMinorUnits: 100_000))
            XCTAssertNil(try Legs.marketMovement(db: db, fundAccountId: fundId, statement: statement, since: nil, openingMinorUnits: nil))
            XCTAssertEqual(try Transaction.filter(Column("accountId") == fundId).fetchCount(db), 0)
        }
    }

    func testFundSubscriptionAndMarketMovement() throws {
        let (manager, bbva, _, fundId, _) = try makeDB()
        let statement = Parser.Statement(periodStart: day(2022, 11, 1), periodEnd: day(2022, 11, 30), currentAccount: "000/111111111", openingMinorUnits: 0,
                                         closingMinorUnits: 0, movements: [], fund: fund([fundMovement(day(2022, 11, 30), 5_000)], closing: 106_050),
                                         summary: [:], loanReceipts: [], unreadLines: [])
        try manager.dbQueue.write { db in
            let debit = try ManualTransactions.add(db: db, accountId: bbva, date: day(2022, 11, 30), description: "SUBSCRIÇÃO PERI", amountMinorUnits: -5_000, categoryId: nil, note: nil)
            let leg = try Legs.addFundSubscription(db: db, subscriptionRowId: debit.id!, fundAccountId: fundId)
            XCTAssertEqual(leg.accountId, fundId)
            XCTAssertEqual(leg.amountMinorUnits, 5_000)
            // From the opening the import set (the day before), or from the app's balance.
            let market = try XCTUnwrap(try Legs.marketMovement(db: db, fundAccountId: fundId, statement: statement, since: day(2022, 10, 31), openingMinorUnits: 100_000))
            XCTAssertEqual(market.amountMinorUnits, 1_050)
            XCTAssertEqual(market.date, day(2022, 11, 30))
            XCTAssertEqual(market.categoryId, try BuiltInCategories.category(db: db, role: .marketMovement).id)
            XCTAssertEqual(market.note, "Statement 2022-11: 11 units at 100 = €1,060.50")
            XCTAssertEqual(try balance(db, fundId), 106_050)
            // Already equal, and already has one that day: nothing more.
            XCTAssertNil(try Legs.marketMovement(db: db, fundAccountId: fundId, statement: statement, since: nil, openingMinorUnits: nil))
            try market.delete(db)
            XCTAssertEqual(try Legs.marketMovement(db: db, fundAccountId: fundId, statement: statement, since: nil, openingMinorUnits: nil)?.amountMinorUnits, 1_050)
            let other = Parser.Statement(periodStart: day(2022, 11, 1), periodEnd: day(2022, 11, 30), currentAccount: nil, openingMinorUnits: 0, closingMinorUnits: 0,
                                         movements: [], fund: fund([], closing: 107_000), summary: [:], loanReceipts: [], unreadLines: [])
            XCTAssertNil(try Legs.marketMovement(db: db, fundAccountId: fundId, statement: other, since: nil, openingMinorUnits: nil))
        }
    }
}
