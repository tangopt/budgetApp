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
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CategorizerError.requestFailed
        }

        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = envelope["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let textData = text.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: textData) as? [String: Any],
              let categoryName = parsed["categoryName"] as? String,
              let confidence = parsed["confidence"] as? Double else {
            throw CategorizerError.unparsableResponse
        }

        return CategorySuggestion(categoryName: categoryName, confidence: confidence)
    }
}
