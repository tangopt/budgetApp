import CoreGraphics
import Foundation

/// Reads the text of PDFs whose fonts have no `ToUnicode` map — BBVA Portugal's, whose Type 3
/// fonts name every glyph (`UNIC0041`, `LA020000`, `ND050000` …) — by walking the page content
/// with `CGPDFScanner` (macOS and iOS) and mapping each character code through its font's
/// encoding `Differences` and `GlyphNameDecoder`. Codes without a known name read as the code
/// itself (Windows-1252). Lines follow the content's text positioning, so the reading order is the
/// order the PDF draws in, which can differ from the page's visual order.
public enum PDFGlyphTextExtractor {
    /// The text of every page (pages separated by a blank line), or "" when there is none.
    public static func text(of document: CGPDFDocument, maxPages: Int = 20) -> String {
        guard document.numberOfPages > 0 else { return "" }
        var pages: [String] = []
        for index in 1...min(document.numberOfPages, maxPages) {
            guard let page = document.page(at: index) else { continue }
            pages.append(text(of: page))
        }
        return pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func text(of page: CGPDFPage) -> String {
        let contentStream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(contentStream) }
        let state = ScanState(contentStream: contentStream)
        guard let table = CGPDFOperatorTableCreate() else { return "" }
        defer { CGPDFOperatorTableRelease(table) }
        register(table)
        let scanner = CGPDFScannerCreate(contentStream, table, Unmanaged.passUnretained(state).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
        return state.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether any font the document's first pages use names its glyphs the BBVA way.
    public static func usesObfuscatedGlyphNames(_ document: CGPDFDocument, maxPages: Int = 3) -> Bool {
        guard document.numberOfPages > 0 else { return false }
        for index in 1...min(document.numberOfPages, maxPages) {
            guard let fonts = resourceDictionary(of: document.page(at: index), "Font") else { continue }
            var found = false
            CGPDFDictionaryApplyBlock(fonts, { _, object, _ in
                var font: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &font), let font,
                   encodingDifferences(of: font).values.contains(where: GlyphNameDecoder.isObfuscatedName) {
                    found = true
                    return false
                }
                return true
            }, nil)
            if found { return true }
        }
        return false
    }

    /// Whether the document's first pages draw any image (a scan or photo), directly or inside
    /// a form XObject.
    public static func containsImages(_ document: CGPDFDocument, maxPages: Int = 3) -> Bool {
        guard document.numberOfPages > 0 else { return false }
        for index in 1...min(document.numberOfPages, maxPages) {
            if let objects = resourceDictionary(of: document.page(at: index), "XObject"), containsImage(objects, depth: 0) { return true }
        }
        return false
    }

    private static func containsImage(_ objects: CGPDFDictionaryRef, depth: Int) -> Bool {
        var found = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                found = true
            case "Form" where depth < 3:
                var resources: CGPDFDictionaryRef?
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
                   CGPDFDictionaryGetDictionary(resources, "XObject", &nested), let nested {
                    found = containsImage(nested, depth: depth + 1)
                }
            default:
                break
            }
            return !found
        }, nil)
        return found
    }

    // MARK: Fonts

    /// A font's encoding `Differences`: character code → glyph name.
    static func encodingDifferences(of font: CGPDFDictionaryRef) -> [UInt8: String] {
        var encoding: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(font, "Encoding", &encoding), let encoding else { return [:] }
        var differences: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(encoding, "Differences", &differences), let differences else { return [:] }
        var map: [UInt8: String] = [:]
        var code = 0
        for index in 0..<CGPDFArrayGetCount(differences) {
            var number: CGPDFInteger = 0
            var name: UnsafePointer<CChar>?
            if CGPDFArrayGetInteger(differences, index, &number) {
                code = number
            } else if CGPDFArrayGetName(differences, index, &name), let name {
                if (0...255).contains(code) { map[UInt8(code)] = String(cString: name) }
                code += 1
            }
        }
        return map
    }

    /// Character code → text for a font: its glyph names decoded, else the code (Windows-1252;
    /// control codes read as nothing).
    static func characterMap(of font: CGPDFDictionaryRef?) -> [String] {
        var map = (0...255).map { code in
            code < 32 ? "" : String(bytes: [UInt8(code)], encoding: .windowsCP1252) ?? ""
        }
        guard let font else { return map }
        for (code, name) in encodingDifferences(of: font) {
            if let character = GlyphNameDecoder.character(forGlyphName: name) { map[Int(code)] = character }
        }
        return map
    }

    private static func resourceDictionary(of page: CGPDFPage?, _ key: String) -> CGPDFDictionaryRef? {
        guard let dictionary = page?.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return nil }
        var result: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, key, &result) else { return nil }
        return result
    }

    // MARK: Scanning

    fileprivate final class ScanState {
        let contentStream: CGPDFContentStreamRef
        var output = ""
        var fontMaps: [String: [String]] = [:]
        var currentMap: [String] = PDFGlyphTextExtractor.characterMap(of: nil)
        /// The text line's vertical position, and where the last text was shown.
        var lineY: CGFloat = 0
        var lineScale: CGFloat = 1
        var shownY: CGFloat?
        var pendingSpace = false

        init(contentStream: CGPDFContentStreamRef) {
            self.contentStream = contentStream
        }

        func selectFont(_ name: String) {
            if let map = fontMaps[name] {
                currentMap = map
                return
            }
            var font: CGPDFDictionaryRef?
            if let object = CGPDFContentStreamGetResource(contentStream, "Font", name) {
                CGPDFObjectGetValue(object, .dictionary, &font)
            }
            let map = PDFGlyphTextExtractor.characterMap(of: font)
            fontMaps[name] = map
            currentMap = map
        }

        func newLine() {
            shownY = nil
            if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
            pendingSpace = false
        }

        func show(_ string: CGPDFStringRef) {
            guard let bytes = CGPDFStringGetBytePtr(string) else { return }
            let length = CGPDFStringGetLength(string)
            guard length > 0 else { return }
            if let shownY, abs(shownY - lineY) > 0.5 {
                newLine()
            } else if pendingSpace, !output.isEmpty, !output.hasSuffix(" "), !output.hasSuffix("\n") {
                output += " "
            }
            pendingSpace = false
            shownY = lineY
            for index in 0..<length {
                output += currentMap[Int(bytes[index])]
            }
        }

        func moveLine(tx: CGFloat, ty: CGFloat) {
            lineY += ty * lineScale
            if tx != 0 { pendingSpace = true }
        }
    }

    private static func register(_ table: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let state = state(info) else { return }
            state.lineY = 0
            state.lineScale = 1
            state.pendingSpace = true
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let state = state(info) else { return }
            _ = popNumber(scanner)
            var name: UnsafePointer<CChar>?
            if CGPDFScannerPopName(scanner, &name), let name { state.selectFont(String(cString: name)) }
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let state = state(info) else { return }
            let ty = popNumber(scanner), tx = popNumber(scanner)
            state.moveLine(tx: tx, ty: ty)
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let state = state(info) else { return }
            let ty = popNumber(scanner), tx = popNumber(scanner)
            state.moveLine(tx: tx, ty: ty)
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let state = state(info) else { return }
            let f = popNumber(scanner)
            _ = popNumber(scanner) // e
            let d = popNumber(scanner)
            state.lineY = f
            state.lineScale = d == 0 ? 1 : abs(d)
            state.pendingSpace = true
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            state(info)?.newLine()
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            guard let state = state(info) else { return }
            var string: CGPDFStringRef?
            if CGPDFScannerPopString(scanner, &string), let string { state.show(string) }
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            guard let state = state(info) else { return }
            state.newLine()
            var string: CGPDFStringRef?
            if CGPDFScannerPopString(scanner, &string), let string { state.show(string) }
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            guard let state = state(info) else { return }
            state.newLine()
            var string: CGPDFStringRef?
            if CGPDFScannerPopString(scanner, &string), let string { state.show(string) }
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let state = state(info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var number: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string {
                    state.show(string)
                } else if CGPDFArrayGetNumber(array, index, &number), number < -250 {
                    state.pendingSpace = true
                }
            }
        }
    }
}

private func state(_ info: UnsafeMutableRawPointer?) -> PDFGlyphTextExtractor.ScanState? {
    guard let info else { return nil }
    return Unmanaged<PDFGlyphTextExtractor.ScanState>.fromOpaque(info).takeUnretainedValue()
}

private func popNumber(_ scanner: CGPDFScannerRef) -> CGFloat {
    var value: CGPDFReal = 0
    return CGPDFScannerPopNumber(scanner, &value) ? value : 0
}
