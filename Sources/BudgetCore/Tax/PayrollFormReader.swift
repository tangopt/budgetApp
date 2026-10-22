import CoreGraphics
import Foundation
import PDFKit
#if canImport(Vision)
import Vision
#endif

/// A word on a page and where it is, in PDF points (origin bottom-left), from the text layer
/// or from text recognition.
public struct PositionedWord: Equatable, Sendable {
    public var text: String
    public var rect: CGRect
    public var page: Int

    public init(text: String, rect: CGRect, page: Int) {
        self.text = text
        self.rect = rect
        self.page = page
    }
}

/// The P60, P45 and P11D layouts HMRC publishes are printed by every payroll provider in its
/// own way, so the reader finds each figure by its printed label and the amounts on the same
/// row (to its right) or just below it, rather than by fixed positions (plan phase 4 Task 1).
/// It reads the PDF's text layer (PDFKit) and, for image-only PDFs and photos, recognises the
/// text (Vision, macOS and iOS). What it finds is a proposal the user confirms.
public enum PayrollFormKind: String, Codable, CaseIterable, Sendable {
    case p60
    case p45
    case p11d

    public var displayName: String {
        switch self {
        case .p60: return "P60"
        case .p45: return "P45"
        case .p11d: return "P11D"
        }
    }

    public var incomeSource: EmploymentIncomeSource? {
        switch self {
        case .p60: return .p60
        case .p45: return .p45
        case .p11d: return nil
        }
    }

    public var documentKind: DocumentKind {
        switch self {
        case .p60: return .p60
        case .p45: return .p45
        case .p11d: return .p11d
        }
    }
}

/// What the reader found on a form; every field may be missing (the user fills it in).
public struct PayrollFormExtraction: Equatable, Sendable {
    public struct Benefit: Equatable, Sendable {
        public var kind: BenefitKind
        public var sa102Box: Int
        public var cashEquivalentMinorUnits: Int

        public init(kind: BenefitKind, sa102Box: Int? = nil, cashEquivalentMinorUnits: Int) {
            self.kind = kind
            self.sa102Box = sa102Box ?? kind.sa102Box
            self.cashEquivalentMinorUnits = cashEquivalentMinorUnits
        }
    }

    public var kind: PayrollFormKind?
    /// How the text was read; `.manual` when nothing could be read.
    public var entryMethod: IncomeEntryMethod
    /// The UK tax year's start (2024 for the P60 "Tax year to 5 April 2025").
    public var startYear: Int?
    public var employerName: String?
    public var payeReference: String?
    public var nationalInsuranceNumber: String?
    public var taxCode: String?
    /// Pay and tax in this employment (P60 "In this employment"; P45 box 7 when filled, else
    /// "to date"), pence.
    public var payMinorUnits: Int?
    public var taxDeductedMinorUnits: Int?
    /// P60 "In previous employment(s)".
    public var previousPayMinorUnits: Int?
    public var previousTaxMinorUnits: Int?
    /// P60 "Total for year"; P45 "Total pay / tax to date".
    public var totalPayMinorUnits: Int?
    public var totalTaxMinorUnits: Int?
    /// P45 leaving date.
    public var leavingDate: Date?
    /// P11D items with a cash equivalent above zero.
    public var benefits: [Benefit]
    /// What the reader couldn't find or wasn't sure of.
    public var warnings: [String]

    public init(kind: PayrollFormKind? = nil, entryMethod: IncomeEntryMethod = .manual, startYear: Int? = nil, employerName: String? = nil,
                payeReference: String? = nil, nationalInsuranceNumber: String? = nil, taxCode: String? = nil, payMinorUnits: Int? = nil,
                taxDeductedMinorUnits: Int? = nil, previousPayMinorUnits: Int? = nil, previousTaxMinorUnits: Int? = nil,
                totalPayMinorUnits: Int? = nil, totalTaxMinorUnits: Int? = nil, leavingDate: Date? = nil, benefits: [Benefit] = [],
                warnings: [String] = []) {
        self.kind = kind
        self.entryMethod = entryMethod
        self.startYear = startYear
        self.employerName = employerName
        self.payeReference = payeReference
        self.nationalInsuranceNumber = nationalInsuranceNumber
        self.taxCode = taxCode
        self.payMinorUnits = payMinorUnits
        self.taxDeductedMinorUnits = taxDeductedMinorUnits
        self.previousPayMinorUnits = previousPayMinorUnits
        self.previousTaxMinorUnits = previousTaxMinorUnits
        self.totalPayMinorUnits = totalPayMinorUnits
        self.totalTaxMinorUnits = totalTaxMinorUnits
        self.leavingDate = leavingDate
        self.benefits = benefits
        self.warnings = warnings
    }
}

public enum PayrollFormReader {
    /// Reads the file: the PDF's text layer, else (image-only PDF or an image) recognised
    /// text when `allowOCR`; with no text at all, an empty manual extraction of `kind`.
    /// `accurateOCR` false uses Vision's fast recogniser (quicker, less exact).
    public static func read(_ url: URL, kind: PayrollFormKind? = nil, allowOCR: Bool = true, accurateOCR: Bool = true,
                            maxPages: Int = 3) -> PayrollFormExtraction {
        var words = textLayerWords(url, maxPages: maxPages)
        var method = IncomeEntryMethod.textLayer
        if words.filter({ $0.text.contains(where: \.isLetter) }).count < 10 {
            words = allowOCR ? recognizedWords(url, accurate: accurateOCR, maxPages: maxPages) : []
            method = .ocr
        }
        guard !words.isEmpty else {
            return PayrollFormExtraction(kind: kind, entryMethod: .manual, warnings: ["No text could be read: enter the figures by hand."])
        }
        var extraction = parse(words: words, kind: kind)
        extraction.entryMethod = method
        if method == .ocr { extraction.warnings.insert("Read by text recognition: check every figure against the document.", at: 0) }
        return extraction
    }

    // MARK: Text

    /// The words of the PDF's text layer, page by page.
    public static func textLayerWords(_ url: URL, maxPages: Int = 3) -> [PositionedWord] {
        guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else { return [] }
        var words: [PositionedWord] = []
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index), let pageText = page.string as NSString?,
                  let all = page.selection(for: page.bounds(for: .mediaBox)) else { continue }
            // Each line's text ranges index `page.string`, as `selection(for:)` does (unlike
            // `characterBounds(at:)`, which skips the spaces and line breaks PDFKit adds), so a
            // word's rectangle is the bounds of the selection of its range.
            for line in all.selectionsByLine() {
                for rangeIndex in 0..<line.numberOfTextRanges(on: page) {
                    let range = line.range(at: rangeIndex, on: page)
                    guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= pageText.length else { continue }
                    let text = pageText.substring(with: range) as NSString
                    var offset = 0
                    while offset < text.length {
                        let rest = NSRange(location: offset, length: text.length - offset)
                        let start = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: [], range: rest)
                        guard start.location != NSNotFound else { break }
                        let end = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [],
                                                        range: NSRange(location: start.location, length: text.length - start.location))
                        let length = (end.location == NSNotFound ? text.length : end.location) - start.location
                        let wordRange = NSRange(location: range.location + start.location, length: length)
                        if let rect = page.selection(for: wordRange)?.bounds(for: page), !rect.isEmpty {
                            words.append(PositionedWord(text: text.substring(with: NSRange(location: start.location, length: length)), rect: rect, page: index))
                        }
                        offset = start.location + length
                    }
                }
            }
            // Filled-in form fields (some payroll PDFs keep the figures only there).
            for annotation in page.annotations where annotation.type == "Widget" {
                guard let value = annotation.widgetStringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                      value != "Off" else { continue }
                let parts = value.split(whereSeparator: \.isWhitespace)
                // A multi-line field's text starts on its top line.
                let full = annotation.bounds
                let bounds = CGRect(x: full.minX, y: full.maxY - min(full.height, 16), width: full.width, height: min(full.height, 16))
                // Left-aligned text about as wide per character as 0.6 of the field's line.
                let width = min(bounds.width / CGFloat(max(value.count, 1)), bounds.height * 0.6)
                var offset = 0
                for part in parts {
                    let start = value.distance(from: value.startIndex, to: value[value.index(value.startIndex, offsetBy: offset)...].range(of: part)!.lowerBound)
                    words.append(PositionedWord(text: String(part), rect: CGRect(x: bounds.minX + CGFloat(start) * width, y: bounds.minY,
                                                                                 width: CGFloat(part.count) * width, height: bounds.height), page: index))
                    offset = start + part.count
                }
            }
        }
        return words
    }

    /// Words recognised in the page images (Vision); empty where Vision isn't available.
    public static func recognizedWords(_ url: URL, accurate: Bool = true, maxPages: Int = 3) -> [PositionedWord] {
        #if canImport(Vision)
        var pages: [(image: CGImage, box: CGRect)] = []
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = CGPDFDocument(url as CFURL) else { return [] }
            for number in 1...max(1, min(document.numberOfPages, maxPages)) {
                guard let page = document.page(at: number), let image = render(page) else { continue }
                pages.append((image, page.getBoxRect(.mediaBox)))
            }
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            pages.append((image, CGRect(x: 0, y: 0, width: image.width, height: image.height)))
        }
        var words: [PositionedWord] = []
        for (index, page) in pages.enumerated() {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = accurate ? .accurate : .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            let handler = VNImageRequestHandler(cgImage: page.image, options: [:])
            guard (try? handler.perform([request])) != nil else { continue }
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let string = candidate.string
                var start = string.startIndex
                while start < string.endIndex {
                    guard let wordStart = string[start...].firstIndex(where: { !$0.isWhitespace }) else { break }
                    let wordEnd = string[wordStart...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                    let box = (try? candidate.boundingBox(for: wordStart..<wordEnd))?.boundingBox ?? observation.boundingBox
                    let rect = CGRect(x: page.box.minX + box.minX * page.box.width, y: page.box.minY + box.minY * page.box.height,
                                      width: box.width * page.box.width, height: box.height * page.box.height)
                    words.append(PositionedWord(text: String(string[wordStart..<wordEnd]), rect: rect, page: index))
                    start = wordEnd
                }
            }
        }
        return words
        #else
        return []
        #endif
    }

    /// The page drawn at 3× (216 dpi) on white.
    static func render(_ page: CGPDFPage, scale: CGFloat = 3) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: Parsing

    /// The form's figures from its words. `kind` nil: guessed from the title.
    public static func parse(words: [PositionedWord], kind: PayrollFormKind? = nil) -> PayrollFormExtraction {
        let layout = Layout(words: words)
        let resolvedKind = kind ?? guessKind(layout.text)
        var extraction = PayrollFormExtraction(kind: resolvedKind, entryMethod: .textLayer)
        extraction.payeReference = payeReference(in: layout.text) ?? payeReferenceNearLabel(layout)
        extraction.nationalInsuranceNumber = nationalInsuranceNumber(in: layout.text)
        switch resolvedKind {
        case .p60: parseP60(layout, into: &extraction)
        case .p45: parseP45(layout, into: &extraction)
        case .p11d: parseP11D(layout, into: &extraction)
        case nil: extraction.warnings.append("Not recognised as a P60, P45 or P11D.")
        }
        if extraction.payeReference == nil { extraction.warnings.append("No employer PAYE reference found.") }
        if extraction.startYear == nil { extraction.warnings.append("No tax year found.") }
        if extraction.employerName == nil { extraction.warnings.append("No employer name found.") }
        return extraction
    }

    static func guessKind(_ text: String) -> PayrollFormKind? {
        let upper = text.uppercased()
        if upper.range(of: #"\bP11D\b"#, options: .regularExpression) != nil, upper.contains("BENEFITS") { return .p11d }
        if upper.range(of: #"\bP45\b"#, options: .regularExpression) != nil, upper.contains("LEAVING") { return .p45 }
        if upper.range(of: #"\bE?P60\b"#, options: .regularExpression) != nil || upper.contains("END OF YEAR CERTIFICATE") { return .p60 }
        return nil
    }

    static func parseP60(_ layout: Layout, into extraction: inout PayrollFormExtraction) {
        extraction.startYear = taxYearOfCertificate(layout)
        extraction.employerName = employerName(layout, labels: ["employer's full name and address", "employer's name and address", "employer name and address", "employer name"])
        extraction.taxCode = taxCode(layout, labels: ["final tax code"])
        let this = layout.amountsRight(of: "in this employment")
        let previous = layout.amountsRight(of: "in previous employment")
        let total = layout.amountsRight(of: "total for year")
        if previous.count >= 2 { (extraction.previousPayMinorUnits, extraction.previousTaxMinorUnits) = (previous[0], previous[1]) }
        if total.count >= 2 { (extraction.totalPayMinorUnits, extraction.totalTaxMinorUnits) = (total[0], total[1]) }
        if this.count >= 2 {
            (extraction.payMinorUnits, extraction.taxDeductedMinorUnits) = (this[0], this[1])
        } else if let totalPay = extraction.totalPayMinorUnits, let totalTax = extraction.totalTaxMinorUnits {
            extraction.payMinorUnits = totalPay - (extraction.previousPayMinorUnits ?? 0)
            extraction.taxDeductedMinorUnits = totalTax - (extraction.previousTaxMinorUnits ?? 0)
            extraction.warnings.append("“In this employment” not found: pay and tax are the year's total less previous employments.")
        } else {
            extraction.warnings.append("No pay and tax figures found.")
        }
        if let pay = extraction.payMinorUnits, let previous = extraction.previousPayMinorUnits, let total = extraction.totalPayMinorUnits,
           pay + previous != total {
            extraction.warnings.append("This employment plus previous employments doesn't add up to the total for the year.")
        }
    }

    static func parseP45(_ layout: Layout, into extraction: inout PayrollFormExtraction) {
        extraction.employerName = employerName(layout, labels: ["employer name and address", "employer's name and address", "employer name"])
        extraction.taxCode = taxCode(layout, labels: ["tax code at leaving date", "tax code"])
        extraction.leavingDate = layout.date(nearLabel: "leaving date")
        if let leaving = extraction.leavingDate { extraction.startYear = UKTaxYear.containing(leaving).startYear }
        extraction.totalPayMinorUnits = layout.amountsRight(of: "total pay to date").first ?? layout.amountBelow("total pay to date")
        extraction.totalTaxMinorUnits = layout.amountsRight(of: "total tax to date").first ?? layout.amountBelow("total tax to date")
        let thisPay = layout.amountsRight(of: "total pay in this employment").first ?? layout.amountBelow("total pay in this employment")
        let thisTax = layout.amountsRight(of: "total tax in this employment").first ?? layout.amountBelow("total tax in this employment")
        if let thisPay, let thisTax {
            (extraction.payMinorUnits, extraction.taxDeductedMinorUnits) = (thisPay, thisTax)
        } else {
            (extraction.payMinorUnits, extraction.taxDeductedMinorUnits) = (extraction.totalPayMinorUnits, extraction.totalTaxMinorUnits)
            if extraction.totalPayMinorUnits != nil {
                extraction.warnings.append("Box 8 (this employment) is empty, so pay and tax are box 7’s “to date” totals: fine if this was your only job since 6 April; otherwise they include the earlier job’s pay and tax.")
            }
        }
        if extraction.payMinorUnits == nil { extraction.warnings.append("No pay and tax figures found.") }
        if extraction.leavingDate == nil { extraction.warnings.append("No leaving date found.") }
    }

    static func parseP11D(_ layout: Layout, into extraction: inout PayrollFormExtraction) {
        if let match = layout.text.firstMatch(of: #/(20\d\d)\s+to\s+(20\d\d)/#), let start = Int(match.1), Int(match.2) == start + 1 {
            extraction.startYear = start
        }
        extraction.employerName = employerName(layout, labels: ["employer name"])
        extraction.benefits = layout.p11dBenefits()
        if extraction.benefits.isEmpty { extraction.warnings.append("No benefits found: check the form for cash equivalents.") }
    }

    // MARK: Fields

    static func payeReference(in text: String) -> String? {
        guard let match = text.firstMatch(of: #/(?:^|[^0-9])([0-9]{3})\s*/\s*([A-Za-z0-9]{1,10})(?![A-Za-z0-9])/#) else { return nil }
        let reference = "\(match.1)/\(match.2)".uppercased()
        // Dates ("012/2025") aren't references: the part after the slash has a letter.
        return reference.contains(where: \.isLetter) ? reference : nil
    }

    /// Office number and reference printed apart (in separate form fields) under the label.
    static func payeReferenceNearLabel(_ layout: Layout) -> String? {
        for anchor in layout.findAll("paye reference") {
            let nearby = layout.words(below: anchor, within: 50)
            guard let office = nearby.first(where: { $0.text.wholeMatch(of: #/[0-9]{3}/#) != nil }) else { continue }
            let reference = nearby.filter { word in
                abs(word.rect.midY - office.rect.midY) < 8 && word.rect.minX > office.rect.minX
                    && word.text.wholeMatch(of: #/[A-Za-z0-9]{1,10}/#) != nil && word.text.contains(where: \.isLetter)
            }.min { $0.rect.minX < $1.rect.minX }
            if let reference { return "\(office.text)/\(reference.text)".uppercased() }
        }
        return nil
    }

    static func nationalInsuranceNumber(in text: String) -> String? {
        guard let match = text.uppercased().firstMatch(of: #/\b([A-Z]{2})\s?([0-9]{2})\s?([0-9]{2})\s?([0-9]{2})\s?([A-D])\b/#) else { return nil }
        return "\(match.1)\(match.2)\(match.3)\(match.4)\(match.5)"
    }

    static let taxCodePattern = #/^(?:[SC])?(?:K?[0-9]{1,5}[LMNTPY]?|BR|D0|D1|D2|NT|0T|SD[0-2])(?:W1|M1|X)?$/#

    static func taxCode(_ layout: Layout, labels: [String]) -> String? {
        for label in labels {
            guard let anchor = layout.find(label) else { continue }
            let candidates = layout.words(rightOf: anchor) + layout.words(below: anchor, within: 40)
            if let code = candidates.first(where: { isTaxCode($0.text) }) { return code.text.uppercased() }
        }
        return nil
    }

    static func isTaxCode(_ text: String) -> Bool {
        let upper = text.uppercased()
        // A bare number is a works number or a box, not a code (codes end in a letter or are K codes).
        guard upper.contains(where: \.isLetter) else { return false }
        return upper.wholeMatch(of: taxCodePattern) != nil
    }

    static func taxYearOfCertificate(_ layout: Layout) -> Int? {
        if let anchor = layout.find("tax year to 5 april") {
            if let year = (layout.words(rightOf: anchor, slack: 20) + layout.words(below: anchor, within: 20))
                .compactMap({ Int($0.text) }).first(where: { (2000...2100).contains($0) }) {
                return year - 1
            }
        }
        if let match = layout.text.firstMatch(of: #/(?i:tax year to 5 april)\s+(20\d\d)/#), let end = Int(match.1) { return end - 1 }
        if let match = layout.text.firstMatch(of: #/(20\d\d)\s*(?:-|–|to|/)\s*(\d\d|20\d\d)\b/#), let start = Int(match.1),
           let end = Int(match.2), end % 100 == (start + 1) % 100 {
            return start
        }
        return nil
    }

    static let companySuffix = #/(?i)\b(LTD|LIMITED|PLC|LLP|LLC|INC|GMBH|CORP|COMPANY)\b\.?/#

    static func employerName(_ layout: Layout, labels: [String]) -> String? {
        for label in labels {
            guard let anchor = layout.find(label) else { continue }
            if let line = layout.lineBelow(anchor, within: 50).map(cleanedEmployer), isEmployerLine(line) { return line }
        }
        // A line naming a company, without the labels sharing its row.
        for line in layout.lines {
            guard line.firstMatch(of: companySuffix) != nil, !line.contains("(Substitute)"), !line.uppercased().contains("P11D(") else { continue }
            let name = cleanedEmployer(line)
            if isEmployerLine(name) { return name }
        }
        return nil
    }

    /// The name without the label text sharing its line ("Student Loan deductions £ Example Ltd").
    /// The address after the name (", 1 Example Street") goes too.
    static func cleanedEmployer(_ line: String) -> String {
        let name = line.components(separatedBy: "£").last!.components(separatedBy: ",").first!
        return name.trimmingCharacters(in: .whitespaces)
    }

    static func isEmployerLine(_ line: String) -> Bool {
        let letters = line.filter(\.isLetter).count
        guard letters >= 2 else { return false }
        let folded = line.lowercased()
        return !["employer", "paye", "address", "postcode", "reference", "national insurance"].contains(where: folded.contains)
    }

    /// "1,234.56", "£1234.56" → pence; `nil` for anything else (the forms always print pence,
    /// so a bare number is a box, a year or a works number).
    /// A leading "-" or a trailing "R" (the P60's refund mark) makes it negative.
    static func pence(_ text: String) -> Int? {
        var trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "*★ "))
        var sign = 1
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("−") { sign = -1; trimmed.removeFirst() }
        // "£-12.34" and "-£12.34" alike.
        if trimmed.hasPrefix("£-") || trimmed.hasPrefix("£−") { sign = -1; trimmed = "£" + trimmed.dropFirst(2) }
        if trimmed.uppercased().hasSuffix("R"), trimmed.count > 1 { sign = -1; trimmed.removeLast() }
        let hasPound = trimmed.hasPrefix("£")
        var cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "£"))
        let withPence = cleaned.wholeMatch(of: #/[0-9]{1,3}(,[0-9]{3})*\.[0-9]{2}|[0-9]+\.[0-9]{2}/#) != nil
        // Whole pounds only with the £ sign ("£2,456"), so boxes and years aren't amounts.
        let wholePounds = hasPound && cleaned.wholeMatch(of: #/[0-9]{1,3}(,[0-9]{3})*|[0-9]+/#) != nil
        guard withPence || wholePounds else { return nil }
        cleaned.removeAll { $0 == "," }
        let parts = cleaned.split(separator: ".")
        guard let pounds = Int(parts[0]) else { return nil }
        let pennies = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return sign * (pounds * 100 + pennies)
    }

    /// The words of the pages, with lines and label lookup.
    struct Layout {
        struct Line {
            var words: [PositionedWord]
            var text: String { words.map(\.text).joined(separator: " ") }
            var rect: CGRect { words.reduce(CGRect.null) { $0.union($1.rect) } }
            var page: Int { words[0].page }
        }

        let words: [PositionedWord]
        /// Words on the same baseline and close together, top to bottom then left to right.
        let runs: [Line]
        let text: String

        var lines: [String] { runs.map(\.text) }

        init(words: [PositionedWord]) {
            self.words = words
            // Lines: words whose middles are within half a word's height, top to bottom.
            var lines: [[PositionedWord]] = []
            for word in words.sorted(by: { ($0.page, -$0.rect.midY, $0.rect.minX) < ($1.page, -$1.rect.midY, $1.rect.minX) }) {
                if let first = lines.last?.first, first.page == word.page,
                   abs(first.rect.midY - word.rect.midY) <= max(min(first.rect.height, word.rect.height), 4) * 0.5 {
                    lines[lines.count - 1].append(word)
                } else {
                    lines.append([word])
                }
            }
            // Runs: a line's words left to right, split where the gap is wide (another column).
            var runs: [Line] = []
            for line in lines {
                var current: [PositionedWord] = []
                for word in line.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                    if let last = current.last, word.rect.minX - last.rect.maxX > max(word.rect.height, 6) * 1.8 {
                        runs.append(Line(words: current))
                        current = []
                    }
                    current.append(word)
                }
                if !current.isEmpty { runs.append(Line(words: current)) }
            }
            self.runs = runs
            self.text = runs.map(\.text).joined(separator: "\n")
        }

        /// Where `label` is printed (case-insensitive, in one run or across a run and the one
        /// just below it at the same left edge), in reading order.
        func findAll(_ label: String) -> [(rect: CGRect, page: Int)] {
            let target = fold(label)
            var found: [(rect: CGRect, page: Int)] = []
            for (index, run) in runs.enumerated() {
                if let rect = match(target, in: run.words) {
                    found.append((rect, run.page))
                    continue
                }
                // A label printed on two lines ("In this" / "employment").
                if let below = runs[(index + 1)...].prefix(8).first(where: { other in
                    let drop = run.rect.midY - other.rect.midY
                    return other.page == run.page && abs(other.rect.minX - run.rect.minX) < 4
                        && drop > min(run.rect.height, other.rect.height) * 0.5 && drop < max(run.rect.height, other.rect.height) * 1.6
                }), let rect = match(target, in: run.words + below.words) {
                    found.append((rect, run.page))
                }
            }
            return found
        }

        func find(_ label: String) -> (rect: CGRect, page: Int)? { findAll(label).first }

        /// The union of the words spelling `target` (folded) in `words`.
        private func match(_ target: String, in words: [PositionedWord]) -> CGRect? {
            var joined = ""
            var spans: [(Range<Int>, CGRect)] = []
            for word in words {
                let folded = fold(word.text)
                guard !folded.isEmpty else { continue }
                if !joined.isEmpty { joined += " " }
                let start = joined.count
                joined += folded
                spans.append((start..<joined.count, word.rect))
            }
            guard let range = joined.range(of: target) else { return nil }
            let lower = joined.distance(from: joined.startIndex, to: range.lowerBound)
            let upper = joined.distance(from: joined.startIndex, to: range.upperBound)
            return spans.filter { $0.0.overlaps(lower..<upper) }.reduce(CGRect.null) { $0.union($1.1) }
        }

        func words(rightOf anchor: (rect: CGRect, page: Int), slack: CGFloat = 4) -> [PositionedWord] {
            words.filter { word in
                word.page == anchor.page && word.rect.minX >= anchor.rect.maxX - 1
                    && word.rect.midY >= anchor.rect.minY - slack && word.rect.midY <= anchor.rect.maxY + slack
            }.sorted { $0.rect.minX < $1.rect.minX }
        }

        /// Words below the label (nearest first) whose left edge is near its column.
        func words(below anchor: (rect: CGRect, page: Int), within distance: CGFloat) -> [PositionedWord] {
            words.filter { word in
                word.page == anchor.page && word.rect.maxY <= anchor.rect.minY + 1 && anchor.rect.minY - word.rect.maxY <= distance
                    && word.rect.maxX >= anchor.rect.minX - 20 && word.rect.minX <= anchor.rect.maxX + 200
            }.sorted { ($0.rect.maxY, -$0.rect.minX) > ($1.rect.maxY, -$1.rect.minX) }
        }

        /// The amounts on the row of the first place `label` is printed with an amount to its
        /// right, left to right.
        func amountsRight(of label: String) -> [Int] {
            for anchor in findAll(label) {
                // An "R" printed after an amount (the refund box) makes it a refund.
                // Only an "R" right next to the amount, with nothing else in between, counts.
                var amounts: [Int] = []
                var lastAmountRect: CGRect?
                for word in words(rightOf: anchor) {
                    if let amount = PayrollFormReader.pence(word.text) {
                        amounts.append(amount)
                        lastAmountRect = word.rect
                    } else {
                        if let rect = lastAmountRect, word.text.uppercased() == "R", word.rect.minX - rect.maxX <= max(rect.height, 6) * 3,
                           amounts[amounts.count - 1] > 0 {
                            amounts[amounts.count - 1].negate()
                        }
                        lastAmountRect = nil
                    }
                }
                if !amounts.isEmpty { return amounts }
            }
            return []
        }

        /// The nearest amount under the label.
        func amountBelow(_ label: String, within distance: CGFloat = 40) -> Int? {
            for anchor in findAll(label) {
                if let amount = words(below: anchor, within: distance).lazy.compactMap({ PayrollFormReader.pence($0.text) }).first {
                    return amount
                }
            }
            return nil
        }

        /// The text of the nearest run under the label that overlaps its column.
        func lineBelow(_ anchor: (rect: CGRect, page: Int), within distance: CGFloat) -> String? {
            runs.filter { run in
                run.page == anchor.page && run.rect.maxY <= anchor.rect.minY + 1 && anchor.rect.minY - run.rect.maxY <= distance
                    && run.rect.minX < anchor.rect.maxX && run.rect.maxX > anchor.rect.minX - 10
            }.max { $0.rect.maxY < $1.rect.maxY }?.text
        }

        /// A date ("31 05 2025", "31/05/2025", "31-05-2025") right of or just under the label.
        func date(nearLabel label: String) -> Date? {
            for anchor in findAll(label) {
                if let date = date(near: anchor) { return date }
            }
            return nil
        }

        private func date(near anchor: (rect: CGRect, page: Int)) -> Date? {
            let nearby = runs.filter { run in
                run.page == anchor.page && run.rect.minX < anchor.rect.maxX + 200 && run.rect.maxX > anchor.rect.minX - 40
                    && run.rect.maxY <= anchor.rect.maxY + 4 && anchor.rect.minY - run.rect.maxY <= 40
            }.sorted { $0.rect.midY > $1.rect.midY }
            // Day, month and year are often printed in separate boxes: read each row whole.
            var rows: [[Line]] = []
            for run in nearby {
                if let first = rows.last?.first, abs(first.rect.midY - run.rect.midY) <= 4 { rows[rows.count - 1].append(run) } else { rows.append([run]) }
            }
            for row in rows {
                let text = row.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ")
                if let match = text.firstMatch(of: #/\b([0-3]?[0-9])[\s/.-]+([01]?[0-9])[\s/.-]+(20[0-9]{2})\b/#),
                   let day = Int(match.1), let month = Int(match.2), let year = Int(match.3),
                   let date = UKTaxYear.utcCalendar.date(from: DateComponents(year: year, month: month, day: day)),
                   UKTaxYear.utcCalendar.component(.day, from: date) == day {
                    return date
                }
            }
            return nil
        }

        /// P11D: each box number (9–16) with an amount to its right on the same row; the
        /// rightmost amount there is the cash equivalent (cost and amount made good sit left of
        /// the box). The section is the nearest letter A–N above in the left margin.
        func p11dBenefits() -> [PayrollFormExtraction.Benefit] {
            let pageWidths = Dictionary(grouping: words, by: \.page).mapValues { $0.map(\.rect.maxX).max() ?? 0 }
            let letters = words.filter { word in
                word.text.count == 1 && ("A"..."N").contains(word.text) && word.rect.minX < max(40, (pageWidths[word.page] ?? 600) * 0.08)
            }
            var benefits: [PayrollFormExtraction.Benefit] = []
            for box in words {
                guard let number = Int(box.text), (9...16).contains(number), box.text.count <= 2 else { continue }
                let amounts = words(rightOf: (box.rect, box.page), slack: 3).compactMap { PayrollFormReader.pence($0.text) }
                guard let value = amounts.last, value > 0 else { continue }
                let section = letters.filter { $0.page == box.page && $0.rect.midY >= box.rect.midY - 3 }
                    .min { ($0.rect.midY - box.rect.midY) < ($1.rect.midY - box.rect.midY) }
                let kind = section.flatMap { BenefitKind.kind(p11dSection: $0.text, box: number) } ?? BenefitKind.kind(sa102Box: number)
                benefits.append(PayrollFormExtraction.Benefit(kind: kind, sa102Box: number, cashEquivalentMinorUnits: value))
            }
            return benefits
        }

        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "’", with: "'")
                .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }
                .split(separator: " ").joined(separator: " ")
        }
    }
}
