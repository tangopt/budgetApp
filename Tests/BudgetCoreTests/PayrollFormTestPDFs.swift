import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Synthetic P60 / P45 / P11D PDFs for the payroll form tests: made-up employers, references
/// and amounts, laid out like the payroll providers' substitute forms (labels with the figures
/// on their row, or just under them).
enum PayrollFormTestPDFs {
    /// Text at a position, in points from the bottom-left of an A4 page.
    struct Item {
        var text: String
        var x: CGFloat
        var y: CGFloat
        var size: CGFloat = 9
        var page: Int = 0

        init(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 9, page: Int = 0) {
            self.text = text
            self.x = x
            self.y = y
            self.size = size
            self.page = page
        }
    }

    static let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)

    /// A PDF with `items` as a normal text layer.
    static func textPDF(_ items: [Item], name: String = "form.pdf") -> URL {
        let url = EvidenceTestPDFs.temporaryURL(name)
        var box = pageBox
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 0...(items.map(\.page).max() ?? 0) {
            context.beginPDFPage(nil)
            draw(items.filter { $0.page == page }, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A one-page PDF that only holds a picture of `items` (a scan): no text layer.
    static func scannedPDF(_ items: [Item], name: String = "scan.pdf", scale: CGFloat = 3) -> URL {
        let width = Int(pageBox.width * scale), height = Int(pageBox.height * scale)
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale)
        draw(items, in: bitmap)
        let image = bitmap.makeImage()!
        let url = EvidenceTestPDFs.temporaryURL(name)
        var box = pageBox
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(image, in: pageBox)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// `items` as text, plus filled-in form fields (name, value, rect).
    static func formFieldPDF(_ items: [Item], fields: [(String, String, CGRect)], name: String = "fields.pdf") -> URL {
        let base = textPDF(items, name: "base-\(name)")
        let document = PDFDocument(url: base)!
        let page = document.page(at: 0)!
        for (fieldName, value, rect) in fields {
            let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
            annotation.widgetFieldType = .text
            annotation.fieldName = fieldName
            annotation.widgetStringValue = value
            page.addAnnotation(annotation)
        }
        let url = EvidenceTestPDFs.temporaryURL(name)
        document.write(to: url)
        return url
    }

    static func draw(_ items: [Item], in context: CGContext) {
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for item in items {
            let font = CTFontCreateWithName("Helvetica" as CFString, item.size, nil)
            let attributed = NSAttributedString(string: item.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ])
            context.textPosition = CGPoint(x: item.x, y: item.y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
    }

    // MARK: Forms

    /// A P60 with the labels on the left and the figures on their rows (one provider's
    /// layout): Example Ltd, 123/AB456, £45,678.90 pay and £6,543.21 tax this employment.
    static var p60RowLayout: [Item] {
        [
            Item("P60 End of Year Certificate", 20, 810, size: 12),
            Item("Tax year to 5 April", 20, 790), Item("2025", 120, 790),
            Item("Employee's Details", 220, 790),
            Item("National Insurance number", 220, 760), Item("QQ123456C", 220, 745),
            Item("Pay and Income Tax details", 220, 700),
            Item("Pay", 380, 680), Item("Tax deducted", 470, 680),
            Item("In previous", 220, 660), Item("employment(s)", 220, 650), Item("0.00", 395, 655), Item("0.00", 495, 655),
            Item("In this", 220, 625), Item("employment", 220, 615), Item("45678.90", 380, 620), Item("6543.21", 480, 620),
            Item("Total for year", 220, 590), Item("45678.90", 380, 590), Item("6543.21", 480, 590),
            Item("Final tax code", 360, 560), Item("1257L", 450, 560),
            Item("Statutory payments included in the pay 'In this", 20, 400), Item("employment' figure above", 20, 390),
            Item("Your employer's full name and address", 300, 300),
            Item("Example Ltd", 300, 285), Item("1 Example Street", 300, 273), Item("London", 300, 261),
            Item("Employer PAYE reference", 20, 240), Item("123 / AB456", 20, 225)
        ]
    }

    /// A P60 with two-line row labels and the year apart from its label (another provider's
    /// layout), where "In this employment" is also printed above the pay rows: Example
    /// Limited, 321/ZX987, £123,456.78 pay and £45,678.12 tax, K100 code.
    static var p60ColumnLayout: [Item] {
        [
            Item("Do not destroy", 40, 810), Item("P60 End of Year Certificate 2024 - 25", 200, 810),
            Item("Your employer's full name and address (including postcode)", 40, 795),
            Item("EXAMPLE LIMITED", 40, 777), Item("1 EXAMPLE STREET", 40, 765),
            Item("Tax Year to 5 April", 335, 790), Item("2025", 470, 790),
            Item("Employer PAYE reference", 312, 757), Item("321 / ZX987", 330, 732),
            Item("Statutory payments", 36, 360), Item("included in the pay 'In this employment' figure below", 120, 360),
            Item("Pay and Income Tax details Pay Tax deducted", 36, 248),
            Item("In previous", 36, 224), Item("employment(s)", 36, 215),
            Item("In this", 36, 200), Item("employment", 36, 191), Item("123,456.78", 140, 192), Item("45,678.12", 241, 192),
            Item("Total for year", 36, 170), Item("123,456.78", 140, 168), Item("45,678.12", 241, 168),
            Item("Please keep this certificate in a safe place", 294, 168),
            Item("Final tax code", 36, 134), Item("K100", 108, 132)
        ]
    }

    /// A P45 Part 1A with the figures under their labels: left Example Ltd on 31 05 2025 with
    /// £12,345.67 pay and £2,345.67 tax to date, code 1257L.
    static var p45: [Item] {
        [
            Item("P45 Part 1A", 485, 807), Item("Details of employee leaving work", 352, 792),
            Item("1 Employer PAYE reference", 50, 718), Item("Office number Reference number", 66, 698), Item("123 / AB456", 80, 687),
            Item("Tax Code at leaving date", 333, 673), Item("1257L", 378, 653),
            Item("4 Leaving date DD MM YYYY", 50, 492), Item("31 05 2025", 77, 473),
            Item("Total pay to date", 333, 516), Item("£ 12345.67 p", 336, 497),
            Item("Total tax to date", 333, 473), Item("£ 2345.67 p", 336, 459),
            Item("This employment pay and tax. If no entry here, the amounts", 66, 417),
            Item("Total pay in this employment", 66, 393), Item("£ p", 70, 377),
            Item("Total tax in this employment", 66, 356), Item("£ p", 70, 340),
            Item("Employer name and address", 329, 282), Item("Example Ltd", 336, 243), Item("1 Example Street", 336, 233)
        ]
    }

    /// A two-page P11D: private medical insurance £1,234.56 (section I, box 11), a car
    /// £3,000 (section F, box 9) and other items £50.00 (section M, box 15); empty boxes left blank.
    static var p11d: [Item] {
        [
            Item("P11D Expenses and benefits 2024 to 2025", 278, 806),
            Item("Employer name", 18, 771), Item("Example Ltd", 20, 756),
            Item("Employer PAYE reference", 18, 739), Item("123/AB456", 20, 724),
            Item("A", 22, 606), Item("Assets transferred (cars, property, goods or other assets)", 38, 607),
            Item("13", 469, 588), Item("1A", 557, 588),
            Item("F", 22, 408), Item("Cars and car fuel", 38, 408),
            Item("Total cash equivalent or relevant amount of all cars made available in 2024 to 2025", 39, 98),
            Item("9", 472, 98), Item("£3,000", 500, 98), Item("1A", 557, 98),
            Item("10", 469, 57), Item("1A", 557, 57),
            Item("I", 23, 538, page: 1), Item("Private medical treatment or insurance", 38, 540, page: 1),
            Item("Private medical treatment or insurance", 38, 520, page: 1),
            Item("1,300.00", 336, 520, page: 1), Item("65.44", 435, 520, page: 1), Item("11", 469, 518, page: 1),
            Item("1,234.56", 500, 520, page: 1), Item("1A", 557, 518, page: 1),
            Item("M", 21, 363, page: 1), Item("Other items (including subscriptions and professional fees)", 38, 365, page: 1),
            Item("15", 469, 341, page: 1), Item("50.00", 500, 341, page: 1), Item("1A", 557, 341, page: 1),
            Item("N", 21, 270, page: 1), Item("16", 469, 246, page: 1)
        ]
    }
}
