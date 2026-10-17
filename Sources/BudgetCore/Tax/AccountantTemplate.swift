import GRDB
import Foundation

/// The accountant's template (spec §4 outputs (b); plan phase 3 Task 3), one .xlsx per person:
/// "Rental accounts - yyyy.yy" (the rent by month and the expense lines in the property's
/// currency, the person's share) and "Other information" (the FTCR inputs, other income).
/// The layout mirrors the accountant's file cell for cell; only positions and the template's
/// own labels are encoded here, never anyone's figures.
public enum AccountantTemplate {
    /// Income the rental accounts don't hold, for "Other information" (minor units; `nil` blank).
    public struct OtherInformation: Equatable, Sendable {
        /// Offshore, in the property's currency.
        public var offshoreInterest: Int?
        public var offshoreDividends: Int?
        public var otherOffshoreIncome: Int?
        /// UK, in GBP.
        public var p60Pay: Int?
        public var p11dBenefits: Int?
        public var ukInterest: Int?
        public var ukDividends: Int?
        public var otherUKIncome: Int?
        public var pensionContributions: Int?

        public init(offshoreInterest: Int? = nil, offshoreDividends: Int? = nil, otherOffshoreIncome: Int? = nil, p60Pay: Int? = nil,
                    p11dBenefits: Int? = nil, ukInterest: Int? = nil, ukDividends: Int? = nil, otherUKIncome: Int? = nil,
                    pensionContributions: Int? = nil) {
            self.offshoreInterest = offshoreInterest
            self.offshoreDividends = offshoreDividends
            self.otherOffshoreIncome = otherOffshoreIncome
            self.p60Pay = p60Pay
            self.p11dBenefits = p11dBenefits
            self.ukInterest = ukInterest
            self.ukDividends = ukDividends
            self.otherUKIncome = otherUKIncome
            self.pensionContributions = pensionContributions
        }
    }

    /// The accountant's layout: rows of the rental accounts sheet (values in column D,
    /// comments in G).
    public enum Layout {
        public static let valueColumn = "D"
        public static let commentColumn = "G"
        /// April … March.
        public static let firstMonthRow = 11
        public static let totalIncomeRow = 24
        public static let firstExpenseRow = 28
        public static let lastExpenseRow = 44
        public static let totalExpensesRow = 47
        public static let profitRow = 49
        public static let lossBroughtForwardRow = 51
        public static let lossCarriedForwardRow = 53
        public static let taxableProfitRow = 55
        public static let notesRow = 59
        public static let noteCount = 11

        /// The expense rows, top to bottom, with the template's labels; the types the app
        /// fills (the others stay blank for the accountant).
        public static let expenseRows: [(row: Int, label: String, type: TaxExpenseType?)] = [
            (28, "Mortgage interest", .financeCost),
            (29, "Repairs and Maintenance", .repairs),
            (30, "Bad Debt", nil),
            (31, "Gas Safety Certificate", nil),
            (32, "Service charge", .serviceCharge),
            (33, "Insurance (Building insurance)", .insurance),
            (34, "Letting fee", .lettingFees),
            (35, "Legal Fees", .legalFees),
            (36, "Check in Check Out", nil),
            (37, "Inventory", nil),
            (38, "Council tax-if paid by landlord", .councilTax),
            (39, "Cleaning", nil),
            (40, "Registering Deposit", nil),
            (41, "Utility Bills", .utilities),
            (42, "Accountancy fee", .accountancy),
            (43, "Private residential tenancy board", nil),
            (44, "Any other expense", .otherExpense)
        ]

        public static let months = ["April", "May", "June", "July", "August", "September", "October", "November", "December",
                                    "January", "February", "March"]

        /// "Rental accounts - 2024.25".
        public static func rentalSheetName(_ year: UKTaxYear) -> String { "Rental accounts - \(dotted(year))" }
        public static let otherSheetName = "Other information"

        static func dotted(_ year: UKTaxYear) -> String { year.label.replacingOccurrences(of: "/", with: ".") }
    }

    /// "Template - 2024-25 - Person A.xlsx" (the sheet keeps the accountant's "2024.25").
    public static func fileName(taxYear: UKTaxYear, personName: String) -> String {
        TaxFileNames.fileName("Template - \(taxYear.fileLabel) - \(personName)", ext: "xlsx")
    }

    /// The two sheets for `accounts`. `foreignTaxBasisRent` is the person's rent on the basis
    /// of their foreign tax line (`RentalAccounts.foreignTaxBasisRent`), so D7 (rent) and D9
    /// (PT tax) match: under "Previous calendar year" both are calendar year N's (the PT
    /// return's year); under the time-apportioned rule both are calendar years N and N + 1
    /// apportioned to the UK year by days.
    public static func sheets(accounts: RentalAccounts.Result, personName: String, foreignTaxBasisRent calendarYearRent: Int,
                              other: OtherInformation = OtherInformation(), notes: [String] = []) -> [XLSXSheetContent] {
        let year = accounts.taxYear
        let code = accounts.currency.rawValue.uppercased()
        let isPounds = accounts.currency == .gbp
        let amountStyle: XLSXCellStyle = isPounds ? .pound : .euro
        let subtotalStyle: XLSXCellStyle = isPounds ? .poundSubtotal : .euroSubtotal
        let totalStyle: XLSXCellStyle = isPounds ? .poundTotal : .euroTotal
        func money(_ minor: Int) -> Double { Double(minor) / 100 }
        var cells: [XLSXCell] = [
            XLSXCell("A1", .text(personName), style: .bold),
            XLSXCell("A2", .text("HMRC self-assessment tax return"), style: .bold),
            XLSXCell("A3", .text("Tax year: \(year.label)"), style: .bold),
            XLSXCell("A4", .text("Offshore Rental Accounts"), style: .bold),
            XLSXCell("D6", .text("Tax Year"), style: .boldUnderline),
            XLSXCell("D7", .text(year.label), style: .bold),
            XLSXCell("F7", .text("Total"), style: .bold),
            XLSXCell("G7", .text("Comments"), style: .bold),
            XLSXCell("D8", .text(code), style: .bold),
            XLSXCell("A9", .text("Rent Receivable:"), style: .bold),
            XLSXCell("A10", .text("Date"), style: .boldItalic),
            XLSXCell("B10", .text("Month"), style: .boldItalic)
        ]
        for (index, name) in Layout.months.enumerated() {
            let row = Layout.firstMonthRow + index
            cells.append(XLSXCell("B\(row)", .text(name)))
            let amount = index < accounts.rentMonths.count ? accounts.rentMonths[index].amount : 0
            cells.append(XLSXCell("D\(row)", .number(money(amount)), style: amountStyle))
        }
        let lastMonthRow = Layout.firstMonthRow + 11
        let rentTotal = accounts.rentMonths.reduce(0) { $0 + $1.amount }
        cells.append(XLSXCell("A\(Layout.totalIncomeRow)", .text("Total Rental (Receivable) income")))
        cells.append(XLSXCell("D\(Layout.totalIncomeRow)", .formula("SUM(D\(Layout.firstMonthRow):D\(lastMonthRow))", cached: money(rentTotal)),
                              style: subtotalStyle))
        if rentTotal != accounts.income.amount.native {
            cells.append(XLSXCell("G\(Layout.totalIncomeRow)", .text("Rental income per the accounts: \(Money.format(accounts.income.amount.native, currency: accounts.currency))")))
        }

        cells.append(XLSXCell("A27", .text("Less expenses:"), style: .bold))
        var expenseTotal = 0
        for (row, label, type) in Layout.expenseRows {
            cells.append(XLSXCell("B\(row)", .text(label)))
            guard let type, let line = accounts.line(type) else { continue }
            if line.amount.native != 0 {
                cells.append(XLSXCell("D\(row)", .number(money(line.amount.native)), style: amountStyle))
                expenseTotal += line.amount.native
            }
            // Pound items aren't in the euro column: say so, as the accountant's comments do.
            if line.amount.gbpNative != 0 {
                let labels = line.sources.filter { $0.currency == .gbp }.map(\.description)
                let list = Array(NSOrderedSet(array: labels)).compactMap { $0 as? String }.joined(separator: ", ")
                cells.append(XLSXCell("G\(row)", .text("Also \(Money.format(line.amount.gbpNative, currency: .gbp)) in GBP, not included above (\(list)).")))
            }
        }
        cells.append(XLSXCell("B\(Layout.totalExpensesRow)", .text("TOTAL EXPENSES")))
        cells.append(XLSXCell("D\(Layout.totalExpensesRow)", .formula("SUM(D\(Layout.firstExpenseRow):D\(Layout.lastExpenseRow))",
                                                                         cached: money(expenseTotal)), style: subtotalStyle))
        cells.append(XLSXCell("A\(Layout.profitRow)", .text("Profit/(Loss) from rental income")))
        cells.append(XLSXCell("D\(Layout.profitRow)", .formula("D\(Layout.totalIncomeRow)-D\(Layout.totalExpensesRow)",
                                                                 cached: money(rentTotal - expenseTotal)), style: totalStyle))
        cells.append(XLSXCell("A\(Layout.lossBroughtForwardRow)", .text("Loss b/f")))
        cells.append(XLSXCell("A\(Layout.lossCarriedForwardRow)", .text("Loss c/f")))
        cells.append(XLSXCell("A\(Layout.taxableProfitRow)", .text("Taxable Profit")))
        cells.append(XLSXCell("A\(Layout.notesRow)", .text("Notes:")))
        for index in 0..<Layout.noteCount {
            let row = Layout.notesRow + 1 + index
            cells.append(XLSXCell("A\(row)", .number(Double(index + 1))))
            if index < notes.count { cells.append(XLSXCell("B\(row)", .text(notes[index]))) }
        }
        let rental = XLSXSheetContent(name: Layout.rentalSheetName(year),
                                      columnWidths: [1: 8.83, 2: 32.16, 3: 2, 4: 14, 5: 1.33, 6: 12, 7: 11.16, 8: 11.16], cells: cells)

        // Other information.
        let calendarYear = year.startYear
        var info: [XLSXCell] = [
            XLSXCell("A1", .text(personName), style: .bold),
            XLSXCell("A2", .text("Tax year: \(year.label)"), style: .bold),
            XLSXCell("D4", .text(code), style: .underline),
            XLSXCell("D5", .text(accounts.foreignTax.rule == .apportionCalendarYear ? "\(year.label) (by days)" : "Year \(calendarYear)"),
                     style: .underline),
            XLSXCell("A6", .number(1)),
            XLSXCell("B6", .text("FTCR"), style: .boldUnderline),
            XLSXCell("B7", .text("Offshore rental income")),
            XLSXCell("D7", .number(money(calendarYearRent)), style: amountStyle),
            XLSXCell("B9", .text("Offshore tax paid")),
            XLSXCell("D9", .number(money(accounts.foreignTax.amount.native)), style: amountStyle),
            XLSXCell("B11", .text("Tax as % of the rent")),
            XLSXCell("D11", .formula("IF(D7=0,0,D9/D7)", cached: calendarYearRent == 0 ? 0
                                        : Double(accounts.foreignTax.amount.native) / Double(calendarYearRent)), style: .percent),
            XLSXCell("A13", .number(2)), XLSXCell("B13", .text("Offshore interest income")),
            XLSXCell("A15", .number(3)), XLSXCell("B15", .text("Offshore dividends")),
            XLSXCell("A17", .number(4)), XLSXCell("B17", .text("Any other taxable offshore income")),
            XLSXCell("B19", .text("Other"), style: .underline), XLSXCell("D19", .text("GBP"), style: .underline),
            XLSXCell("A20", .number(5)), XLSXCell("B20", .text("P60 - UK employment income")),
            XLSXCell("B21", .text("P11 d - related to employment")),
            XLSXCell("A23", .number(6)), XLSXCell("B23", .text("UK interest income")),
            XLSXCell("A25", .number(7)), XLSXCell("B25", .text("UK dividends")),
            XLSXCell("A27", .number(8)), XLSXCell("B27", .text("Any other UK taxable income?")),
            XLSXCell("A29", .number(9)), XLSXCell("B29", .text("Pension contributions"))
        ]
        let optional: [(String, Int?, XLSXCellStyle)] = [
            ("D13", other.offshoreInterest, amountStyle), ("D15", other.offshoreDividends, amountStyle),
            ("D17", other.otherOffshoreIncome, amountStyle), ("D20", other.p60Pay, .pound), ("D21", other.p11dBenefits, .pound),
            ("D23", other.ukInterest, .pound), ("D25", other.ukDividends, .pound), ("D27", other.otherUKIncome, .pound),
            ("D29", other.pensionContributions, .pound)
        ]
        for (reference, value, style) in optional {
            if let value { info.append(XLSXCell(reference, .number(money(value)), style: style)) }
        }
        let otherSheet = XLSXSheetContent(name: Layout.otherSheetName, columnWidths: [2: 36.83, 4: 14], cells: info)
        return [rental, otherSheet]
    }

    /// The person's template for the year, computed from the records.
    public static func xlsx(db: Database, taxYear: UKTaxYear, personId: Int64, propertyId: Int64,
                            other: OtherInformation = OtherInformation(), notes: [String] = []) throws -> Data {
        let accounts = try RentalAccounts.compute(db: db, taxYear: taxYear, personId: personId, propertyId: propertyId)
        guard let person = try Person.fetchOne(db, key: personId) else { throw TaxError.personNotFound }
        let rent = try RentalAccounts.foreignTaxBasisRent(db: db, accounts: accounts)
        return try XLSXWriter.data(sheets: sheets(accounts: accounts, personName: person.name, foreignTaxBasisRent: rent, other: other, notes: notes))
    }
}

extension RentalAccounts {
    /// The person's rent for a calendar year by rent period (the issued receipts spread by
    /// days), at their rental-income share of the UK year starting in it: the rent the PT
    /// return for that year taxes.
    public static func calendarYearRent(db: Database, calendarYear: Int, personId: Int64, propertyId: Int64) throws -> Int {
        let calendar = MonthRange.calendar
        let interval = DateInterval(start: calendar.date(from: DateComponents(year: calendarYear, month: 1, day: 1))!,
                                    end: calendar.date(from: DateComponents(year: calendarYear + 1, month: 1, day: 1))!)
        let whole = try RentReceipts.receipts(db: db, propertyId: propertyId, overlapping: interval).reduce(0) {
            $0 + PropertyFinance.apportioned($1.amountMinorUnits, start: $1.periodStart, lastDay: $1.periodEnd, to: interval)
        }
        let share = try TaxSplits.share(db: db, startYear: calendarYear, personId: personId, propertyId: propertyId, expenseType: .rentalIncome)
        return shareOf(whole, share.shareBasisPoints)
    }
}
