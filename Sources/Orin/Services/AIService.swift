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

/// Stable interface surface retained after the EPIC-02 inference refactor.
///
/// All HTTP and inference logic has moved to `InferenceWorker` + concrete
/// `InferenceProvider` implementations.  This class is kept for:
///
/// - Keychain account name constants (used by Settings and keychain helpers)
/// - `resolvedOllamaModel()` / `resolvedOllamaEndpoint()` (used by perf logging)
/// - `selectProvider()` (testable pure function for provider selection logic)
/// - Registration with `ServiceContainer` (Settings views resolve it by type)
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

    // MARK: - Configuration helpers

    func resolvedOllamaEndpoint() -> String {
        let stored = UserDefaults.standard.string(forKey: "orin.ai.ollamaEndpoint") ?? ""
        return stored.isEmpty ? config.localOllamaEndpoint : stored
    }

    func resolvedOllamaModel() -> String {
        let stored = UserDefaults.standard.string(forKey: "orin.ai.ollamaModel") ?? ""
        return stored.isEmpty ? "mistral" : stored
    }
}
