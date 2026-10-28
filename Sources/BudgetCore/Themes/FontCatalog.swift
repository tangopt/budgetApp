// Sources/BudgetCore/Themes/FontCatalog.swift
import Foundation

/// One typeface the iPhone and iPad can show app text in (step 16). Three are the system's own designs; ten are
/// bundled under `Phone/Fonts/<Family>/`, each with its SIL Open Font Licence beside it.
public struct PhoneFont: Identifiable, Equatable, Sendable {
    public enum SystemDesign: Sendable, Equatable { case `default`, rounded, serif }
    public enum Kind: Sendable, Equatable { case system(design: SystemDesign), bundled }
    public enum Weight: Int, CaseIterable, Sendable { case regular, medium, semibold, bold }

    public let id: String
    public let name: String
    public let kind: Kind
    /// Paths relative to `Phone/Fonts`; empty for the system fonts.
    public let files: [String]
    /// The PostScript name that draws each weight; a weight the family lacks maps to the nearest bundled one.
    public let postScriptNames: [Weight: String]
    /// Whether the font's digits all share one width (by default or through the `tnum` feature). When false, figures
    /// are drawn in the system font's tabular digits instead.
    public let hasTabularDigits: Bool
}

public enum FontCatalog {
    public static let defaultID = "sf-pro"

    /// The 13 fonts, in the picker's order.
    public static let all: [PhoneFont] = [
        PhoneFont(id: "sf-pro", name: "SF Pro", kind: .system(design: .default), files: [], postScriptNames: [:], hasTabularDigits: true),
        PhoneFont(id: "sf-rounded", name: "SF Pro Rounded", kind: .system(design: .rounded), files: [], postScriptNames: [:], hasTabularDigits: true),
        PhoneFont(id: "new-york", name: "New York", kind: .system(design: .serif), files: [], postScriptNames: [:], hasTabularDigits: true),
        PhoneFont(
            id: "inter", name: "Inter", kind: .bundled, files: ["Inter/Inter[opsz,wght].ttf"],
            postScriptNames: [.regular: "Inter-Regular", .medium: "Inter-Regular_Medium", .semibold: "Inter-Regular_SemiBold", .bold: "Inter-Regular_Bold"],
            hasTabularDigits: true),
        PhoneFont(
            id: "ibm-plex-sans", name: "IBM Plex Sans", kind: .bundled, files: ["IBMPlexSans/IBMPlexSans[wdth,wght].ttf"],
            postScriptNames: [.regular: "IBMPlexSans-Regular", .medium: "IBMPlexSans-Medium", .semibold: "IBMPlexSans-SemiBold", .bold: "IBMPlexSans-Bold"],
            hasTabularDigits: true),
        PhoneFont(
            id: "source-sans-3", name: "Source Sans 3", kind: .bundled, files: ["SourceSans3/SourceSans3[wght].ttf"],
            postScriptNames: [.regular: "SourceSans3-Roman_Regular", .medium: "SourceSans3-Roman_Medium", .semibold: "SourceSans3-Roman_SemiBold", .bold: "SourceSans3-Roman_Bold"],
            hasTabularDigits: true),
        PhoneFont(
            id: "public-sans", name: "Public Sans", kind: .bundled, files: ["PublicSans/PublicSans[wght].ttf"],
            postScriptNames: [.regular: "PublicSansRoman-Regular", .medium: "PublicSansRoman-Medium", .semibold: "PublicSansRoman-SemiBold", .bold: "PublicSansRoman-Bold"],
            hasTabularDigits: true),
        PhoneFont(
            id: "dm-sans", name: "DM Sans", kind: .bundled, files: ["DMSans/DMSans[opsz,wght].ttf"],
            postScriptNames: [.regular: "DMSans-9ptRegular_Regular", .medium: "DMSans-9ptRegular_Medium", .semibold: "DMSans-9ptRegular_SemiBold", .bold: "DMSans-9ptRegular_Bold"],
            hasTabularDigits: false),
        PhoneFont(
            id: "manrope", name: "Manrope", kind: .bundled, files: ["Manrope/Manrope[wght].ttf"],
            postScriptNames: [.regular: "Manrope-Regular", .medium: "Manrope-Medium", .semibold: "Manrope-SemiBold", .bold: "Manrope-Bold"],
            hasTabularDigits: true),
        PhoneFont(
            id: "atkinson-hyperlegible", name: "Atkinson Hyperlegible", kind: .bundled,
            files: ["AtkinsonHyperlegible/AtkinsonHyperlegible-Regular.ttf", "AtkinsonHyperlegible/AtkinsonHyperlegible-Bold.ttf"],
            // Google ships regular and bold only: medium rides on regular, semibold on bold.
            postScriptNames: [.regular: "AtkinsonHyperlegible-Regular", .medium: "AtkinsonHyperlegible-Regular", .semibold: "AtkinsonHyperlegible-Bold", .bold: "AtkinsonHyperlegible-Bold"],
            hasTabularDigits: true),
        PhoneFont(
            id: "lexend", name: "Lexend", kind: .bundled, files: ["Lexend/Lexend[wght].ttf"],
            postScriptNames: [.regular: "Lexend-Regular", .medium: "Lexend-Medium", .semibold: "Lexend-SemiBold", .bold: "Lexend-Bold"],
            hasTabularDigits: false),
        PhoneFont(
            id: "source-serif-4", name: "Source Serif 4", kind: .bundled, files: ["SourceSerif4/SourceSerif4[opsz,wght].ttf"],
            postScriptNames: [.regular: "SourceSerif4Roman-Regular", .medium: "SourceSerif4Roman-Medium", .semibold: "SourceSerif4Roman-SemiBold", .bold: "SourceSerif4Roman-Bold"],
            hasTabularDigits: true),
        PhoneFont(
            id: "ibm-plex-mono", name: "IBM Plex Mono", kind: .bundled,
            files: ["IBMPlexMono/IBMPlexMono-Regular.ttf", "IBMPlexMono/IBMPlexMono-Medium.ttf", "IBMPlexMono/IBMPlexMono-SemiBold.ttf", "IBMPlexMono/IBMPlexMono-Bold.ttf"],
            postScriptNames: [.regular: "IBMPlexMono-Regular", .medium: "IBMPlexMono-Medium", .semibold: "IBMPlexMono-SemiBold", .bold: "IBMPlexMono-Bold"],
            hasTabularDigits: true),
    ]

    /// The font stored under `id`; an unknown or empty id (an older or newer build, a hand-edited default) is SF Pro.
    public static func font(id: String) -> PhoneFont {
        all.first { $0.id == id } ?? all[0]
    }

    /// Every bundled font file, relative to `Phone/Fonts`.
    public static var bundledFiles: [String] { all.flatMap(\.files) }
}
