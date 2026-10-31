import Foundation

/// Where files picked in Files (or shared to Mango) wait to be imported on the iPhone. Each one is copied in first (the
/// security-scoped original is released at once and never touched again), then kept in an app-private
/// `DownloadsTray` of its own, so the Check & link engine reads it exactly as it reads an iPad download. Over
/// `maxFiles` at once, the first 20 are taken and the rest is counted ("20 of 27 added, import the rest next").
public struct ImportInbox: Sendable {
    /// The most files one batch takes.
    public static let maxFiles = 20

    public let tray: DownloadsTray
    private let staging: URL

    /// `directory`: the inbox's own folder (app-private; emptied by `releaseAll`).
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        tray = DownloadsTray(directory: directory.appendingPathComponent("Files", isDirectory: true), now: now)
        staging = directory.appendingPathComponent("Incoming", isDirectory: true)
    }

    /// One file offered, in the order it was offered: kept in the inbox, or turned away with a reason.
    public enum Entry: Equatable, Sendable {
        case file(TrayItem)
        case unsupported(name: String, reason: String)

        public var name: String {
            switch self {
            case .file(let item): item.fileName
            case .unsupported(let name, _): name
            }
        }
    }

    /// What `add` did.
    public struct Intake: Equatable, Sendable {
        public var entries: [Entry]
        /// How many files were offered, and how many of them were left for the next batch.
        public var offered: Int
        public var overflow: Int

        public var added: Int { offered - overflow }
        /// "20 of 27 added, import the rest next"; nil when everything was taken.
        public var overflowNote: String? {
            overflow > 0 ? ImportInboxCopy.overflow(added: added, offered: offered) : nil
        }
    }

    /// Takes `urls` (a picker's or the share sheet's), in order. A same file twice is one entry. A file Mango can't read
    /// (OFX, a Word file, an archive, an empty file) stays out of the inbox as an `.unsupported` entry and the rest go
    /// on.
    public func add(_ urls: [URL]) -> Intake {
        var entries: [Entry] = []
        var kept: Set<UUID> = []
        for url in urls.prefix(Self.maxFiles) {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if let reason = Self.unsupportedReason(ext) {
                entries.append(.unsupported(name: name, reason: reason))
                continue
            }
            do {
                let copy = try stage(url)
                defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
                let item = try tray.ingest(fileAt: copy, suggestedName: name, sourceHost: nil, accepting: DownloadsTray.importExtensions)
                if kept.insert(item.id).inserted { entries.append(.file(item)) }
            } catch {
                entries.append(.unsupported(name: name, reason: Self.reason(for: error)))
            }
        }
        return Intake(entries: entries, offered: urls.count, overflow: max(0, urls.count - Self.maxFiles))
    }

    /// Cancel: the batch's copies are gone (and nothing else in the inbox).
    public func release(_ items: [TrayItem]) {
        items.forEach(tray.discard)
    }

    /// Sign-out, leaving the household, demo data and the launch sweep: the whole inbox emptied.
    public func releaseAll() {
        tray.purgeAll()
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: Files

    static func unsupportedReason(_ ext: String) -> String? {
        if DownloadsTray.importExtensions.contains(ext) { return nil }
        if ext == "ofx" || ext == "qfx" { return ImportInboxCopy.ofx }
        return ImportInboxCopy.unsupported
    }

    private static func reason(for error: Error) -> String {
        switch error as? TrayError {
        case .empty?: ImportInboxCopy.empty
        case .tooLarge?: ImportInboxCopy.tooLarge
        case .notAPDF?: ImportInboxCopy.notAPDF
        default: ImportInboxCopy.unreadable
        }
    }

    /// The original copied under its own name into a folder of its own (the security-scoped access is released as soon
    /// as the copy is made).
    private func stage(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

/// The inbox's words.
public enum ImportInboxCopy {
    public static func overflow(added: Int, offered: Int) -> String { "\(added) of \(offered) added, import the rest next" }
    public static let ofx = "Mango can’t read OFX files yet. Use the bank’s PDF or CSV."
    public static let unsupported = "Mango reads PDF, CSV and photo files only."
    public static let empty = "This file is empty."
    public static let tooLarge = "This file is larger than 50 MB."
    public static let notAPDF = "This isn’t a PDF, although its name says so."
    public static let unreadable = "Mango couldn’t open this file."
}

extension ImportInboxCopy {
    public static let photoStatement = "A photo of a statement can’t be trusted for its numbers. Use the bank’s PDF or CSV."
}
