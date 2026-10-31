import CryptoKit
import Foundation

/// A PDF waiting in the Downloads tray: fetched in the iPad's browser, or shared into Mango, and not yet checked.
public struct TrayItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The name the site (or the sharing app) gave it; shown, never used as the stored file's name.
    public var fileName: String
    public var sha256: String
    public var byteCount: Int
    public var receivedAt: Date
    /// The site it came from; nil when it was shared in.
    public var sourceHost: String?
    /// The stored file's extension, lower case: "pdf" for everything the browser fetches; the iPhone's import inbox
    /// also keeps "csv" and images.
    public var fileExtension: String

    public init(id: UUID, fileName: String, sha256: String, byteCount: Int, receivedAt: Date, sourceHost: String?,
                fileExtension: String = "pdf") {
        self.id = id
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
        self.receivedAt = receivedAt
        self.sourceHost = sourceHost
        self.fileExtension = fileExtension
    }

    private enum CodingKeys: String, CodingKey { case id, fileName, sha256, byteCount, receivedAt, sourceHost, fileExtension }

    /// An index written before the extension existed holds PDFs only.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fileName = try values.decode(String.self, forKey: .fileName)
        sha256 = try values.decode(String.self, forKey: .sha256)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        receivedAt = try values.decode(Date.self, forKey: .receivedAt)
        sourceHost = try values.decodeIfPresent(String.self, forKey: .sourceHost)
        fileExtension = try values.decodeIfPresent(String.self, forKey: .fileExtension) ?? "pdf"
    }
}

/// Why the tray refused a file. Nothing is kept for either.
public enum TrayError: Error, Equatable, LocalizedError {
    /// The file doesn't start with `%PDF-` (an HTML error page or a sign-in page saved as `.pdf`, an image...).
    case notAPDF
    /// The file has no bytes.
    case empty
    /// Larger than the tray takes (`DownloadsTray.maxBytes`, 50 MB): no bill or statement is that big.
    case tooLarge
    /// The iPhone's import inbox only: not a PDF, CSV or image.
    case unsupportedType

    public var errorDescription: String? {
        switch self {
        case .notAPDF: "That download isn't a PDF, so it wasn't kept. The site may have sent an error page instead."
        case .empty: "That download was empty, so it wasn't kept."
        case .tooLarge: "That download is larger than 50 MB, so it wasn't kept."
        case .unsupportedType: "Mango reads PDF, CSV and image files only."
        }
    }
}

/// The iPad's Downloads tray (step 10, Task 5): PDFs from the built-in browser or shared into Mango wait here until
/// they are checked. App-private: one folder with file protection `completeUntilFirstUserAuthentication`, excluded
/// from backup, and never synced (a checked file becomes a normal document or import; the tray copy is discarded).
/// One item per sha256. Sign-out, leaving the household and demo data empty it (`purgeAll`).
///
/// Each file is stored as `<id>.pdf`; the items' metadata is a JSON sidecar (`tray.json`) in the same folder. A sidecar
/// that can't be read is rebuilt from the files (their names are lost: "Download.pdf"). All work runs on one serial
/// queue.
public final class DownloadsTray: @unchecked Sendable {
    public let directory: URL
    /// The largest file taken, in bytes.
    public let maxBytes: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "ubberninja.mango.downloadsTray")
    private let fileManager = FileManager.default

    static let indexName = "tray.json"
    static let pdfMagic = Data("%PDF-".utf8)
    /// 50 MB.
    public static let defaultMaxBytes = 50 * 1024 * 1024

    public init(directory: URL, maxBytes: Int = DownloadsTray.defaultMaxBytes, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.now = now
    }

    /// Takes the file at `url` into the tray: it must be non-empty and start with `%PDF-`. Accepted, the file is
    /// moved in (the original is gone, which takes a shared file out of `Documents/Inbox`, a backed-up folder),
    /// protected and excluded from backup; a file whose sha256 is already here returns that item and the duplicate is
    /// deleted. Refused, nothing is kept and the file at `url` is left for the caller to remove.
    public func ingest(fileAt url: URL, suggestedName: String, sourceHost: String?) throws -> TrayItem {
        try ingest(fileAt: url, suggestedName: suggestedName, sourceHost: sourceHost, accepting: ["pdf"])
    }

    /// The extensions the iPhone's import inbox keeps: PDF, CSV and photos.
    public static let importExtensions: Set<String> = ["pdf", "csv", "jpg", "jpeg", "png", "heic", "heif"]

    /// `ingest` for the import inbox: any of `accepting` (lower-case extensions, taken from `suggestedName`, else the
    /// file's own). A PDF must still start with `%PDF-`; the others only need bytes.
    public func ingest(fileAt url: URL, suggestedName: String, sourceHost: String?, accepting: Set<String>) throws -> TrayItem {
        try queue.sync {
            let suggested = (suggestedName as NSString).pathExtension.lowercased()
            // The browser's tray: whatever the site called it, it is judged as a PDF by its bytes.
            let fileExtension = accepting == ["pdf"] ? "pdf" : (suggested.isEmpty ? url.pathExtension.lowercased() : suggested)
            guard accepting.contains(fileExtension) else { throw TrayError.unsupportedType }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes { throw TrayError.tooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maxBytes else { throw TrayError.tooLarge }
            guard !data.isEmpty else { throw TrayError.empty }
            guard fileExtension != "pdf" || data.starts(with: Self.pdfMagic) else { throw TrayError.notAPDF }
            let hash = Self.sha256(data)
            try prepareDirectory()
            var items = try readIndex()
            if let existing = items.first(where: { $0.sha256 == hash }) {
                try? fileManager.removeItem(at: url)
                return existing
            }
            let item = TrayItem(id: UUID(), fileName: Self.displayName(suggestedName, fileExtension: fileExtension), sha256: hash, byteCount: data.count,
                                receivedAt: now(), sourceHost: sourceHost, fileExtension: fileExtension)
            var stored = storedURL(item)
            do {
                try fileManager.moveItem(at: url, to: stored)
            } catch {
                // A file the app may read but not move (another app's): copied, then the original removed if it can be.
                try fileManager.copyItem(at: url, to: stored)
                try? fileManager.removeItem(at: url)
            }
            do {
                try protect(&stored)
            } catch {
                try? fileManager.removeItem(at: stored)
                throw error
            }
            items.append(item)
            try writeIndex(items)
            return item
        }
    }

    /// What is in the tray, newest first.
    public func items() -> [TrayItem] {
        queue.sync { ((try? readIndex()) ?? []).sorted { $0.receivedAt > $1.receivedAt } }
    }

    /// Where `item`'s file is.
    public func fileURL(for item: TrayItem) -> URL { storedURL(item) }

    /// Removes `item` and its file.
    public func discard(_ item: TrayItem) {
        queue.sync {
            try? fileManager.removeItem(at: storedURL(item))
            guard let items = try? readIndex() else { return }
            try? writeIndex(items.filter { $0.id != item.id })
        }
    }

    /// Empties the tray: its folder and everything in it are deleted.
    public func purgeAll() {
        queue.sync {
            if fileManager.fileExists(atPath: directory.path) { try? fileManager.removeItem(at: directory) }
        }
    }

    // MARK: Files

    /// The name shown for a download: the last path component of what the site suggested, ending in `.pdf`.
    public static func displayName(_ suggested: String, fileExtension: String = "pdf") -> String {
        let last = (suggested as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = last.isEmpty || last == "/" ? "Download" : last
        return name.lowercased().hasSuffix("." + fileExtension) ? name : name + "." + fileExtension
    }

    private func storedURL(_ item: TrayItem) -> URL {
        directory.appendingPathComponent(item.id.uuidString.lowercased() + "." + item.fileExtension)
    }

    private var indexURL: URL { directory.appendingPathComponent(Self.indexName) }

    private func prepareDirectory() throws {
        var folder = directory
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: Self.protection)
        }
        try protect(&folder)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The items whose files are still here. A sidecar that can't be read is rebuilt from the files.
    private func readIndex() throws -> [TrayItem] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        guard let data = try? Data(contentsOf: indexURL), let items = try? JSONDecoder().decode([TrayItem].self, from: data) else {
            let rebuilt = rebuiltIndex()
            try? writeIndex(rebuilt)
            return rebuilt
        }
        return items.filter { fileManager.fileExists(atPath: storedURL($0).path) }
    }

    /// The items the stored files still say: each `<id>.pdf` that is a PDF, dated by its file; the rest are deleted.
    private func rebuiltIndex() -> [TrayItem] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var seen: Set<String> = []
        return names.compactMap { name -> TrayItem? in
            let ext = (name as NSString).pathExtension
            guard ext == "pdf" || Self.importExtensions.contains(ext),
                  let id = UUID(uuidString: (name as NSString).deletingPathExtension) else { return nil }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), !data.isEmpty, ext != "pdf" || data.starts(with: Self.pdfMagic), data.count <= maxBytes,
                  seen.insert(Self.sha256(data)).inserted
            else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now()
            return TrayItem(id: id, fileName: "Download." + ext, sha256: Self.sha256(data), byteCount: data.count,
                            receivedAt: date, sourceHost: nil, fileExtension: ext)
        }
    }

    private func writeIndex(_ items: [TrayItem]) throws {
        // Dates as their exact seconds (the default), so an item read back equals the one returned.
        try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
        var index = indexURL
        try protect(&index)
    }

    private static var protection: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }

    /// File protection `completeUntilFirstUserAuthentication` (iOS; the Mac has no protection classes) and no backup.
    private func protect(_ url: inout URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(Self.protection, ofItemAtPath: url.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        url.removeAllCachedResourceValues()
    }
}
