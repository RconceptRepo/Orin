import Foundation

enum AIProvider: String {
    case ollama
    case openAI
    case anthropic
    case gemini
}

struct AIConfiguration {
    var primaryProvider: AIProvider
    var localOllamaEndpoint = "http://localhost:11434"
}

final class AIService: Service {
    private var config: AIConfiguration

    // Keychain account identifiers for external provider keys
    static let openAIAccount    = "openai"
    static let anthropicAccount = "anthropic"
    static let geminiAccount    = "gemini"

    init(config: AIConfiguration) {
        self.config = config
    }

    func updateOllamaEndpoint(_ endpoint: String) {
        config.localOllamaEndpoint = endpoint
    }

    // MARK: - Summary generation with fallover

    /// Returns (summaryText, fallbackWasUsed).
    /// Reads the current provider and endpoint from UserDefaults at call time so Settings
    /// changes take effect immediately without restarting the service.
    func generateSummary(for transcript: String) async -> (text: String, fallbackUsed: Bool) {
        let providerRaw = UserDefaults.standard.string(forKey: "orin.ai.provider") ?? config.primaryProvider.rawValue
        let provider = AIProvider(rawValue: providerRaw) ?? config.primaryProvider
        if let endpoint = UserDefaults.standard.string(forKey: "orin.ai.ollamaEndpoint"), !endpoint.isEmpty {
            config.localOllamaEndpoint = endpoint
        }

        switch provider {
        case .ollama:
            let result = await generateOllamaSummary(transcript: transcript)
            return (result ?? "Ollama is unavailable. Verify it is running at \(config.localOllamaEndpoint).", false)

        case .openAI:
            if let key = AIKeychainService.load(account: Self.openAIAccount),
               let result = await generateOpenAISummary(transcript: transcript, key: key) {
                return (result, false)
            }
            return await ollamaFallback(transcript: transcript, from: "OpenAI")

        case .anthropic:
            if let key = AIKeychainService.load(account: Self.anthropicAccount),
               let result = await generateAnthropicSummary(transcript: transcript, key: key) {
                return (result, false)
            }
            return await ollamaFallback(transcript: transcript, from: "Claude")

        case .gemini:
            if let key = AIKeychainService.load(account: Self.geminiAccount),
               let result = await generateGeminiSummary(transcript: transcript, key: key) {
                return (result, false)
            }
            return await ollamaFallback(transcript: transcript, from: "Gemini")
        }
    }

    private func ollamaFallback(transcript: String, from provider: String) async -> (text: String, fallbackUsed: Bool) {
        if let local = await generateOllamaSummary(transcript: transcript) {
            return ("External AI (\(provider)) unavailable. Using Local AI.\n\n\(local)", true)
        }
        return ("External AI (\(provider)) unavailable. Local AI also failed. Verify Ollama is running at \(config.localOllamaEndpoint).", true)
    }

    // MARK: - Ollama (local)

    private func generateOllamaSummary(transcript: String) async -> String? {
        guard let url = URL(string: "\(config.localOllamaEndpoint)/api/generate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "model": "llama3",
            "prompt": summaryPrompt(for: transcript),
            "stream": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - OpenAI

    private func generateOpenAISummary(transcript: String, key: String) async -> String? {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [["role": "user", "content": summaryPrompt(for: transcript)]],
            "max_tokens": 512
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
            return nil
        }
    }

    // MARK: - Anthropic (Claude)

    private func generateAnthropicSummary(transcript: String, key: String) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 512,
            "messages": [["role": "user", "content": summaryPrompt(for: transcript)]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = json?["content"] as? [[String: Any]]
            return (content?.first?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Gemini

    private func generateGeminiSummary(transcript: String, key: String) async -> String? {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(key)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "contents": [["parts": [["text": summaryPrompt(for: transcript)]]]]
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
            return nil
        }
    }

    // MARK: - Shared prompt

    private func summaryPrompt(for transcript: String) -> String {
        "Summarize this meeting transcript accurately. Focus on decisions made, commitments given, and next actions required:\n\n\(transcript)"
    }
}
