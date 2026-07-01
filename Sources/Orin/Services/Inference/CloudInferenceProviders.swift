import Foundation
import OSLog

private let log = Logger(subsystem: "com.clavrit.orin", category: "CloudProviders")

// MARK: - OpenAIProvider

/// Reads its API key from keychain at call time so keys added in Settings are
/// honoured immediately — no app restart required.
final class OpenAIProvider: InferenceProvider, @unchecked Sendable {
    var name: String { "OpenAI" }
    var modelName: String { "gpt-4o-mini" }

    func infer(_ request: InferenceRequest) async throws -> String {
        guard let apiKey = AIKeychainService.load(account: AIService.openAIAccount),
              !apiKey.isEmpty else {
            throw InferenceError.allProvidersFailed
        }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw InferenceError.allProvidersFailed
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 45

        let body: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": request.prompt]],
            "max_tokens": request.maxTokens,
            "temperature": 0
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            log.warning("OpenAI returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            throw InferenceError.allProvidersFailed
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let text = (message?["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw InferenceError.allProvidersFailed
        }
        return text
    }

    func isAvailable() async -> Bool {
        guard let key = AIKeychainService.load(account: AIService.openAIAccount) else { return false }
        return !key.isEmpty
    }
}

// MARK: - AnthropicProvider

/// Reads its API key from keychain at call time so keys added in Settings are
/// honoured immediately — no app restart required.
final class AnthropicProvider: InferenceProvider, @unchecked Sendable {
    var name: String { "Anthropic" }
    var modelName: String { "claude-haiku-4-5-20251001" }

    func infer(_ request: InferenceRequest) async throws -> String {
        guard let apiKey = AIKeychainService.load(account: AIService.anthropicAccount),
              !apiKey.isEmpty else {
            throw InferenceError.allProvidersFailed
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw InferenceError.allProvidersFailed
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = 45

        let body: [String: Any] = [
            "model": modelName,
            "max_tokens": request.maxTokens,
            "temperature": 0,
            "messages": [["role": "user", "content": request.prompt]]
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            log.warning("Anthropic returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            throw InferenceError.allProvidersFailed
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        guard let text = (content?.first?["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw InferenceError.allProvidersFailed
        }
        return text
    }

    func isAvailable() async -> Bool {
        guard let key = AIKeychainService.load(account: AIService.anthropicAccount) else { return false }
        return !key.isEmpty
    }
}

// MARK: - GeminiProvider

/// Reads its API key from keychain at call time so keys added in Settings are
/// honoured immediately — no app restart required.
final class GeminiProvider: InferenceProvider, @unchecked Sendable {
    var name: String { "Gemini" }
    var modelName: String { "gemini-1.5-flash" }

    func infer(_ request: InferenceRequest) async throws -> String {
        guard let apiKey = AIKeychainService.load(account: AIService.geminiAccount),
              !apiKey.isEmpty else {
            throw InferenceError.allProvidersFailed
        }
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw InferenceError.allProvidersFailed
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 45

        let body: [String: Any] = [
            "contents": [["parts": [["text": request.prompt]]]],
            "generationConfig": ["maxOutputTokens": request.maxTokens, "temperature": 0]
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            log.warning("Gemini returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            throw InferenceError.allProvidersFailed
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = json?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        guard let text = (parts?.first?["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw InferenceError.allProvidersFailed
        }
        return text
    }

    func isAvailable() async -> Bool {
        guard let key = AIKeychainService.load(account: AIService.geminiAccount) else { return false }
        return !key.isEmpty
    }
}

// MARK: - MockInferenceProvider

/// Deterministic provider for unit and integration tests.
///
/// Inject at the composition root in DEBUG builds to run the full inference
/// pipeline without network access.
final class MockInferenceProvider: InferenceProvider, @unchecked Sendable {
    let name: String
    let modelName: String

    var responseText: String
    var shouldFail: Bool
    var simulatedDelaySeconds: Double

    init(
        name: String = "Mock",
        modelName: String = "mock-model",
        responseText: String = "",
        shouldFail: Bool = false,
        simulatedDelaySeconds: Double = 0.01
    ) {
        self.name = name
        self.modelName = modelName
        self.responseText = responseText
        self.shouldFail = shouldFail
        self.simulatedDelaySeconds = simulatedDelaySeconds
    }

    func infer(_ request: InferenceRequest) async throws -> String {
        if simulatedDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelaySeconds * 1e9))
        }
        if shouldFail { throw InferenceError.allProvidersFailed }
        return responseText
    }

    func isAvailable() async -> Bool { !shouldFail }
}
