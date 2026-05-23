import Foundation

enum AIProvider {
    case ollama
    case openAI
    case anthropic
    case gemini
}

struct AIConfiguration {
    var primaryProvider: AIProvider
    var openAIKey: String?
    var anthropicKey: String?
    var geminiKey: String?
    var localOllamaEndpoint = "http://localhost:11434"
}

final class AIService: Service {
    private var config: AIConfiguration

    init(config: AIConfiguration) {
        self.config = config
    }

    func generateSummary(for transcript: String) async -> (text: String, fallbackUsed: Bool) {
        if let summary = await generateLocalSummary(transcript: transcript) {
            return (summary, false)
        }
        return ("Failed to run local summary inference. Please verify Ollama is running.", false)
    }

    private func generateLocalSummary(transcript: String) async -> String? {
        guard let url = URL(string: "\(config.localOllamaEndpoint)/api/generate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": "llama3",
            "prompt": "Summarize this meeting transcript accurately. Focus on decisions, commitments, and next actions:\n\n\(transcript)",
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
}
