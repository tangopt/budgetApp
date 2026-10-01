// Sources/BudgetCore/Categorization/OnDeviceCategorizer.swift
import Foundation
import FoundationModels

public struct CategorySuggestion: Equatable {
    public let categoryName: String
    public let confidence: Double

    public init(categoryName: String, confidence: Double) {
        self.categoryName = categoryName
        self.confidence = confidence
    }
}

public protocol Categorizing {
    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion?
    /// Batched form of `suggestCategory`: one model call for many descriptions instead of
    /// one call per description. Returns one result per input description, in the same
    /// order — `nil` at a given position means "no suggestion for that one", exactly like
    /// the single-item method's `nil` return.
    func suggestCategories(descriptions: [String], candidateCategoryNames: [String]) async throws -> [CategorySuggestion?]
}

/// Abstraction over "something that can turn a transaction description into a category
/// guess" — lets `OnDeviceCategorizer` be tested with a stub instead of invoking the real
/// on-device model (which is slow and non-deterministic in a unit test).
public protocol GenerativeSession {
    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion?
    func suggestCategories(descriptions: [String], candidateCategoryNames: [String]) async throws -> [CategorySuggestion?]
}

@Generable
struct CategoryGuess {
    @Guide(description: "The single best-matching category name, copied exactly from the provided list")
    let categoryName: String
    @Guide(description: "Confidence in this categorization, from 0.0 (unsure) to 1.0 (certain)", .range(0.0...1.0))
    let confidence: Double
}

@Generable
struct BatchCategoryGuesses {
    @Guide(description: "One guess per transaction, in the exact same order as the numbered transactions given in the prompt — never fewer or more than the number given")
    let guesses: [CategoryGuess]
}

/// Real implementation, wrapping Apple's on-device `LanguageModelSession`. No API key, no
/// network call — verified to type-check and run correctly against this SDK.
public final class FoundationModelsSession: GenerativeSession {
    public init() {}

    public func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? {
        let session = LanguageModelSession()
        let prompt = """
        Categorize this UK bank transaction description into exactly one of these categories: \(candidateCategoryNames.joined(separator: ", ")).
        Transaction description: "\(description)"
        """
        let response = try await session.respond(to: prompt, generating: CategoryGuess.self)
        let guess = response.content
        guard candidateCategoryNames.contains(guess.categoryName) else { return nil }
        return CategorySuggestion(categoryName: guess.categoryName, confidence: guess.confidence)
    }

    /// One model call covering every description in `descriptions`, instead of one call
    /// per description — the fix for bulk CSV/PDF import being slow (a few hundred
    /// transactions previously meant a few hundred sequential on-device model calls).
    ///
    /// Safety: if the model's response doesn't have exactly as many guesses as
    /// descriptions given (it skipped, merged, or hallucinated an extra item — a real risk
    /// with structured generation over a list), this discards the whole batch's guesses
    /// and returns `nil` for every position rather than risk pairing a guess with the
    /// wrong transaction by position. Worse case is "no suggestion", same as an
    /// unavailable model — never a silently wrong category.
    public func suggestCategories(descriptions: [String], candidateCategoryNames: [String]) async throws -> [CategorySuggestion?] {
        guard !descriptions.isEmpty else { return [] }
        let session = LanguageModelSession()
        let numbered = descriptions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        Categorize each of these \(descriptions.count) UK bank transaction descriptions into exactly one of these categories: \(candidateCategoryNames.joined(separator: ", ")).
        Return exactly \(descriptions.count) guesses, one per transaction, in the same order as the numbered list below. Do not skip, merge, or add any.

        \(numbered)
        """
        let response = try await session.respond(to: prompt, generating: BatchCategoryGuesses.self)
        let guesses = response.content.guesses
        guard guesses.count == descriptions.count else {
            return Array(repeating: nil, count: descriptions.count)
        }
        return guesses.map { guess in
            guard candidateCategoryNames.contains(guess.categoryName) else { return nil }
            return CategorySuggestion(categoryName: guess.categoryName, confidence: guess.confidence)
        }
    }
}

/// Replaces the former Claude-API-backed categorizer — same `Categorizing` conformance, so
/// `CategorizationService`'s rules-first-then-fallback-then-uncategorized chain needs no
/// changes. Checks model availability before ever invoking the session, so a Mac without
/// Apple Intelligence enabled (or too old to support it) degrades to "no suggestion"
/// exactly like a missing API key did — never crashes, never blocks import.
public final class OnDeviceCategorizer: Categorizing {
    private let session: GenerativeSession
    private let isAvailable: () -> Bool

    public init(session: GenerativeSession, isAvailable: @escaping () -> Bool) {
        self.session = session
        self.isAvailable = isAvailable
    }

    public func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? {
        guard isAvailable() else { return nil }
        return try await session.suggestCategory(description: description, candidateCategoryNames: candidateCategoryNames)
    }

    public func suggestCategories(descriptions: [String], candidateCategoryNames: [String]) async throws -> [CategorySuggestion?] {
        guard isAvailable() else { return Array(repeating: nil, count: descriptions.count) }
        return try await session.suggestCategories(descriptions: descriptions, candidateCategoryNames: candidateCategoryNames)
    }

    /// Production convenience: the real on-device session, checked against the real
    /// system availability at call time (not cached at construction, so the app reacts
    /// correctly if the user enables/disables Apple Intelligence while it's running).
    public static func systemDefault() -> OnDeviceCategorizer {
        OnDeviceCategorizer(
            session: FoundationModelsSession(),
            isAvailable: { SystemLanguageModel.default.availability == .available }
        )
    }
}
