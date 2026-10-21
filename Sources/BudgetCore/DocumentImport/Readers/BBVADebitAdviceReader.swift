import Foundation
import GRDB

/// BBVA debit advices ("Pagamentos – Serviços/Compras", "Débito Direto"; `BBVADebitAdvice`):
/// filed as bank debit advices and linked to the debit they announce. Never a utility invoice
/// and never an invoice record: the effect is filing only, and the link is a plain certain link
/// (applied by `ImportEffects.applyRecords`).
///
/// The debit: the advice's exact amount, booked within `dayWindow` days of its date, its
/// description naming the advice's creditor or reference (`BBVADebitAdvice.namedWord`). Linked
/// only when exactly one debit fits all three; otherwise the debits of that amount and date are
/// offered (`chooseLink`). With none, the advice is filed with a note. A file of this kind
/// whose text doesn't read as a debit advice (a learnt or chosen kind) is read as any other
/// evidence document (`EvidenceDocumentReader`).
public struct BBVADebitAdviceReader: ImportReader {
    static let dayWindow = BBVADebitAdvice.dayWindow
    static let groupKey = "\(DocumentKind.bankDebitAdvice.displayName) documents"

    public init() {}

    public func handles(_ kind: ImportKind) -> Bool { kind == .evidence(.bankDebitAdvice) }

    public func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        var items: [ImportItem?] = []
        var unread: [(index: Int, entry: (file: ImportFile, recognition: ImportRecognition))] = []
        for (index, entry) in files.enumerated() {
            if let advice = entry.file.text.flatMap(BBVADebitAdvice.parse) {
                items.append(try item(file: entry.file, recognition: entry.recognition, advice: advice, context: context, db: db))
            } else {
                items.append(nil)
                unread.append((index, entry))
            }
        }
        if !unread.isEmpty {
            let read = try EvidenceDocumentReader().propose(unread.map(\.entry), context: context, db: db)
            for (slot, item) in zip(unread, read) { items[slot.index] = item }
        }
        return items.compactMap { $0 }
    }

    private func item(file: ImportFile, recognition: ImportRecognition, advice: BBVADebitAdvice.Advice,
                      context: ImportContext, db: Database) throws -> ImportItem {
        let source: ImportFactSource = file.usedOCR ? .ocr : .textLayer
        var facts = [ImportFact(field: .docDate, value: .date(advice.date), source: source, confidence: .certain,
                                reason: "Date on the advice")]
        if let creditor = advice.creditor {
            facts.append(ImportFact(field: .issuer, value: .text(creditor), source: source, confidence: .certain,
                                    reason: "Creditor on the advice"))
        }
        if let reference = advice.reference {
            facts.append(ImportFact(field: .reference, value: .text(reference), source: source, confidence: .certain,
                                    reason: "Reference on the advice"))
        }
        let kind = DocumentKind.bankDebitAdvice
        var item = ImportItem(file: file, recognition: recognition, title: "\(kind.displayName) of \(PropertyDates.isoDay(advice.date))",
                              facts: facts, effect: .file, groupKey: Self.groupKey)

        // The user's target (a transaction's Add document…): linked there.
        if let target = context.intent.target {
            setAmount(&item, advice.amount, source: source, reason: "Amount on the advice")
            if let label = try entityTitle(db: db, target.entity) {
                item.links = [ProposedLink(entity: target.entity, role: target.role, label: label, confidence: .certain,
                                           reasons: [context.intent.targetReason(label: label)])]
            } else {
                let text = "The \(target.entity.type.displayName.lowercased()) you added it to no longer exists"
                item.issues.append(ImportIssue(id: "readerProblem\(item.issues.count)", kind: .readerProblem(text), reason: text,
                                               offers: [.fileWithoutLink]))
            }
            item.placement = ImportNaming.placement(kind: recognition.kind, facts: item.facts, file: file, persons: [])
            return item
        }

        let (debits, named) = try BBVADebitAdvice.debits(db: db, advice: advice)
        if named.count == 1, let (debit, word) = named.first, let id = debit.id {
            // The amount is the debit's when the advice states several (the layout scatters them).
            if let amount = advice.amount {
                setAmount(&item, amount, source: source, reason: "Amount on the advice")
            } else {
                setAmount(&item, -debit.amountMinorUnits, source: .matchedRecord, reason: "Amount of the matched debit")
            }
            let money = Money.format(-debit.amountMinorUnits, currency: .eur)
            item.links = [ProposedLink(entity: .transaction(id), label: try entityLabel(db: db, .transaction(id)), confidence: .certain,
                                       reasons: ["Debit of \(money) booked on \(PropertyDates.isoDay(debit.date)), within \(Self.dayWindow) days of the advice",
                                                 "Its description's \(word) is named in the advice"])]
        } else if !debits.isEmpty {
            setAmount(&item, advice.amount, source: source, reason: "Amount on the advice")
            // The debits naming the advice first.
            let ordered = named.map(\.0) + debits.filter { debit in !named.contains { $0.0.id == debit.id } }
            let candidates = try ordered.prefix(5).compactMap { debit -> LinkCandidate? in
                guard let id = debit.id else { return nil }
                var reasons = ["Debit of \(Money.format(-debit.amountMinorUnits, currency: .eur)) booked on \(PropertyDates.isoDay(debit.date))"]
                if let word = BBVADebitAdvice.namedWord(debit.rawDescription, in: advice) {
                    reasons.append("Its description's \(word) is named in the advice")
                }
                return LinkCandidate(entity: .transaction(id), label: try entityLabel(db: db, .transaction(id)), reasons: reasons)
            }
            let reason = named.count >= 2 ? "\(named.count) debits fit this advice: which one is it?"
                : "A debit fits the amount and date, but its description doesn't name the advice's creditor or reference: is it this one?"
            item.issues.append(ImportIssue(id: "chooseLink", kind: .chooseLink(candidates), reason: reason, offers: [.fileWithoutLink]))
        } else {
            setAmount(&item, advice.amount, source: source, reason: "Amount on the advice")
            item.notes.append("Not linked: no matching debit yet")
        }
        item.placement = ImportNaming.placement(kind: recognition.kind, facts: item.facts, file: file, persons: [])
        return item
    }

    private func setAmount(_ item: inout ImportItem, _ amount: Int?, source: ImportFactSource, reason: String) {
        guard let amount else { return }
        item.facts.append(ImportFact(field: .amount, value: .money(amount, .eur), source: source, confidence: .certain, reason: reason))
    }
}
