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

    public init(id: UUID, fileName: String, sha256: String, byteCount: Int, receivedAt: Date, sourceHost: String?) {
        self.id = id
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
        self.receivedAt = receivedAt
        self.sourceHost = sourceHost
    }
}

/// Why the tray refused a file. Nothing is kept for either.
public enum TrayError: Error, Equatable, LocalizedError {
    /// The file doesn't start with `%PDF-` (an HTML error page or a sign-in page saved as `.pdf`, an image...).
    case notAPDF
    /// The file has no bytes.
    case empty

    public var errorDescription: String? {
        switch self {
        case .notAPDF: "That download isn't a PDF, so it wasn't kept. The site may have sent an error page instead."
        case .empty: "That download was empty, so it wasn't kept."
        }
    }
}

/// The iPad's Downloads tray (step 10, Task 5): PDFs from the built-in browser or shared into Mango wait here until
/// they are checked. App-private: one folder with file protection `completeUntilFirstUserAuthentication`, excluded
/// from backup, and never synced (a checked file becomes a normal document or import; the tray copy is discarded).
/// One item per sha256. Sign-out, leaving the household and demo data empty it (`purgeAll`).
///
/// Each file is stored as `<id>.pdf`; the items' metadata is a JSON sidecar (`tray.json`) in the same folder. All work
/// runs on one serial queue.
public final class DownloadsTray: @unchecked Sendable {
    public let directory: URL
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "ubberninja.mango.downloadsTray")
    private let fileManager = FileManager.default

    static let indexName = "tray.json"
    static let pdfMagic = Data("%PDF-".utf8)

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Takes the file at `url` into the tray: it must be non-empty and start with `%PDF-`. Accepted, the file is
    /// moved in (the original is gone, which takes a shared file out of `Documents/Inbox`, a backed-up folder),
    /// protected and excluded from backup; a file whose sha256 is already here returns that item and the duplicate is
    /// deleted. Refused, nothing is kept and the file at `url` is left for the caller to remove.
    public func ingest(fileAt url: URL, suggestedName: String, sourceHost: String?) throws -> TrayItem {
        try queue.sync {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else { throw TrayError.empty }
            guard data.starts(with: Self.pdfMagic) else { throw TrayError.notAPDF }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try prepareDirectory()
            var items = try readIndex()
            if let existing = items.first(where: { $0.sha256 == hash }) {
                try? fileManager.removeItem(at: url)
                return existing
            }
            let item = TrayItem(id: UUID(), fileName: Self.displayName(suggestedName), sha256: hash, byteCount: data.count,
                                receivedAt: now(), sourceHost: sourceHost)
            var stored = storedURL(item.id)
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
    public func fileURL(for item: TrayItem) -> URL { storedURL(item.id) }

    /// Removes `item` and its file.
    public func discard(_ item: TrayItem) {
        queue.sync {
            try? fileManager.removeItem(at: storedURL(item.id))
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
    public static func displayName(_ suggested: String) -> String {
        let last = (suggested as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = last.isEmpty || last == "/" ? "Download" : last
        return name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"
    }

    private func storedURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".pdf")
    }

    private var indexURL: URL { directory.appendingPathComponent(Self.indexName) }

    private func prepareDirectory() throws {
        var folder = directory
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: Self.protection)
        }
        try protect(&folder)
    }

    /// The items whose files are still here.
    private func readIndex() throws -> [TrayItem] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let items = try JSONDecoder().decode([TrayItem].self, from: Data(contentsOf: indexURL))
        return items.filter { fileManager.fileExists(atPath: storedURL($0.id).path) }
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
