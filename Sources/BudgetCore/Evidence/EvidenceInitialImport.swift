import GRDB
import Foundation

/// The one-off initial evidence import (plan 2026-10-16 phase 1, Task 6): registers the user's
/// source folders, scans them, adds the evidence-relevant documents to the library — linking
/// each to its transaction when the match is confident, marking the rest "needs review" when
/// they're recent — seeds the property's missing-evidence rules, and reports what it did.
/// Only ever reads the source folders; everything else is left where it is.
public enum EvidenceInitialImport {
    /// The kinds the import brings in: evidence for the property's transactions and PT tax.
    public static let relevantKinds: Set<DocumentKind> = [
        .mortgageNotice, .mortgageReceipt, .mortgageInterestStatement, .insuranceReceipt, .insurancePolicy, .imiNotice, .imiPayment,
        .condominioReceipt, .repairInvoice, .accountantInvoice, .legalInvoice, .courtFee, .lettingAgentFee,
        .ptIRSDeclaration, .ptIRSAssessment, .ptIRSPaymentNote, .ptIRSPaymentProof, .utilityInvoice, .bankTransferProof
    ]

    /// The note on documents added without a link.
    public static let reviewNote = "Initial import: needs review"

    public struct Options: Sendable {
        /// Only transactions on or after this are linked.
        public var minimumTransactionDate: Date
        /// Unmatched relevant documents dated in this window are added for review.
        public var reviewWindow: DateInterval
        public var categoryGroupName: String
        public var mortgageAccountName: String
        /// Canonical file names by content hash (the move maps' new names).
        public var canonicalNames: [String: String]
        /// The tax years whose missing-evidence progress is reported.
        public var taxYears: [UKTaxYear]
        /// Paths inside a folder (`/`-separated prefixes) never imported: the extraction's
        /// working files.
        public var excludedPathPrefixes: [String]

        public init(minimumTransactionDate: Date, reviewWindow: DateInterval, categoryGroupName: String = "Lisbon",
                    mortgageAccountName: String = "BBVA mortgage", canonicalNames: [String: String] = [:], taxYears: [UKTaxYear] = [],
                    excludedPathPrefixes: [String] = ["_app-import/"]) {
            self.minimumTransactionDate = minimumTransactionDate
            self.reviewWindow = reviewWindow
            self.categoryGroupName = categoryGroupName
            self.mortgageAccountName = mortgageAccountName
            self.canonicalNames = canonicalNames
            self.taxYears = taxYears
            self.excludedPathPrefixes = excludedPathPrefixes
        }
    }

    // MARK: Deciding

    public enum LeaveReason: String, CaseIterable, Sendable {
        case excluded = "in an excluded folder"
        case notAnalysed = "not analysed"
        case notRelevant = "not evidence-relevant"
        case matchedBeforeMinimum = "matched a transaction before the minimum date"
        case outsideReviewWindow = "unmatched and dated outside the review window"
        case duplicate = "same content as another file"
    }

    public enum ReviewReason: String, Sendable {
        case noCandidate = "no candidate transaction"
        case ambiguous = "ambiguous (candidates tie)"
        case notConfident = "no confident match"
        case matchedBeforeMinimum = "confident match before the minimum date"
    }

    public enum Decision: Equatable, Sendable {
        case link(EvidenceMatcher.Suggestion)
        case review(ReviewReason)
        case leave(LeaveReason)

        var rank: Int {
            switch self {
            case .link: 0
            case .review: 1
            case .leave: 2
            }
        }
    }

    /// What to do with a scanned file not in the library: link it to its confident match (a
    /// transaction on or after the minimum date), add it for review (relevant, unmatched or
    /// ambiguous, dated in the review window), or leave it in the folder.
    public static func decide(_ file: SourceFolderScanner.ScannedFile, transactionDates: [Int64: Date], options: Options) -> Decision {
        if options.excludedPathPrefixes.contains(where: { file.relativePath.hasPrefix($0) }) { return .leave(.excluded) }
        guard let analysis = file.analysis else { return .leave(.notAnalysed) }
        guard relevantKinds.contains(analysis.metadata.kind) else { return .leave(.notRelevant) }
        let confident = EvidenceMatcher.confidentMatch(file.suggestions)
        if let confident, let date = transactionDates[confident.transactionId] {
            if date >= options.minimumTransactionDate { return .link(confident) }
        }
        let date = analysis.metadata.docDate ?? analysis.metadata.periodEnd ?? analysis.metadata.periodStart
        guard let date, date >= options.reviewWindow.start, date < options.reviewWindow.end else {
            return .leave(confident != nil ? .matchedBeforeMinimum : .outsideReviewWindow)
        }
        if confident != nil { return .review(.matchedBeforeMinimum) }
        guard let best = file.suggestions.first else { return .review(.noCandidate) }
        if file.suggestions.count > 1, file.suggestions[1].score >= best.score { return .review(.ambiguous) }
        return .review(.notConfident)
    }

    // MARK: Report

    public struct FolderReport: Equatable, Sendable {
        public var name: String
        public var path: String
        public var alreadyRegistered: Bool
        public var new = 0
        public var changed = 0
        public var inLibrary = 0
        public var missing = 0
        public var ignored = 0
        public var notDownloaded = 0
        public var unreadable = 0
        /// New or changed files of a relevant kind.
        public var relevant = 0
        public var linked = 0
        public var forReview = 0
    }

    public struct LinkEntry: Equatable, Sendable {
        public var documentId: Int64
        public var transactionId: Int64
        public var kind: DocumentKind
        public var categoryName: String
        public var path: String
    }

    public struct ReviewEntry: Equatable, Sendable {
        public var documentId: Int64
        public var path: String
        public var kind: DocumentKind
        public var date: Date?
        public var amountMinorUnits: Int?
        public var currency: Currency?
        public var reason: ReviewReason
        /// The best candidate, described ("2024-05-02 COBR. REC. … -500.00 (score 140)").
        public var topSuggestion: String?
    }

    public struct Report: Sendable {
        public var folders: [FolderReport] = []
        public var documentsAdded = 0
        /// Chosen files whose content was already in the library (added by an earlier run).
        public var documentsAlreadyInLibrary = 0
        public var links: [LinkEntry] = []
        public var review: [ReviewEntry] = []
        public var left: [LeaveReason: Int] = [:]
        public var rulesAdded: [String] = []
        public var warnings: [String] = []
        public var progressBefore: [UKTaxYear: MissingEvidence.Progress] = [:]
        public var progressAfter: [UKTaxYear: MissingEvidence.Progress] = [:]
        public var taxYears: [UKTaxYear] = []

        /// Links per "category · kind", most first.
        public var linksByCategoryAndKind: [(key: String, count: Int)] {
            Dictionary(grouping: links) { "\($0.categoryName) · \($0.kind.displayName)" }
                .map { (key: $0.key, count: $0.value.count) }
                .sorted { ($0.count, $1.key) > ($1.count, $0.key) }
        }

        /// Transactions given more than one document.
        public var transactionsWithSeveralDocuments: Int {
            Dictionary(grouping: links, by: \.transactionId).values.filter { $0.count > 1 }.count
        }

        public func text(reviewLimit: Int = .max) -> String {
            var lines: [String] = []
            lines.append("Folders:")
            for folder in folders {
                lines.append("  \(folder.name) (\(folder.path))\(folder.alreadyRegistered ? " [already registered]" : "")")
                lines.append("    new \(folder.new), changed \(folder.changed), in library \(folder.inLibrary), missing \(folder.missing), "
                             + "ignored \(folder.ignored), not downloaded \(folder.notDownloaded), unreadable \(folder.unreadable)")
                lines.append("    relevant \(folder.relevant) → linked \(folder.linked), for review \(folder.forReview)")
            }
            lines.append("Documents added: \(documentsAdded) (already in library: \(documentsAlreadyInLibrary))")
            lines.append("Links created: \(links.count) (transactions with several documents: \(transactionsWithSeveralDocuments))")
            for entry in linksByCategoryAndKind { lines.append("  \(entry.count)\t\(entry.key)") }
            lines.append("Left in folders:")
            for reason in LeaveReason.allCases { lines.append("  \(left[reason] ?? 0)\t\(reason.rawValue)") }
            lines.append("Rules added: \(rulesAdded.isEmpty ? "none" : rulesAdded.joined(separator: "; "))")
            for warning in warnings { lines.append("Warning: \(warning)") }
            lines.append("Missing evidence (done/total, before links → after):")
            for year in taxYears {
                let before = progressBefore[year] ?? MissingEvidence.Progress()
                let after = progressAfter[year] ?? MissingEvidence.Progress()
                lines.append("  \(year.label): \(before.done)/\(before.total) (\(before.percentDone)%) → \(after.done)/\(after.total) (\(after.percentDone)%)")
            }
            lines.append("Needs review: \(review.count)")
            let byReason = Dictionary(grouping: review, by: \.reason.rawValue).map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }
            for (reason, count) in byReason { lines.append("  \(count)\t\(reason)") }
            for entry in review.prefix(reviewLimit) {
                let amount = entry.amountMinorUnits.map { EvidenceInitialImport.format($0, entry.currency) } ?? "—"
                lines.append("  \(entry.path) | \(entry.kind.displayName) | \(entry.date.map(EvidenceInitialImport.day) ?? "—") | \(amount) | "
                             + "\(entry.reason.rawValue) | top: \(entry.topSuggestion ?? "—")")
            }
            if review.count > reviewLimit { lines.append("  … and \(review.count - reviewLimit) more") }
            return lines.joined(separator: "\n")
        }
    }

    static func day(_ date: Date) -> String {
        let components = EvidenceText.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func format(_ minorUnits: Int, _ currency: Currency?) -> String {
        let sign = minorUnits < 0 ? "-" : ""
        let value = abs(minorUnits)
        return "\(sign)\(value / 100).\(String(format: "%02d", value % 100))\(currency.map { " " + $0.rawValue.uppercased() } ?? "")"
    }

    // MARK: Move maps

    /// Canonical names by content hash from move-map CSVs (`new_path`, `sha256` columns): the
    /// new path's file name. Rows without either are skipped.
    public static func canonicalNames(fromMoveMap text: String) -> [String: String] {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)[...]
        guard let header = lines.popFirst() else { return [:] }
        let columns = CSVRowSplitter.split(line: header, delimiter: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let newPath = columns.firstIndex(of: "new_path"), let sha = columns.firstIndex(of: "sha256") else { return [:] }
        var names: [String: String] = [:]
        for line in lines {
            let fields = CSVRowSplitter.split(line: line, delimiter: ",")
            guard fields.count > max(newPath, sha) else { continue }
            let hash = fields[sha].trimmingCharacters(in: .whitespaces).lowercased()
            let name = (fields[newPath] as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
            guard hash.count == 64, !name.isEmpty else { continue }
            names[hash] = names[hash] ?? name
        }
        return names
    }

    // MARK: Running

    /// Runs the import against `library` (its database and store): registers `folderURLs`
    /// (those already registered are reused), scans them, adds and links as `decide` says,
    /// then — in one transaction — seeds the rules for the category group and mortgage
    /// account named in `options`, measures the tax years' progress, creates the links and
    /// measures again. `log` hears progress lines.
    public static func run(library: EvidenceLibrary, folderURLs: [URL], options: Options, now: Date = Date(),
                           log: ((String) -> Void)? = nil) throws -> Report {
        let scanner = SourceFolderScanner(library: library)
        var report = Report()
        report.taxYears = options.taxYears

        // 1. Folders.
        let registered = try scanner.sourceFolders()
        var folders: [(SourceFolder, Bool)] = []
        for url in folderURLs {
            let path = url.standardizedFileURL.path
            if let existing = registered.first(where: { $0.path == path }) {
                folders.append((existing, true))
            } else {
                folders.append((try scanner.register(url), false))
            }
        }

        // 2. Scans.
        var scans: [(SourceFolder, SourceFolderScanner.ScanResult, Bool)] = []
        for (folder, already) in folders {
            log?("Scanning \(folder.path)…")
            let result = try scanner.scan(folder, options: .init(analyzeNewFiles: true, suggestionLimit: 5), now: now)
            scans.append((result.folder, result, already))
        }

        let (transactions, categoryNames) = try library.database.read { db in
            (try Transaction.fetchAll(db), Dictionary(uniqueKeysWithValues: try Category.fetchAll(db).compactMap { c in c.id.map { ($0, c.name) } }))
        }
        let transactionsById = Dictionary(uniqueKeysWithValues: transactions.compactMap { t in t.id.map { ($0, t) } })
        let transactionDates = transactionsById.mapValues(\.date)

        // 3. Decisions, one file per content (the best decision wins).
        struct Candidate {
            var folderIndex: Int
            var file: SourceFolderScanner.ScannedFile
            var decision: Decision
        }
        var candidates: [Candidate] = []
        for (index, scan) in scans.enumerated() {
            let (folder, result, already) = scan
            var folderReport = FolderReport(name: folder.name, path: folder.path, alreadyRegistered: already)
            folderReport.new = result.new.count
            folderReport.changed = result.changed.count
            folderReport.inLibrary = result.inLibrary.count
            folderReport.missing = result.missing.count
            folderReport.ignored = result.ignored.count
            folderReport.notDownloaded = result.notDownloaded.count
            folderReport.unreadable = result.unreadable.count
            for file in result.new + result.changed where file.documentId == nil {
                let decision = decide(file, transactionDates: transactionDates, options: options)
                if decision != .leave(.excluded), let kind = file.analysis?.metadata.kind, relevantKinds.contains(kind) { folderReport.relevant += 1 }
                candidates.append(Candidate(folderIndex: index, file: file, decision: decision))
            }
            report.folders.append(folderReport)
        }
        var chosen: [Candidate] = []
        var bySha: [String: Int] = [:]
        for candidate in candidates {
            if let existing = bySha[candidate.file.sha256] {
                if candidate.decision.rank < chosen[existing].decision.rank {
                    report.left[.duplicate, default: 0] += 1
                    chosen[existing] = candidate
                } else {
                    report.left[.duplicate, default: 0] += 1
                }
            } else {
                bySha[candidate.file.sha256] = chosen.count
                chosen.append(candidate)
            }
        }

        // Adds (each its own write: a file copy and its row).
        var pendingLinks: [(documentId: Int64, suggestion: EvidenceMatcher.Suggestion, candidate: Candidate)] = []
        for candidate in chosen {
            let path = "\(scans[candidate.folderIndex].0.name)/\(candidate.file.relativePath)"
            switch candidate.decision {
            case .leave(let reason):
                report.left[reason, default: 0] += 1
            case .link(let suggestion):
                let added = try add(candidate.file, folder: scans[candidate.folderIndex].0, note: nil, scanner: scanner, options: options, now: now, report: &report)
                guard let documentId = added.id else { continue }
                pendingLinks.append((documentId, suggestion, candidate))
                report.folders[candidate.folderIndex].linked += 1
            case .review(let reason):
                let added = try add(candidate.file, folder: scans[candidate.folderIndex].0, note: reviewNote, scanner: scanner, options: options, now: now, report: &report)
                guard let documentId = added.id else { continue }
                report.folders[candidate.folderIndex].forReview += 1
                let top = candidate.file.suggestions.first.map { suggestion -> String in
                    guard let transaction = transactionsById[suggestion.transactionId] else { return "#\(suggestion.transactionId)" }
                    return "\(day(transaction.date)) \(transaction.rawDescription) \(format(transaction.amountMinorUnits, nil)) (score \(suggestion.score))"
                }
                report.review.append(ReviewEntry(documentId: documentId, path: path, kind: added.kind, date: added.docDate,
                                                 amountMinorUnits: added.amountMinorUnits, currency: added.currency, reason: reason,
                                                 topSuggestion: top))
            }
        }
        report.review.sort { ($0.date ?? .distantPast, $0.path) < ($1.date ?? .distantPast, $1.path) }

        // 4–5. Rules, progress and links: one transaction.
        try library.database.write { db in
            if let group = try CategoryGroup.filter(Column("name") == options.categoryGroupName).fetchOne(db), let groupId = group.id {
                let mortgage = try Account.filter(Column("name") == options.mortgageAccountName).fetchOne(db)?.id
                if mortgage == nil { report.warnings.append("No account named \(options.mortgageAccountName): no instalment rule.") }
                let added = try EvidenceRequirementDefaults.seedPropertyRules(db: db, categoryGroupId: groupId, mortgageAccountIds: mortgage.map { [$0] } ?? [])
                report.rulesAdded = added.map(\.name)
            } else {
                report.warnings.append("No category group named \(options.categoryGroupName): no rules seeded.")
            }
            for year in options.taxYears {
                report.progressBefore[year] = MissingEvidence.progress(try MissingEvidence.items(db: db, taxYear: year))
            }
            for pending in pendingLinks {
                try EvidenceLinks.link(db: db, documentId: pending.documentId, to: .transaction(pending.suggestion.transactionId))
                let transaction = transactionsById[pending.suggestion.transactionId]
                let kind = try EvidenceDocument.fetchOne(db, key: pending.documentId)?.kind ?? .other
                report.links.append(LinkEntry(documentId: pending.documentId, transactionId: pending.suggestion.transactionId, kind: kind,
                                              categoryName: transaction?.categoryId.flatMap { categoryNames[$0] } ?? "Uncategorized",
                                              path: "\(scans[pending.candidate.folderIndex].0.name)/\(pending.candidate.file.relativePath)"))
            }
            for year in options.taxYears {
                report.progressAfter[year] = MissingEvidence.progress(try MissingEvidence.items(db: db, taxYear: year))
            }
        }
        return report
    }

    private static func add(_ file: SourceFolderScanner.ScannedFile, folder: SourceFolder, note: String?, scanner: SourceFolderScanner,
                            options: Options, now: Date, report: inout Report) throws -> EvidenceDocument {
        let metadata = EvidenceMetadata(canonicalName: options.canonicalNames[file.sha256], note: note)
        let added = try scanner.addToLibrary(file, from: folder, metadata: metadata, now: now)
        if added.isNew { report.documentsAdded += 1 } else { report.documentsAlreadyInLibrary += 1 }
        return added.document
    }
}
