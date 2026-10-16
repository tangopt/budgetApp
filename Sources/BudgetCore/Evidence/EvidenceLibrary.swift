import GRDB
import Foundation
import CryptoKit

public enum EvidenceLibraryError: Error, Equatable, LocalizedError {
    case documentNotFound
    /// `remove` without `force` on a document that is evidence for something.
    case documentIsLinked(linkCount: Int)
    case notAFile
    /// `link` to a transaction, account or category that doesn't exist.
    case entityNotFound

    public var errorDescription: String? {
        switch self {
        case .documentNotFound: return "That document is no longer in the library."
        case .documentIsLinked(let count): return "That document is linked to \(count) record\(count == 1 ? "" : "s"); unlink it first."
        case .notAFile: return "Only files can be added to the library."
        case .entityNotFound: return "That record no longer exists."
        }
    }
}

/// What the caller knows about a file being added. Everything is optional; text extraction
/// and classification fill in more later.
public struct EvidenceMetadata: Equatable, Sendable {
    public var kind: DocumentKind
    public var docDate: Date?
    public var periodStart: Date?
    public var periodEnd: Date?
    public var amountMinorUnits: Int?
    public var currency: Currency?
    public var persons: [String]
    public var canonicalName: String?
    public var sourceFolderId: Int64?
    public var sourceRelativePath: String?
    public var sourceModifiedAt: Date?
    public var note: String?
    /// How readable the file is and its text (`EvidenceAnalyzer`); `.unknown` when not analysed.
    public var textStatus: DocumentTextStatus
    public var extractedText: String?

    public init(kind: DocumentKind = .other, docDate: Date? = nil, periodStart: Date? = nil, periodEnd: Date? = nil,
                amountMinorUnits: Int? = nil, currency: Currency? = nil, persons: [String] = [], canonicalName: String? = nil,
                sourceFolderId: Int64? = nil, sourceRelativePath: String? = nil, sourceModifiedAt: Date? = nil, note: String? = nil,
                textStatus: DocumentTextStatus = .unknown, extractedText: String? = nil) {
        self.kind = kind
        self.docDate = docDate
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.persons = persons
        self.canonicalName = canonicalName
        self.sourceFolderId = sourceFolderId
        self.sourceRelativePath = sourceRelativePath
        self.sourceModifiedAt = sourceModifiedAt
        self.note = note
        self.textStatus = textStatus
        self.extractedText = extractedText
    }
}

/// The app's evidence library (spec 2026-10-16 §3): copies of the files the user adds or links,
/// stored by content under `root` as `<sha[0..2]>/<sha>.<ext>`, one per distinct content, with
/// their metadata and links in the database. The user's own files are only ever read.
public struct EvidenceLibrary: Sendable {
    public struct AddResult: Equatable, Sendable {
        public var document: EvidenceDocument
        /// `false` when the same content was already in the library (that document is returned
        /// unchanged).
        public var isNew: Bool
    }

    public let root: URL
    public let database: any DatabaseWriter

    /// `Application Support/Budget/Evidence`, next to the database.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Budget", isDirectory: true)
            .appendingPathComponent("Evidence", isDirectory: true)
    }

    public init(root: URL = EvidenceLibrary.defaultRoot, database: any DatabaseWriter) {
        self.root = root
        self.database = database
    }

    // MARK: Files

    public func fileURL(for document: EvidenceDocument) -> URL {
        root.appendingPathComponent(document.storedRelativePath)
    }

    /// Lowercase hex SHA-256 of the file's bytes, read in chunks.
    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `<sha[0..2]>/<sha>.<ext>` (lowercase extension; none when the file has none).
    static func storedRelativePath(sha256: String, fileExtension: String) -> String {
        let name = fileExtension.isEmpty ? sha256 : "\(sha256).\(fileExtension.lowercased())"
        return "\(sha256.prefix(2))/\(name)"
    }

    // MARK: Adding and removing

    /// Test seams around `add`: after the temporary copy is written, and just before the row
    /// is inserted.
    struct AddHooks: Sendable {
        var afterCopy: (@Sendable (_ temporary: URL) throws -> Void)?
        var beforeInsert: (@Sendable () throws -> Void)?
    }

    /// Copies `fileURL` into the library and records it, or returns the document that already
    /// has the same content. The source is read once, into a temporary copy beside the store;
    /// the hash and size describe that copy, which then moves into place under its hash. A
    /// symbolic link adds the file it points to (named after the link). If the row can't be
    /// written the copy is removed — unless another add recorded the same content meanwhile,
    /// in which case that document is returned.
    @discardableResult
    public func add(_ fileURL: URL, metadata: EvidenceMetadata = EvidenceMetadata(), now: Date = Date()) throws -> AddResult {
        try add(fileURL, metadata: metadata, analysis: .none, now: now, hooks: AddHooks())
    }

    /// `add`, recording `analysis` (what `EvidenceAnalyzer` proposed, perhaps confirmed by the
    /// user): its kind, dates, period, amount and currency where `metadata` leaves them unset,
    /// and its text status and text.
    @discardableResult
    public func add(_ fileURL: URL, metadata: EvidenceMetadata = EvidenceMetadata(), analysis: EvidenceAnalysis,
                    now: Date = Date()) throws -> AddResult {
        try add(fileURL, metadata: metadata, analysis: .provided(analysis), now: now, hooks: AddHooks())
    }

    /// `add`, analysing the stored copy first (`EvidenceAnalyzer`, named after `fileURL`) and
    /// recording what it finds where `metadata` leaves it unset. A file already in the library
    /// is returned unchanged, unanalysed.
    @discardableResult
    public func addAnalyzing(_ fileURL: URL, metadata: EvidenceMetadata = EvidenceMetadata(), now: Date = Date()) throws -> AddResult {
        try add(fileURL, metadata: metadata, analysis: .analyze, now: now, hooks: AddHooks())
    }

    enum AnalysisMode {
        case none
        case provided(EvidenceAnalysis)
        case analyze
    }

    /// `metadata`'s values, falling back to `analysis`'s for the kind (when `.other`), dates,
    /// period, amount and currency.
    static func merged(_ metadata: EvidenceMetadata, with analysis: EvidenceAnalysis) -> EvidenceMetadata {
        var merged = metadata
        let proposed = analysis.metadata
        if merged.kind == .other { merged.kind = proposed.kind }
        merged.docDate = merged.docDate ?? proposed.docDate
        if merged.periodStart == nil && merged.periodEnd == nil {
            merged.periodStart = proposed.periodStart
            merged.periodEnd = proposed.periodEnd
        }
        if merged.amountMinorUnits == nil {
            merged.amountMinorUnits = proposed.amountMinorUnits
            merged.currency = merged.currency ?? proposed.currency
        }
        if merged.persons.isEmpty { merged.persons = proposed.persons }
        if merged.textStatus == .unknown {
            let proposedStatus = proposed.textStatus != .unknown ? proposed.textStatus : analysis.textStatus
            merged.textStatus = proposedStatus
            merged.extractedText = merged.extractedText ?? proposed.extractedText ?? analysis.extractedText
        }
        return merged
    }

    /// Analyses the file at `url` (a copy stored under its hash) as if it were called `fileName`.
    static func analyze(_ url: URL, named fileName: String) -> EvidenceAnalysis {
        autoreleasepool {
            let extraction = EvidenceTextExtractor.extract(from: url)
            return EvidenceAnalyzer.analyze(text: extraction.text, textStatus: extraction.status, fileName: fileName)
        }
    }

    func add(_ fileURL: URL, metadata: EvidenceMetadata, now: Date, hooks: AddHooks) throws -> AddResult {
        try add(fileURL, metadata: metadata, analysis: .none, now: now, hooks: hooks)
    }

    func add(_ fileURL: URL, metadata callerMetadata: EvidenceMetadata, analysis mode: AnalysisMode, now: Date, hooks: AddHooks) throws -> AddResult {
        let fileManager = FileManager.default
        let source = fileURL.resolvingSymlinksInPath()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw EvidenceLibraryError.notAFile }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        removeStaleTemporaryFiles(now: now)
        let temporary = root.appendingPathComponent("\(Self.temporaryPrefix)\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)")
        let hash: String, byteCount: Int64
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try hooks.afterCopy?(temporary)
            hash = try Self.sha256(of: temporary)
            byteCount = try Self.byteCount(of: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        if let existing = try document(sha256: hash) {
            try? fileManager.removeItem(at: temporary)
            return AddResult(document: existing, isNew: false)
        }

        let relativePath = Self.storedRelativePath(sha256: hash, fileExtension: fileURL.pathExtension)
        let destination = root.appendingPathComponent(relativePath)
        let movedIn: Bool
        do {
            movedIn = try place(temporary, at: destination, sha256: hash, byteCount: byteCount)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        let analysis: EvidenceAnalysis? = switch mode {
        case .none: nil
        case .provided(let analysis): analysis
        case .analyze: Self.analyze(destination, named: fileURL.lastPathComponent)
        }
        let metadata = analysis.map { Self.merged(callerMetadata, with: $0) } ?? callerMetadata

        var document = EvidenceDocument(
            sha256: hash, storedRelativePath: relativePath, originalFileName: fileURL.lastPathComponent,
            byteCount: byteCount, canonicalName: Transaction.normalizedNote(metadata.canonicalName),
            kind: metadata.kind, docDate: metadata.docDate, periodStart: metadata.periodStart, periodEnd: metadata.periodEnd,
            amountMinorUnits: metadata.amountMinorUnits, currency: metadata.currency, persons: metadata.persons,
            textStatus: metadata.textStatus, extractedText: metadata.extractedText,
            sourceFolderId: metadata.sourceFolderId, sourceRelativePath: metadata.sourceRelativePath,
            sourceModifiedAt: metadata.sourceModifiedAt.map(EvidenceLinks.wholeSeconds),
            addedAt: EvidenceLinks.wholeSeconds(now), note: Transaction.normalizedNote(metadata.note))
        do {
            try hooks.beforeInsert?()
            try database.write { db in try document.insert(db) }
        } catch {
            // Another add recorded the same content meanwhile: its row owns the stored file.
            if let existing = try? self.document(sha256: hash) {
                return AddResult(document: existing, isNew: false)
            }
            if movedIn { try? fileManager.removeItem(at: destination) }
            throw error
        }
        return AddResult(document: document, isNew: true)
    }

    static let temporaryPrefix = ".adding-"

    /// Moves the temporary copy to `destination`; `false` when a file with this content was
    /// already there (left by an earlier failed add, or placed by a concurrent one) and the
    /// copy was dropped instead. A leftover of the wrong size — or same size, other hash — is
    /// replaced.
    private func place(_ temporary: URL, at destination: URL, sha256 hash: String, byteCount: Int64) throws -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            let existingSize = try? Self.byteCount(of: destination)
            if existingSize == byteCount, (try? Self.sha256(of: destination)) == hash {
                try? fileManager.removeItem(at: temporary)
                return false
            }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch CocoaError.fileWriteFileExists {
            // A concurrent add placed the same content first.
            try? fileManager.removeItem(at: temporary)
            return false
        }
        return true
    }

    /// Removes temporary copies left by adds that never finished (older than an hour, by the
    /// time in their name), leaving any in progress alone.
    private func removeStaleTemporaryFiles(now: Date) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Int(now.timeIntervalSince1970) - 3600
        for name in names where name.hasPrefix(Self.temporaryPrefix) {
            let stamp = name.dropFirst(Self.temporaryPrefix.count).split(separator: "-").first.flatMap { Int($0) }
            if stamp.map({ $0 < cutoff }) ?? true {
                try? fileManager.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    static func byteCount(of fileURL: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Deletes the document, its links and its stored copy. A linked document is refused
    /// unless `force`.
    public func remove(_ documentId: Int64, force: Bool = false) throws {
        let document: EvidenceDocument = try database.write { db in
            guard let document = try EvidenceDocument.fetchOne(db, key: documentId) else { throw EvidenceLibraryError.documentNotFound }
            let linkCount = try DocumentLink.filter(Column("documentId") == documentId).fetchCount(db)
            if linkCount > 0 && !force { throw EvidenceLibraryError.documentIsLinked(linkCount: linkCount) }
            try document.delete(db) // links cascade
            return document
        }
        // After the commit: the row is gone for good, so its copy can go.
        try? FileManager.default.removeItem(at: fileURL(for: document))
    }

    // MARK: Reading

    public func document(sha256: String) throws -> EvidenceDocument? {
        try database.read { db in try EvidenceDocument.filter(Column("sha256") == sha256).fetchOne(db) }
    }

    /// Every document without its extracted text, newest added first: for lists.
    public func documentSummaries() throws -> [EvidenceDocumentSummary] {
        try database.read { db in try EvidenceDocumentSummary.newestFirst.fetchAll(db) }
    }

    public func documents(inSourceFolder folderId: Int64) throws -> [EvidenceDocument] {
        try database.read { db in
            try EvidenceDocument.filter(Column("sourceFolderId") == folderId).order(Column("sourceRelativePath"), Column("id")).fetchAll(db)
        }
    }

    // MARK: Links

    @discardableResult
    public func link(_ documentId: Int64, to entity: EvidenceEntity, role: String? = nil) throws -> DocumentLink {
        try database.write { db in try EvidenceLinks.link(db: db, documentId: documentId, to: entity, role: role) }
    }

    /// Sets (or, with `nil`, clears) the role of an existing link; `false` when there is none.
    @discardableResult
    public func setRole(_ role: String?, documentId: Int64, entity: EvidenceEntity) throws -> Bool {
        try database.write { db in try EvidenceLinks.setRole(db: db, role, documentId: documentId, entity: entity) }
    }

    @discardableResult
    public func unlink(_ documentId: Int64, from entity: EvidenceEntity) throws -> Bool {
        try database.write { db in try EvidenceLinks.unlink(db: db, documentId: documentId, from: entity) }
    }

    public func documents(for entity: EvidenceEntity) throws -> [EvidenceDocument] {
        try database.read { db in try EvidenceLinks.documents(db: db, for: entity) }
    }

    /// The records `documentId` is evidence for (its links, in the order they were made).
    public func entities(for documentId: Int64) throws -> [DocumentLink] {
        try database.read { db in try EvidenceLinks.links(db: db, for: documentId) }
    }

    public func linkCounts(_ type: EvidenceEntityType) throws -> [Int64: Int] {
        try database.read { db in try EvidenceLinks.linkCounts(db: db, type) }
    }

    public func unlinkedDocuments() throws -> [EvidenceDocument] {
        try database.read { db in try EvidenceLinks.unlinkedDocuments(db: db) }
    }
}
