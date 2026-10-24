import Foundation
import GRDB

/// A file of a review that wasn't imported, offered to keep for later or copy to a folder
/// (spec 2026-10-24 §1).
public struct SetAsideFile: Equatable, Sendable {
    /// Where it was read (the user's original; Mango's copy for a waiting file).
    public var url: URL
    public var fileName: String
    public var sha256: String
    public var byteCount: Int64
    /// The text already read (kept with it: no second reading on this device).
    public var text: String?
    public var textStatus: DocumentTextStatus
    /// Why it wasn't imported ("Left out by you", "Not recognised", "Possibly a duplicate of …").
    public var reason: String
    /// What the review recognised it as, by name.
    public var recognisedAs: String

    public init(url: URL, fileName: String, sha256: String, byteCount: Int64, text: String?, textStatus: DocumentTextStatus,
                reason: String, recognisedAs: String) {
        self.url = url
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
        self.text = text
        self.textStatus = textStatus
        self.reason = reason
        self.recognisedAs = recognisedAs
    }
}

/// Which files of a review are set aside, and Copy to a folder….
public enum ImportSetAside {
    public static let leftOutReason = "Left out by you"
    public static let discardedReason = "Import discarded"

    /// The files a review leaves unimported: top-level items only (never a statement's rows), each file
    /// once — at Confirm the items left out and the duplicates skipped, when `discarding` every item —
    /// except a file identical to a library document (Mango already holds those bytes) and a file that
    /// couldn't be read. `reason`: the item's first Needs-you reason, else what it duplicates, else
    /// "Left out by you", else "Import discarded"; `recognisedAs`: its kind's name (`names`: custom kinds').
    public static func candidates(_ plan: ImportPlan, discarding: Bool, names: ImportKindNames = ImportKindNames()) -> [SetAsideFile] {
        var seen: Set<String> = []
        var files: [SetAsideFile] = []
        for item in plan.items where item.parentId == nil {
            if let duplicate = item.duplicate, duplicate.level == .file, duplicate.existingDocumentId != nil { continue }
            if ImportResolutions.isUnreadable(item) { continue }
            guard discarding || item.isLeftOut || item.duplicate != nil else { continue }
            guard seen.insert(item.file.sha256.lowercased()).inserted else { continue }
            let reason = item.needsYouReasons.first ?? item.duplicate?.of ?? (item.isLeftOut ? leftOutReason : discardedReason)
            files.append(SetAsideFile(url: item.file.url, fileName: item.file.fileName, sha256: item.file.sha256, byteCount: item.file.byteCount,
                                      text: item.file.text, textStatus: item.file.textStatus, reason: reason,
                                      recognisedAs: names.displayName(item.recognition.kind)))
        }
        return files
    }

    public struct CopyResult: Equatable, Sendable {
        public var copied: [URL] = []
        public var failed: [ImportSetAsideFailure] = []
    }

    /// Copies each file into `folder`: the original when it still exists, else Mango's waiting copy
    /// (`waitingCopy`, by hash). A name already there gets " 2", " 3"… before its extension; nothing
    /// is ever overwritten, and the source is only read.
    public static func copy(_ files: [SetAsideFile], waitingCopy: (String) -> URL?, to folder: URL) -> CopyResult {
        let manager = FileManager.default
        var result = CopyResult()
        for file in files {
            let source: URL
            if manager.fileExists(atPath: file.url.path) {
                source = file.url
            } else if let copy = waitingCopy(file.sha256), manager.fileExists(atPath: copy.path) {
                source = copy
            } else {
                result.failed.append(ImportSetAsideFailure(fileName: file.fileName, reason: "Neither the original nor Mango's copy can be found"))
                continue
            }
            do {
                result.copied.append(try copyUnique(source, named: file.fileName, into: folder))
            } catch {
                result.failed.append(ImportSetAsideFailure(fileName: file.fileName, reason: "Couldn't copy it: \(error.localizedDescription)"))
            }
        }
        return result
    }

    /// `name`, `name 2.ext`, `name 3.ext`… : the first that isn't taken (copying refuses an existing
    /// destination, so a file appearing meanwhile isn't overwritten either).
    private static func copyUnique(_ source: URL, named name: String, into folder: URL) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 1
        while true {
            let candidate = number == 1 ? name : (ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            let destination = folder.appendingPathComponent(candidate)
            number += 1
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            do {
                // A symlink's target, never the link.
                try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
    }
}

extension ImportPipeline {
    /// How the waiting list re-reads a file (`ImportWaitingList.recheck`): the recognisers a reading
    /// builds now (the built-in ones, the enabled learnt kinds, the file-name fallback), the kinds'
    /// names (custom kinds' from the catalog) and the recognisers' signature, all read from `db`.
    public func waitingRecogniser(db: Database) throws -> (recognise: @Sendable (ImportFile) -> ImportRecognition,
                                                          kindName: @Sendable (ImportKind) -> String, signature: String) {
        let providers = try UtilityProvider.fetchAll(db)
        let rules = try ImportLearning.enabledRules(db: db)
        let ownNIFs = try IssuerKey.knownParties(db: db)
        let catalog = try DocumentKindCatalog.load(db: db)
        let detector = self.detector ?? ImportDetector(providers: providers,
                                                            learnt: [ImportLearning.recogniser(rules: rules, ownNIFs: ownNIFs, catalog: catalog)])
        let names = ImportKindNames(catalog: catalog, pending: [])
        return ({ detector.detect($0) }, { names.displayName($0) }, try ImportWaitingList.signature(db: db))
    }
}
