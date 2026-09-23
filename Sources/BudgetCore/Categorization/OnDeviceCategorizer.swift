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
}

/// Abstraction over "something that can turn a transaction description into a category
/// guess" — lets `OnDeviceCategorizer` be tested with a stub instead of invoking the real
/// on-device model (which is slow and non-deterministic in a unit test).
public protocol GenerativeSession {
    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion?
}

@Generable
struct CategoryGuess {
    @Guide(description: "The single best-matching category name, copied exactly from the provided list")
    let categoryName: String
    @Guide(description: "Confidence in this categorization, from 0.0 (unsure) to 1.0 (certain)", .range(0.0...1.0))
    let confidence: Double
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
}

/// Replaces `ClaudeCategorizer` — same `Categorizing` conformance, so
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
