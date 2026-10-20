import GRDB
import Foundation

public enum SourceFolderError: Error, Equatable, LocalizedError {
    case folderNotFound
    case notAFolder
    /// The folder's bookmark no longer resolves and its path is gone (deleted, or a disk that
    /// isn't connected).
    case unavailable(path: String)

    public var errorDescription: String? {
        switch self {
        case .folderNotFound: return "That source folder is no longer registered."
        case .notAFolder: return "Only folders can be registered as evidence sources."
        case .unavailable(let path): return "The folder \(path) can't be found. Is its disk connected?"
        }
    }
}

/// Registered source folders (spec 2026-10-16 §3) and scans of them: what's new, changed,
/// missing or already in the library, with a proposed classification and transaction links
/// for each new file. Scans only read the user's files — nothing in the folder is moved,
/// renamed or written — and only the library's own tables record what was seen.
public struct SourceFolderScanner: Sendable {
    public let library: EvidenceLibrary
    public var database: any DatabaseWriter { library.database }

    public init(library: EvidenceLibrary) {
        self.library = library
    }

    // MARK: Registering

    /// Remembers `url` as a source folder, with a bookmark to reopen it across launches
    /// (security-scoped on macOS). Registering a folder twice updates its bookmark.
    @discardableResult
    public func register(_ url: URL, name: String? = nil) throws -> SourceFolder {
        let folderURL = url.standardizedFileURL
        let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values.isDirectory == true, values.isPackage != true else { throw SourceFolderError.notAFolder }
        let bookmark = try? Self.bookmark(for: folderURL)
        let path = folderURL.path
        return try database.write { db in
            if var existing = try SourceFolder.filter(Column("path") == path).fetchOne(db) {
                existing.bookmark = bookmark ?? existing.bookmark
                try existing.update(db)
                return existing
            }
            var folder = SourceFolder(path: path, bookmark: bookmark, name: name ?? folderURL.lastPathComponent)
            try folder.insert(db)
            return folder
        }
    }

    public func sourceFolders() throws -> [SourceFolder] {
        try database.read { db in try SourceFolder.order(Column("name").collating(.localizedCaseInsensitiveCompare), Column("id")).fetchAll(db) }
    }

    /// Forgets the folder and what its scans saw. Library documents that came from it stay
    /// (they only lose the reference to it); the folder itself is untouched.
    public func removeSourceFolder(_ folderId: Int64) throws {
        try database.write { db in
            guard try SourceFolder.deleteOne(db, key: folderId) else { throw SourceFolderError.folderNotFound }
        }
    }

    /// A bookmark to `url`: security-scoped on macOS (falling back to a plain one where that
    /// isn't available), plain on iOS (whose document-picker URLs carry their own scope).
    static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        if let scoped = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        #endif
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public struct ResolvedFolder: Equatable, Sendable {
        public var url: URL
        /// The folder as stored afterwards (path and bookmark refreshed when it moved or the
        /// bookmark was stale).
        public var folder: SourceFolder
        /// The bookmark was stale (or missing) and was recreated.
        public var bookmarkWasRefreshed: Bool
    }

    /// Where the folder is now: its bookmark resolved (following a move or rename), else its
    /// path. A stale or missing bookmark is recreated and the new path saved.
    public func resolve(_ folder: SourceFolder) throws -> ResolvedFolder {
        try withResolvedFolder(folder) { $0 }
    }

    /// Resolves `folder` and runs `body` inside its security scope: access starts right after
    /// the bookmark resolves, covers the existence check and any bookmark refresh, and is held
    /// until `body` returns.
    func withResolvedFolder<T>(_ folder: SourceFolder, _ body: (ResolvedFolder) throws -> T) throws -> T {
        var isStale = false
        let resolvedURL = folder.bookmark.flatMap { Self.resolveBookmark($0, isStale: &isStale) }
        // The resolved URL carries the scope, so access starts on it (not a copy).
        let url = resolvedURL ?? URL(fileURLWithPath: folder.path, isDirectory: true)
        if resolvedURL == nil { isStale = true }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SourceFolderError.unavailable(path: folder.path)
        }
        let path = url.standardizedFileURL.path
        var updated = folder
        var refreshed = false
        if isStale, let bookmark = try? Self.bookmark(for: url) {
            updated.bookmark = bookmark
            refreshed = true
        }
        updated.path = path
        if updated != folder, let id = folder.id {
            let toSave = updated
            try database.write { db in
                // Another registered folder already has this path: keep the stored one.
                guard try SourceFolder.filter(Column("path") == toSave.path && Column("id") != id).fetchCount(db) == 0 else { return }
                try toSave.update(db)
            }
        }
        return try body(ResolvedFolder(url: url, folder: updated, bookmarkWasRefreshed: refreshed))
    }

    static func resolveBookmark(_ bookmark: Data, isStale: inout Bool) -> URL? {
        #if os(macOS)
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return url
        }
        isStale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
    }

    // MARK: Scanning

    public struct Options: Sendable {
        /// Analyse new and changed files that aren't in the library and propose transactions.
        public var analyzeNewFiles: Bool
        public var suggestionLimit: Int

        public init(analyzeNewFiles: Bool = true, suggestionLimit: Int = 5) {
            self.analyzeNewFiles = analyzeNewFiles
            self.suggestionLimit = suggestionLimit
        }
    }

    public struct Progress: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            /// Walking the folder (`completed` counts the entries found so far, `total` is 0).
            case listing
            /// Reading files: hashing changed ones, analysing new ones.
            case reading
        }

        public var phase: Phase
        public var completed: Int
        public var total: Int
        public var currentPath: String?
    }

    /// A file found by a scan.
    public struct ScannedFile: Equatable, Sendable {
        public var relativePath: String
        public var url: URL
        public var size: Int64
        public var modifiedAt: Date
        public var sha256: String
        /// The library document with this content, if any.
        public var documentId: Int64?
        /// For a changed file (a change not yet acknowledged): the content before the change,
        /// the document it was in the library as, and when the change was noticed.
        public var previousSha256: String?
        public var previousDocumentId: Int64?
        public var changeDetectedAt: Date?
        /// For a new or changed file not in the library: what it looks like (when analysed).
        public var analysis: EvidenceAnalysis?
        /// …and the transactions it may be evidence for, best first.
        public var suggestions: [EvidenceMatcher.Suggestion]

        public init(relativePath: String, url: URL, size: Int64, modifiedAt: Date, sha256: String, documentId: Int64? = nil,
                    previousSha256: String? = nil, previousDocumentId: Int64? = nil, changeDetectedAt: Date? = nil,
                    analysis: EvidenceAnalysis? = nil, suggestions: [EvidenceMatcher.Suggestion] = []) {
            self.relativePath = relativePath
            self.url = url
            self.size = size
            self.modifiedAt = modifiedAt
            self.sha256 = sha256
            self.documentId = documentId
            self.previousSha256 = previousSha256
            self.previousDocumentId = previousDocumentId
            self.changeDetectedAt = changeDetectedAt
            self.analysis = analysis
            self.suggestions = suggestions
        }
    }

    public struct IgnoredFile: Equatable, Sendable {
        public enum Reason: String, Equatable, Sendable {
            /// A dot-file or hidden folder.
            case hidden
            /// `.DS_Store`, `Icon\r`, `Thumbs.db`, `desktop.ini`.
            case systemFile
            /// A Finder alias or symbolic link (its target isn't followed).
            case alias
            /// Microsoft Office's `~$name` lock file.
            case officeLock
            /// An app or other package.
            case package
        }

        public var relativePath: String
        public var reason: Reason
    }

    public struct UnreadableFile: Equatable, Sendable {
        public var relativePath: String
        public var message: String
    }

    public struct ScanResult: Equatable, Sendable {
        public var folder: SourceFolder
        public var scannedAt: Date
        /// Files whose content isn't in the library, whether or not an earlier scan saw them
        /// (pending review until added).
        public var new: [ScannedFile]
        /// Files whose content changed since it was first recorded, until the change is
        /// acknowledged (`acknowledgeChange`) — this scan's and earlier scans' changes alike.
        public var changed: [ScannedFile]
        /// Files seen by an earlier scan that aren't in the folder any more.
        public var missing: [SourceFile]
        /// Files whose content is already in the library (perhaps under another name).
        public var inLibrary: [ScannedFile]
        public var ignored: [IgnoredFile]
        /// iCloud (or other cloud) files whose content isn't on this Mac — not read, since
        /// reading would download them, which is the user's call.
        public var notDownloaded: [String]
        public var unreadable: [UnreadableFile]

        public init(folder: SourceFolder, scannedAt: Date, new: [ScannedFile] = [], changed: [ScannedFile] = [], missing: [SourceFile] = [],
                    inLibrary: [ScannedFile] = [], ignored: [IgnoredFile] = [], notDownloaded: [String] = [], unreadable: [UnreadableFile] = []) {
            self.folder = folder
            self.scannedAt = scannedAt
            self.new = new
            self.changed = changed
            self.missing = missing
            self.inLibrary = inLibrary
            self.ignored = ignored
            self.notDownloaded = notDownloaded
            self.unreadable = unreadable
        }
    }

    /// Scans `folder` (registered): lists its files, hashes those that are new or whose size
    /// or modification date changed since the last scan, sorts them into new / changed /
    /// in-library, reports missing ones, and — with `analyzeNewFiles` — analyses the new and
    /// changed files not in the library and proposes transactions for them. Records what it
    /// saw (`SourceFile`, pending changes included) and the folder's `lastScanAt` in one write
    /// at the end, so a cancelled scan (the calling task cancelled: throws `CancellationError`)
    /// records nothing. Runs inside the folder's security scope. `progress` is called
    /// synchronously on the scanning thread.
    public func scan(_ folder: SourceFolder, options: Options = Options(), now: Date = Date(),
                     progress: (@Sendable (Progress) -> Void)? = nil) throws -> ScanResult {
        guard let folderId = folder.id else { throw SourceFolderError.folderNotFound }
        return try withResolvedFolder(folder) { resolved in
            try scan(resolved, folderId: folderId, options: options, now: now, progress: progress)
        }
    }

    private func scan(_ resolved: ResolvedFolder, folderId: Int64, options: Options, now: Date,
                      progress: (@Sendable (Progress) -> Void)?) throws -> ScanResult {
        let root = resolved.url

        // What earlier scans saw, and the library's contents by hash.
        let (records, documentsBySha) = try database.read { db -> ([String: SourceFile], [String: Int64]) in
            let rows = try SourceFile.filter(Column("folderId") == folderId).fetchAll(db)
            let documents = try Row.fetchAll(db, sql: "SELECT id, sha256 FROM document")
            return (Dictionary(rows.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first }),
                    Dictionary(documents.map { ($0["sha256"] as String, $0["id"] as Int64) }, uniquingKeysWith: { first, _ in first }))
        }

        let listing = try list(root, progress: progress)
        var result = ScanResult(folder: resolved.folder, scannedAt: now, new: [], changed: [], missing: [], inLibrary: [],
                                ignored: listing.ignored, notDownloaded: listing.notDownloaded, unreadable: [])
        var seen = Set(listing.notDownloaded).union(listing.ignored.map(\.relativePath))
        var toSave: [SourceFile] = []
        var toAnalyze: [(bucket: WritableKeyPath<ScanResult, [ScannedFile]>, index: Int)] = []

        for (index, entry) in listing.files.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(phase: .reading, completed: index, total: listing.files.count, currentPath: entry.relativePath))
            seen.insert(entry.relativePath)
            let record = records[entry.relativePath]
            let unchanged = record.map { $0.size == entry.size && Self.sameInstant($0.modifiedAt, entry.modifiedAt) } ?? false
            let hash: String
            if unchanged, let record {
                hash = record.sha256
            } else {
                do {
                    hash = try EvidenceLibrary.sha256(of: entry.url)
                } catch {
                    result.unreadable.append(UnreadableFile(relativePath: entry.relativePath, message: error.localizedDescription))
                    continue
                }
            }
            let documentId = documentsBySha[hash]
            var row = SourceFile(id: record?.id, folderId: folderId, relativePath: entry.relativePath, size: entry.size,
                                 modifiedAt: entry.modifiedAt, sha256: hash, documentId: documentId, lastSeenAt: now,
                                 previousSha256: record?.previousSha256, previousDocumentId: record?.previousDocumentId,
                                 changeDetectedAt: record?.changeDetectedAt)
            if let record, record.sha256 != hash {
                if record.hasPendingChange {
                    // Changed again: still compared with the content before the first change —
                    // unless it's back to that content.
                    if hash == record.previousSha256 {
                        row.previousSha256 = nil
                        row.previousDocumentId = nil
                        row.changeDetectedAt = nil
                    }
                } else {
                    row.previousSha256 = record.sha256
                    row.previousDocumentId = record.documentId
                    row.changeDetectedAt = now
                }
            }
            let scanned = ScannedFile(relativePath: entry.relativePath, url: entry.url, size: entry.size, modifiedAt: entry.modifiedAt,
                                      sha256: hash, documentId: documentId, previousSha256: row.previousSha256,
                                      previousDocumentId: row.previousDocumentId, changeDetectedAt: row.changeDetectedAt,
                                      analysis: nil, suggestions: [])
            if row.hasPendingChange {
                result.changed.append(scanned)
                if documentId == nil { toAnalyze.append((\.changed, result.changed.count - 1)) }
            } else if documentId != nil {
                result.inLibrary.append(scanned)
            } else {
                result.new.append(scanned)
                toAnalyze.append((\.new, result.new.count - 1))
            }
            toSave.append(row)
        }
        progress?(Progress(phase: .reading, completed: listing.files.count, total: listing.files.count, currentPath: nil))

        if options.analyzeNewFiles && !toAnalyze.isEmpty {
            let matching = try MatchingIndex(database: database)
            for (offset, item) in toAnalyze.enumerated() {
                try Task.checkCancellation()
                let file = result[keyPath: item.bucket][item.index]
                progress?(Progress(phase: .reading, completed: listing.files.count + offset,
                                   total: listing.files.count + toAnalyze.count, currentPath: file.relativePath))
                let analysis = EvidenceLibrary.analyze(file.url, named: file.url.lastPathComponent)
                result[keyPath: item.bucket][item.index].analysis = analysis
                result[keyPath: item.bucket][item.index].suggestions = matching.suggestions(for: analysis, fileName: file.relativePath,
                                                                                             limit: options.suggestionLimit)
            }
            progress?(Progress(phase: .reading, completed: listing.files.count + toAnalyze.count,
                               total: listing.files.count + toAnalyze.count, currentPath: nil))
        }

        result.missing = records.values.filter { !seen.contains($0.relativePath) }.sorted { $0.relativePath < $1.relativePath }
        // Still in the folder but not read this time (not downloaded, unreadable, now ignored):
        // seen, so not missing.
        let savedPaths = Set(toSave.map(\.relativePath))
        let touchedIds = records.values.filter { seen.contains($0.relativePath) && !savedPaths.contains($0.relativePath) }.compactMap(\.id)
        try Task.checkCancellation()

        var savedFolder = resolved.folder
        savedFolder.lastScanAt = now
        result.folder = savedFolder
        let folderToSave = savedFolder
        try database.write { db in
            guard try SourceFolder.exists(db, key: folderId) else { throw SourceFolderError.folderNotFound }
            for var file in toSave {
                if file.id != nil { try file.update(db) } else { try file.insert(db) }
            }
            if !touchedIds.isEmpty {
                try SourceFile.filter(keys: touchedIds).updateAll(db, Column("lastSeenAt").set(to: now))
            }
            try folderToSave.update(db, columns: ["lastScanAt"])
        }
        return result
    }

    /// Adds a scanned file to the library as `metadata` says (what the user confirmed), with
    /// the scan's analysis, records where it came from, and notes the document on the file's
    /// scan record.
    @discardableResult
    public func addToLibrary(_ file: ScannedFile, from folder: SourceFolder, metadata: EvidenceMetadata = EvidenceMetadata(),
                             now: Date = Date()) throws -> EvidenceLibrary.AddResult {
        guard let folderId = folder.id else { throw SourceFolderError.folderNotFound }
        var metadata = metadata
        metadata.sourceFolderId = folderId
        metadata.sourceRelativePath = file.relativePath
        metadata.sourceModifiedAt = file.modifiedAt
        let added = try withResolvedFolder(folder) { resolved in
            let url = resolved.url.appendingPathComponent(file.relativePath)
            return if let analysis = file.analysis {
                try library.add(url, metadata: metadata, analysis: analysis, now: now)
            } else {
                try library.addAnalyzing(url, metadata: metadata, now: now)
            }
        }
        if let documentId = added.document.id {
            try database.write { db in
                try db.execute(sql: "UPDATE sourceFile SET documentId = ? WHERE folderId = ? AND sha256 = ?",
                               arguments: [documentId, folderId, added.document.sha256])
            }
        }
        return added
    }

    // MARK: Changes

    /// The folder's files with a pending change (content changed since first recorded), by path.
    public func pendingChanges(inFolder folderId: Int64) throws -> [SourceFile] {
        try database.read { db in
            try SourceFile.filter(Column("folderId") == folderId && Column("changeDetectedAt") != nil)
                .order(Column("relativePath")).fetchAll(db)
        }
    }

    /// Clears the pending change on the file at `relativePath` (the user has dealt with it):
    /// later scans compare with its current content. `false` when there was none.
    @discardableResult
    public func acknowledgeChange(folderId: Int64, relativePath: String) throws -> Bool {
        try database.write { db in
            try SourceFile.filter(Column("folderId") == folderId && Column("relativePath") == relativePath && Column("changeDetectedAt") != nil)
                .updateAll(db, Column("previousSha256").set(to: nil), Column("previousDocumentId").set(to: nil),
                           Column("changeDetectedAt").set(to: nil)) > 0
        }
    }

    // MARK: Summaries

    /// What the folder's last scan recorded.
    public struct Summary: Equatable, Sendable {
        public var folderId: Int64
        /// Files the last scan found and recorded (ignored files, and ones never read because
        /// not downloaded or unreadable, aren't recorded).
        public var fileCount: Int
        /// …of which already in the library.
        public var inLibraryCount: Int
        /// Files earlier scans saw that the last one didn't.
        public var missingCount: Int
        /// Files found by the last scan with a pending change.
        public var changedCount: Int

        public var notInLibraryCount: Int { fileCount - inLibraryCount }
    }

    public func summaries() throws -> [Int64: Summary] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.id AS folderId,
                       COUNT(s.id) FILTER (WHERE s.lastSeenAt >= f.lastScanAt) AS fileCount,
                       COUNT(s.id) FILTER (WHERE s.lastSeenAt >= f.lastScanAt AND s.documentId IS NOT NULL) AS inLibraryCount,
                       COUNT(s.id) FILTER (WHERE s.lastSeenAt < f.lastScanAt) AS missingCount,
                       COUNT(s.id) FILTER (WHERE s.lastSeenAt >= f.lastScanAt AND s.changeDetectedAt IS NOT NULL) AS changedCount
                FROM sourceFolder f LEFT JOIN sourceFile s ON s.folderId = f.id
                GROUP BY f.id
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: Int64 = row["folderId"]
                return (id, Summary(folderId: id, fileCount: row["fileCount"], inLibraryCount: row["inLibraryCount"], missingCount: row["missingCount"],
                                    changedCount: row["changedCount"]))
            })
        }
    }

    // MARK: Listing

    struct ListedFile {
        var relativePath: String
        var url: URL
        var size: Int64
        var modifiedAt: Date
    }

    struct Listing {
        var files: [ListedFile] = []
        var ignored: [IgnoredFile] = []
        var notDownloaded: [String] = []
    }

    static let systemFileNames: Set<String> = [".DS_Store", "Icon\r", "Thumbs.db", "desktop.ini", ".localized"]
    /// iCloud's old-style placeholder for a file not downloaded: `.Name.pdf.icloud`.
    static let iCloudPlaceholderExtension = "icloud"

    private static let listingKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey, .isPackageKey, .fileSizeKey,
        .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
    ]

    /// Why a listed entry is left out of a folder listing (before any iCloud placeholder
    /// handling), or nil when it is a candidate file or an ordinary folder to descend into.
    /// Shared by scans and by import's file collection.
    static func ignoreReason(name: String, values: URLResourceValues) -> IgnoredFile.Reason? {
        let isDirectory = values.isDirectory == true
        if values.isSymbolicLink == true || (values.isAliasFile == true && !isDirectory) { return .alias }
        if systemFileNames.contains(name) { return .systemFile }
        if name.hasPrefix(".") || values.isHidden == true { return .hidden }
        if isDirectory { return values.isPackage == true ? .package : nil }
        if values.isRegularFile == true && name.hasPrefix("~$") { return .officeLock }
        return nil
    }

    /// Every entry under `root`, sorted by path, sorted into readable files, ignored ones and
    /// iCloud files not downloaded. Doesn't descend into hidden folders or packages, or follow
    /// links.
    func list(_ root: URL, progress: (@Sendable (Progress) -> Void)?) throws -> Listing {
        var listing = Listing()
        // The enumerator may report `/private/var/…` for a root given as `/var/…`, and vice versa.
        // (`resolvingSymlinksInPath` drops `/private`, so ask `realpath`.)
        let realRoot = realpath(root.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }
        let rootPrefixes = Set([root.path, realRoot].compactMap { $0 }).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Self.listingKeys,
                                                              options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
        else { return listing }
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count % 200 == 0 {
                try Task.checkCancellation()
                progress?(Progress(phase: .listing, completed: count, total: 0, currentPath: nil))
            }
            let path = url.path
            let relativePath = rootPrefixes.first(where: path.hasPrefix).map { String(path.dropFirst($0.count)) } ?? url.lastPathComponent
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: Set(Self.listingKeys)) else {
                listing.files.append(ListedFile(relativePath: relativePath, url: url, size: -1, modifiedAt: .distantPast))
                continue
            }
            let isDirectory = values.isDirectory == true

            let reason = Self.ignoreReason(name: name, values: values)
            if reason == .alias {
                listing.ignored.append(IgnoredFile(relativePath: relativePath, reason: .alias))
                continue
            }
            if !isDirectory && name.hasPrefix(".") && (name as NSString).pathExtension == Self.iCloudPlaceholderExtension {
                // `.Name.pdf.icloud` stands for `Name.pdf`.
                let original = String((name as NSString).deletingPathExtension.dropFirst())
                let directory = (relativePath as NSString).deletingLastPathComponent
                listing.notDownloaded.append(directory.isEmpty ? original : directory + "/" + original)
                continue
            }
            if let reason {
                if reason == .hidden && isDirectory { enumerator.skipDescendants() }
                listing.ignored.append(IgnoredFile(relativePath: relativePath, reason: reason))
                continue
            }
            guard values.isRegularFile == true else { continue }
            if Self.isNotDownloaded(url, values: values) {
                listing.notDownloaded.append(relativePath)
                continue
            }
            listing.files.append(ListedFile(relativePath: relativePath, url: url, size: Int64(values.fileSize ?? 0),
                                            modifiedAt: values.contentModificationDate ?? .distantPast))
        }
        listing.files.sort { $0.relativePath < $1.relativePath }
        listing.ignored.sort { $0.relativePath < $1.relativePath }
        listing.notDownloaded.sort()
        return listing
    }

    /// An iCloud (or other File Provider) file whose content isn't on this device: reading it
    /// would download it.
    static func isNotDownloaded(_ url: URL, values: URLResourceValues) -> Bool {
        var info = stat()
        let isDataless = lstat(url.path, &info) == 0 && info.st_flags & sfDataless != 0
        return isNotDownloaded(isUbiquitous: values.isUbiquitousItem, status: values.ubiquitousItemDownloadingStatus, isDataless: isDataless)
    }

    /// `SF_DATALESS`: a File Provider file whose content was evicted, whatever the provider.
    static let sfDataless: UInt32 = 0x4000_0000

    /// Only `.notDownloaded` counts: `.downloaded` (an older version is local) and `.current`
    /// can be read without downloading.
    static func isNotDownloaded(isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?, isDataless: Bool) -> Bool {
        if isUbiquitous == true, status == .notDownloaded { return true }
        return isDataless
    }

    /// Modification dates as stored (milliseconds) and as read (nanoseconds) are the same
    /// instant.
    static func sameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.0015
    }
}

/// The transactions, accounts and categories a scan matches new files against: one
/// `EvidenceMatcher.Index` over all of them per scan (it slices by date per file itself, and
/// a payment reference counts only when unique across all transactions).
struct MatchingIndex {
    let index: EvidenceMatcher.Index

    init(database: any DatabaseReader) throws {
        index = try database.read { db in
            EvidenceMatcher.Index(transactions: try Transaction.fetchAll(db), accounts: try Account.fetchAll(db),
                                  categories: try Category.fetchAll(db))
        }
    }

    func suggestions(for analysis: EvidenceAnalysis, fileName: String, limit: Int) -> [EvidenceMatcher.Suggestion] {
        var document = EvidenceDocument(sha256: "", storedRelativePath: "", originalFileName: (fileName as NSString).lastPathComponent,
                                        byteCount: 0, addedAt: Date())
        analysis.apply(to: &document)
        return EvidenceMatcher.suggestions(document: document, index: index, limit: limit)
    }
}
