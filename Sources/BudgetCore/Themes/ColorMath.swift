// Sources/BudgetCore/Themes/ColorMath.swift
import Foundation

/// Colour maths for the theme rules: WCAG 2 relative luminance and contrast ratio, alpha
/// compositing, sRGB → CIELAB (D65) and the CIEDE2000 colour difference.
public enum ColorMath {
    public struct Lab: Equatable, Sendable {
        public var l: Double
        public var a: Double
        public var b: Double

        public init(l: Double, a: Double, b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }
    }

    /// An sRGB channel (0…1) to linear light.
    static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// Linear light (0…1) to an sRGB channel.
    static func encoded(_ linear: Double) -> Double {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    /// The colour with its light scaled so its relative luminance is `luminance` (a shade of
    /// it: same chromaticity, less light), opaque and not a system colour. Only darkens.
    public static func shaded(_ color: ThemeColor, toLuminance luminance: Double) -> ThemeColor {
        let current = relativeLuminance(color)
        guard current > luminance, current > 0 else { return color }
        let k = luminance / current
        func channel(_ value: Double) -> UInt32 {
            UInt32((min(max(encoded(linear(value) * k), 0), 1) * 255).rounded())
        }
        return ThemeColor(hexValue: (channel(color.red) << 16) | (channel(color.green) << 8) | channel(color.blue))
    }

    /// WCAG 2 relative luminance of the colour's RGB (opacity ignored: composite first).
    public static func relativeLuminance(_ color: ThemeColor) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG 2 contrast ratio, 1…21, either order.
    public static func contrastRatio(_ first: ThemeColor, _ second: ThemeColor) -> Double {
        let l1 = relativeLuminance(first), l2 = relativeLuminance(second)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// `color` (at its effective opacity) drawn over the opaque `background`, in sRGB as
    /// the window server blends: an opaque, non-system colour.
    public static func composite(_ color: ThemeColor, over background: ThemeColor) -> ThemeColor {
        let alpha = min(max(color.effectiveAlpha, 0), 1)
        func channel(_ top: Double, _ bottom: Double) -> UInt32 {
            UInt32((top * alpha + bottom * (1 - alpha)) * 255 + 0.5)
        }
        let r = channel(color.red, background.red)
        let g = channel(color.green, background.green)
        let b = channel(color.blue, background.blue)
        return ThemeColor(hexValue: (r << 16) | (g << 8) | b)
    }

    /// CIELAB (D65 white) of the colour's RGB.
    public static func lab(_ color: ThemeColor) -> Lab {
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / 1.0
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// CIEDE2000 ΔE between two colours' RGB.
    public static func deltaE2000(_ first: ThemeColor, _ second: ThemeColor) -> Double {
        deltaE2000(lab(first), lab(second))
    }

    /// CIEDE2000 ΔE (kL = kC = kH = 1), after Sharma, Wu & Dalal (2005).
    public static func deltaE2000(_ first: Lab, _ second: Lab) -> Double {
        let degrees = 180.0 / Double.pi
        let c1 = hypot(first.a, first.b), c2 = hypot(second.a, second.b)
        let cMean = (c1 + c2) / 2
        let cMean7 = pow(cMean, 7)
        let g = 0.5 * (1 - sqrt(cMean7 / (cMean7 + pow(25, 7))))
        let a1 = (1 + g) * first.a, a2 = (1 + g) * second.a
        let c1p = hypot(a1, first.b), c2p = hypot(a2, second.b)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) * degrees
            return h >= 0 ? h : h + 360
        }
        let h1p = hue(first.b, a1), h2p = hue(second.b, a2)

        let dLp = second.l - first.l
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * sqrt(c1p * c2p) * sin(dhp / 2 / degrees)

        let lMean = (first.l + second.l) / 2
        let cpMean = (c1p + c2p) / 2
        var hpMean = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 {
                hpMean /= 2
            } else {
                hpMean = h1p + h2p < 360 ? (hpMean + 360) / 2 : (hpMean - 360) / 2
            }
        }
        let t = 1 - 0.17 * cos((hpMean - 30) / degrees) + 0.24 * cos(2 * hpMean / degrees)
            + 0.32 * cos((3 * hpMean + 6) / degrees) - 0.20 * cos((4 * hpMean - 63) / degrees)
        let dTheta = 30 * exp(-pow((hpMean - 275) / 25, 2))
        let cpMean7 = pow(cpMean, 7)
        let rc = 2 * sqrt(cpMean7 / (cpMean7 + pow(25, 7)))
        let lOffset = pow(lMean - 50, 2)
        let sl = 1 + 0.015 * lOffset / sqrt(20 + lOffset)
        let sc = 1 + 0.045 * cpMean
        let sh = 1 + 0.015 * cpMean * t
        let rt = -sin(2 * dTheta / degrees) * rc

        let lTerm = dLp / sl, cTerm = dCp / sc, hTerm = dHp / sh
        return sqrt(lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + rt * cTerm * hTerm)
    }
}
