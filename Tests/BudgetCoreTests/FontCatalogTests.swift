// Tests/BudgetCoreTests/FontCatalogTests.swift
import XCTest
@testable import BudgetCore
#if canImport(CoreText)
import CoreText
#endif

final class FontCatalogTests: XCTestCase {
    private let expectedIDs = [
        "sf-pro", "sf-rounded", "new-york", "inter", "ibm-plex-sans", "source-sans-3", "public-sans", "dm-sans",
        "manrope", "atkinson-hyperlegible", "lexend", "source-serif-4", "ibm-plex-mono",
    ]

    private var fontsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Phone/Fonts", isDirectory: true)
    }

    private var bundled: [PhoneFont] { FontCatalog.all.filter { $0.kind == .bundled } }

    func testThirteenFontsInOrderWithSFProDefault() {
        XCTAssertEqual(FontCatalog.all.map(\.id), expectedIDs)
        XCTAssertEqual(FontCatalog.defaultID, "sf-pro")
    }

    func testUnknownIdFallsBackToSFPro() {
        XCTAssertEqual(FontCatalog.font(id: "comic-sans").id, "sf-pro")
        XCTAssertEqual(FontCatalog.font(id: "").id, "sf-pro")
        XCTAssertEqual(FontCatalog.font(id: "lexend").id, "lexend")
    }

    func testSystemFontsHaveNoFiles() {
        let system = FontCatalog.all.filter { if case .system = $0.kind { true } else { false } }
        XCTAssertEqual(system.count, 3)
        for font in system { XCTAssertTrue(font.files.isEmpty, font.id) }
        XCTAssertEqual(bundled.count, 10)
        for font in bundled { XCTAssertFalse(font.files.isEmpty, font.id) }
    }

    func testBoldAndRegularExistForEveryBundledFont() {
        for font in bundled {
            XCTAssertNotNil(font.postScriptNames[.regular], font.id)
            XCTAssertNotNil(font.postScriptNames[.bold], font.id)
        }
    }

    #if canImport(CoreText)
    private func descriptors(_ path: String) -> [CTFontDescriptor] {
        let url = fontsDirectory.appendingPathComponent(path)
        return (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
    }

    func testEveryBundledFontFileExistsAndMatchesItsPostScriptName() throws {
        XCTAssertEqual(FontCatalog.bundledFiles.count, Set(FontCatalog.bundledFiles).count)
        for font in bundled {
            var foundPostScript = Set<String>()
            var foundFamilies = Set<String>()
            for path in font.files {
                let url = fontsDirectory.appendingPathComponent(path)
                var isDirectory: ObjCBool = true
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), path)
                XCTAssertFalse(isDirectory.boolValue, path)
                let licence = url.deletingLastPathComponent().appendingPathComponent("OFL.txt")
                XCTAssertTrue(FileManager.default.fileExists(atPath: licence.path), "OFL.txt beside \(path)")
                let found = descriptors(path)
                XCTAssertFalse(found.isEmpty, "\(path) is not a font CoreText can read")
                for descriptor in found {
                    let ctFont = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
                    foundPostScript.insert(CTFontCopyPostScriptName(ctFont) as String)
                    foundFamilies.insert(CTFontCopyFamilyName(ctFont) as String)
                }
            }
            XCTAssertTrue(foundFamilies.contains { $0.contains(font.name) }, "\(font.id): families \(foundFamilies)")
            for (weight, name) in font.postScriptNames {
                XCTAssertTrue(foundPostScript.contains(name), "\(font.id) \(weight): \(name) not in \(foundPostScript.sorted())")
            }
        }
    }

    /// A digit set is tabular when the font offers the monospaced-numbers feature or its default digits already share one width.
    private func hasTabularDigits(_ path: String) -> Bool {
        guard let descriptor = descriptors(path).first else { return false }
        let ctFont = CTFontCreateWithFontDescriptor(descriptor, 100, nil)
        let features = (CTFontCopyFeatures(ctFont) as? [[String: Any]]) ?? []
        for feature in features where (feature[kCTFontFeatureTypeIdentifierKey as String] as? Int) == kNumberSpacingType {
            let selectors = (feature[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]]) ?? []
            if selectors.contains(where: { ($0[kCTFontFeatureSelectorIdentifierKey as String] as? Int) == kMonospacedNumbersSelector }) {
                return true
            }
        }
        var characters = Array("0123456789".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, characters.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, characters.count)
        return Set(advances.map(\.width)).count == 1
    }

    func testTabularFlagMatchesFontFeatures() {
        for font in bundled {
            let regular = font.files.first { $0.contains("Regular") } ?? font.files[0]
            XCTAssertEqual(font.hasTabularDigits, hasTabularDigits(regular), font.id)
        }
    }
    #endif
}
