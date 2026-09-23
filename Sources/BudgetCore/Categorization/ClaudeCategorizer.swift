import Foundation

public struct CategorySuggestion: Equatable {
    public let categoryName: String
    public let confidence: Double
}

public protocol Categorizing {
    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion?
}

public enum CategorizerError: Error {
    case missingAPIKey
    case requestFailed
    case unparsableResponse
}

public final class ClaudeCategorizer: Categorizing {
    private let apiKeyStore: APIKeyStoring
    private let session: URLSession
    private let model = "claude-sonnet-5"

    public init(apiKeyStore: APIKeyStoring, session: URLSession) {
        self.apiKeyStore = apiKeyStore
        self.session = session
    }

    public func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? {
        guard let apiKey = apiKeyStore.getAPIKey(), !apiKey.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        Categorize this UK bank transaction description into exactly one of these categories: \(candidateCategoryNames.joined(separator: ", ")).
        Transaction description: "\(description)"
        Respond with ONLY a JSON object: {"categoryName": "<one of the categories above>", "confidence": <0.0-1.0>}
        """
        // claude-sonnet-5 runs adaptive thinking when `thinking` is omitted, and thinking
        // tokens count toward max_tokens — 256 could be exhausted before the answer.
        // Low effort keeps this trivial classification cheap and fast.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "output_config": ["effort": "low"],
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CategorizerError.requestFailed
        }

        guard let suggestion = Self.parseSuggestion(fromResponseData: data) else {
            throw CategorizerError.unparsableResponse
        }
        return suggestion
    }

    /// Parses a Messages API response body. The `content` array may start with a
    /// `thinking` (or `redacted_thinking`) block before the `text` block, so the answer
    /// is taken from the `text`-typed block(s), never blindly from `content.first`.
    /// The text itself may be wrapped in a markdown code fence (```json … ```) or have
    /// stray prose around the JSON object; both are tolerated.
    static func parseSuggestion(fromResponseData data: Data) -> CategorySuggestion? {
        guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = envelope["content"] as? [[String: Any]] else { return nil }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty,
              let parsed = jsonObject(inModelText: text),
              let categoryName = parsed["categoryName"] as? String,
              let confidence = (parsed["confidence"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CategorySuggestion(categoryName: categoryName, confidence: confidence)
    }

    static func jsonObject(inModelText text: String) -> [String: Any]? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            // Drop the opening fence line (``` or ```json) and a closing fence.
            if let firstNewline = candidate.firstIndex(of: "\n") {
                candidate = String(candidate[candidate.index(after: firstNewline)...])
            } else {
                candidate = String(candidate.dropFirst(3))
            }
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasSuffix("```") {
                candidate = String(candidate.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let object = decodeObject(candidate) { return object }
        // Last resort: the outermost {...} span, for JSON surrounded by prose.
        guard let open = candidate.firstIndex(of: "{"), let close = candidate.lastIndex(of: "}"), open < close else { return nil }
        return decodeObject(String(candidate[open...close]))
    }

    private static func decodeObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
