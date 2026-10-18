// App/Property/RechargeSheets.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BudgetCore
import GRDB

// MARK: - Statement

/// One month's statement (plan phase 5 Task 3): its invoice lines (the invoices since the
/// last statement) and manual lines, staged until Save; the email (template per language,
/// editable) opened as a draft in Mail with the invoices attached — the user sends it; and
/// Mark sent. Prepare email and Mark sent save the staged lines first.
@MainActor
final class RechargeStatementModel: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        var lineId: Int64?
        var invoiceId: Int64?
        var label: String
        var detail: String
        var note: String?
        var amountMinorUnits: Int
        var manualText: String
        var manualAmountText: String
        var isNew: Bool
        var removed = false
        /// The invoice's utility (nil for a manual line).
        var kind: UtilityKind? = nil
        /// The line's document, attached to the email.
        var documentId: Int64? = nil
        /// What the email preview reads: the invoice and its provider, and a prorated line's days.
        var invoice: UtilityInvoice? = nil
        var provider: UtilityProvider? = nil
        var daysInTenancy: Int? = nil
        var daysInPeriod: Int? = nil
        var isManual: Bool { invoiceId == nil }
        var currentAmount: Int? { isManual ? Money.parseMinorUnits(manualAmountText) : amountMinorUnits }
    }

    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary
    let propertyId: Int64
    let tenancy: Tenancy
    let currency: Currency
    let month: Date
    @Published private(set) var statement: RechargeStatement?
    @Published var lines: [Line] = []
    @Published var language: RechargeEmailLanguage = .portuguese { didSet { if language != oldValue { loadTemplate() } } }
    @Published var subject = ""
    @Published var bodyText = ""
    @Published var sentDate = PropertyDays.utcToday(AppClock.now)
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// The lines' documents' file names (as attached), by id.
    @Published private(set) var documentNames: [Int64: String] = [:]
    /// What a sent (or paid) statement still needs, and what credits paid of it.
    @Published private(set) var owedMinorUnits: Int?
    @Published private(set) var receivedMinorUnits = 0
    /// The property's name, for the email preview.
    @Published private(set) var propertyName = ""
    /// The last prepared message's attachment copies (removed at the next one).
    private static var attachmentFolder: URL?

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, propertyId: Int64, tenancy: Tenancy, currency: Currency,
         target: RechargeStatementTarget) {
        self.dbQueue = dbQueue
        self.library = library
        self.propertyId = propertyId
        self.tenancy = tenancy
        self.currency = currency
        self.month = target.month
        load(statementId: target.statementId)
        loadTemplate()
    }

    var isEditable: Bool { statement.map { $0.status == .draft } ?? true }
    var total: Int { lines.filter { !$0.removed }.reduce(0) { $0 + ($1.currentAmount ?? 0) } }
    var isValid: Bool { lines.filter { !$0.removed && $0.isManual }.allSatisfy { !$0.manualText.trimmingCharacters(in: .whitespaces).isEmpty && $0.currentAmount != nil } }
    var hasLines: Bool { lines.contains { !$0.removed } }
    /// A sent date before the statement's month is probably a slip.
    var sentDateWarning: String? {
        sentDate < month ? "The sent date is before \(RechargeEmail.monthName(month, language: .english))." : nil
    }
    /// Recipients as they'll be addressed.
    var recipients: [String] { Tenancies.emailAddresses(tenancy) }
    var title: String { "Utilities · \(RechargeEmail.monthName(month, language: .english))" }
    /// Included invoice lines without their PDF: the email says the invoices are attached.
    var linesWithoutDocument: Int { lines.filter { !$0.removed && !$0.isManual && $0.documentId == nil }.count }

    /// The email as it would be prepared now — the included lines as they stand, the subject
    /// and text with their placeholders filled (`RechargeEmail.draft`).
    var preview: RechargeEmail.Draft {
        let details = lines.filter { !$0.removed }.map { line -> Recharges.LineDetail in
            var record = RechargeLine(id: line.lineId, statementId: statement?.id ?? 0, invoiceId: line.invoiceId,
                                      lineDescription: line.isManual ? line.manualText : nil, amountMinorUnits: line.currentAmount ?? 0,
                                      note: line.note, documentId: line.isManual ? line.documentId : nil)
            record.daysInTenancy = line.daysInTenancy
            record.daysInPeriod = line.daysInPeriod
            return Recharges.LineDetail(line: record, invoice: line.invoice, provider: line.provider)
        }
        return RechargeEmail.draft(details: details, totalMinorUnits: total, month: month, tenancy: tenancy, propertyName: propertyName,
                                   currency: currency, language: language,
                                   template: RechargeEmailTemplate(propertyId: propertyId, language: language, subject: subject, body: bodyText))
    }

    /// What the email attaches: the included lines' documents, each once, in line order.
    var attachments: [(id: Int64, name: String)] {
        var seen: Set<Int64> = []
        return lines.filter { !$0.removed }.compactMap(\.documentId).filter { seen.insert($0).inserted }
            .map { ($0, documentNames[$0] ?? "Document") }
    }

    private func load(statementId: Int64?) {
        do {
            let (statement, details, pending, documents, owed, propertyName) = try dbQueue.read { [tenancy, month, propertyId] db in
                let statement = try statementId.flatMap { try RechargeStatement.fetchOne(db, key: $0) }
                let details = try statement.map { try Recharges.lineDetails(db: db, statementId: $0.id!) } ?? []
                var pending: [(Recharges.PendingLine, UtilityProvider?)] = []
                if statement?.status ?? .draft == .draft {
                    let lastDay = MonthRange.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: month)!
                    pending = try Recharges.pendingLines(db: db, tenancyId: tenancy.id!, through: lastDay).map {
                        ($0, try UtilityProvider.fetchOne(db, key: $0.invoice.providerId))
                    }
                }
                let ids = details.compactMap(\.documentId) + pending.compactMap { $0.0.invoice.documentId }
                let documents = try EvidenceDocument.filter(keys: ids).fetchAll(db)
                let owed = try statement.flatMap { $0.status == .draft ? nil : try Recharges.outstanding(db: db, statementId: $0.id!) }
                return (statement, details, pending, documents, owed, try Property.fetchOne(db, key: propertyId)?.name ?? "")
            }
            self.statement = statement
            self.propertyName = propertyName
            if let sentAt = statement?.sentAt { sentDate = sentAt }
            documentNames = Dictionary(documents.compactMap { document in
                document.id.map { ($0, (document.canonicalName ?? document.originalFileName).replacingOccurrences(of: "/", with: "-")) }
            }, uniquingKeysWith: { first, _ in first })
            owedMinorUnits = owed
            receivedMinorUnits = statement.map { $0.totalMinorUnits - (owed ?? $0.totalMinorUnits) } ?? 0
            lines = details.map { detail in
                Line(lineId: detail.line.id, invoiceId: detail.line.invoiceId, label: label(detail.invoice, detail.provider, manual: detail.line.lineDescription),
                     detail: detail.invoice.map(invoiceDetail) ?? "", note: detail.line.note, amountMinorUnits: detail.line.amountMinorUnits,
                     manualText: detail.line.lineDescription ?? "", manualAmountText: Money.formatInput(detail.line.amountMinorUnits), isNew: false,
                     kind: detail.provider?.kind, documentId: detail.documentId, invoice: detail.invoice, provider: detail.provider,
                     daysInTenancy: detail.line.daysInTenancy, daysInPeriod: detail.line.daysInPeriod)
            } + pending.map { pending, provider in
                // On an existing draft, invoices that arrived since are offered unticked.
                Line(lineId: nil, invoiceId: pending.invoice.id, label: label(pending.invoice, provider, manual: nil),
                     detail: invoiceDetail(pending.invoice), note: pending.note, amountMinorUnits: pending.amountMinorUnits,
                     manualText: "", manualAmountText: "", isNew: true, removed: statement != nil,
                     kind: provider?.kind, documentId: pending.invoice.documentId, invoice: pending.invoice, provider: provider,
                     daysInTenancy: pending.daysInTenancy, daysInPeriod: pending.daysInPeriod)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The provider and the invoice number (its utility shows as the line's icon and caption).
    private func label(_ invoice: UtilityInvoice?, _ provider: UtilityProvider?, manual: String?) -> String {
        guard let invoice else { return manual ?? "" }
        return [provider?.name, invoice.invoiceNumber].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Issued 18 Aug 2026 · 15 Jul – 14 Aug 2026".
    private func invoiceDetail(_ invoice: UtilityInvoice) -> String {
        var text = "Issued \(DocumentFormat.day(invoice.issueDate))"
        if let start = invoice.periodStart, let end = invoice.periodEnd { text += " · \(RechargeFormat.period(start, end))" }
        return text
    }

    func loadTemplate() {
        let template = (try? dbQueue.read { [propertyId, language] db in
            try RechargeEmail.template(db: db, propertyId: propertyId, language: language)
        }) ?? RechargeEmail.defaultTemplate(propertyId: propertyId, language: language)
        subject = template.subject
        bodyText = template.body
    }

    func addManualLine() {
        lines.append(Line(lineId: nil, invoiceId: nil, label: "", detail: "", note: nil, amountMinorUnits: 0, manualText: "",
                          manualAmountText: "", isNew: true))
    }

    /// Applies the staged lines: the statement (created empty), the ticked new invoice lines
    /// added at the amounts shown, lines left out removed, manual lines added or changed.
    /// Returns its id.
    @discardableResult
    func apply() throws -> Int64 {
        if let statement, statement.status != .draft { return statement.id! }
        let lines = lines
        let id = try dbQueue.write { [tenancy, month] db -> Int64 in
            let statement = try Recharges.draftStatement(db: db, tenancyId: tenancy.id!, month: month, addPending: false)
            let id = statement.id!
            for line in lines {
                if line.isManual {
                    if line.removed {
                        if let lineId = line.lineId { try Recharges.removeLine(db: db, lineId: lineId) }
                    } else if let amount = line.currentAmount {
                        try Recharges.saveManualLine(db: db, statementId: id, lineId: line.lineId, description: line.manualText, amountMinorUnits: amount)
                    }
                } else if let invoiceId = line.invoiceId {
                    if line.removed {
                        if line.lineId != nil { try Recharges.removeLine(db: db, statementId: id, invoiceId: invoiceId) }
                    } else if line.lineId == nil {
                        try Recharges.setLine(db: db, statementId: id, invoiceId: invoiceId, amountMinorUnits: line.amountMinorUnits, note: line.note)
                    }
                }
            }
            return id
        }
        load(statementId: id)
        return id
    }

    func save() -> Bool {
        do {
            try apply()
            return true
        } catch {
            errorMessage = RechargeMessages.text(for: error)
            return false
        }
    }

    func saveTemplate() {
        do {
            try dbQueue.write { [propertyId, language, subject, bodyText] db in
                var template = try RechargeEmail.template(db: db, propertyId: propertyId, language: language)
                template.subject = subject
                template.body = bodyText
                try RechargeEmail.saveTemplate(db: db, &template)
            }
            infoMessage = "Saved as the \(language.displayName) template."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetTemplate() {
        try? dbQueue.write { [propertyId, language] db in try RechargeEmail.resetTemplate(db: db, propertyId: propertyId, language: language) }
        loadTemplate()
    }

    /// Saves the lines, then opens a new message in Mail (recipients, subject, body, the
    /// invoices attached under their own names). Nothing is sent: the user reviews and sends.
    func prepareEmail() {
        do {
            let id = try apply()
            let template = RechargeEmailTemplate(propertyId: propertyId, language: language, subject: subject, body: bodyText)
            let (draft, documents) = try dbQueue.read { [language] db in
                let draft = try RechargeEmail.draft(db: db, statementId: id, language: language, template: template)
                return (draft, try EvidenceDocument.filter(keys: draft.attachmentDocumentIds).fetchAll(db))
            }
            // The previous draft's copies go (Mail has them by now).
            if let previous = Self.attachmentFolder { try? FileManager.default.removeItem(at: previous) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Recharges-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.attachmentFolder = folder
            var attachments: [URL] = []
            for documentId in draft.attachmentDocumentIds {
                guard let document = documents.first(where: { $0.id == documentId }) else { continue }
                let name = (document.canonicalName ?? document.originalFileName).replacingOccurrences(of: "/", with: "-")
                var base = (name as NSString).deletingPathExtension
                var ext = (name as NSString).pathExtension
                if ext.isEmpty { ext = (document.storedRelativePath as NSString).pathExtension }
                if base.isEmpty { base = "Invoice" }
                // Two documents with the same name: "name (2).pdf".
                var target = folder.appendingPathComponent(base).appendingPathExtension(ext)
                var copy = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent("\(base) (\(copy))").appendingPathExtension(ext)
                    copy += 1
                }
                try FileManager.default.copyItem(at: library.fileURL(for: document), to: target)
                attachments.append(target)
            }
            let items: [Any] = [draft.body as NSString] + attachments.map { $0 as NSURL }
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) else {
                errorMessage = "No email app is set up to compose a message: set one in Mail ▸ Settings."
                return
            }
            service.recipients = draft.recipients
            service.subject = draft.subject
            service.perform(withItems: items)
            infoMessage = draft.recipients.isEmpty
                ? "Message prepared with no recipient: add the tenant's email to the tenancy."
                : "Message prepared for \(draft.recipients.joined(separator: ", ")). Check and send it from your email app, then Mark sent."
        } catch {
            errorMessage = RechargeMessages.text(for: error)
        }
    }

    func markSent() -> Bool {
        do {
            let id = try apply()
            try dbQueue.write { [sentDate] db in _ = try Recharges.markSent(db: db, statementId: id, at: sentDate) }
            return true
        } catch {
            errorMessage = RechargeMessages.text(for: error)
            return false
        }
    }
}


/// How the recharge screens show utilities and periods.
enum RechargeFormat {
    /// The utility's glyph (a one-off line's when `nil`).
    static func icon(_ kind: UtilityKind?) -> String {
        switch kind {
        case .electricity: return "bolt.fill"
        case .gas: return "flame.fill"
        case .water: return "drop.fill"
        case .other: return "square.grid.2x2.fill"
        case nil: return "plus.forwardslash.minus"
        }
    }

    /// A sent statement still owed this many days after it was sent shows as overdue: the
    /// window in which `Recharges.matchPayments` looks for a credit that pays it on its own (a
    /// credit paying it with later statements in a run can still come after it).
    static let overdueAfterDays = Recharges.paymentWindowDays

    static func isOverdue(_ statement: RechargeStatement, today: Date) -> Bool {
        guard statement.status == .sent, let sent = statement.sentAt else { return false }
        return MonthRange.calendar.date(byAdding: .day, value: overdueAfterDays, to: MonthRange.calendar.startOfDay(for: sent))! < today
    }

    /// Whether credits have paid some of a sent statement: the one "part paid" test of the
    /// statements table and the statement sheet.
    static func isPartPaid(receivedMinorUnits: Int) -> Bool { receivedMinorUnits != 0 }

    /// A statement's state as a pill: Draft; Sent (Overdue past the matching window, Part paid
    /// once a credit pays some of it); Paid.
    static func statusPill(_ statement: RechargeStatement, receivedMinorUnits: Int, today: Date) -> StatusPill {
        switch statement.status {
        case .draft:
            return StatusPill("Draft")
        case .paid:
            return StatusPill("Paid", tone: .positive, systemImage: "checkmark")
        case .sent:
            if isPartPaid(receivedMinorUnits: receivedMinorUnits) { return StatusPill("Part paid", tone: .warning) }
            if isOverdue(statement, today: today) {
                return StatusPill("Overdue", tone: .warning, systemImage: "exclamationmark.triangle.fill",
                                  help: "Sent more than \(overdueAfterDays) days ago and not paid yet")
            }
            return StatusPill("Sent", tone: .accent)
        }
    }

    /// "15 Jul – 14 Aug 2026"; both years when they differ ("15 Dec 2025 – 14 Jan 2026").
    static func period(_ start: Date, _ end: Date) -> String {
        guard MonthRange.components(of: start).year == MonthRange.components(of: end).year else {
            return "\(DocumentFormat.day(start)) – \(DocumentFormat.day(end))"
        }
        let dayMonth = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).day().month(.abbreviated)
        return "\(start.formatted(dayMonth)) – \(DocumentFormat.day(end))"
    }
}

/// A utility's glyph in a fixed width, so the text after it lines up.
struct UtilityKindIcon: View {
    let kind: UtilityKind?

    var body: some View {
        Image(systemName: RechargeFormat.icon(kind))
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .help(kind?.displayName ?? "One-off line")
            .accessibilityHidden(true)
    }
}

/// Small capsules (recipients, attachments) in rows that wrap.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let height = rows.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map { row in row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                           proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }
}

/// A capsule with a glyph and a name (a recipient, an attachment).
struct NameChip: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .help(title)
    }
}

/// The statement sheet (UI polish §4.2): on the left, the month's figures, its lines as a
/// table (tick to include; one-off lines edited in place) with the total, and how it's sent
/// (Prepare email…, then Mark sent with the day); on the right, the email — recipients, and the
/// subject and text as the tenant will get them (placeholders filled from the lines included),
/// or behind Edit template… the template with its placeholders and actions — and the files
/// attached, with any invoice line missing its PDF as a to-do.
struct RechargeStatementSheet: View {
    @StateObject var model: RechargeStatementModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    /// The email's template text instead of its preview.
    @State private var editingTemplate = false

    var body: some View {
        SheetScaffold(title: model.title,
                      subtitle: model.isEditable
                          ? "The invoices issued (or debited) since the last statement, prorated to the tenancy's days where needed. Leave lines out or add one-off lines; nothing is saved until Save, Prepare email or Mark sent."
                          : "Sent \(model.statement?.sentAt.map(DocumentFormat.day) ?? ""): its lines are fixed.",
                      error: model.errorMessage, width: SheetMetrics.workspaceWidth, cancelTitle: model.isEditable ? "Cancel" : "Close", onCancel: { dismiss() },
                      primary: model.isEditable ? SheetAction("Save", isEnabled: model.isValid) { if model.save() { dismiss() } } : nil) {
            VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
                SplitRow(ratio: 0.5, stackBelow: 0) {
                    VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
                        linesPanel
                        sendPanel
                    }
                    emailPanel
                }
                if let info = model.infoMessage {
                    InlineBanner(.info, info) { model.infoMessage = nil }
                }
            }
        }
    }

    // MARK: Lines

    /// A line of the table: the id of its line in `model.lines` (the total: none). Cells find
    /// their line by id, never by position, so a load or an edit that replaces the lines can't
    /// leave a cell (a focused field) pointing past the end.
    private struct LineRow: Identifiable {
        let id: String
        let lineId: UUID?
    }

    private var lineRows: [LineRow] {
        model.lines.map { LineRow(id: $0.id.uuidString, lineId: $0.id) }
    }

    /// A field of the line `id` as a binding, by id: the line as it is now (`fallback` once it's
    /// gone), and a write to a line that's gone does nothing.
    private func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<RechargeStatementModel.Line, Value>,
                                fallback: Value) -> Binding<Value> {
        Binding(get: { model.lines.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
                set: { value in
                    guard let index = model.lines.firstIndex(where: { $0.id == id }) else { return }
                    model.lines[index][keyPath: keyPath] = value
                })
    }

    private var linesPanel: some View {
        Panel("Lines") {
            if model.isEditable {
                Button("Add line") { model.addManualLine() }
                    .controlSize(.small)
                    .help("A one-off charge, or a refund (negative)")
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FigureStrip(figures)
                if model.lines.isEmpty {
                    Text(model.isEditable
                         ? "No invoices since the last statement. Record them with Utility invoices…, or add a one-off line."
                         : "This statement has no lines.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Always in a scroll view (its height the lines', at most 230 pt), so the
                    // table keeps its identity — and a focused field — as lines come and go.
                    ScrollView { DataTable(columns: lineColumns, rows: lineRows, total: LineRow(id: "total", lineId: nil), zebra: false) }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: 230)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var figures: [FigureTile] {
        let included = model.lines.filter { !$0.removed }
        let invoices = included.filter { !$0.isManual }.count, oneOff = included.count - invoices
        let leftOut = model.lines.count - included.count
        var parts = ["\(invoices) invoice\(invoices == 1 ? "" : "s")"]
        if oneOff > 0 { parts.append("\(oneOff) one-off") }
        if leftOut > 0 { parts.append("\(leftOut) left out") }
        var tiles = [
            FigureTile(title: "Total", value: .money(model.total, model.currency, .neutral),
                       caption: model.total < 0 ? "Owed back to the tenant" : nil),
            FigureTile(title: "Lines", value: .text("\(included.count)"), caption: parts.joined(separator: " · "))
        ]
        if let statement = model.statement, statement.status != .draft {
            let today = PropertyDays.utcToday(AppClock.now)
            tiles.append(FigureTile(title: "Sent", value: .text(statement.sentAt.map(DocumentFormat.day) ?? "—"),
                                    pill: RechargeFormat.statusPill(statement, receivedMinorUnits: model.receivedMinorUnits, today: today)))
            if statement.status == .sent, let owed = model.owedMinorUnits {
                tiles.append(FigureTile(title: "Still owed", value: .money(owed, model.currency, .neutral),
                                        caption: model.receivedMinorUnits != 0 ? "\(Money.format(model.receivedMinorUnits, currency: model.currency)) received" : nil))
            } else if model.receivedMinorUnits != 0 {
                tiles.append(FigureTile(title: "Received", value: .money(model.receivedMinorUnits, model.currency, .signed)))
            }
        } else {
            tiles.append(FigureTile(title: "Status", value: .text(model.statement == nil ? "New" : "Draft"), caption: "Not sent yet"))
        }
        return tiles
    }

    private var lineColumns: [DataTableColumn<LineRow>] {
        var columns: [DataTableColumn<LineRow>] = []
        if model.isEditable {
            columns.append(DataTableColumn("", alignment: .center, width: .fixed(30)) { row, kind in
                if kind == .row, let id = row.lineId, let line = model.lines.first(where: { $0.id == id }) {
                    let removed = binding(id, \.removed, fallback: true)
                    Toggle("Include", isOn: Binding(get: { !removed.wrappedValue }, set: { removed.wrappedValue = !$0 }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .help(line.removed ? "Left out: tick to include" : "Included: untick to leave it out")
                        .accessibilityLabel("Include \(line.isManual ? line.manualText : line.label)")
                }
            })
        }
        columns.append(DataTableColumn("Line", width: .fill(min: 180)) { row, kind in
            if kind == .total {
                Text("Total").fontWeight(.semibold)
            } else if let id = row.lineId, let line = model.lines.first(where: { $0.id == id }) {
                lineCell(line)
            }
        })
        columns.append(DataTableColumn("Amount", alignment: .trailing, width: .min(96)) { row, kind in
            if kind == .total {
                MoneyText(minorUnits: model.total, currency: model.currency, font: .body.monospacedDigit().weight(.semibold), role: .neutral)
            } else if let id = row.lineId, let line = model.lines.first(where: { $0.id == id }) {
                amountCell(line)
            }
        })
        return columns
    }

    @ViewBuilder
    private func lineCell(_ line: RechargeStatementModel.Line) -> some View {
        if line.isManual && model.isEditable {
            HStack(spacing: 6) {
                UtilityKindIcon(kind: nil)
                TextField("Description", text: binding(line.id, \.manualText, fallback: ""), prompt: Text("One-off charge or refund"))
                    .accessibilityLabel("Description of the one-off line")
            }
            .opacity(line.removed ? 0.45 : 1)
        } else {
            HStack(spacing: 6) {
                UtilityKindIcon(kind: line.isManual ? nil : line.kind)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(line.isManual ? line.manualText : line.label).lineLimit(1)
                        if line.isNew && model.statement != nil {
                            StatusPill("New", tone: .accent, help: "Arrived since the draft was saved: tick it to include it")
                        }
                        if !line.isManual && line.documentId == nil && !line.removed {
                            StatusPill("No PDF", tone: .warning, help: "The invoice's document isn't in the library: it won't be attached to the email")
                        }
                    }
                    let caption = (line.isManual ? ["One-off line"] : [line.kind?.displayName, line.detail.isEmpty ? nil : line.detail].compactMap { $0 })
                        + [line.note].compactMap { $0 }
                    Text(caption.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(caption.joined(separator: " · "))
                }
            }
            .opacity(line.removed ? 0.45 : 1)
        }
    }

    @ViewBuilder
    private func amountCell(_ line: RechargeStatementModel.Line) -> some View {
        if line.isManual && model.isEditable {
            MoneyField("Amount", text: binding(line.id, \.manualAmountText, fallback: ""), currency: model.currency, width: 80)
                .opacity(line.removed ? 0.45 : 1)
        } else {
            // As on the statement: neutral.
            MoneyText(minorUnits: line.currentAmount ?? 0, currency: model.currency, role: .neutral)
                .opacity(line.removed ? 0.45 : 1)
        }
    }

    // MARK: Sending

    private var sendPanel: some View {
        Panel("Send", subtitle: model.isEditable
              ? "Prepare the email, check and send it from Mail, then mark the statement sent: its lines are then fixed and the next tenant credit can pay it."
              : "The email can be prepared again, with the same lines and invoices.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Prepare email…") { model.prepareEmail() }
                        .disabled(!model.isValid || !model.hasLines)
                        .help("Saves the statement and opens a new message in Mail with the invoices attached; you send it")
                    Spacer(minLength: 8)
                    if model.isEditable {
                        DatePicker("Sent on", selection: utcDay($model.sentDate), displayedComponents: .date)
                            .fixedSize()
                        Button("Mark sent") { if model.markSent() { dismiss() } }
                            .disabled(!model.isValid || !model.hasLines)
                            .help("Saves the statement and fixes its lines; the next tenant credit can then pay it")
                    }
                }
                if model.isEditable, let warning = model.sentDateWarning {
                    Text(warning).font(.callout).foregroundStyle(theme.expense)
                }
            }
        }
    }

    // MARK: Email

    private var emailPanel: some View {
        Panel("Email", subtitle: editingTemplate ? "The template: placeholders are filled in when the message is prepared"
                                                 : "As the tenant will get it, opened in Mail for you to check and send", fillsHeight: true) {
            Picker("Language", selection: $model.language) {
                ForEach(RechargeEmailLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Language")
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if editingTemplate {
                    templateEditor
                } else {
                    emailPreview
                }
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Attached").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        if model.attachments.isEmpty {
                            Text("No documents on the included lines.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            ChipFlow {
                                ForEach(model.attachments, id: \.id) { NameChip(systemImage: "paperclip", title: $0.name) }
                            }
                        }
                        // The email says the invoices are attached: a line without its PDF is a to-do.
                        let missing = model.linesWithoutDocument
                        if missing > 0 {
                            Label("\(missing) invoice line\(missing == 1 ? "" : "s") without \(missing == 1 ? "its" : "their") PDF",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(theme.pending)
                                .help("Add the invoice's document (Utility invoices…) so it's attached to the email")
                        }
                    }
                }
            }
        }
    }

    /// The recipients, then the subject and text with the placeholders filled from the lines
    /// included now; Edit template… opens the text behind it.
    private var emailPreview: some View {
        let draft = model.preview
        return VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                recipientsRow
                GridRow {
                    Text("Subject").foregroundStyle(.secondary)
                    Text(draft.subject).fontWeight(.medium).lineLimit(2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ScrollView {
                Text(draft.body)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 170, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .accessibilityLabel("Email text as it will be sent")
            HStack(spacing: 8) {
                Text("Filled in from the lines included now.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Edit template…") { withAnimation(.snappy) { editingTemplate = true } }
                    .controlSize(.small)
                    .help("Change the text and its placeholders for this property's statements")
            }
        }
    }

    /// The template: subject and text with their placeholders, Reset and Save as template, and
    /// Preview to go back.
    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                recipientsRow
                GridRow {
                    Text("Subject").foregroundStyle(.secondary)
                    TextField("Subject", text: $model.subject).labelsHidden()
                }
            }
            TextEditor(text: $model.bodyText)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 170, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Email text")
            Text("{tenant} {month} {property} {utilities} {table} {total_label} {total}")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("Placeholders, filled in when the message is prepared")
            HStack(spacing: 8) {
                Button("Reset") { model.resetTemplate() }
                    .buttonStyle(.borderless)
                    .help("Back to the default text for the language")
                Button("Save as template") { model.saveTemplate() }
                    .controlSize(.small)
                    .help("Keep this text for the property's statements in this language")
                Spacer(minLength: 8)
                Button("Preview") { withAnimation(.snappy) { editingTemplate = false } }
                    .controlSize(.small)
                    .help("The email as the tenant will get it")
            }
        }
    }

    @ViewBuilder
    private var recipientsRow: some View {
        GridRow {
            Text("To").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            if model.recipients.isEmpty {
                StatusPill("No email on the tenancy", tone: .warning, systemImage: "exclamationmark.triangle.fill",
                           help: "Add the tenant's email to the tenancy (Tenancies ▸ Edit)")
            } else {
                ChipFlow { ForEach(model.recipients, id: \.self) { NameChip(systemImage: "person.fill", title: $0) } }
            }
        }
    }
}

// MARK: - Providers

/// The property's utility providers and how their invoices are read (stored as data), with
/// "Test against a document…" to check the rules on a real invoice before saving.
struct UtilityProvidersSheet: View {
    let dbQueue: DatabaseQueue
    let propertyId: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [UtilityProvider] = []
    @State private var editing: UtilityProvider?
    @State private var deleting: UtilityProvider?
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: "Utility providers", subtitle: "Each provider's bank description and how its invoices are read.",
                      error: error, width: SheetMetrics.listWidth, cancelTitle: "Done", onCancel: { dismiss() }) {
            VStack(alignment: .leading, spacing: 10) {
                if providers.isEmpty {
                    SheetEmptyState(systemImage: "bolt.horizontal", title: "No providers yet",
                                    message: "Add one from a preset (its reading rules filled in) or blank.", minHeight: 130)
                } else {
                    DataTable(columns: [
                        DataTableColumn("Provider", width: .fill(min: 160), accessibilityValue: { $0.name }) { provider, _ in
                            HStack(spacing: 6) {
                                UtilityKindIcon(kind: provider.kind)
                                Text(provider.name).lineLimit(1)
                            }
                        },
                        .text("Kind", width: .fit) { $0.kind.displayName },
                        .text("Account", width: .fit) { $0.accountReference.flatMap { $0.isEmpty ? nil : $0 } ?? "—" },
                        DataTableColumn("Bank description", accessibilityValue: { $0.bankDescriptionPattern }) { provider, _ in
                            Text(provider.bankDescriptionPattern.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        },
                        .actions { provider in
                            [DataTableAction("Edit \(provider.name)…", systemImage: "pencil", inline: true) { editing = provider },
                             // In the ••• menu, confirmed: it takes the provider's invoices with it.
                             DataTableAction("Delete \(provider.name)…", systemImage: "trash", role: .destructive) { deleting = provider }]
                        }
                    ], rows: providers, zebra: false)
                }
                Menu("Add provider") {
                    ForEach(UtilityInvoiceRules.presets) { preset in
                        Button("\(preset.name) (\(preset.kind.displayName.lowercased()))") {
                            editing = UtilityProvider(propertyId: propertyId, name: preset.name, kind: preset.kind,
                                                      bankDescriptionPattern: preset.bankDescriptionPattern, invoiceRules: preset.rules)
                        }
                    }
                    Divider()
                    Button("Blank") { editing = UtilityProvider(propertyId: propertyId, name: "", kind: .other, invoiceRules: .generic) }
                }
                .fixedSize()
                .help("A preset fills in how its invoices are read; Blank starts from the generic rules")
            }
        }
        .onAppear(perform: load)
        .sheet(item: $editing, onDismiss: load) { provider in
            UtilityProviderFormSheet(dbQueue: dbQueue, provider: provider)
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { provider in
            Button("Delete provider and its invoices", role: .destructive) { delete(provider) }
        } message: { _ in
            Text("Its invoices go too (their documents stay in the library). A provider with invoices on a statement can't be deleted. This can't be undone.")
        }
    }

    private func load() {
        providers = (try? dbQueue.read { db in try Recharges.providers(db: db, propertyId: propertyId) }) ?? []
    }

    private func delete(_ provider: UtilityProvider) {
        do {
            _ = try dbQueue.write { db in try Recharges.deleteProvider(db: db, id: provider.id!) }
            error = nil
            load()
        } catch {
            self.error = error as? RechargeError == .invoiceOnStatement
                ? "\(provider.name) has invoices on statements: it can't be deleted."
                : error.localizedDescription
        }
    }
}

/// A provider: who it is and how its bank debits read, then — under their own heading, folded
/// away until opened, in the same aligned form — how its invoices are read (lists
/// comma-separated, patterns one per line), with "Test against a document…" showing what the
/// rules read from a real invoice, as a panel, before saving.
struct UtilityProviderFormSheet: View {
    let dbQueue: DatabaseQueue
    @State var provider: UtilityProvider
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var markers = ""
    @State private var fileNameMarkers = ""
    @State private var numberPatterns = ""
    @State private var issueLabels = ""
    @State private var periodLabels = ""
    @State private var amountLabels = ""
    @State private var refundLabels = ""
    @State private var testing = false
    @State private var test: TestRun?
    @State private var error: String?
    /// Whether the reading rules show (expert fields: folded away by default).
    @State private var showsRules = false

    /// A test of the rules on a document: reading (no reading yet), then what was read.
    private struct TestRun {
        let fileName: String
        var reading: UtilityInvoiceReading?
        var usedOCR = false
    }

    init(dbQueue: DatabaseQueue, provider: UtilityProvider) {
        self.dbQueue = dbQueue
        _provider = State(initialValue: provider)
        let rules = provider.effectiveRules
        _markers = State(initialValue: rules.textMarkers.joined(separator: ", "))
        _fileNameMarkers = State(initialValue: rules.fileNameMarkers.joined(separator: ", "))
        _numberPatterns = State(initialValue: rules.invoiceNumberPatterns.joined(separator: "\n"))
        _issueLabels = State(initialValue: rules.issueDateLabels.joined(separator: ", "))
        _periodLabels = State(initialValue: rules.periodLabels.joined(separator: ", "))
        _amountLabels = State(initialValue: rules.amountLabels.joined(separator: ", "))
        _refundLabels = State(initialValue: rules.refundLabels.joined(separator: ", "))
    }

    private var rules: UtilityInvoiceRules {
        func list(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return UtilityInvoiceRules(textMarkers: list(markers), fileNameMarkers: list(fileNameMarkers),
                                   invoiceNumberPatterns: numberPatterns.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                   issueDateLabels: list(issueLabels), periodLabels: list(periodLabels),
                                   amountLabels: list(amountLabels), refundLabels: list(refundLabels))
    }

    var body: some View {
        SheetScaffold(title: provider.id == nil ? "New provider" : "Edit provider", error: error, width: SheetMetrics.listWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: !provider.name.trimmingCharacters(in: .whitespaces).isEmpty, action: save)) {
            VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
                SheetForm {
                    LabeledContent("Name") { TextField("Name", text: $provider.name) }
                    LabeledContent("Kind") {
                        Picker("Kind", selection: $provider.kind) {
                            ForEach(UtilityKind.allCases, id: \.self) { kind in
                                Label(kind.displayName, systemImage: RechargeFormat.icon(kind)).tag(kind)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    LabeledContent("Account / contract") { TextField("Account", text: Binding(get: { provider.accountReference ?? "" }, set: { provider.accountReference = $0 })) }
                    LabeledContent("Bank description") {
                        TextField("Bank description", text: Binding(get: { provider.bankDescriptionPattern ?? "" }, set: { provider.bankDescriptionPattern = $0 }),
                                  prompt: Text("Text its debits contain; alternatives separated by |"))
                            .sheetFieldNote("Matches its debits on the bank statements, so each invoice finds the one that paid it.")
                    }
                    sectionHeader
                    if showsRules {
                        LabeledContent("Identifying words") { listField("Words", text: $markers, prompt: "In the invoice text, comma-separated") }
                        LabeledContent("File name words") { listField("Words", text: $fileNameMarkers, prompt: "e.g. LUZ, AGUA") }
                        LabeledContent("Number patterns") {
                            TextField("Patterns", text: $numberPatterns, prompt: Text("Regular expressions, one per line; group 1 is the number"), axis: .vertical)
                                .lineLimit(2...4).font(.callout.monospaced())
                        }
                        LabeledContent("Issue date after") { listField("Labels", text: $issueLabels, prompt: "Labels; none: the first date") }
                        LabeledContent("Period after") { listField("Labels", text: $periodLabels, prompt: "Labels before the period's days") }
                        LabeledContent("Total after") { listField("Labels", text: $amountLabels, prompt: "Labels before the amount due") }
                        LabeledContent("Refund after") { listField("Labels", text: $refundLabels, prompt: "Labels that mean a credit note") }
                    }
                    LabeledContent("Test") {
                        Button("Test against a document…") { testing = true }
                            .help("Reads an invoice with the rules as they are now (nothing is saved)")
                    }
                }
                if let test { testPanel(test) }
            }
        }
        .fileImporter(isPresented: $testing, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            run(url)
        }
    }

    /// The reading rules' heading, across both columns: a disclosure that opens them.
    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.bottom, 6)
            Button { withAnimation(.snappy) { showsRules.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsRules ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Reading its invoices").font(.headline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsRules ? "Hide the reading rules" : "Show the reading rules")
            Text(showsRules ? "Words and labels as they're printed on the invoices; lists separated by commas."
                 : "How its invoices are read: identifying words, number patterns and labels. Open to change them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A comma-separated list of words or labels (its whole text in the tooltip).
    private func listField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        TextField(title, text: text, prompt: Text(prompt))
            .help(text.wrappedValue.isEmpty ? prompt : text.wrappedValue)
    }

    private func testPanel(_ test: TestRun) -> some View {
        Panel("Test: \(test.fileName)", subtitle: test.reading == nil ? "Reading…" : "What these rules read; nothing is saved") {
            if test.reading == nil {
                ProgressView().controlSize(.small)
            } else if test.usedOCR {
                StatusPill("Read with OCR", tone: .warning, help: "Read from the image: check every figure")
            }
        } content: {
            if let reading = test.reading {
                PropertyFacts {
                    PropertyFact("Number") { testValue(reading.invoiceNumber) }
                    PropertyFact("Issued") { testValue(reading.issueDate.map(DocumentFormat.day)) }
                    PropertyFact("Period") {
                        if let start = reading.periodStart, let end = reading.periodEnd {
                            Text(RechargeFormat.period(start, end)).monospacedDigit()
                        } else {
                            testValue(nil)
                        }
                    }
                    PropertyFact("Amount") { testValue(reading.amountMinorUnits.map { Money.formatInput($0) }) }
                }
            }
        }
    }

    @ViewBuilder
    private func testValue(_ text: String?) -> some View {
        if let text {
            Text(text).monospacedDigit().textSelection(.enabled)
        } else {
            StatusPill("Not found", tone: .warning, systemImage: "questionmark.circle")
        }
    }

    private func run(_ url: URL) {
        let rules = rules
        test = TestRun(fileName: url.lastPathComponent)
        Task {
            let reading = await Task.detached(priority: .userInitiated) { () -> (UtilityInvoiceReading, Bool) in
                let text = EvidenceFiles.withAccess(url) { UtilityInvoiceIntake.text(of: url) }
                return (UtilityInvoiceReader.read(text: text.text, fileName: url.lastPathComponent, rules: rules), text.usedOCR)
            }.value
            test = TestRun(fileName: url.lastPathComponent, reading: reading.0, usedOCR: reading.1)
        }
    }

    private func save() {
        do {
            var provider = provider
            provider.invoiceRules = rules
            try dbQueue.write { db in try Recharges.saveProvider(db: db, &provider) }
            dismiss()
        } catch {
            self.error = RechargeMessages.text(for: error)
            // A pattern that doesn't read is in the reading rules: unfold them to show it.
            if case RechargeError.invalidPattern = error { withAnimation(.snappy) { showsRules = true } }
        }
    }
}
