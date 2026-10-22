#!/usr/bin/env swift
// scripts/generate-app-icon.swift
//
// Rasterises the master artwork docs/design/mango-icon.svg into every macOS AppIcon size plus
// Contents.json in App/Assets.xcassets/AppIcon.appiconset.
// NSImage renders SVG on macOS 26 but through CoreSVG, which ignores the blur filters and mangles the
// shading gradients and clips, so the master is rasterised once at 1024 px with Quick Look (qlmanage,
// WebKit's renderer, which draws it faithfully) and that bitmap is scaled down for every size.
// The master is an unmasked square, so each size is drawn into the 824pt rounded tile of the macOS
// icon grid with a soft drop shadow. Below `simplifiedBelowPixels` a simplified drawing is rasterised
// instead: the shadow, shading and highlight groups and the leaf veins are removed from the SVG first.
// Run from the repo root:  swift scripts/generate-app-icon.swift
import AppKit
import CoreGraphics

let outputDir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let masterURL = URL(fileURLWithPath: "docs/design/mango-icon.svg")
let simplifiedBelowPixels = 32
/// Element ids dropped from the master in the simplified drawing.
let simplifiedDrops = ["shadow", "shading", "highlight", "leaf-veins"]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Rasterises the master (optionally simplified) at 1024 px with qlmanage.
func loadArtwork(simplified: Bool) throws -> CGImage {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("mango-icon-\(simplified ? "small" : "full")", isDirectory: true)
    try? FileManager.default.removeItem(at: work)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let doc = try XMLDocument(contentsOf: masterURL, options: [])
    if simplified {
        for id in simplifiedDrops {
            for node in try doc.nodes(forXPath: "//*[@id='\(id)']") { node.detach() }
        }
    }
    let svg = work.appendingPathComponent("mango.svg")
    try doc.xmlData.write(to: svg)
    let ql = Process()
    ql.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    ql.arguments = ["-t", "-s", "1024", "-o", work.path, svg.path]
    ql.standardOutput = FileHandle.nullDevice
    ql.standardError = FileHandle.nullDevice
    try ql.run()
    ql.waitUntilExit()
    let png = work.appendingPathComponent("mango.svg.png")
    guard let source = CGImageSourceCreateWithURL(png as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("qlmanage could not rasterise \(masterURL.path)")
    }
    return image
}

let fullArtwork = try loadArtwork(simplified: false)
let simplifiedArtwork = try loadArtwork(simplified: true)

func renderPNG(pixels: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)

    // macOS icon grid: 824pt rounded square centred in the 1024 canvas (y-up here; it is symmetric).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x0A2440))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.draw(pixels < simplifiedBelowPixels ? simplifiedArtwork : fullArtwork, in: tile)
    ctx.restoreGState()

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
