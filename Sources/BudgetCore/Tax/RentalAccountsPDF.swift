import CoreGraphics
import CoreText
import Foundation

/// A printable summary of a person's rental accounts (plan phase 3 Task 3): the lines in the
/// property's currency, in GBP-native and in GBP at the HMRC rate, the totals, the finance
/// costs and FTCR input, the rent by month, and every line's sources with the rule applied.
/// CoreGraphics and CoreText only (macOS and iOS); A4 pages.
public enum RentalAccountsPDF {
    public static func data(accounts: RentalAccounts.Result, personName: String, propertyName: String, generatedAt: Date = Date()) -> Data {
        var writer = PageWriter()
        let currency = accounts.currency
        func money(_ value: Int, _ currency: Currency) -> String { Money.format(value, currency: currency) }
        func gbp(_ amount: RentalAccounts.Amount) -> String { amount.gbp.map { money($0, .gbp) } ?? "—" }

        writer.text("Rental accounts \(accounts.taxYear.label) — \(personName)", size: 16, bold: true)
        writer.text("\(propertyName) · UK tax year \(RentalAccounts.day(accounts.taxYear.start)) – \(RentalAccounts.day(accounts.taxYear.lastDay))", size: 10)
        if let rate = accounts.rate {
            writer.text(String(format: "HMRC average rate: £%.6f per %@ (%@)", rate.gbpPerUnit, currency.rawValue.uppercased(), rate.source.rawValue), size: 10)
        }
        writer.text("Generated \(RentalAccounts.day(generatedAt))", size: 9)
        writer.space(8)
        for warning in accounts.warnings { writer.text("! \(warning)", size: 9) }
        writer.space(6)

        let columns: [CGFloat] = [0, 250, 340, 420]
        writer.row(["Line", currency.rawValue.uppercased(), "GBP items", "GBP"], at: columns, bold: true)
        func lineRow(_ line: RentalAccounts.Line) {
            writer.row([line.label, money(line.amount.native, currency), money(line.amount.gbpNative, .gbp), gbp(line.amount)], at: columns)
        }
        lineRow(accounts.income)
        for line in accounts.expenses { lineRow(line) }
        writer.space(4)
        let totals = accounts.totals
        writer.row(["Total expenses", money(totals.expenses.native, currency), money(totals.expenses.gbpNative, .gbp), gbp(totals.expenses)], at: columns, bold: true)
        writer.row(["Profit before finance costs", money(totals.profit.native, currency), money(totals.profit.gbpNative, .gbp), gbp(totals.profit)], at: columns, bold: true)
        writer.space(4)
        writer.row(["Finance costs (relief at basic rate)", money(totals.financeCosts.native, currency), money(totals.financeCosts.gbpNative, .gbp),
                    gbp(totals.financeCosts)], at: columns)
        writer.row(["Foreign tax paid (FTCR input)", money(totals.foreignTax.native, currency), money(totals.foreignTax.gbpNative, .gbp),
                    gbp(totals.foreignTax)], at: columns)
        writer.row(["Not deductible (information)", money(accounts.notDeductible.amount.native, currency), "", ""], at: columns)

        if !accounts.rentMonths.isEmpty {
            writer.space(10)
            writer.text("Rent by month (rent period)", size: 11, bold: true)
            for month in accounts.rentMonths {
                writer.row([RentalAccounts.month(month.start), money(month.whole, currency), money(month.amount, currency)], at: [0, 250, 340])
            }
        }

        writer.space(10)
        writer.text("Sources", size: 12, bold: true)
        for line in accounts.allLines where !line.sources.isEmpty {
            writer.space(6)
            writer.text("\(line.label): \(money(line.amount.native, currency))\(line.amount.gbpNative != 0 ? " + \(money(line.amount.gbpNative, .gbp))" : "")",
                        size: 10, bold: true)
            writer.text("\(line.ruleExplanation) Share: \(line.shareExplanation).", size: 8)
            for source in line.sources {
                let date = source.date.map(RentalAccounts.day) ?? "—"
                writer.row([date, source.description, money(source.attributedMinorUnits, source.currency)], at: [0, 60, 340], size: 8)
                writer.text("    \(source.explanation)\(source.shareBasisPoints != line.share.shareBasisPoints ? " · share \(TaxShare.percent(source.shareBasisPoints))" : "")",
                            size: 7)
            }
        }
        return writer.finish()
    }

    /// Lays text out top to bottom, wrapping long text, starting new pages as needed (a block
    /// taller than a page starts one and runs off it rather than looping).
    struct PageWriter {
        static let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        static let margin: CGFloat = 40
        let data = NSMutableData()
        let context: CGContext
        var y: CGFloat = 0
        var pageOpen = false

        init() {
            var box = Self.page
            let consumer = CGDataConsumer(data: data as CFMutableData)!
            context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        }

        /// Starts a page when the next `height` points don't fit on this one.
        mutating func ensure(_ height: CGFloat) {
            if !pageOpen || (y - height < Self.margin && y < Self.page.height - Self.margin) {
                if pageOpen { context.endPDFPage() }
                context.beginPDFPage(nil)
                pageOpen = true
                y = Self.page.height - Self.margin
            }
        }

        mutating func space(_ points: CGFloat) { y -= points }

        /// A paragraph across the page, wrapped.
        mutating func text(_ string: String, size: CGFloat, bold: Bool = false) {
            let width = Self.page.width - 2 * Self.margin
            let height = Self.height(of: string, size: size, bold: bold, width: width)
            ensure(height)
            draw(string, x: Self.margin, size: size, bold: bold, width: width, height: height)
            y -= height
        }

        /// Cells at `offsets`, each wrapped within its column; the row is as tall as its tallest cell.
        mutating func row(_ cells: [String], at offsets: [CGFloat], size: CGFloat = 9, bold: Bool = false) {
            let columns = cells.indices.filter { $0 < offsets.count }.map { index -> (String, CGFloat, CGFloat) in
                let next = index + 1 < offsets.count ? offsets[index + 1] : Self.page.width - 2 * Self.margin
                return (cells[index], offsets[index], next - offsets[index] - 6)
            }
            let height = columns.map { Self.height(of: $0.0, size: size, bold: bold, width: $0.2) }.max() ?? 0
            ensure(height)
            for (cell, offset, width) in columns {
                draw(cell, x: Self.margin + offset, size: size, bold: bold, width: width, height: height)
            }
            y -= height
        }

        static func attributed(_ string: String, size: CGFloat, bold: Bool) -> CFAttributedString {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            return NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]) as CFAttributedString
        }

        /// The height the text takes wrapped to `width` (at least one line, plus leading).
        static func height(of string: String, size: CGFloat, bold: Bool, width: CGFloat) -> CGFloat {
            let setter = CTFramesetterCreateWithAttributedString(attributed(string.isEmpty ? " " : string, size: size, bold: bold))
            let fitted = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                      CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), nil)
            return ceil(max(fitted.height, size * 1.2)) + 3
        }

        /// The text wrapped in the box from the current line down `height` points.
        func draw(_ string: String, x: CGFloat, size: CGFloat, bold: Bool, width: CGFloat, height: CGFloat) {
            guard !string.isEmpty else { return }
            let setter = CTFramesetterCreateWithAttributedString(Self.attributed(string, size: size, bold: bold))
            let path = CGPath(rect: CGRect(x: x, y: y - height, width: max(width, 1), height: height), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
        }

        mutating func finish() -> Data {
            ensure(0)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
    }
}
