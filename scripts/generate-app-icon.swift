#!/usr/bin/env swift
// scripts/generate-app-icon.swift
//
// Draws the Budget app icon ("rising chart in a ledger") with Core Graphics and writes
// every macOS AppIcon size plus Contents.json into App/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root:  swift scripts/generate-app-icon.swift
//
// All geometry is in a 1024×1024 canvas with a y-down origin (like the design mockup);
// sizes below `simplifiedBelowPixels` drop the ledger rules and use one thick line so the
// mark stays legible in the menu bar and Finder list view.
import AppKit
import CoreGraphics

let outputDir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let simplifiedBelowPixels = 64

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(in ctx: CGContext, simplified: Bool) {
    // macOS icon grid: 824pt rounded square centred in the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile, as system icons have.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x0E5B45))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient, top-left deep green → bottom-right teal.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x0E5B45), color(0x127C7A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])

    let chart: [CGPoint]
    if simplified {
        chart = [CGPoint(x: 210, y: 760), CGPoint(x: 470, y: 650), CGPoint(x: 834, y: 290)]
    } else {
        // Ledger rules and the margin line.
        ctx.setStrokeColor(color(0xFFFFFF, 0.16))
        ctx.setLineWidth(10)
        for y in stride(from: 300, through: 780, by: 120) {
            ctx.move(to: CGPoint(x: 190, y: y))
            ctx.addLine(to: CGPoint(x: 834, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(color(0xFFFFFF, 0.12))
        ctx.move(to: CGPoint(x: 300, y: 210))
        ctx.addLine(to: CGPoint(x: 300, y: 840))
        ctx.strokePath()

        chart = [CGPoint(x: 190, y: 760), CGPoint(x: 350, y: 680), CGPoint(x: 470, y: 710), CGPoint(x: 620, y: 520), CGPoint(x: 834, y: 290)]

        // Fading area fill under the line.
        ctx.saveGState()
        ctx.addLines(between: chart + [CGPoint(x: 834, y: 840), CGPoint(x: 190, y: 840)])
        ctx.closePath()
        ctx.clip()
        let area = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x7FF0C8, 0.35), color(0x7FF0C8, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(area, start: CGPoint(x: 0, y: 290), end: CGPoint(x: 0, y: 840), options: [])
        ctx.restoreGState()
    }

    ctx.setStrokeColor(color(0xA8FFE0))
    ctx.setLineWidth(simplified ? 110 : 44)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addLines(between: chart)
    ctx.strokePath()

    if !simplified {
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: 834 - 46, y: 290 - 46, width: 92, height: 92))
    }
    ctx.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // Flip to y-down and scale the 1024 design canvas to the target size.
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawIcon(in: ctx, simplified: pixels < simplifiedBelowPixels)

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try renderPNG(pixels: points * scale, to: outputDir.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDir.appendingPathComponent("Contents.json"))

let catalogContents = outputDir.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalogContents.path) {
    try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!.write(to: catalogContents)
}
print("Wrote \(images.count) icon images to \(outputDir.path)")
