// App/Import/CSVMappingModel.swift
import Foundation
import BudgetCore

/// State behind the CSV column-mapping sheet. The file is split into rows once, here, and
/// the live check / result preview are recomputed only when the mapping, date format or
/// flip-sign choice changes — never per cell render. Held as a `@StateObject` so a parent
/// re-render doesn't rebuild it.
@MainActor
final class CSVMappingModel: ObservableObject {
    /// What the options row shows under the table.
    enum Check: Equatable {
        /// Roles still to map before anything can be parsed.
        case missing([CSVColumnRole])
        /// The whole file parsed with the draft mapping.
        case parsed(rowCount: Int, unreadableLines: [String], preview: [ParsedTransaction])
    }

    static let sampleRowCount = 8
    static let previewCount = 8
    /// Format detection looks at this many non-blank Date values from the top of the file,
    /// so a footer or summary line further down shows up as "can't be read" in the live
    /// check instead of ruling out every format.
    static let detectionValueCount = 50
    /// Typing a custom date format re-parses the whole file, so wait for a pause.
    static let customFormatDebounce: Duration = .milliseconds(250)

    let header: [String]
    let sampleRows: [[String]]
    let columnCount: Int
    let allowBalance: Bool
    let currency: Currency
    /// Natural width for each column from its header and sample values, before the
    /// Description column's minimum is applied.
    let contentWidths: [CGFloat]

    @Published private(set) var mapping: CSVColumnMapping
    @Published private(set) var dateFormatCandidates: [String] = []
    /// `nil` means "Custom…", read from `customDateFormat`.
    @Published var selectedDateFormat: String? { didSet { if selectedDateFormat != oldValue, !isUpdatingRoles { recompute() } } }
    @Published var customDateFormat: String { didSet { if selectedDateFormat == nil, customDateFormat != oldValue { scheduleRecompute() } } }
    @Published var negateAmounts: Bool { didSet { if negateAmounts != oldValue { recompute() } } }
    @Published private(set) var check: Check = .missing([])

    private let csvText: String
    private let accountId: Int64
    /// Every data row (header excluded), split once — the Date column's values feed format
    /// detection whenever a different column becomes Date.
    private let dataRows: [[String]]
    /// True inside `setRole`, so a format change it causes doesn't parse the file a second time.
    private var isUpdatingRoles = false
    /// The pending debounced recompute after a Custom… keystroke.
    private var pendingRecompute: Task<Void, Never>?

    init(account: Account, csvText: String, existingProfile: ImportProfile?) {
        self.csvText = csvText
        self.accountId = account.id ?? 0
        self.allowBalance = account.kind != .credit
        self.currency = account.currency
        let lines = CSVStatementParser.splitLines(csvText)
        let rows = lines.map { CSVRowSplitter.split(line: $0, delimiter: ",") }
        let header = rows.first ?? []
        let dataRows = Array(rows.dropFirst())
        let sampleRows = Array(dataRows.prefix(Self.sampleRowCount))
        // Never narrower than the saved mapping, so editing can't silently drop a mapped column.
        let profileColumns = [
            existingProfile?.csvDateColumnIndex, existingProfile?.csvDescriptionColumnIndex,
            existingProfile?.csvAmountColumnIndex, existingProfile?.csvCreditAmountColumnIndex,
            existingProfile?.csvBalanceColumnIndex
        ].compactMap { $0 }
        let columnCount = max(header.count, sampleRows.map(\.count).max() ?? 0, (profileColumns.max() ?? -1) + 1)
        self.header = header
        self.dataRows = dataRows
        self.sampleRows = sampleRows
        self.columnCount = columnCount
        self.contentWidths = (0..<columnCount).map { index in
            let texts = [header[safe: index] ?? ""] + sampleRows.map { $0[safe: index] ?? "" }
            let longest = texts.map(\.count).max() ?? 0
            return min(max(CGFloat(longest) * 7.5 + 24, 160), 320)
        }

        var mapping: CSVColumnMapping
        if let existingProfile {
            mapping = CSVColumnMapping(columnCount: columnCount, profile: existingProfile)
        } else {
            mapping = CSVColumnMapping(columnCount: columnCount, suggestion: CSVColumnSuggester.suggest(header: header))
        }
        if !allowBalance, let balance = mapping.roles.firstIndex(of: .balance) {
            mapping.assign(.ignore, toColumn: balance)
        }
        self.mapping = mapping
        self.negateAmounts = existingProfile?.csvNegateAmounts ?? false
        self.customDateFormat = ""
        self.selectedDateFormat = nil

        let candidates = Self.detectFormats(mapping: mapping, dataRows: dataRows)
        dateFormatCandidates = candidates
        if let saved = existingProfile?.csvDateFormat, !saved.isEmpty {
            if candidates.contains(saved) { selectedDateFormat = saved } else { customDateFormat = saved }
        } else {
            selectedDateFormat = candidates.first
        }
        recompute()
    }

    /// The roles a column's menu offers — Balance only for accounts that track one.
    var offeredRoles: [CSVColumnRole] {
        CSVColumnRole.allCases.filter { $0 != .balance || allowBalance }
    }

    /// The header text, or "Column N" for a blank or missing header cell.
    func headerTitle(column: Int) -> String {
        let text = header[safe: column] ?? ""
        return text.isEmpty ? "Column \(column + 1)" : text
    }

    /// A sample cell, blank when the row is shorter than the widest row.
    func sampleValue(row: Int, column: Int) -> String {
        sampleRows[safe: row]?[safe: column] ?? ""
    }

    var effectiveDateFormat: String {
        (selectedDateFormat ?? customDateFormat).trimmingCharacters(in: .whitespaces)
    }

    var hasSignedAmountColumn: Bool { mapping.roles.contains(.amount) }

    /// True when a Date column is mapped but none of the known formats reads its leading values.
    var noFormatMatches: Bool {
        mapping.roles.contains(.date) && dateFormatCandidates.isEmpty
    }

    func setRole(_ role: CSVColumnRole, forColumn index: Int) {
        let previousDateColumn = mapping.roles.firstIndex(of: .date)
        isUpdatingRoles = true
        mapping.assign(role, toColumn: index)
        if mapping.roles.firstIndex(of: .date) != previousDateColumn { refreshDateFormats() }
        isUpdatingRoles = false
        recompute()
    }

    /// Why Save can't go ahead yet, or `nil` when it can.
    var saveBlocker: String? {
        switch check {
        case .missing(let roles):
            return "Still needed: \(Self.missingDescription(roles))."
        case .parsed(let rowCount, _, _):
            if effectiveDateFormat.isEmpty { return "Choose a date format." }
            if rowCount == 0 { return "No rows can be read with this mapping. Check the date format and the amount columns." }
            return nil
        }
    }

    /// The profile to save, or `nil` while `saveBlocker` is set.
    func makeProfile() -> ImportProfile? {
        // Don't judge a Custom… format by the check from before the last keystroke.
        if pendingRecompute != nil { recompute() }
        guard saveBlocker == nil else { return nil }
        return draftProfile()
    }

    static func missingDescription(_ roles: [CSVColumnRole]) -> String {
        roles.map { role in
            role == .amount ? "Amount (or Money out and Money in)" : role.title
        }.joined(separator: ", ")
    }

    // MARK: - Private

    private func draftProfile() -> ImportProfile? {
        mapping.profile(accountId: accountId, dateFormat: effectiveDateFormat, negateAmounts: hasSignedAmountColumn && negateAmounts, allowBalance: allowBalance)
    }

    /// Re-detects formats for a newly chosen Date column, keeping the current choice when it
    /// still fits and otherwise moving to the best match (or Custom… when nothing matches).
    private func refreshDateFormats() {
        dateFormatCandidates = Self.detectFormats(mapping: mapping, dataRows: dataRows)
        if let selected = selectedDateFormat, dateFormatCandidates.contains(selected) { return }
        if selectedDateFormat == nil, !customDateFormat.isEmpty, dateFormatCandidates.isEmpty { return }
        selectedDateFormat = dateFormatCandidates.first
    }

    private func scheduleRecompute() {
        pendingRecompute?.cancel()
        pendingRecompute = Task { [weak self] in
            try? await Task.sleep(for: Self.customFormatDebounce)
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    private func recompute() {
        pendingRecompute?.cancel()
        pendingRecompute = nil
        guard let profile = draftProfile() else {
            check = .missing(mapping.missingRoles)
            return
        }
        let result = CSVStatementParser.parse(csvText: csvText, profile: profile)
        check = .parsed(
            rowCount: result.transactions.count,
            unreadableLines: result.unparsedLines,
            preview: Array(result.transactions.prefix(Self.previewCount))
        )
    }

    private static func detectFormats(mapping: CSVColumnMapping, dataRows: [[String]]) -> [String] {
        guard let dateColumn = mapping.roles.firstIndex(of: .date) else { return [] }
        let values = dataRows.lazy
            .compactMap { $0[safe: dateColumn] }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(detectionValueCount)
        return CSVDateFormatDetector.candidates(values: Array(values))
    }
}

extension CSVColumnRole {
    /// The label used in the column menus and the "Still needed" message.
    var title: String {
        switch self {
        case .date: "Date"
        case .description: "Description"
        case .amount: "Amount (signed)"
        case .moneyOut: "Money out"
        case .moneyIn: "Money in"
        case .balance: "Balance"
        case .ignore: "Ignore"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
