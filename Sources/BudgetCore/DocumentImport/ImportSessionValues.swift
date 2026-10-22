// Sources/BudgetCore/DocumentImport/ImportSessionValues.swift
import Foundation

/// `ImportSession`'s value types and the stateless parts of its decisions: what each phase is,
/// what the review says when something fails, which transactions a plan names.
extension ImportSession {
    public enum Phase: Equatable, Sendable {
        /// Nothing in progress (the screen shows the history).
        case idle
        /// Files being read (into the open review, if there is one).
        case reading(ImportProgress)
        /// A plan waiting for the user.
        case review
        /// Confirm import pressed: the plan is being applied.
        case applying
        /// The last confirmed import.
        case finished(ImportRunSummary)
        /// Reading failed with no review to return to.
        case failed(String)
    }

    /// Why the open review couldn't be confirmed or changed (a filed return would move, the
    /// plan is out of date, a resolution failed): shown over the review, which stays open so
    /// the user can leave items out.
    public struct Problem: Equatable, Sendable {
        public var title: String
        public var lines: [String]

        public init(title: String, lines: [String]) {
            self.title = title
            self.lines = lines
        }
    }

    /// Why an answer to one question wasn't taken, shown beside that question (the item stays
    /// as it was): an "Import anyway" with a blank reason.
    public struct AnswerProblem: Equatable, Sendable {
        public var itemId: UUID
        public var issueId: String?
        public var message: String

        public init(itemId: UUID, issueId: String?, message: String) {
            self.itemId = itemId
            self.issueId = issueId
            self.message = message
        }
    }

    public struct RuleFitsReview: Identifiable, Equatable, Sendable {
        public let sourceId: UUID
        public var id: UUID { sourceId }

        public init(sourceId: UUID) {
            self.sourceId = sourceId
        }
    }

    public struct PendingUndo: Equatable, Sendable {
        public let itemId: UUID
        public let resolution: ImportResolution
        /// How many other documents the rule changed.
        public let others: Int

        public init(itemId: UUID, resolution: ImportResolution, others: Int) {
            self.itemId = itemId
            self.resolution = resolution
            self.others = others
        }
    }

    /// What the review says when Confirm import fails; `held`: the items the filed-year check
    /// now holds in Needs you (named first).
    public nonisolated static func problem(for error: Error, held: [String] = []) -> Problem {
        switch error {
        case ImportApplyError.notConfirmable:
            return Problem(title: "Settle everything in Needs you first", lines: [])
        case ImportApplyError.filedYearChanged(let impacts):
            let names = held.isEmpty ? [] : ["Held in Needs you: \(held.joined(separator: ", "))"]
            let lines = names + impacts.flatMap { [$0.headline] + $0.explanation }
            return Problem(title: "Nothing was imported: this import would change a filed return. Leave out the items that cause it.",
                           lines: lines)
        case ImportApplyError.planOutdated(let reason):
            return Problem(title: "Nothing was imported: the review is out of date. Leave the item out or import its file again.",
                           lines: [reason])
        default:
            return Problem(title: "Nothing was imported: \(error.localizedDescription)", lines: [])
        }
    }

    /// Every transaction the plan's items link to or a "which one?" offers.
    public nonisolated static func transactionIds(in plan: ImportPlan) -> [Int64] {
        var ids: [Int64] = []
        var seen = Set<Int64>()
        for item in plan.items {
            let offered = item.issues.flatMap { issue -> [EvidenceEntity] in
                if case .chooseLink(let candidates) = issue.kind { return candidates.map(\.entity) }
                return []
            }
            for entity in item.links.map(\.entity) + offered where entity.type == .transaction && seen.insert(entity.id).inserted {
                ids.append(entity.id)
            }
        }
        return ids
    }
}

extension Result where Failure == Error {
    /// `Result(catching:)` for an async body.
    static func catching(_ body: () async throws -> Success) async -> Result<Success, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
