import XCTest
import SwiftUI
import BudgetCore
@testable import MangoUI
#if canImport(CoreText)
import CoreText
#endif

/// The phone's typeface (step 16): which font a text style and weight resolve to in each catalogue font, the SF Pro
/// fallback when a bundled font isn't registered, the system font's tabular digits for figures in a font without
/// them, and registering the bundled files at launch.
final class PhoneTypefaceTests: XCTestCase {
    private let registered: (String) -> Bool = { _ in true }

    private func choice(_ id: String, _ style: Font.TextStyle, weight: Font.Weight? = nil, isFigure: Bool = false,
                        available: ((String) -> Bool)? = nil) -> TypefaceResolver.Choice {
        TypefaceResolver.choice(FontCatalog.font(id: id), style: style, weight: weight, isFigure: isFigure,
                                available: available ?? registered)
    }

    func testSystemFontsUseDesign() {
        XCTAssertEqual(choice("sf-pro", .body), .system(design: .default, weight: nil))
        XCTAssertEqual(choice("sf-rounded", .body, weight: .bold), .system(design: .rounded, weight: .bold))
        XCTAssertEqual(choice("new-york", .headline), .system(design: .serif, weight: nil))
    }

    func testBundledFontUsesCustomNameRelativeToStyle() {
        XCTAssertEqual(choice("inter", .body), .custom(postScriptName: "Inter-Regular", size: 17, relativeTo: .body))
        XCTAssertEqual(choice("inter", .footnote),
                       .custom(postScriptName: "Inter-Regular", size: 13, relativeTo: .footnote))
        let sizes: [(Font.TextStyle, CGFloat)] = [
            (.largeTitle, 34), (.title, 28), (.title2, 22), (.title3, 20), (.headline, 17), (.body, 17),
            (.callout, 16), (.subheadline, 15), (.footnote, 13), (.caption, 12), (.caption2, 11),
        ]
        for (style, size) in sizes {
            guard case let .custom(_, shown, relativeTo) = choice("manrope", style) else {
                return XCTFail("\(style) isn't custom")
            }
            XCTAssertEqual(shown, size, "\(style)")
            XCTAssertEqual(relativeTo, style)
        }
    }

    func testWeightMapsToNearestBundledWeight() {
        func name(_ id: String, _ style: Font.TextStyle, _ weight: Font.Weight?) -> String? {
            guard case let .custom(name, _, _) = choice(id, style, weight: weight) else { return nil }
            return name
        }
        XCTAssertEqual(name("atkinson-hyperlegible", .body, .semibold), "AtkinsonHyperlegible-Bold")
        XCTAssertEqual(name("atkinson-hyperlegible", .body, .medium), "AtkinsonHyperlegible-Regular")
        XCTAssertEqual(name("ibm-plex-sans", .body, .medium), "IBMPlexSans-Medium")
        XCTAssertEqual(name("ibm-plex-sans", .body, .heavy), "IBMPlexSans-Bold")
        XCTAssertEqual(name("ibm-plex-sans", .body, .black), "IBMPlexSans-Bold")
        XCTAssertEqual(name("ibm-plex-sans", .body, .light), "IBMPlexSans-Regular")
        XCTAssertEqual(name("ibm-plex-sans", .body, .ultraLight), "IBMPlexSans-Regular")
        XCTAssertEqual(name("ibm-plex-mono", .headline, nil), "IBMPlexMono-SemiBold")
        XCTAssertEqual(name("ibm-plex-mono", .headline, .bold), "IBMPlexMono-Bold")
        XCTAssertEqual(name("ibm-plex-mono", .subheadline, nil), "IBMPlexMono-Regular")
    }

    func testFallbackWhenFontNotRegistered() {
        XCTAssertEqual(choice("inter", .body, weight: .semibold, available: { _ in false }),
                       .system(design: .default, weight: .semibold))
        XCTAssertEqual(choice("lexend", .headline, available: { _ in false }), .system(design: .default, weight: nil))
    }

    func testFiguresUseSystemFontWhenFontLacksTabularDigits() {
        XCTAssertEqual(choice("lexend", .title2, weight: .semibold, isFigure: true),
                       .system(design: .default, weight: .semibold))
        XCTAssertEqual(choice("dm-sans", .body, isFigure: true), .system(design: .default, weight: nil))
        XCTAssertEqual(choice("lexend", .title2, weight: .semibold, isFigure: false),
                       .custom(postScriptName: "Lexend-SemiBold", size: 22, relativeTo: .title2))
        XCTAssertEqual(choice("inter", .body, isFigure: true),
                       .custom(postScriptName: "Inter-Regular", size: 17, relativeTo: .body))
        // The system designs keep their own digits.
        XCTAssertEqual(choice("sf-rounded", .body, isFigure: true), .system(design: .rounded, weight: nil))
    }

    /// SF Pro, the default, draws exactly the fonts the app drew before step 16.
    func testSFProResolvesToTheStyleFontsUsedBefore() {
        let sfPro = FontCatalog.font(id: FontCatalog.defaultID)
        func font(_ style: Font.TextStyle, _ weight: Font.Weight? = nil, figure: Bool = false) -> Font {
            TypefaceResolver.font(sfPro, style: style, weight: weight, isFigure: figure)
        }
        XCTAssertEqual(font(.subheadline), Font.subheadline)
        XCTAssertEqual(font(.title3, .semibold), Font.title3.weight(.semibold))
        XCTAssertEqual(font(.headline, figure: true), Font.headline)
        XCTAssertEqual(font(.largeTitle, .bold), Font.largeTitle.weight(.bold))
    }

    func testTextStyleValuesCarryStyleAndWeight() {
        let style: PhoneTextStyle = .title2.weight(.semibold)
        XCTAssertEqual(style, PhoneTextStyle(.title2, weight: .semibold))
        XCTAssertEqual(PhoneTextStyle.caption.bold(), PhoneTextStyle(.caption, weight: .bold))
        XCTAssertNil(PhoneTextStyle.body.weight)
    }

    /// `.mangoFont` on an amount stays the amount's own (figure digits), not the general modifier around it.
    @MainActor
    func testMangoFontOnMoneyTextKeepsItAnAmount() {
        let amount = MoneyText(minorUnits: 100, currency: .gbp, role: .neutral).mangoFont(.title2, weight: .semibold)
        XCTAssertTrue(type(of: amount) == MoneyText.self)
        XCTAssertEqual(amount.font, PhoneTextStyle(.title2, weight: .semibold))
    }

    #if canImport(CoreText)
    func testRegisterIsIdempotentAndReportsNames() throws {
        let fonts = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Phone/Fonts")
        let source = fonts.appending(path: "Lexend/Lexend[wght].ttf")
        let names = (CTFontManagerCreateFontDescriptorsFromURL(source as CFURL) as? [CTFontDescriptor] ?? [])
            .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        XCTAssertTrue(names.contains("Lexend-Regular"), "\(names)")
        if BundledFonts.isAvailable("Lexend-Regular") {
            throw XCTSkip("Lexend is installed on this Mac, so registering it is a no-op")
        }

        let root = FileManager.default.temporaryDirectory.appending(path: "PhoneTypefaceTests-\(UUID().uuidString)")
        let folder = root.appending(path: "Fonts/Lexend")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: source, to: folder.appending(path: "Lexend[wght].ttf"))
        let bundle = try XCTUnwrap(Bundle(path: root.path))

        let first = BundledFonts.register(bundle: bundle)
        XCTAssertEqual(Set(first), Set(names))
        XCTAssertTrue(BundledFonts.isAvailable("Lexend-Regular"))
        XCTAssertTrue(BundledFonts.isAvailable("Lexend-SemiBold"))
        XCTAssertEqual(BundledFonts.register(bundle: bundle), [])

        // The whole folder as the app bundles it: every catalogue name (named instances of the variable files
        // included) then draws, so no weight falls back to SF Pro.
        try FileManager.default.removeItem(at: root.appending(path: "Fonts"))
        try FileManager.default.copyItem(at: fonts, to: root.appending(path: "Fonts"))
        BundledFonts.register(bundle: try XCTUnwrap(Bundle(path: root.path)))
        for face in FontCatalog.all where face.kind == .bundled {
            for name in Set(face.postScriptNames.values) {
                XCTAssertTrue(BundledFonts.isAvailable(name), "\(face.name): \(name)")
            }
        }
    }

    func testABundleWithoutFontsRegistersNothing() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PhoneTypefaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(BundledFonts.register(bundle: try XCTUnwrap(Bundle(path: root.path))), [])
    }
    #endif
}
