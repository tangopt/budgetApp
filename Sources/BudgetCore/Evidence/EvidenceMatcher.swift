import Foundation

/// Proposes the transactions a document is evidence for (spec §2–§3), ranked: the exact
/// amount (sign-free, in the transaction's account currency) is the strongest signal, then a
/// payment reference the description repeats, the date within the kind's window (a mortgage
/// notice's value date ±3 days, a mortgage receipt its own date ±3 (a weekend's debit), an IMI payment the same day, an insurance receipt ±10 days, a
/// rent receipt's rent-period month for the credit, a repair bill −15…45 days, stamp duty −1…60 …), and the category, account and
/// description the kind usually has (the Lisbon categories, the BBVA account). Equal scores are
/// left equal — `confidentMatch` only picks a single clear winner.
public enum EvidenceMatcher {
    public struct Suggestion: Equatable, Sendable {
        public var transactionId: Int64
        public var score: Int
        /// Why, for the review screen ("Amount €1,234.56", "2 days after").
        public var reasons: [String]
        /// The exact amount matched (in the transaction's currency).
        public var amountMatched: Bool
        /// The date is inside the kind's window (not only within the exact amount's grace).
        public var dateInWindow: Bool
        /// A payment reference in the document appears in this transaction's description and in
        /// no other transaction's.
        public var referenceMatched: Bool

        public init(transactionId: Int64, score: Int, reasons: [String], amountMatched: Bool = false, dateInWindow: Bool = false,
                    referenceMatched: Bool = false) {
            self.transactionId = transactionId
            self.score = score
            self.reasons = reasons
            self.amountMatched = amountMatched
            self.dateInWindow = dateInWindow
            self.referenceMatched = referenceMatched
        }
    }

    enum Direction {
        case debit, credit, either
    }

    /// What a kind's transaction usually looks like.
    struct Expectation {
        var direction: Direction = .either
        /// Days from the anchor date (negative: before) the transaction is expected in.
        var window: ClosedRange<Int> = -7...7
        /// The anchor: the document's date, or its period's start or end.
        var anchor: Anchor = .docDate
        /// Lowercased fragments of the category's name.
        var categoryHints: [String] = []
        /// Uppercased, diacritic-free fragments of the description.
        var descriptionHints: [String] = []
        /// The account's name or alias mentions this (uppercased), e.g. BBVA for Lisbon costs.
        var accountHint: String?

        enum Anchor {
            case docDate, periodStart, periodEnd
        }
    }

    static let bbva = "BBVA"

    /// A custom kind has no usual transaction: the default expectation.
    static func expectation(for ref: DocumentKindRef) -> Expectation {
        switch ref {
        case .builtIn(let kind): return expectation(for: kind)
        case .custom: return Expectation()
        }
    }

    static func expectation(for kind: DocumentKind) -> Expectation {
        switch kind {
        case .mortgageNotice:
            return Expectation(direction: .debit, window: -3...3, anchor: .periodEnd, categoryHints: ["mortgage", "hipoteca"],
                               descriptionHints: ["COBR. REC", "COBR REC", "PRESTACAO", "EMPRESTIMO"], accountHint: bbva)
        case .mortgageReceipt:
            // Dated on the debit's own day (its value date), or the working day after a
            // weekend's debit: ±3 days still never reaches the month before or after.
            return Expectation(direction: .debit, window: -3...3, anchor: .docDate, categoryHints: ["mortgage", "hipoteca"],
                               descriptionHints: ["COBR. REC", "COBR REC", "PRESTACAO", "EMPRESTIMO"], accountHint: bbva)
        case .insuranceReceipt:
            return Expectation(direction: .debit, window: -10...10, categoryHints: ["insurance", "seguro"],
                               descriptionHints: ["BBVASEG", "SEGUR", "MAPFRE", "TRANQUILIDADE", "GENERALI"], accountHint: bbva)
        case .imiPayment:
            return Expectation(direction: .debit, window: -1...1, categoryHints: ["imi"], descriptionHints: ["PAGEST", "ESTADO", "IMI"], accountHint: bbva)
        case .imiNotice:
            return Expectation(direction: .debit, window: 0...150, categoryHints: ["imi"], descriptionHints: ["PAGEST", "ESTADO", "IMI"], accountHint: bbva)
        case .ptIRSPaymentProof:
            return Expectation(direction: .debit, window: -1...1, categoryHints: ["pt tax", "irs"], descriptionHints: ["PAGEST", "ESTADO", "IRS"], accountHint: bbva)
        case .ptIRSPaymentNote:
            return Expectation(direction: .debit, window: 0...60, categoryHints: ["pt tax", "irs"], descriptionHints: ["PAGEST", "ESTADO", "IRS"], accountHint: bbva)
        case .ptIRSAssessment:
            // An assessment can be a bill or a refund.
            return Expectation(direction: .either, window: 0...60, categoryHints: ["pt tax", "irs"],
                               descriptionHints: ["PAGEST", "ESTADO", "IRS", "AUTORIDADE TRIBUTARIA", "REEMBOLSO"], accountHint: bbva)
        case .courtFee:
            return Expectation(direction: .debit, window: -1...3, categoryHints: ["legal"], descriptionHints: ["PAGEST", "ESTADO", "IGFEJ"], accountHint: bbva)
        case .lettingAgentFee:
            return Expectation(direction: .debit, window: -15...30, categoryHints: ["letting", "agent"], descriptionHints: ["MEDIAC", "IMOBILIARIA"])
        case .condominioReceipt:
            return Expectation(direction: .debit, window: -10...10, categoryHints: ["condom"], descriptionHints: ["CONDOM"], accountHint: bbva)
        case .rentReceipt:
            // The rent for a month arrives in that month, or in the last days of the one before.
            return Expectation(direction: .credit, window: -10...30, anchor: .periodStart, categoryHints: ["rent"], descriptionHints: ["RENDA", "RENT"], accountHint: bbva)
        case .repairInvoice:
            // Paid on the spot, by deposit before the work, or weeks after the invoice.
            return Expectation(direction: .debit, window: -15...45, categoryHints: ["repair", "manuten", "obras"])
        case .stampDuty:
            // Paid by the note's deadline: from the day before to two months after.
            return Expectation(direction: .debit, window: -1...60, anchor: .docDate, categoryHints: ["selo", "stamp"],
                               descriptionHints: ["PAGEST", "ESTADO", "SELO"], accountHint: bbva)
        case .accountantInvoice:
            return Expectation(direction: .debit, window: -15...30, categoryHints: ["accountant", "contabil"],
                               descriptionHints: ["CONTABIL", "ACCOUNTAN", "TAX ADVISER"])
        case .legalInvoice:
            return Expectation(direction: .debit, window: -15...30, categoryHints: ["legal"], descriptionHints: ["ADVOGAD", "SOLICITADOR", "LEGAL"])
        case .utilityInvoice:
            return Expectation(direction: .debit, window: -5...45, categoryHints: ["utilit"],
                               descriptionHints: ["EDP", "GDL", "LISBOAGAS", "SIMAR", "SMAS", "GALP", "AGUAS", "EPAL"], accountHint: bbva)
        case .bankTransferProof:
            return Expectation(direction: .either, window: -1...3)
        case .bankDebitAdvice:
            return Expectation(direction: .debit, window: -2...2, accountHint: bbva)
        case .hmrcPaymentProof:
            return Expectation(direction: .debit, window: -1...5, categoryHints: ["uk tax", "hmrc"], descriptionHints: ["HMRC"])
        default:
            return Expectation()
        }
    }

    // Points.
    static let amountPoints = 100
    static let referencePoints = 60
    static let datePoints = 40
    static let categoryPoints = 20
    static let descriptionPoints = 15
    static let accountPoints = 10
    /// Below this a candidate isn't suggested (a date in the window alone is not enough).
    static let minimumScore = 60
    /// An exact amount still counts this far outside the date window.
    static let amountGraceDays = 30

    /// Transactions prepared for matching many documents: sorted by date, grouped by amount,
    /// descriptions normalized once.
    public struct Index: Sendable {
        struct Entry: Sendable {
            let transaction: Transaction
            let id: Int64
            let description: String
            let digits: String
        }

        let byDate: [Entry]
        let byAmount: [Int: [Entry]]
        let byId: [Int64: Entry]
        let accounts: [Int64: Account]
        let categories: [Int64: Category]

        public init(transactions: [Transaction], accounts: [Account], categories: [Category]) {
            let entries = transactions.compactMap { transaction -> Entry? in
                guard let id = transaction.id else { return nil }
                let description = EvidenceText.normalized(transaction.rawDescription)
                return Entry(transaction: transaction, id: id, description: description, digits: description.filter(\.isNumber))
            }
            byDate = entries.sorted { ($0.transaction.date, $0.id) < ($1.transaction.date, $1.id) }
            byAmount = Dictionary(grouping: entries) { abs($0.transaction.amountMinorUnits) }
            byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.accounts = Dictionary(accounts.compactMap { account in account.id.map { ($0, account) } }, uniquingKeysWith: { first, _ in first })
            self.categories = Dictionary(categories.compactMap { category in category.id.map { ($0, category) } }, uniquingKeysWith: { first, _ in first })
        }

        /// The debits among `transactionIds` (a document's linked transactions) with what each paid,
        /// sign-free, those of accounts in `currency` only (credits never pay a document).
        public func linkedDebits(_ transactionIds: [Int64], currency: Currency?) -> [LinkedDebit] {
            guard let currency else { return [] }
            return transactionIds.compactMap { id in
                guard let transaction = byId[id]?.transaction, transaction.amountMinorUnits < 0,
                      accounts[transaction.accountId]?.currency == currency else { return nil }
                return LinkedDebit(transactionId: id, amountMinorUnits: -transaction.amountMinorUnits)
            }
        }

        /// Entries dated within `start...end` (binary search).
        func entries(from start: Date, to end: Date) -> ArraySlice<Entry> {
            func firstIndex(notBefore date: Date) -> Int {
                var low = 0, high = byDate.count
                while low < high {
                    let mid = (low + high) / 2
                    if byDate[mid].transaction.date < date { low = mid + 1 } else { high = mid }
                }
                return low
            }
            let lower = firstIndex(notBefore: start)
            let upper = max(lower, firstIndex(notBefore: end.addingTimeInterval(1)))
            return byDate[lower..<upper]
        }
    }

    /// Candidate transactions for `document`, best first; at most `limit`.
    public static func suggestions(document: EvidenceDocument, transactions: [Transaction], accounts: [Account],
                                   categories: [Category], limit: Int = 10) -> [Suggestion] {
        suggestions(document: document, index: Index(transactions: transactions, accounts: accounts, categories: categories), limit: limit)
    }

    /// Candidate transactions for `document` from a prepared `index` (many documents, one index).
    /// `linkedDebits`: the debits already linked to it (`linkedDebits(db:)`); another debit of the
    /// rest of a part-paid document counts as its exact amount (`remainder`), never a linked one.
    public static func suggestions(document: EvidenceDocument, index: Index, limit: Int = 10, linkedDebits: [LinkedDebit] = []) -> [Suggestion] {
        // An addendum amends a tenancy (`TenancyAddendum`): its new rent's credits aren't its to prove.
        guard document.kind != .tenancyAddendum else { return [] }
        let expectation = expectation(for: document.kindRef)
        let anchor: Date? = switch expectation.anchor {
        case .docDate: document.docDate
        case .periodStart: document.periodStart ?? document.docDate
        case .periodEnd: document.periodEnd ?? document.docDate
        }
        let documentAmount = document.amountMinorUnits.map(abs)
        let linkedAmounts = linkedDebits.map(\.amountMinorUnits)
        let linkedIds = Set(linkedDebits.map(\.transactionId))

        // Only transactions that could score: in the window (plus the exact amount's grace)
        // around the anchor, or — undated — of the document's amount.
        let pool: [Index.Entry]
        if let anchor {
            let day: TimeInterval = 86_400
            pool = Array(index.entries(from: anchor.addingTimeInterval(Double(expectation.window.lowerBound - amountGraceDays) * day),
                                       to: anchor.addingTimeInterval(Double(expectation.window.upperBound + amountGraceDays) * day)))
        } else if let documentAmount {
            pool = index.byAmount[documentAmount] ?? []
        } else {
            return []
        }
        let candidates = pool.filter { entry in
            switch expectation.direction {
            case .debit: return entry.transaction.amountMinorUnits <= 0
            case .credit: return entry.transaction.amountMinorUnits >= 0
            case .either: return true
            }
        }

        // A reference counts only when exactly one transaction of all repeats it (a loan number
        // on every instalment says nothing about which one).
        var referenceOwner: [Int64: String] = [:]
        for reference in paymentReferences(in: document.extractedText ?? "") {
            let owners = index.byDate.lazy.filter { $0.digits.contains(reference) }.prefix(2)
            if owners.count == 1, let owner = owners.first, referenceOwner[owner.id] == nil { referenceOwner[owner.id] = reference }
        }

        var ranked: [(suggestion: Suggestion, distance: Int)] = []
        for entry in candidates {
            let transaction = entry.transaction
            let account = index.accounts[transaction.accountId]
            var score = 0
            var reasons: [String] = []

            var amountMatches = false
            if let documentAmount, let currency = document.currency, let account,
               account.currency == currency, abs(transaction.amountMinorUnits) == documentAmount {
                amountMatches = true
                score += amountPoints
                reasons.append("Amount \(Money.format(documentAmount, currency: currency))")
            } else if !linkedAmounts.isEmpty, !linkedIds.contains(entry.id), let account,
                      let rest = remainder(document: document, linkedAmounts: linkedAmounts, transaction: transaction, currency: account.currency) {
                amountMatches = true
                score += rest.score
                reasons += rest.reasons
            }

            var distance = Int.max
            var inWindow = false
            if let anchor {
                let offset = days(from: anchor, to: transaction.date)
                distance = abs(offset)
                if expectation.window.contains(offset) {
                    inWindow = true
                    // Full points on the anchor day (or the window's nearest day), half at its far edge.
                    let nearest = min(max(0, expectation.window.lowerBound), expectation.window.upperBound)
                    let span = max(1, max(abs(expectation.window.lowerBound - nearest), abs(expectation.window.upperBound - nearest)))
                    score += datePoints - (datePoints / 2) * abs(offset - nearest) / span
                    reasons.append(offset == 0 ? "Same day" : "\(abs(offset)) day\(abs(offset) == 1 ? "" : "s") \(offset < 0 ? "before" : "after")")
                } else {
                    let outside = offset < expectation.window.lowerBound ? expectation.window.lowerBound - offset : offset - expectation.window.upperBound
                    guard amountMatches, outside <= amountGraceDays else { continue }
                }
            } else if !amountMatches {
                continue
            }

            let reference = referenceOwner[entry.id]
            if let reference {
                score += referencePoints
                reasons.append("Reference \(reference)")
            }
            if let hint = expectation.descriptionHints.first(where: { entry.description.contains($0) }) {
                score += descriptionPoints
                reasons.append("Description mentions \(hint)")
            }
            if let categoryId = transaction.categoryId, let category = index.categories[categoryId] {
                let name = EvidenceText.fold(category.name).lowercased()
                if expectation.categoryHints.contains(where: { name.contains($0) }) {
                    score += categoryPoints
                    reasons.append("Category \(category.name)")
                }
            }
            if let hint = expectation.accountHint, let account,
               [account.name, account.alias ?? ""].contains(where: { $0.uppercased().contains(hint) }) {
                score += accountPoints
                reasons.append("\(account.alias ?? account.name) account")
            }

            guard score >= minimumScore else { continue }
            ranked.append((Suggestion(transactionId: entry.id, score: score, reasons: reasons, amountMatched: amountMatches,
                                      dateInWindow: inWindow, referenceMatched: reference != nil), distance))
        }
        ranked.sort { lhs, rhs in
            if lhs.suggestion.score != rhs.suggestion.score { return lhs.suggestion.score > rhs.suggestion.score }
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.suggestion.transactionId < rhs.suggestion.transactionId
        }
        return ranked.prefix(limit).map(\.suggestion)
    }

    // MARK: One document on several transactions

    /// Two debits that together paid a document (spec 2026-10-24 §4c).
    public struct InstalmentMatch: Equatable, Sendable {
        /// The two debits, earliest first.
        public var transactionIds: [Int64]
        /// "Paid in 2 instalments: €40.00 + €39.95".
        public var reasons: [String]

        public init(transactionIds: [Int64], reasons: [String]) {
            self.transactionIds = transactionIds
            self.reasons = reasons
        }
    }

    /// A debit linked to a document, with what it paid (sign-free, in the document's currency).
    public struct LinkedDebit: Equatable, Sendable {
        public var transactionId: Int64
        public var amountMinorUnits: Int

        public init(transactionId: Int64, amountMinorUnits: Int) {
            self.transactionId = transactionId
            self.amountMinorUnits = amountMinorUnits
        }
    }

    /// Whether a document of this kind is paid by debits (a bill, a notice, a receipt of a
    /// payment): only those can be part-paid. Never a statement, a contract, a policy, an annual
    /// form, a kind that proves credits or either way, nor a custom kind (no usual transaction).
    public static func isPaidByDebits(_ kind: DocumentKindRef) -> Bool {
        expectation(for: kind).direction == .debit
    }

    /// Bank words that name no merchant ("PAG", "COMPRA", "TRF"): never enough to tie a debit to a document.
    static let bankWords: Set<String> = ["COMPRA", "PAGAMENTO", "PAGAMENTOS", "PAGTO", "TRANSFERENCIA", "TRANSF", "DEBITO", "DIRECTO",
                                         "DIRETO", "CARTAO", "PAYMENT", "CARD", "DIRECT", "DEBIT", "SERVICOS", "COMPRAS", "MBWAY"]

    /// Whether a debit could be the document's: its category or description has one of the kind's
    /// hints, or a word of its merchant (4+ letters, not a bank word) is in the document's text.
    /// When the document has no text and its kind no hints, nothing ties them: any debit.
    static func ties(_ entry: Index.Entry, to document: EvidenceDocument, text: String, expectation: Expectation, index: Index) -> Bool {
        if expectation.descriptionHints.contains(where: { entry.description.contains($0) }) { return true }
        if let categoryId = entry.transaction.categoryId, let category = index.categories[categoryId] {
            let name = EvidenceText.fold(category.name).lowercased()
            if expectation.categoryHints.contains(where: { name.contains($0) }) { return true }
        }
        if !text.isEmpty {
            let words = MerchantKey.keptTokens(EvidenceText.fold(entry.transaction.rawDescription))
                .filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) && !bankWords.contains($0) && !MerchantKey.genericTokens.contains($0)
                    && !MerchantKey.processorTokens.contains($0) }
            if words.contains(where: { text.contains($0) }) { return true }
        }
        return text.isEmpty && expectation.descriptionHints.isEmpty && expectation.categoryHints.isEmpty
    }

    /// How many instalment pairs are proposed at most.
    static let maxInstalmentMatches = 3

    /// Pairs of debits that may have paid `document` in two instalments: both debits (a kind
    /// that proves a credit has none), in the kind's window plus `amountGraceDays` around its
    /// anchor, of the same merchant (`MerchantKey`) tied to the document (`ties`: the kind's
    /// hints, or the merchant named in its text), each smaller than the document's amount,
    /// together exactly its amount in their accounts' currency (the document's); never one of
    /// `excluding` (debits that already carry a document of its kind). At most
    /// `maxInstalmentMatches`, earliest first. Only ever a proposal: the importer asks.
    public static func instalments(document: EvidenceDocument, index: Index, excluding: Set<Int64> = []) -> [InstalmentMatch] {
        guard document.kind != .tenancyAddendum, let total = document.amountMinorUnits.map(abs), total > 1,
              let currency = document.currency else { return [] }
        let expectation = expectation(for: document.kindRef)
        guard expectation.direction != .credit else { return [] }
        let anchor: Date? = switch expectation.anchor {
        case .docDate: document.docDate
        case .periodStart: document.periodStart ?? document.docDate
        case .periodEnd: document.periodEnd ?? document.docDate
        }
        guard let anchor else { return [] }
        let day: TimeInterval = 86_400
        let text = EvidenceText.normalized(document.extractedText ?? "")
        let pool = index.entries(from: anchor.addingTimeInterval(Double(expectation.window.lowerBound - amountGraceDays) * day),
                                 to: anchor.addingTimeInterval(Double(expectation.window.upperBound + amountGraceDays) * day))
            .filter { entry in
                let amount = -entry.transaction.amountMinorUnits
                return amount > 0 && amount < total && !excluding.contains(entry.id)
                    && index.accounts[entry.transaction.accountId]?.currency == currency
                    && ties(entry, to: document, text: text, expectation: expectation, index: index)
            }
        // Same merchant, in date order (the pool is).
        var byMerchant: [String: [Index.Entry]] = [:]
        var merchants: [String] = []
        for entry in pool {
            let key = MerchantKey.make(entry.transaction.rawDescription)
            if byMerchant[key] == nil { merchants.append(key) }
            byMerchant[key, default: []].append(entry)
        }
        var pairs: [(first: Index.Entry, second: Index.Entry)] = []
        for key in merchants {
            let entries = byMerchant[key] ?? []
            for i in entries.indices {
                for j in entries.indices where j > i {
                    if -entries[i].transaction.amountMinorUnits - entries[j].transaction.amountMinorUnits == total {
                        pairs.append((entries[i], entries[j]))
                    }
                }
            }
        }
        pairs.sort { lhs, rhs in
            (lhs.first.transaction.date, lhs.second.transaction.date, lhs.first.id, lhs.second.id)
                < (rhs.first.transaction.date, rhs.second.transaction.date, rhs.first.id, rhs.second.id)
        }
        return pairs.prefix(maxInstalmentMatches).map { pair in
            let a = Money.format(-pair.first.transaction.amountMinorUnits, currency: currency)
            let b = Money.format(-pair.second.transaction.amountMinorUnits, currency: currency)
            return InstalmentMatch(transactionIds: [pair.first.id, pair.second.id], reasons: ["Paid in 2 instalments: \(a) + \(b)"])
        }
    }

    /// `transaction` as the debit of what is left to pay on a part-paid document (of a kind paid by
    /// debits, `isPaidByDebits`): its amount (in
    /// `currency`, its account's, the document's) is the document's amount minus `linkedAmounts`,
    /// what the debits already linked to it paid, when that is more than nothing. Scored as an
    /// exact amount; nil otherwise.
    public static func remainder(document: EvidenceDocument, linkedAmounts: [Int], transaction: Transaction,
                                 currency: Currency) -> Suggestion? {
        guard isPaidByDebits(document.kindRef), let total = document.amountMinorUnits.map(abs), document.currency == currency,
              !linkedAmounts.isEmpty, transaction.amountMinorUnits < 0, let id = transaction.id else { return nil }
        let paid = linkedAmounts.reduce(0) { $0 + abs($1) }
        let rest = total - paid
        guard paid > 0, rest > 0, -transaction.amountMinorUnits == rest else { return nil }
        let reason = "Pays the rest of \(document.displayName): \(Money.format(rest, currency: currency)) after \(Money.format(paid, currency: currency))"
        return Suggestion(transactionId: id, score: amountPoints, reasons: [reason], amountMatched: true)
    }

    /// The single clear winner of `suggestions` (best first), safe to link without asking: the
    /// exact amount, and the date in the kind's window or a reference only it repeats; at least
    /// `minimumScore` and strictly ahead of the next. Nil when two tie (the user picks), or when
    /// only a neighbouring period's equal amount is there (the expected debit is missing).
    public static func confidentMatch(_ suggestions: [Suggestion], minimumScore: Int = 140) -> Suggestion? {
        guard let best = suggestions.first, best.score >= minimumScore, best.amountMatched,
              best.dateInWindow || best.referenceMatched else { return nil }
        if suggestions.count > 1, suggestions[1].score >= best.score { return nil }
        return best
    }

    /// Payment references in a document (9+ digits, spaces between groups removed:
    /// `104 700 000 000 001` → `104700000000001`), which bank descriptions repeat.
    static func paymentReferences(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let regex = referencePattern
        let source = text as NSString
        var seen = Set<String>()
        var references: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let digits = source.substring(with: match.range).filter(\.isNumber)
            guard (9...25).contains(digits.count), seen.insert(digits).inserted else { continue }
            references.append(digits)
        }
        return references
    }

    private static let referencePattern = try! NSRegularExpression(pattern: #"(?<![\d.,])\d{3,}(?: \d{3})+(?![\d.,])|(?<![\d.,])\d{9,}(?![\d.,])"#)

    static func days(from start: Date, to end: Date) -> Int {
        let calendar = EvidenceText.utcCalendar
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }
}
