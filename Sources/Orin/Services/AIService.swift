import Foundation
import OSLog

private let aiLogger = Logger(subsystem: "com.clavrit.orin", category: "AIService")

enum AIProvider: String {
    case ollama
    case openAI
    case anthropic
    case gemini
}

enum ProviderConnectionStatus: Equatable {
    case unknown
    case testing
    case connected
    case failed(reason: String)
    case notConfigured

    var displayLabel: String {
        switch self {
        case .unknown:        "Not tested"
        case .testing:        "Testing..."
        case .connected:      "Connected"
        case .failed:         "Failed"
        case .notConfigured:  "Not configured"
        }
    }
}

struct AIConfiguration {
    var primaryProvider: AIProvider
    var localOllamaEndpoint = "http://localhost:11434"
}

final class AIService: Service {
    private var config: AIConfiguration

    static let openAIAccount    = "openai"
    static let anthropicAccount = "anthropic"
    static let geminiAccount    = "gemini"

    init(config: AIConfiguration) {
        self.config = config
    }

    // MARK: - Provider selection (testable pure function)

    /// Returns the first available provider given the current availability state.
    /// Priority: Ollama → OpenAI → Claude → Gemini.
    func selectProvider(
        ollamaAvailable: Bool,
        openAIKey: String?,
        anthropicKey: String?,
        geminiKey: String?
    ) -> AIProvider? {
        if ollamaAvailable        { return .ollama }
        if openAIKey != nil       { return .openAI }
        if anthropicKey != nil    { return .anthropic }
        if geminiKey != nil       { return .gemini }
        return nil
    }

    // MARK: - Generic prompt completion (preferred for structured analysis)
    //
    // Sends `prompt` to providers without wrapping it in `summaryPrompt`.
    // Use this when callers control the full prompt (e.g. MeetingIntelligenceService).
    // Returns (text, fallbackUsed: true) when all providers fail.

    func generate(prompt: String, maxTokens: Int = 1500) async -> (text: String, fallbackUsed: Bool) {
        let endpoint = resolvedOllamaEndpoint()

        if await isOllamaAvailable(endpoint: endpoint) {
            if let result = await callOllama(prompt: prompt, maxTokens: maxTokens) {
                return (result, false)
            }
        }
        if let key = AIKeychainService.load(account: Self.openAIAccount),
           let result = await callOpenAI(prompt: prompt, key: key, maxTokens: maxTokens) {
            return (result, false)
        }
        if let key = AIKeychainService.load(account: Self.anthropicAccount),
           let result = await callAnthropic(prompt: prompt, key: key, maxTokens: maxTokens) {
            return (result, false)
        }
        if let key = AIKeychainService.load(account: Self.geminiAccount),
           let result = await callGemini(prompt: prompt, key: key, maxTokens: maxTokens) {
            return (result, false)
        }
        return ("", true)
    }

    // MARK: - Summary generation (legacy — wraps prompt in summaryPrompt)

    /// Tries providers in fixed priority order: Ollama → OpenAI → Claude → Gemini.
    /// Returns (text, fallbackUsed: true) when all providers fail so callers can
    /// substitute local text extraction.
    func generateSummary(for transcript: String) async -> (text: String, fallbackUsed: Bool) {
        let result = await generate(prompt: summaryPrompt(for: transcript), maxTokens: 512)
        if result.fallbackUsed && result.text.isEmpty {
            return ("No AI provider available. Start Ollama locally or add an API key in Settings → AI.", true)
        }
        return result
    }

    // MARK: - Ollama availability check

    func isOllamaAvailable(endpoint: String) async -> Bool {
        guard let url = URL(string: "\(endpoint)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            // Expected when Ollama is not running — fallback to next provider
            aiLogger.debug("Ollama availability check failed: \(error)")
            return false
        }
    }

    // MARK: - Provider implementations (generic prompt)

    private func callOllama(prompt: String, maxTokens: Int) async -> String? {
        let endpoint = resolvedOllamaEndpoint()
        guard let url = URL(string: "\(endpoint)/api/generate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60  // longer for comprehensive analysis

        let payload: [String: Any] = [
            "model": "mistral",
            "prompt": prompt,
            "stream": false,
            "options": ["num_predict": maxTokens]
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            aiLogger.warning("Ollama request failed: \(error) — trying next provider")
            return nil
        }
    }

    private func callOpenAI(prompt: String, key: String, maxTokens: Int) async -> String? {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            return (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            aiLogger.warning("OpenAI request failed: \(error) — trying next provider")
            return nil
        }
    }

    private func callAnthropic(prompt: String, key: String, maxTokens: Int) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 45

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = json?["content"] as? [[String: Any]]
            return (content?.first?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            aiLogger.warning("Anthropic request failed: \(error) — trying next provider")
            return nil
        }
    }

    private func callGemini(prompt: String, key: String, maxTokens: Int) async -> String? {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(key)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["maxOutputTokens": maxTokens]
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let candidates = json?["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            return (parts?.first?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            aiLogger.warning("Gemini request failed: \(error) — all providers exhausted")
            return nil
        }
    }

    // MARK: - Helpers

    private func summaryPrompt(for transcript: String) -> String {
        "Summarize this meeting transcript accurately. Focus on decisions made, commitments given, and next actions required:\n\n\(transcript)"
    }

    private func resolvedOllamaEndpoint() -> String {
        let stored = UserDefaults.standard.string(forKey: "orin.ai.ollamaEndpoint") ?? ""
        return stored.isEmpty ? config.localOllamaEndpoint : stored
    }
}
