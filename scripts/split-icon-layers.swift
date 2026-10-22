#!/usr/bin/env swift
// scripts/split-icon-layers.swift
//
// Splits the master artwork docs/design/mango-icon.svg into one standalone SVG per top-level
// group (one Icon Composer layer each), written to docs/design/mango-icon-layers/NN-<id>.svg.
// Every layer keeps the shared <defs> and the 1024 viewBox, so it renders on its own and the
// layers stack back into the master. Run from the repo root:  swift scripts/split-icon-layers.swift
import Foundation

let master = URL(fileURLWithPath: "docs/design/mango-icon.svg")
let outputDir = URL(fileURLWithPath: "docs/design/mango-icon-layers", isDirectory: true)

let doc = try XMLDocument(contentsOf: master, options: [])
guard let root = doc.rootElement(), let defs = root.elements(forName: "defs").first else {
    fatalError("mango-icon.svg has no <defs>")
}
let groups = root.elements(forName: "g")

try? FileManager.default.removeItem(at: outputDir)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for (index, group) in groups.enumerated() {
    let name = group.attribute(forName: "id")?.stringValue ?? "layer\(index + 1)"
    let svg = XMLElement(name: "svg")
    svg.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://www.w3.org/2000/svg") as! XMLNode)
    for key in ["viewBox", "width", "height"] {
        if let value = root.attribute(forName: key)?.stringValue {
            svg.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
        }
    }
    svg.addChild(defs.copy() as! XMLNode)
    svg.addChild(group.copy() as! XMLNode)
    let layer = XMLDocument(rootElement: svg)
    layer.characterEncoding = "UTF-8"
    let file = String(format: "%02d-%@.svg", index + 1, name)
    try layer.xmlData(options: [.nodePrettyPrint]).write(to: outputDir.appendingPathComponent(file))
    print("Wrote \(file)")
}
print("Wrote \(groups.count) layers to \(outputDir.path)")
