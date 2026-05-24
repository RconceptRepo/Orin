import XCTest
@testable import Orin

@MainActor
final class AIProviderTests: XCTestCase {

    // MARK: - Provider selection — pure routing logic (no network required)

    func testSelectProviderPrioritizesOllama() {
        let service = AIService(config: AIConfiguration(primaryProvider: .ollama))
        XCTAssertEqual(
            service.selectProvider(ollamaAvailable: true, openAIKey: "k", anthropicKey: "k", geminiKey: "k"),
            .ollama
        )
    }

    func testSelectProviderFallsToOpenAI() {
        let service = AIService(config: AIConfiguration(primaryProvider: .ollama))
        XCTAssertEqual(
            service.selectProvider(ollamaAvailable: false, openAIKey: "sk-123", anthropicKey: nil, geminiKey: nil),
            .openAI
        )
    }

    func testSelectProviderFallsToAnthropic() {
        let service = AIService(config: AIConfiguration(primaryProvider: .ollama))
        XCTAssertEqual(
            service.selectProvider(ollamaAvailable: false, openAIKey: nil, anthropicKey: "sk-ant-123", geminiKey: nil),
            .anthropic
        )
    }

    func testSelectProviderFallsToGemini() {
        let service = AIService(config: AIConfiguration(primaryProvider: .ollama))
        XCTAssertEqual(
            service.selectProvider(ollamaAvailable: false, openAIKey: nil, anthropicKey: nil, geminiKey: "gemini-123"),
            .gemini
        )
    }

    func testSelectProviderReturnsNilWhenAllUnavailable() {
        let service = AIService(config: AIConfiguration(primaryProvider: .ollama))
        XCTAssertNil(
            service.selectProvider(ollamaAvailable: false, openAIKey: nil, anthropicKey: nil, geminiKey: nil)
        )
    }

    func testSelectProviderPreferrsOpenAIOverAnthropic() {
        let service = AIService(config: AIConfiguration(primaryProvider: .ollama))
        XCTAssertEqual(
            service.selectProvider(ollamaAvailable: false, openAIKey: "sk-123", anthropicKey: "sk-ant-123", geminiKey: nil),
            .openAI
        )
    }

    func testSelectProviderPreferrsAnthropicOverGemini() {
        let service = AIService(config: AIConfiguration(primaryProvider: .ollama))
        XCTAssertEqual(
            service.selectProvider(ollamaAvailable: false, openAIKey: nil, anthropicKey: "sk-ant", geminiKey: "gem"),
            .anthropic
        )
    }

    // MARK: - ProviderConnectionStatus display labels

    func testUnknownStatusLabel() {
        XCTAssertEqual(ProviderConnectionStatus.unknown.displayLabel, "Not tested")
    }

    func testTestingStatusLabel() {
        XCTAssertEqual(ProviderConnectionStatus.testing.displayLabel, "Testing...")
    }

    func testConnectedStatusLabel() {
        XCTAssertEqual(ProviderConnectionStatus.connected.displayLabel, "Connected")
    }

    func testFailedStatusLabel() {
        XCTAssertEqual(ProviderConnectionStatus.failed(reason: "some error").displayLabel, "Failed")
    }

    func testNotConfiguredStatusLabel() {
        XCTAssertEqual(ProviderConnectionStatus.notConfigured.displayLabel, "Not configured")
    }

    // MARK: - ProviderConnectionStatus Equatable

    func testConnectedEquality() {
        XCTAssertEqual(ProviderConnectionStatus.connected, .connected)
    }

    func testFailedEqualityMatchesReason() {
        XCTAssertEqual(
            ProviderConnectionStatus.failed(reason: "err"),
            ProviderConnectionStatus.failed(reason: "err")
        )
    }

    func testFailedInequalityOnDifferentReasons() {
        XCTAssertNotEqual(
            ProviderConnectionStatus.failed(reason: "a"),
            ProviderConnectionStatus.failed(reason: "b")
        )
    }

    // MARK: - AIProviderTestService initial state

    func testTesterInitialStatusesAreUnknown() {
        let tester = AIProviderTestService()
        XCTAssertEqual(tester.ollamaStatus,    .unknown)
        XCTAssertEqual(tester.openAIStatus,    .unknown)
        XCTAssertEqual(tester.anthropicStatus, .unknown)
        XCTAssertEqual(tester.geminiStatus,    .unknown)
    }

    // MARK: - Unavailable provider / missing key paths

    func testOpenAITestSetsNotConfiguredWhenNoKey() async {
        let tester = AIProviderTestService()
        // Only run if no real key is present — deterministic in CI
        guard AIKeychainService.load(account: AIService.openAIAccount) == nil else { return }
        await tester.testOpenAI()
        XCTAssertEqual(tester.openAIStatus, .notConfigured)
    }

    func testAnthropicTestSetsNotConfiguredWhenNoKey() async {
        let tester = AIProviderTestService()
        guard AIKeychainService.load(account: AIService.anthropicAccount) == nil else { return }
        await tester.testAnthropic()
        XCTAssertEqual(tester.anthropicStatus, .notConfigured)
    }

    func testGeminiTestSetsNotConfiguredWhenNoKey() async {
        let tester = AIProviderTestService()
        guard AIKeychainService.load(account: AIService.geminiAccount) == nil else { return }
        await tester.testGemini()
        XCTAssertEqual(tester.geminiStatus, .notConfigured)
    }

    func testOllamaTestSetsFailedWhenEndpointUnreachable() async {
        let tester = AIProviderTestService()
        // Use a port that is guaranteed not to have Ollama
        await tester.testOllama(endpoint: "http://127.0.0.1:19999")
        if case .failed = tester.ollamaStatus { } else {
            XCTFail("Expected .failed but got \(tester.ollamaStatus)")
        }
    }

    // MARK: - Fallback chain: generateSummary returns fallbackUsed when nothing is available

    func testGenerateSummaryReturnsFallbackUsedWhenNoProvidersAvailable() async {
        // Use a non-existent Ollama endpoint so local AI is unavailable.
        // If no API keys are in keychain, all providers fail and fallbackUsed should be true.
        let noKeysInKeychain = AIKeychainService.load(account: AIService.openAIAccount) == nil
            && AIKeychainService.load(account: AIService.anthropicAccount) == nil
            && AIKeychainService.load(account: AIService.geminiAccount) == nil

        guard noKeysInKeychain else { return } // developer machine with real keys — skip

        let config = AIConfiguration(
            primaryProvider: .ollama,
            localOllamaEndpoint: "http://127.0.0.1:19999"
        )
        let service = AIService(config: config)
        let result = await service.generateSummary(for: "test transcript")
        XCTAssertTrue(result.fallbackUsed, "Expected fallbackUsed=true when no provider is reachable")
        XCTAssertFalse(result.text.isEmpty, "Error message must not be empty")
    }
}
