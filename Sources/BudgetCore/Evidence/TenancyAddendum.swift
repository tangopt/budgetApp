import GRDB
import Foundation

/// An addendum to a tenancy's contract (`DocumentKind.tenancyAddendum`: "Aditamento" or
/// "Adenda" ao contrato de arrendamento) — a new rent, a longer term. Reads its date (signed,
/// else in effect), finds the tenancy it amends (the contract's) and names it after that
/// tenancy. Filed on the tenancy beside its contract: never the contract the tenancy asks for,
/// never a transaction's evidence.
public enum TenancyAddendum {
    /// The role of its link to the tenancy (the contract's is "Contract").
    public static let linkRole = "Addendum"

    // MARK: Date

    /// Just before a signature's date: "Lisboa, " or "assinado em ".
    private static let signatureLead = try! NSRegularExpression(
        pattern: #"(?:\p{L}{3,}\s*,\s*(?:(?:em|aos|a)\s+)?|(?:assinad[oa]s?|feito|outorgad[oa])\s+(?:em|aos|a)\s+)$"#,
        options: [.caseInsensitive])
    /// Just before the date it takes effect from: "com efeitos a partir de ", "entra em vigor em ".
    private static let effectLead = try! NSRegularExpression(
        pattern: #"(?:efeitos?|a\s+partir\s+d[eo]|com\s+inicio\s+(?:em|a)|vigor\s+(?:em|a))[^.\n]{0,20}$"#,
        options: [.caseInsensitive])

    /// The addendum's date: its signature's ("Lisboa, 15 de fevereiro de 2025", the last such),
    /// else the date it takes effect from (the first); nil without either (the contract's own
    /// date, quoted in it, is neither).
    public static func date(in text: String) -> Date? {
        let folded = EvidenceText.fold(text)
        let source = folded as NSString
        let dates = EvidenceDateParser.dates(in: folded)
        func lead(_ found: EvidenceDateParser.Found, _ regex: NSRegularExpression) -> Bool {
            let start = max(0, found.range.location - 50)
            let before = source.substring(with: NSRange(location: start, length: found.range.location - start))
            return regex.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
        }
        if let signed = dates.last(where: { lead($0, signatureLead) }) { return signed.date }
        return dates.first { lead($0, effectLead) }?.date
    }

    /// Labels whose next amount is the new rent, most specific first (a rent the addendum
    /// only repeats is no new rent).
    static let rentLabels = ["NOVA RENDA", "PASSA A SER DE", "PASSARA A SER DE", "PASSA A SER", "PASSARA A SER", "ATUALIZADA PARA",
                             "ACTUALIZADA PARA", "ALTERADA PARA", "AUMENTADA PARA", "REDUZIDA PARA", "FIXADA EM"]

    // MARK: Naming

    /// `<date> - Property - Tenancy addendum - <tenancy>` (`EvidenceNaming`): the tenancy's
    /// reference label when known.
    public static func canonicalName(date: Date, tenancyLabel: String?) -> String {
        EvidenceNaming.canonicalName(date: date, area: ImportNaming.area(of: .tenancyAddendum), type: DocumentKind.tenancyAddendum.displayName,
                                     detail: tenancyLabel)
    }

    // MARK: Tenancy

    /// A tenancy the addendum may amend, with why.
    public struct Candidate: Equatable, Sendable {
        public var tenancy: Tenancy
        public var score: Int
        public var reasons: [String]
        /// Named by the addendum: its contract number or its tenant.
        public var identified: Bool
    }

    static let contractPoints = 100
    static let tenantPoints = 60
    static let datePoints = 20
    /// An addendum may be signed a little before its tenancy starts.
    static let daysBeforeStart = 60

    /// The tenancies (of `propertyId`, else all), scored by what the addendum names — the
    /// contract number, the tenant — and whether its date falls in the tenancy; best first.
    public static func candidates(db: Database, text: String?, date: Date?, propertyId: Int64? = nil) throws -> [Candidate] {
        var request = Tenancy.order(Column("startDate"), Column("id"))
        if let propertyId { request = request.filter(Column("propertyId") == propertyId) }
        let body = EvidenceText.normalized(text ?? "")
        let words = Set(body.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return try request.fetchAll(db).map { tenancy in
            var score = 0
            var reasons: [String] = []
            var identified = false
            if let number = tenancy.contractNumber.map(EvidenceText.normalized), !number.isEmpty, contains(number, in: body) {
                score += contractPoints
                identified = true
                reasons.append("Contract nº \(tenancy.contractNumber ?? number)")
            }
            if let name = tenancy.tenantName.map(EvidenceText.normalized), name.count >= 3 {
                let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
                if contains(name, in: body) || (!parts.isEmpty && parts.allSatisfy(words.contains)) {
                    score += tenantPoints
                    identified = true
                    reasons.append("Tenant \(tenancy.tenantName ?? name)")
                }
            }
            if let date, fits(date, tenancy) {
                score += datePoints
                reasons.append("Dated within the tenancy")
            }
            return Candidate(tenancy: tenancy, score: score, reasons: reasons, identified: identified)
        }
        .sorted { $0.score > $1.score }
    }

    /// The single tenancy the addendum names, better than any other; nil when none or a tie.
    public static func clearMatch(_ candidates: [Candidate]) -> Candidate? {
        let named = candidates.filter(\.identified)
        guard let best = named.first, !named.dropFirst().contains(where: { $0.score == best.score }) else { return nil }
        return best
    }

    /// The tenancies to choose from when there's no clear match: those tied for the best
    /// named, else those the date fits, else all.
    public static func options(_ candidates: [Candidate], date: Date?) -> [Candidate] {
        let named = candidates.filter(\.identified)
        if let best = named.first { return named.filter { $0.score == best.score } }
        if let date {
            let fitting = candidates.filter { fits(date, $0.tenancy) }
            if !fitting.isEmpty { return fitting }
        }
        return candidates
    }

    private static func fits(_ date: Date, _ tenancy: Tenancy) -> Bool {
        let earliest = tenancy.startDate.addingTimeInterval(-Double(daysBeforeStart) * 86_400)
        return date >= earliest && (tenancy.endDate.map { date < PropertyDates.nextDay($0) } ?? true)
    }

    /// `needle` in `text` as whole words (a contract number never inside a longer one).
    private static func contains(_ needle: String, in text: String) -> Bool {
        let pattern = #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: needle) + #"(?![\p{L}\d])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
