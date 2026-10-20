import Foundation

/// A file read for import: its hash, size and whatever text could be read from it.
public struct ImportFile: Equatable, Sendable {
    public var url: URL
    public var fileName: String
    public var sha256: String
    public var byteCount: Int64
    public var fileExtension: String
    public var text: String?
    public var textStatus: DocumentTextStatus
    public var usedOCR: Bool
    public var sourceFolderId: Int64?
    public var sourceRelativePath: String?
    public var sourceModifiedAt: Date?
    /// A payroll form's reading (positioned words, OCR for scans), filled by
    /// `PayrollFormImportReader.prepare` before the review's write transaction.
    public var payrollExtraction: PayrollFormExtraction?

    public init(url: URL, fileName: String, sha256: String, byteCount: Int64, fileExtension: String, text: String?,
                textStatus: DocumentTextStatus, usedOCR: Bool, sourceFolderId: Int64? = nil,
                sourceRelativePath: String? = nil, sourceModifiedAt: Date? = nil, payrollExtraction: PayrollFormExtraction? = nil) {
        self.url = url
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
        self.fileExtension = fileExtension
        self.text = text
        self.textStatus = textStatus
        self.usedOCR = usedOCR
        self.sourceFolderId = sourceFolderId
        self.sourceRelativePath = sourceRelativePath
        self.sourceModifiedAt = sourceModifiedAt
        self.payrollExtraction = payrollExtraction
    }

    /// Reads `url`: PDFs and images give their text layer (else OCR when `ocr`), `.csv` / `.txt`
    /// their contents (UTF-8, else ISO Latin 1, a leading byte order mark dropped), anything else no text.
    public static func load(_ url: URL, ocr: Bool = true) throws -> ImportFile {
        let sha = try EvidenceLibrary.sha256(of: url)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let ext = url.pathExtension.lowercased()
        var text: String?
        var status = DocumentTextStatus.noText
        var usedOCR = false
        switch ext {
        case "csv", "txt":
            if let data = try? Data(contentsOf: url) {
                text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
                if text?.hasPrefix("\u{FEFF}") == true { text?.removeFirst() }
                status = text == nil ? .noText : .text
            }
        case "pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp":
            let read = UtilityInvoiceIntake.text(of: url, ocr: ocr)
            text = read.text
            status = read.status
            usedOCR = read.usedOCR
        default:
            break
        }
        return ImportFile(url: url, fileName: url.lastPathComponent, sha256: sha, byteCount: Int64(values?.fileSize ?? 0),
                          fileExtension: ext, text: text, textStatus: status, usedOCR: usedOCR,
                          sourceModifiedAt: values?.contentModificationDate)
    }
}

/// Expands dropped or chosen URLs into the files to import.
public enum ImportFileCollector {
    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey, .isPackageKey
    ]

    /// Files in the order given; folders expand recursively in natural name order. What
    /// `SourceFolderScanner.ignoreReason` ignores (hidden, system, lock, alias, package) is
    /// left out and its name returned in `ignored`.
    public static func collect(_ urls: [URL]) -> (files: [URL], ignored: [String]) {
        var files: [URL] = []
        var ignored: [String] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if SourceFolderScanner.ignoreReason(name: url.lastPathComponent, values: values) != nil {
                ignored.append(url.lastPathComponent)
            } else if values.isDirectory == true {
                collectFolder(url, files: &files, ignored: &ignored)
            } else if values.isRegularFile == true {
                files.append(url)
            }
        }
        return (files, ignored)
    }

    private static func collectFolder(_ folder: URL, files: inout [URL], ignored: inout [String]) {
        let children = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var subfolders: [URL] = []
        for child in children {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if SourceFolderScanner.ignoreReason(name: child.lastPathComponent, values: values) != nil {
                ignored.append(child.lastPathComponent)
            } else if values.isDirectory == true {
                subfolders.append(child)
            } else if values.isRegularFile == true {
                files.append(child)
            }
        }
        for sub in subfolders { collectFolder(sub, files: &files, ignored: &ignored) }
    }
}
