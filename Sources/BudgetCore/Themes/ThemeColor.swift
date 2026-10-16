// Sources/BudgetCore/Themes/ThemeColor.swift
import Foundation

/// A theme's light or dark half.
public enum ThemeVariant: String, CaseIterable, Sendable {
    case light, dark
}

/// One theme colour: an sRGB value and an opacity, optionally standing for a macOS system
/// colour. A system colour (Classic's tokens) is drawn as that system colour — so it keeps
/// following the user's accent and accessibility settings — and `hex` holds the value it
/// resolves to in its variant on macOS 26, for the contrast and ΔE maths.
public struct ThemeColor: Equatable, Hashable, Sendable {
    /// The macOS colours a theme can stand for.
    public enum System: String, Sendable {
        case accent, label, controlBackground, windowBackground
        case green, red, blue, orange, teal, purple, pink, brown, indigo, mint, gray, yellow
    }

    /// 0xRRGGBB, sRGB.
    public let hexValue: UInt32
    /// The opacity the app applies (SwiftUI's `.opacity`), 0…1.
    public let alpha: Double
    public let system: System?

    public init(hexValue: UInt32, alpha: Double = 1, system: System? = nil) {
        self.hexValue = hexValue
        self.alpha = alpha
        self.system = system
    }

    public static func hex(_ value: UInt32, alpha: Double = 1) -> ThemeColor {
        ThemeColor(hexValue: value, alpha: alpha)
    }

    /// A system colour as it resolves in `variant`, at `alpha`.
    public static func system(_ system: System, _ variant: ThemeVariant, alpha: Double = 1) -> ThemeColor {
        ThemeColor(hexValue: SystemColorValues.hex(system, variant), alpha: alpha, system: system)
    }

    /// Fully transparent.
    public static let clear = ThemeColor(hexValue: 0x000000, alpha: 0)

    /// The same colour at `alpha` times its opacity.
    public func opacity(_ alpha: Double) -> ThemeColor {
        ThemeColor(hexValue: hexValue, alpha: self.alpha * alpha, system: system)
    }

    public var red: Double { Double((hexValue >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hexValue >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hexValue & 0xFF) / 255 }

    /// The opacity actually drawn: `alpha` times the system colour's own (the label colour is
    /// itself translucent).
    public var effectiveAlpha: Double {
        alpha * (system.map { SystemColorValues.intrinsicAlpha($0) } ?? 1)
    }

    /// "#RRGGBB".
    public var hexString: String { String(format: "#%06X", hexValue) }
}

/// The macOS 26 system colours as they resolve in the light (aqua) and dark (darkAqua)
/// appearances, sRGB. The accent is the default blue.
enum SystemColorValues {
    static func hex(_ system: ThemeColor.System, _ variant: ThemeVariant) -> UInt32 {
        let light = variant == .light
        switch system {
        case .accent: return 0x007AFF
        case .label: return light ? 0x000000 : 0xFFFFFF
        case .controlBackground, .windowBackground: return light ? 0xFFFFFF : 0x1E1E1E
        case .green: return light ? 0x34C759 : 0x30D158
        case .red: return light ? 0xFF383C : 0xFF4245
        case .blue: return light ? 0x0088FF : 0x0091FF
        case .orange: return light ? 0xFF8D28 : 0xFF9230
        case .teal: return light ? 0x00C3D0 : 0x00D2E0
        case .purple: return light ? 0xCB30E0 : 0xDB34F2
        case .pink: return light ? 0xFF2D55 : 0xFF375F
        case .brown: return light ? 0xAC7F5E : 0xB78A66
        case .indigo: return light ? 0x6155F5 : 0x6D7CFF
        case .mint: return light ? 0x00C8B3 : 0x00DAC3
        case .gray: return light ? 0x8E8E93 : 0x98989D
        case .yellow: return light ? 0xFFCC00 : 0xFFD600
        }
    }

    /// The label colour is 84.7% black (light) or white (dark); the rest are opaque.
    static func intrinsicAlpha(_ system: ThemeColor.System) -> Double {
        system == .label ? 0.847 : 1
    }
}
