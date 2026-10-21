import Foundation

/// A source folder's scan handed to the importer (`ImportShortcut.sourceFolder`): its new and
/// changed files are planned (`ImportPipeline.plan(folder:scanner:inputs:)`) carrying the
/// folder's metadata, and on Confirm import each file's scan record gets the document it was
/// filed as (or duplicates) and its change is acknowledged — also for duplicates and left-out
/// files, which the user has seen (`ImportApplier`). Missing, ignored, not-downloaded and
/// unreadable files are reported by the scan as before; they are not imported.
public enum SourceFolderImport {
    /// A scanned file to import.
    public struct Input: Equatable, Sendable {
        public var url: URL
        public var folderId: Int64
        /// Its path inside the folder (what the scan records it by).
        public var relativePath: String
        public var modifiedAt: Date
        /// A changed file (a change not yet acknowledged), not a new one. Informational only (the
        /// review may show it): Confirm import acknowledges whatever change the file's scan record
        /// still holds for the content the review read.
        public var isChange: Bool

        public init(url: URL, folderId: Int64, relativePath: String, modifiedAt: Date, isChange: Bool) {
            self.url = url
            self.folderId = folderId
            self.relativePath = relativePath
            self.modifiedAt = modifiedAt
            self.isChange = isChange
        }
    }

    /// The scan's new and changed files, by path.
    public static func inputs(from result: SourceFolderScanner.ScanResult) -> [Input] {
        guard let folderId = result.folder.id else { return [] }
        func input(_ file: SourceFolderScanner.ScannedFile, isChange: Bool) -> Input {
            Input(url: file.url, folderId: folderId, relativePath: file.relativePath, modifiedAt: file.modifiedAt, isChange: isChange)
        }
        return (result.new.map { input($0, isChange: false) } + result.changed.map { input($0, isChange: true) })
            .sorted { $0.relativePath < $1.relativePath }
    }
}
