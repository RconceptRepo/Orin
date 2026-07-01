import Foundation
import OSLog

private let log = Logger(subsystem: "com.clavrit.orin", category: "OllamaProvider")

// MARK: - OllamaProvider

/// The single component in the application that communicates with Ollama.
///
/// All HTTP mechanics for the local Ollama endpoint live here and ONLY here.
/// `InferenceWorker` is responsible for retry policy, circuit-breaking, and
/// provider selection; `OllamaProvider` is responsible for executing one request.
///
/// ## Configuration
///
/// Endpoint and model are read from `UserDefaults` on every call so changes
/// in Settings take effect immediately without restarting the app.
final class OllamaProvider: InferenceProvider, @unchecked Sendable {

    var name: String { "Ollama" }

    var modelName: String { resolvedModel() }

    // MARK: - InferenceProvider

    func infer(_ request: InferenceRequest) async throws -> String {
        let endpoint = resolvedEndpoint()
        let model    = resolvedModel()
        guard let url = URL(string: "\(endpoint)/api/generate") else {
            throw InferenceError.allProvidersFailed
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 60

        let payload: [String: Any] = [
            "model":   model,
            "prompt":  request.prompt,
            "stream":  false,
            "options": ["num_predict": request.maxTokens, "temperature": 0]
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        AnalysisPerfLogger.event(
            "Ollama request started model=\(model)"
            + " promptChars=\(request.prompt.count)"
            + " maxTokens=\(request.maxTokens)"
        )
        let callStart = ContinuousClock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let err as URLError where err.code == .timedOut {
            let elapsed = ContinuousClock.now - callStart
            AnalysisPerfLogger.event(
                String(format: "Ollama TIMEOUT after %.1fs", elapsed.components.seconds)
            )
            log.warning("Ollama request timed out (60s)")
            throw InferenceError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AnalysisPerfLogger.event("Ollama request FAILED error=\(error.localizedDescription)")
            log.warning("Ollama request failed: \(error)")
            throw error
        }

        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let elapsed = ContinuousClock.now - callStart
            AnalysisPerfLogger.event(
                String(format: "Ollama HTTP %d duration=%.2fs", code, elapsed.components.seconds)
            )
            throw InferenceError.allProvidersFailed
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = (json?["response"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw InferenceError.allProvidersFailed
        }

        let elapsed = ContinuousClock.now - callStart
        let elapsedSec = Double(elapsed.components.seconds)
                       + Double(elapsed.components.attoseconds) / 1e18
        AnalysisPerfLogger.event(
            String(format: "Ollama response OK duration=%.2fs responseChars=%d",
                   elapsedSec, text.count)
        )
        return text
    }

    func isAvailable() async -> Bool {
        let endpoint = resolvedEndpoint()
        guard let url = URL(string: "\(endpoint)/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            log.debug("Ollama availability check failed: \(error)")
            return false
        }
    }

    // MARK: - Configuration

    /// Reads the Ollama endpoint from UserDefaults, falling back to localhost.
    func resolvedEndpoint() -> String {
        let stored = UserDefaults.standard.string(forKey: "orin.ai.ollamaEndpoint") ?? ""
        return stored.isEmpty ? "http://localhost:11434" : stored
    }

    /// Reads the active Ollama model from UserDefaults, falling back to "mistral".
    func resolvedModel() -> String {
        let stored = UserDefaults.standard.string(forKey: "orin.ai.ollamaModel") ?? ""
        return stored.isEmpty ? "mistral" : stored
    }
}
