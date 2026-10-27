import Foundation
import CoreGraphics
import CoreText
import BudgetCore

/// The check-and-link snapshot routes' synthetic files and proposals (step 10, Task 8): example names, a PDF drawn here
/// and kept in a temporary tray, no real provider, account or tenant.
@MainActor
enum CheckSamples {
    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A one-page PDF with `lines` of text, in a tray under the temporary folder (emptied first); its item.
    static func trayItem(_ name: String, fileName: String, lines: [String]) -> (TrayItem, DownloadsTray) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mango-snapshot-\(name)-tray", isDirectory: true)
        DownloadsTray(directory: folder).purgeAll()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("mango-snapshot-\(UUID().uuidString).pdf")
        draw(lines, to: source)
        let tray = DownloadsTray(directory: folder)
        let item = try! tray.ingest(fileAt: source, suggestedName: fileName, sourceHost: "energy.example.test")
        return (item, tray)
    }

    private static func draw(_ lines: [String], to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 48, y: 780 - CGFloat(index) * 30)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
    }

    /// An electricity bill: the amount read by text recognition (to check), the payment suggested, the tenant's share
    /// joining the October draft.
    static func utility(refusal: String?) -> CheckAndLinkModel {
        let (item, tray) = trayItem("pad-check-utility", fileName: "Electricity invoice October 2026.pdf", lines: [
            "Example Energy - customer copy", "Invoice no. FT 41/26", "Issued on 5 Oct 2026",
            "Billing period 1 Aug 2026 to 30 Sep 2026", "Amount due 100.00 EUR"])
        let check = CheckAndLinkCheck(title: "Invoice FT 41/26 of Example Energy, 5 Oct 2026", fileName: item.fileName,
                                      toCheck: ["Amount"])
        let payment = PaymentSuggestion(transactionId: 1, description: "EXAMPLE ENERGY DD 41", date: day(2026, 10, 9),
                                        amountMinorUnits: 10_000, currency: .eur,
                                        reasons: ["Booked on 9 Oct 2026 for exactly €100.00; its description is Example Energy’s"])
        let bill = UtilityBillFields(
            check: check, provider: CheckedValue(value: 1, origin: .read), providerName: "Example Energy", propertyId: 1,
            propertyName: "Example flat", currency: .eur,
            periodStart: CheckedValue(value: day(2026, 8, 1), origin: .read), periodEnd: CheckedValue(value: day(2026, 9, 30), origin: .read),
            amount: CheckedValue(value: 10_000, origin: .read, needsCheck: true),
            issueDate: CheckedValue(value: day(2026, 10, 5), origin: .read),
            invoiceNumber: CheckedValue(value: "FT 41/26", origin: .read),
            paidBy: payment, paymentChoices: [payment],
            tenantShares: [TenantShare(tenancyId: 1, tenancyName: "Flat A", amountMinorUnits: 4_210, note: "17 of 60 days in the tenancy",
                                       month: day(2026, 10, 1), joinsStatement: 1, statementMonth: day(2026, 10, 1))])
        return CheckAndLinkModel(item: item, tray: tray, proposal: .utilityBill(bill), refusal: refusal)
    }

    /// A bank statement the balance of which matches; Save sends it to the Mac.
    static func statement() -> CheckAndLinkModel {
        let (item, tray) = trayItem("pad-check-statement", fileName: "statement-2026-09-current-account.pdf", lines: [
            "Example Bank - statement", "Current account ending 0000", "1 Sep 2026 to 30 Sep 2026",
            "Opening balance 2,410.55 EUR", "Closing balance 1,982.10 EUR"])
        let check = CheckAndLinkCheck(title: "Example Bank statement 2026-09", fileName: item.fileName)
        let summary = StatementImportSummary(
            check: check, accountId: 1, accountName: CheckedValue(value: "Current account", origin: .known), currency: .eur,
            periodStart: CheckedValue(value: day(2026, 9, 1), origin: .read), periodEnd: CheckedValue(value: day(2026, 9, 30), origin: .read),
            openingBalance: CheckedValue(value: 241_055, origin: .read), closingBalance: CheckedValue(value: 198_210, origin: .read),
            rowsToAdd: 14, alreadyImported: 2, instalments: "1 instalment: interest €112.53, capital €700.00")
        return CheckAndLinkModel(item: item, tray: tray, proposal: .statement(summary))
    }
}
