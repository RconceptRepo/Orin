import Foundation
import Observation

/// Tests live connectivity for each configured AI provider.
/// Status transitions: unknown → testing → connected | failed | notConfigured.
/// All state mutations happen on @MainActor so @Observable drives SwiftUI updates directly.
@Observable
final class AIProviderTestService: Service, @unchecked Sendable {

    private(set) var ollamaStatus:    ProviderConnectionStatus = .unknown
    private(set) var openAIStatus:    ProviderConnectionStatus = .unknown
    private(set) var anthropicStatus: ProviderConnectionStatus = .unknown
    private(set) var geminiStatus:    ProviderConnectionStatus = .unknown

    // MARK: - Ollama

    @MainActor
    func testOllama(endpoint: String) async {
        ollamaStatus = .testing

        // Step 1: health check + model list
        guard let tagURL = URL(string: "\(endpoint)/api/tags") else {
            ollamaStatus = .failed(reason: "Invalid endpoint URL.")
            return
        }
        var healthReq = URLRequest(url: tagURL)
        healthReq.timeoutInterval = 5

        let tagData: Data
        do {
            let (data, response) = try await URLSession.shared.data(for: healthReq)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                ollamaStatus = .failed(reason: "Ollama returned HTTP \(code). Is Ollama running?")
                return
            }
            tagData = data
        } catch let err as URLError where err.code == .timedOut {
            ollamaStatus = .failed(reason: "Connection timed out. Is Ollama running at \(endpoint)?")
            return
        } catch {
            ollamaStatus = .failed(reason: "Cannot reach Ollama at \(endpoint). Start Ollama and try again.")
            return
        }

        // Step 2: verify a usable model is installed
        let json = (try? JSONSerialization.jsonObject(with: tagData)) as? [String: Any]
        let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        guard !models.isEmpty else {
            ollamaStatus = .failed(reason: "Ollama is running but no models are installed. Run: ollama pull llama3")
            return
        }
        let modelName = models.first(where: { $0.hasPrefix("llama3") }) ?? models[0]

        // Step 3: inference test — confirms the model actually responds
        guard let genURL = URL(string: "\(endpoint)/api/generate") else {
            ollamaStatus = .connected
            return
        }
        var genReq = URLRequest(url: genURL)
        genReq.httpMethod = "POST"
        genReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        genReq.timeoutInterval = 20
        genReq.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": modelName, "prompt": "Say hello.", "stream": false
        ])

        do {
            let (_, genResponse) = try await URLSession.shared.data(for: genReq)
            if (genResponse as? HTTPURLResponse)?.statusCode == 200 {
                ollamaStatus = .connected
            } else {
                ollamaStatus = .failed(reason: "Ollama inference failed. The model may still be loading — try again.")
            }
        } catch let err as URLError where err.code == .timedOut {
            ollamaStatus = .failed(reason: "Inference timed out. Model is likely still loading — try again in a moment.")
        } catch {
            ollamaStatus = .failed(reason: "Inference error: \(error.localizedDescription)")
        }
    }

    // MARK: - OpenAI

    /// Validates `key` if provided; falls back to the keychain-stored key.
    @MainActor
    func testOpenAI(key: String? = nil) async {
        let resolvedKey: String
        if let k = key, !k.isEmpty {
            resolvedKey = k
        } else if let k = AIKeychainService.load(account: AIService.openAIAccount) {
            resolvedKey = k
        } else {
            openAIStatus = .notConfigured
            return
        }

        openAIStatus = .testing
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(resolvedKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini",
            "messages": [["role": "user", "content": "Say hello."]],
            "max_tokens": 5
        ])

        await performTest(
            request: request,
            successCodes: [200],
            statusSetter: { [weak self] in self?.openAIStatus = $0 },
            errorMap: [
                401: "Invalid API key. Verify your OpenAI key at platform.openai.com.",
                429: "Rate limited or monthly quota exceeded.",
            ],
            defaultError: "OpenAI"
        )
    }

    // MARK: - Anthropic (Claude)

    @MainActor
    func testAnthropic(key: String? = nil) async {
        let resolvedKey: String
        if let k = key, !k.isEmpty {
            resolvedKey = k
        } else if let k = AIKeychainService.load(account: AIService.anthropicAccount) {
            resolvedKey = k
        } else {
            anthropicStatus = .notConfigured
            return
        }

        anthropicStatus = .testing
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(resolvedKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 5,
            "messages": [["role": "user", "content": "Say hello."]]
        ])

        await performTest(
            request: request,
            successCodes: [200],
            statusSetter: { [weak self] in self?.anthropicStatus = $0 },
            errorMap: [
                401: "Invalid API key. Verify your Anthropic key at console.anthropic.com.",
                403: "Access denied. Check your Anthropic key permissions.",
                429: "Rate limited or credits exhausted.",
            ],
            defaultError: "Claude"
        )
    }

    // MARK: - Gemini

    @MainActor
    func testGemini(key: String? = nil) async {
        let resolvedKey: String
        if let k = key, !k.isEmpty {
            resolvedKey = k
        } else if let k = AIKeychainService.load(account: AIService.geminiAccount) {
            resolvedKey = k
        } else {
            geminiStatus = .notConfigured
            return
        }

        geminiStatus = .testing
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(resolvedKey)"
        guard let url = URL(string: urlString) else {
            geminiStatus = .failed(reason: "Could not form URL. Verify the key contains no special characters.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": "Say hello."]]]]
        ])

        await performTest(
            request: request,
            successCodes: [200],
            statusSetter: { [weak self] in self?.geminiStatus = $0 },
            errorMap: [
                400: "Bad request. Verify your Gemini API key at aistudio.google.com.",
                403: "Invalid API key or API not enabled for this project.",
                429: "Rate limited or quota exceeded.",
            ],
            defaultError: "Gemini"
        )
    }

    // MARK: - Shared HTTP test runner

    private func performTest(
        request: URLRequest,
        successCodes: [Int],
        statusSetter: @MainActor @escaping (ProviderConnectionStatus) -> Void,
        errorMap: [Int: String],
        defaultError providerName: String
    ) async {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if successCodes.contains(code) {
                await statusSetter(.connected)
            } else if let msg = errorMap[code] {
                await statusSetter(.failed(reason: msg))
            } else {
                await statusSetter(.failed(reason: "\(providerName) returned HTTP \(code)."))
            }
        } catch let err as URLError where err.code == .timedOut {
            await statusSetter(.failed(reason: "Request timed out. Check your internet connection."))
        } catch {
            await statusSetter(.failed(reason: error.localizedDescription))
        }
    }
}
