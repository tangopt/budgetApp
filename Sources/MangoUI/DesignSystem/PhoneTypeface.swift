import SwiftUI
import BudgetCore
import Synchronization
import OSLog
#if canImport(CoreText)
import CoreText
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension EnvironmentValues {
    /// The typeface the phone and iPad draw app text in (step 16; Settings ▸ Appearance ▸ Font). SF Pro by default.
    /// Read through `mangoFont(_:weight:)`, `MoneyText`, `DateText` and `figureText`.
    @Entry public var phoneTypeface: PhoneFont = FontCatalog.font(id: FontCatalog.defaultID)

    /// The style and weight the nearest `mangoFont` set, and the font it set, so a figure inside can redraw the same
    /// style in figure digits.
    @Entry var mangoFontContext: MangoFontContext?
}

struct MangoFontContext: Equatable {
    let style: PhoneTextStyle
    let font: Font
}

/// A text style and, when it isn't the style's own, a weight: what `MoneyText` and `DateText` take, written as a
/// `Font` would be (`.subheadline`, `.title2.weight(.semibold)`), so the typeface can draw it.
public struct PhoneTextStyle: Hashable, Sendable {
    public var style: Font.TextStyle
    public var weight: Font.Weight?

    public init(_ style: Font.TextStyle, weight: Font.Weight? = nil) {
        self.style = style
        self.weight = weight
    }

    public static let largeTitle = PhoneTextStyle(.largeTitle)
    public static let title = PhoneTextStyle(.title)
    public static let title2 = PhoneTextStyle(.title2)
    public static let title3 = PhoneTextStyle(.title3)
    public static let headline = PhoneTextStyle(.headline)
    public static let body = PhoneTextStyle(.body)
    public static let callout = PhoneTextStyle(.callout)
    public static let subheadline = PhoneTextStyle(.subheadline)
    public static let footnote = PhoneTextStyle(.footnote)
    public static let caption = PhoneTextStyle(.caption)
    public static let caption2 = PhoneTextStyle(.caption2)

    public func weight(_ weight: Font.Weight) -> PhoneTextStyle { PhoneTextStyle(style, weight: weight) }
    public func bold() -> PhoneTextStyle { weight(.bold) }
}

/// Which font a text style draws in for a typeface. Pure: `mangoFont`, `MoneyText`, `DateText` and `figureText` call
/// it with what the environment holds.
public enum TypefaceResolver {
    public enum Choice: Equatable, Sendable {
        /// The system font in one of its designs (SF Pro, SF Pro Rounded, New York), at the style's size.
        case system(design: Font.Design, weight: Font.Weight?)
        /// A bundled font by PostScript name, at the style's default size and scaling with it (Dynamic Type).
        case custom(postScriptName: String, size: CGFloat, relativeTo: Font.TextStyle)
    }

    /// The font for `style` in `face`. A bundled font that isn't registered falls back to SF Pro; a figure in a
    /// bundled font without tabular digits is drawn in the system font (the view adds `monospacedDigit()`).
    public static func choice(_ face: PhoneFont, style: Font.TextStyle, weight: Font.Weight?, isFigure: Bool,
                              available: (String) -> Bool = BundledFonts.isAvailable) -> Choice {
        switch face.kind {
        case let .system(design):
            return .system(design: design.font, weight: weight)
        case .bundled:
            if isFigure && !face.hasTabularDigits { return .system(design: .default, weight: weight) }
            let bundled = bundledWeight(weight ?? (style == .headline ? .semibold : .regular))
            guard let name = face.postScriptNames[bundled] ?? face.postScriptNames[.regular], available(name) else {
                return .system(design: .default, weight: weight)
            }
            return .custom(postScriptName: name, size: baseSize(style), relativeTo: style)
        }
    }

    public static func font(_ face: PhoneFont, style: Font.TextStyle, weight: Font.Weight?, isFigure: Bool,
                            available: (String) -> Bool = BundledFonts.isAvailable) -> Font {
        switch choice(face, style: style, weight: weight, isFigure: isFigure, available: available) {
        case let .system(.default, weight):
            // Exactly the fonts the app drew before step 16 (`.subheadline`, `.title3.weight(.semibold)`).
            let font = styleFont(style)
            return weight.map { font.weight($0) } ?? font
        case let .system(design, weight):
            return .system(style, design: design, weight: weight)
        case let .custom(name, size, relativeTo):
            return .custom(name, size: size, relativeTo: relativeTo)
        }
    }

    /// The iOS default size of each style at the default Dynamic Type size (`Font.custom` scales from it).
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }

    /// The nearest weight a bundled family draws: lighter than regular is regular, heavier than bold is bold.
    static func bundledWeight(_ weight: Font.Weight) -> PhoneFont.Weight {
        switch weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold, .heavy, .black: .bold
        default: .regular
        }
    }

    private static func styleFont(_ style: Font.TextStyle) -> Font {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        default: .system(style)
        }
    }
}

extension PhoneFont.SystemDesign {
    var font: Font.Design {
        switch self {
        case .default: .default
        case .rounded: .rounded
        case .serif: .serif
        }
    }
}

/// The bundled font files (`Phone/Fonts`, copied into the app as the `Fonts` folder), registered for the process at
/// launch with CoreText rather than listed in `UIAppFonts`.
public enum BundledFonts {
    private static let known = Mutex<Set<String>>([])

    /// Registers every `.ttf`/`.otf` under the bundle's `Fonts` folder (searched recursively) that isn't registered
    /// yet, and returns the PostScript names it registered: none on a second call, or where there are no files (a
    /// macOS test host).
    @discardableResult
    public static func register(bundle: Bundle = .main) -> [String] {
        #if canImport(CoreText)
        guard let folder = bundle.resourceURL?.appending(path: "Fonts"),
              let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var urls: [URL] = []
        var names: [String] = []
        for case let url as URL in walker where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            let inFile = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? [])
                .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            guard !inFile.isEmpty, !inFile.allSatisfy(isAvailable) else { continue }
            urls.append(url)
            names += inFile
        }
        guard !urls.isEmpty else { return [] }
        var errors: Unmanaged<CFArray>?
        CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, &errors)
        if let errors = errors?.takeRetainedValue() as? [Error], !errors.isEmpty {
            Logger.fonts.error("Registering bundled fonts: \(errors.map(String.init(describing:)), privacy: .public)")
        }
        return names.filter(isAvailable)
        #else
        return []
        #endif
    }

    /// Whether a font with this PostScript name can be drawn (registered, or installed on the system).
    public static func isAvailable(_ postScriptName: String) -> Bool {
        if known.withLock({ $0.contains(postScriptName) }) { return true }
        #if canImport(UIKit)
        let found = UIFont(name: postScriptName, size: 12) != nil
        #elseif canImport(AppKit)
        let found = NSFont(name: postScriptName, size: 12) != nil
        #else
        let found = false
        #endif
        // Only a found font is remembered: one missing now may be registered later.
        if found { known.withLock { _ = $0.insert(postScriptName) } }
        return found
    }
}

private extension Logger {
    static let fonts = Logger(subsystem: "ubberninja.mango", category: "fonts")
}

extension View {
    /// App text in the phone's typeface (`\.phoneTypeface`) at a Dynamic Type style: the replacement for
    /// `.mangoFont(.subheadline)` / `.mangoFont(.title3, weight: .semibold)`. `figures` draws the digits tabular (in the system
    /// font's digits when the typeface has no tabular ones).
    public func mangoFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, figures: Bool = false) -> some View {
        modifier(MangoFontModifier(style: PhoneTextStyle(style, weight: weight), figures: figures))
    }

    /// The same for a style held in a value (`MoneyText`'s, a row's).
    public func mangoFont(_ style: PhoneTextStyle, figures: Bool = false) -> some View {
        modifier(MangoFontModifier(style: style, figures: figures))
    }
}

struct MangoFontModifier: ViewModifier {
    let style: PhoneTextStyle
    let figures: Bool
    @Environment(\.phoneTypeface) private var face

    func body(content: Content) -> some View {
        let font = TypefaceResolver.font(face, style: style.style, weight: style.weight, isFigure: figures)
        let drawn = figures ? font.monospacedDigit() : font
        content
            .font(drawn)
            .environment(\.mangoFontContext, MangoFontContext(style: style, font: drawn))
    }
}

/// A figure (`figureText`) in the font around it: when that font came from `mangoFont` and the typeface has no
/// tabular digits, the same style in the system font's. SF Pro and a font set any other way are left as they are.
struct FigureFontModifier: ViewModifier {
    @Environment(\.phoneTypeface) private var face
    @Environment(\.mangoFontContext) private var context
    @Environment(\.font) private var font

    func body(content: Content) -> some View {
        if face.hasTabularDigits == false, let context, context.font == font {
            content.font(TypefaceResolver.font(face, style: context.style.style, weight: context.style.weight,
                                               isFigure: true).monospacedDigit())
        } else {
            content
        }
    }
}
