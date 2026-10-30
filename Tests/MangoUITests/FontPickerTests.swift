import XCTest
import BudgetCore
@testable import MangoUI

final class FontPickerTests: XCTestCase {
    func testRowsListTenFontsWithTheSampleFigure() {
        let rows = FontPickerModel.rows(selected: "sf-pro")
        XCTAssertEqual(rows.count, 10)
        XCTAssertTrue(rows.allSatisfy { $0.sample == "£1,284.50" })
        XCTAssertEqual(rows.first?.id, "sf-pro")
    }

    func testSelectedRowMatchesStoredIdAndUnknownSelectsSFPro() {
        XCTAssertEqual(FontPickerModel.rows(selected: "manrope").filter(\.isSelected).map(\.id), ["manrope"])
        XCTAssertEqual(FontPickerModel.rows(selected: "nope").filter(\.isSelected).map(\.id), ["sf-pro"])
    }

    func testLicenceTextExistsForEveryBundledFont() {
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Phone/Fonts")
        XCTAssertEqual(FontLicences.entries.count, 7)
        for entry in FontLicences.entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fonts.appending(path: entry.path).path), entry.path)
        }
    }
}
