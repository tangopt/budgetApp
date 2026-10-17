import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the text of image-only documents (photos, screenshots, scanned PDFs) with Vision's
/// on-device text recognition (plan phase 5 Task 2). Lines come out top to bottom, one per line.
public enum EvidenceOCR {
    /// The recognised text of an image file or an image-only PDF (its first `maxPages` pages),
    /// `nil` when nothing was recognised or the file can't be read.
    public static func text(of url: URL, maxPages: Int = 4) -> String? {
        let images: [CGImage]
        if url.pathExtension.lowercased() == "pdf" {
            images = pdfImages(url, maxPages: maxPages)
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            images = [image]
        } else {
            images = []
        }
        let pages = images.compactMap(recognize)
        let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The recognised lines of one image, top to bottom.
    public static func recognize(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["pt-PT", "en-GB"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let observations = (request.results ?? []).sorted {
            // Vision's origin is bottom-left: higher boxes first, then left to right.
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY
                                                                  : $0.boundingBox.minX < $1.boundingBox.minX
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The PDF's pages rendered at about 200 dpi.
    static func pdfImages(_ url: URL, maxPages: Int) -> [CGImage] {
        guard let document = CGPDFDocument(url as CFURL) else { return [] }
        var images: [CGImage] = []
        for number in 1...max(1, min(document.numberOfPages, maxPages)) {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 200 / 72
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            if let image = context.makeImage() { images.append(image) }
        }
        return images
    }
}
