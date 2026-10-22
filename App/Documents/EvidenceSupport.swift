// App/Documents/EvidenceSupport.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

/// How many documents each transaction has (`EvidenceLinks.linkCounts`), kept current by
/// observing the links table: every paperclip in the app reads it, whatever changed the
/// links (Documents, Edit transaction, a deleted transaction's trigger).
@MainActor
final class TransactionDocumentCounts: ObservableObject {
    static let shared = TransactionDocumentCounts()
    @Published private(set) var counts: [Int64: Int] = [:]
    private var task: Task<Void, Never>?

    func start(dbQueue: DatabaseQueue) {
        task?.cancel()
        let values = ValueObservation
            .tracking { db in try EvidenceLinks.linkCounts(db: db, .transaction) }
            .removeDuplicates()
            .values(in: dbQueue)
        task = Task { [weak self] in
            do {
                for try await counts in values {
                    self?.counts = counts
                }
            } catch {
                // The badges stay as last read.
            }
        }
    }

    func count(_ transactionId: Int64?) -> Int {
        transactionId.flatMap { counts[$0] } ?? 0
    }
}

/// A record's paperclip with its document count, visible only when it has documents. In a
/// grid row it takes its place even then, so the row keeps every cell and its columns line up
/// (spec C4); inline in a line of text (`keepsPlace: false`) it takes none.
struct DocumentCountBadge: View {
    let count: Int
    var keepsPlace = true

    var body: some View {
        let badge = HStack(spacing: 1) {
            Image(systemName: "paperclip")
            if count > 1 { Text("\(count)").monospacedDigit() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
        if count > 0 {
            badge
                .help(count == 1 ? "1 document" : "\(count) documents")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(count == 1 ? "1 document" : "\(count) documents")
        } else if keepsPlace {
            badge.hidden().accessibilityHidden(true)
        }
    }
}

/// The paperclip for one transaction, read from `TransactionDocumentCounts`.
struct TransactionDocumentBadge: View {
    let transactionId: Int64?
    @ObservedObject private var counts = TransactionDocumentCounts.shared

    var body: some View {
        DocumentCountBadge(count: counts.count(transactionId), keepsPlace: false)
    }
}

/// What files the library accepts from the open panel and drops.
enum EvidenceFiles {
    static let contentTypes: [UTType] = [.pdf, .image, .data]

    /// The regular files among `urls`, and the names of the folders (or anything else that
    /// isn't a file) left out.
    static func files(_ urls: [URL]) -> (files: [URL], skipped: [String]) {
        var files: [URL] = [], skipped: [String] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        return (files, skipped)
    }

    /// "Skipped “Lisboa” (a folder): …", or nil when nothing was skipped.
    static func skippedMessage(_ skipped: [String]) -> String? {
        guard !skipped.isEmpty else { return nil }
        let names = skipped.map { "“\($0)”" }.joined(separator: ", ")
        return "Skipped \(names) — only files are added. To have Mango look in a folder, add it in Settings ▸ Evidence."
    }

    /// Runs `body` with access to a file from the open panel (a no-op outside the sandbox).
    static func withAccess<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

/// Common link roles, offered in the role menu (free text is stored).
enum EvidenceRoles {
    static let presets = ["Notice", "Receipt", "Invoice", "Payment proof", "Statement", "Contract"]
}

/// A transaction as the evidence screens show it: with its account's name and currency.
struct EvidenceTransactionInfo: Identifiable, Equatable, Sendable {
    let transaction: Transaction
    let accountName: String
    let currency: Currency
    let categoryName: String?

    var id: Int64 { transaction.id ?? -1 }
}

/// Every transaction, account and category, prepared for the evidence pickers: searching
/// (`TransactionSearch`) and matching (`EvidenceMatcher`). Built off the main thread.
struct TransactionCatalog: Sendable {
    let transactionsById: [Int64: Transaction]
    let accountsById: [Int64: Account]
    let categoriesById: [Int64: Category]
    let searchIndex: TransactionSearch.Index
    let matcherIndex: EvidenceMatcher.Index

    static func load(_ dbQueue: DatabaseQueue) async throws -> TransactionCatalog {
        try await Task.detached(priority: .userInitiated) {
            let (transactions, accounts, categories, links, rate) = try dbQueue.read { db in
                (try Transaction.fetchAll(db), try Account.fetchAll(db), try Category.fetchAll(db), try TransferLink.fetchAll(db),
                 try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate)
            }
            return TransactionCatalog(
                transactionsById: Dictionary(transactions.compactMap { t in t.id.map { ($0, t) } }, uniquingKeysWith: { a, _ in a }),
                accountsById: Dictionary(accounts.compactMap { a in a.id.map { ($0, a) } }, uniquingKeysWith: { a, _ in a }),
                categoriesById: Dictionary(categories.compactMap { c in c.id.map { ($0, c) } }, uniquingKeysWith: { a, _ in a }),
                searchIndex: TransactionSearch.Index(TransactionSearch.Input(transactions: transactions, categories: categories,
                                                                             accounts: accounts, links: links, eurToGbpRate: rate)),
                matcherIndex: EvidenceMatcher.Index(transactions: transactions, accounts: accounts, categories: categories))
        }.value
    }

    func info(_ id: Int64) -> EvidenceTransactionInfo? {
        guard let transaction = transactionsById[id] else { return nil }
        let account = accountsById[transaction.accountId]
        return EvidenceTransactionInfo(transaction: transaction, accountName: account?.displayName ?? "",
                                       currency: account?.currency ?? .gbp,
                                       categoryName: transaction.categoryId.flatMap { categoriesById[$0]?.name })
    }

    /// Transactions matching `text` (descriptions, notes, categories, an amount), newest first.
    func search(_ text: String, limit: Int = 100) -> [EvidenceTransactionInfo] {
        let rows = TransactionSearch.rows(searchIndex, criteria: TransactionSearch.Criteria(text: text), now: AppClock.now)
        return rows.prefix(limit).compactMap { info($0.id) }
    }
}

/// One transaction in a picker or list: its description, then date · account · category (and
/// why it's suggested, on one line — all of it in the tooltip), the amount trailing.
struct EvidenceTransactionRow: View {
    let info: EvidenceTransactionInfo
    var reasons: [String] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.transaction.rawDescription).lineLimit(1)
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                if !reasons.isEmpty {
                    Text(reasons.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(([info.transaction.rawDescription, caption] + reasons).joined(separator: "\n"))
            Spacer(minLength: 8)
            MoneyText(minorUnits: info.transaction.amountMinorUnits, currency: info.currency)
                .fixedSize()
        }
    }

    private var caption: String {
        var parts = [info.transaction.date.formatted(date: .abbreviated, time: .omitted), info.accountName]
        if let category = info.categoryName { parts.append(category) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A picker row's Link: an icon button (the sheets' rows all link, so a word on each would
/// only repeat itself).
struct PickerLinkButton: View {
    /// What VoiceOver says: "Link to …".
    let accessibilityTitle: String
    var help = "Link"
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "link.badge.plus").imageScale(.large).foregroundStyle(theme.accent)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(accessibilityTitle)
    }
}

/// In place of a picker row's Link once it is linked (or will be on Save).
struct PickerLinkedMark: View {
    var title = "Linked"
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.income).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A library document in a picker: its type glyph and name, then kind · date · amount, and
/// why it's suggested (one line; all of it in the tooltip).
struct EvidenceDocumentPickRow: View {
    let summary: EvidenceDocumentSummary
    var reasons: [String] = []

    var body: some View {
        let caption = DocumentFormat.caption(kind: summary.kind, date: summary.docDate, amountMinorUnits: summary.amountMinorUnits,
                                             currency: summary.currency)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: DocumentFormat.icon(summary.textStatus))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayName).lineLimit(1).truncationMode(.middle)
                DocumentCaptionLine(kind: summary.kind, date: summary.docDate, amountMinorUnits: summary.amountMinorUnits,
                                    currency: summary.currency)
                    .font(.caption).foregroundStyle(.secondary)
                if !reasons.isEmpty {
                    Text(reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help(([summary.displayName, caption] + reasons).joined(separator: "\n"))
    }
}

/// `DocumentFormat.caption` on one line — "Mortgage notice · 31 Jan 2024 · €1,234.56" — where
/// the kind truncates and the day and amount never do.
struct DocumentCaptionLine: View {
    let kind: DocumentKind
    let date: Date?
    let amountMinorUnits: Int?
    let currency: Currency?

    var body: some View {
        let figures = [date.map(DocumentFormat.day),
                       amountMinorUnits.flatMap { amount in currency.map { Money.format(amount, currency: $0) } }].compactMap { $0 }
        HStack(spacing: 0) {
            Text(kind.displayName).lineLimit(1)
            if !figures.isEmpty {
                Text(" · " + figures.joined(separator: " · ")).figureText()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension DocumentKind {
    /// Every kind by name, "Other" last: for pickers.
    static var byDisplayName: [DocumentKind] {
        allCases.filter { $0 != .other }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } + [.other]
    }
}

/// Formats for document rows.
enum DocumentFormat {
    /// "12 Oct 2026", in UTC (stored days are UTC midnights).
    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!))
    }

    /// "Mortgage notice · 31 Jan 2024 · €1,234.56".
    static func caption(kind: DocumentKind, date: Date?, amountMinorUnits: Int?, currency: Currency?) -> String {
        var parts = [kind.displayName]
        if let date { parts.append(day(date)) }
        if let amount = amountMinorUnits, let currency { parts.append(Money.format(amount, currency: currency)) }
        return parts.joined(separator: " · ")
    }

    /// The glyph for a document by what Budget could read of it: text, an image, or nothing.
    static func icon(_ status: DocumentTextStatus) -> String {
        switch status {
        case .image: return "photo"
        case .noText: return "doc"
        default: return "doc.text"
        }
    }

    static func period(start: Date?, end: Date?) -> String? {
        switch (start, end) {
        case let (start?, end?): return "\(day(start)) – \(day(end))"
        case let (start?, nil): return "From \(day(start))"
        case let (nil, end?): return "To \(day(end))"
        default: return nil
        }
    }
}
