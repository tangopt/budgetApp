import XCTest
import SwiftUI
import BudgetCore
@testable import MangoUI

/// Settings ▸ Theme (step 8): the eight cards, the stored set marked, what VoiceOver reads, the grid's columns; and
/// which face each text style draws in for a set.
final class ThemePickerTests: XCTestCase {
    func testEightCardsInOrderWithTheirFontNames() {
        let cards = ThemePickerModel.cards(selected: "mango")
        XCTAssertEqual(cards.map(\.id), ["mango", "classic", "editorial", "clear", "studio", "calm", "library", "flat"])
        XCTAssertEqual(cards.first?.fontNames, "SF Pro Rounded · SF Pro")
        XCTAssertEqual(cards.first { $0.id == "calm" }?.fontNames, "Manrope · Source Sans 3 · SF Pro")
    }

    func testTheStoredSetIsSelectedAndAnUnknownOneSelectsMango() {
        XCTAssertEqual(ThemePickerModel.cards(selected: "library").filter(\.isSelected).map(\.id), ["library"])
        XCTAssertEqual(ThemePickerModel.cards(selected: "ocean").filter(\.isSelected).map(\.id), ["mango"])
    }

    func testCardsReadAsRadioButtons() {
        let cards = ThemePickerModel.cards(selected: "editorial")
        XCTAssertEqual(cards.first { $0.id == "editorial" }?.spoken, "Editorial, serif headings, selected")
        XCTAssertEqual(cards.first { $0.id == "flat" }?.spoken, "Flat, flat colour blocks")
    }

    func testTwoByFourOnTheIPhoneFourByTwoOnTheIPadOneAtAccessibilitySizes() {
        XCTAssertEqual(ThemePickerModel.columns(regularWidth: false, accessibilitySize: false), 2)
        XCTAssertEqual(ThemePickerModel.columns(regularWidth: true, accessibilitySize: false), 4)
        XCTAssertEqual(ThemePickerModel.columns(regularWidth: false, accessibilitySize: true), 1)
    }

    func testFontLicencesListTheSevenBundledFaces() {
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Phone/Fonts")
        XCTAssertEqual(FontLicences.entries.map(\.name), ["Inter", "IBM Plex Sans", "Source Sans 3", "Manrope",
                                                          "Atkinson Hyperlegible", "Source Serif 4", "IBM Plex Mono"])
        for entry in FontLicences.entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fonts.appending(path: entry.path).path), entry.path)
        }
    }

    // MARK: Faces

    func testDisplayBodyAndFigureRolesPickTheirFaces() {
        let studio = ThemeSet.studio.fonts
        XCTAssertEqual(TypefaceResolver.face(studio, style: .largeTitle, isFigure: false).id, "ibm-plex-sans")
        XCTAssertEqual(TypefaceResolver.face(studio, style: .body, isFigure: true).id, "ibm-plex-mono")
        let calm = ThemeSet.calm.fonts
        for style: Font.TextStyle in [.largeTitle, .title, .title2, .title3, .headline] {
            XCTAssertEqual(TypefaceResolver.face(calm, style: style, isFigure: false).id, "manrope", "\(style)")
        }
        for style: Font.TextStyle in [.body, .callout, .subheadline, .footnote, .caption, .caption2] {
            XCTAssertEqual(TypefaceResolver.face(calm, style: style, isFigure: false).id, "source-sans-3", "\(style)")
        }
        XCTAssertEqual(TypefaceResolver.face(calm, style: .largeTitle, isFigure: true).id, "sf-pro")
        // Mango: rounded headings, SF Pro body and figures.
        let mango = ThemeSet.mango.fonts
        XCTAssertEqual(TypefaceResolver.font(mango, style: .title3, weight: .semibold, isFigure: false, available: { _ in true }),
                       Font.system(.title3, design: .rounded, weight: .semibold))
        XCTAssertEqual(TypefaceResolver.font(mango, style: .subheadline, weight: nil, isFigure: false, available: { _ in true }),
                       Font.subheadline)
    }
}
