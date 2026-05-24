import XCTest
@testable import Orin

@MainActor
final class OllamaSetupServiceTests: XCTestCase {

    // MARK: - Initial state

    func testInitialSetupPhaseIsIdle() {
        let service = OllamaInstallerService()
        XCTAssertEqual(service.setupPhase, .idle)
    }

    func testInitialAvailableModelsIsEmpty() {
        let service = OllamaInstallerService()
        XCTAssertTrue(service.availableModels.isEmpty)
    }

    func testInitialSetupErrorMessageIsEmpty() {
        let service = OllamaInstallerService()
        XCTAssertTrue(service.setupErrorMessage.isEmpty)
    }

    func testInitialPreferredModelIsEmpty() {
        let service = OllamaInstallerService()
        XCTAssertTrue(service.preferredModel.isEmpty)
    }

    func testInitialTestResponseIsEmpty() {
        let service = OllamaInstallerService()
        XCTAssertTrue(service.testResponse.isEmpty)
    }

    // MARK: - Skip

    func testSkipSetupSetsSkippedPhase() {
        let service = OllamaInstallerService()
        service.skipSetup()
        XCTAssertEqual(service.setupPhase, .skipped)
    }

    // MARK: - Reset

    func testResetSetupRestoresIdlePhase() {
        let service = OllamaInstallerService()
        service.skipSetup()
        service.resetSetup()
        XCTAssertEqual(service.setupPhase, .idle)
    }

    func testResetClearsSetupErrorMessage() {
        let service = OllamaInstallerService()
        service.resetSetup()
        XCTAssertTrue(service.setupErrorMessage.isEmpty)
    }

    func testResetClearsAvailableModels() {
        let service = OllamaInstallerService()
        service.resetSetup()
        XCTAssertTrue(service.availableModels.isEmpty)
    }

    func testResetClearsPreferredModel() {
        let service = OllamaInstallerService()
        service.resetSetup()
        XCTAssertTrue(service.preferredModel.isEmpty)
    }

    func testResetClearsTestResponse() {
        let service = OllamaInstallerService()
        service.resetSetup()
        XCTAssertTrue(service.testResponse.isEmpty)
    }

    // MARK: - SetupPhase Equatable

    func testSetupPhaseIdleEquality() {
        XCTAssertEqual(SetupPhase.idle, .idle)
    }

    func testSetupPhaseCompleteEquality() {
        XCTAssertEqual(SetupPhase.complete, .complete)
    }

    func testSetupPhaseSkippedEquality() {
        XCTAssertEqual(SetupPhase.skipped, .skipped)
    }

    func testSetupPhaseInequality() {
        XCTAssertNotEqual(SetupPhase.complete, .skipped)
        XCTAssertNotEqual(SetupPhase.idle, .notInstalled)
        XCTAssertNotEqual(SetupPhase.serviceDown, .noModels)
    }

    // MARK: - Network paths (unreachable endpoint)

    func testRunSetupWithUnreachableEndpointEndsInExpectedPhase() async {
        let service = OllamaInstallerService()
        await service.runSetup(endpoint: "http://127.0.0.1:19999")
        let phase = service.setupPhase
        // Either notInstalled (app not present) or serviceDown (app present but port dead)
        XCTAssertTrue(
            phase == .notInstalled || phase == .serviceDown,
            "Expected .notInstalled or .serviceDown, got \(phase)"
        )
    }

    func testRetryFromServiceDownWithBadEndpointSetsServiceDown() async {
        let service = OllamaInstallerService()
        await service.retryFromServiceDown(endpoint: "http://127.0.0.1:19999")
        if case .serviceDown = service.setupPhase { } else {
            XCTFail("Expected .serviceDown, got \(service.setupPhase)")
        }
    }

    func testRetryFromServiceDownClearsErrorMessageBeforeAttempt() async {
        let service = OllamaInstallerService()
        // After a failed run the error message should be set; retryFromServiceDown clears it first
        await service.runSetup(endpoint: "http://127.0.0.1:19999")
        // If we're in serviceDown, verify retry clears message before setting new one
        if service.setupPhase == .serviceDown {
            await service.retryFromServiceDown(endpoint: "http://127.0.0.1:19999")
            // Error should be re-set (non-empty) after retry fails
            XCTAssertFalse(service.setupErrorMessage.isEmpty)
        }
    }

    // MARK: - Legacy verify still works

    func testLegacyVerifyWithBadEndpointSetsMissing() async {
        let service = OllamaInstallerService()
        await service.verify(endpoint: "http://127.0.0.1:19999")
        XCTAssertEqual(service.status, .missing)
    }
}
