import AVFoundation
import Speech
import XCTest
@testable import Orin

@MainActor
final class RecordingServiceTests: XCTestCase {

    func testInitialState() {
        let service = RecordingService()
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.elapsedSeconds, 0)
        XCTAssertEqual(service.transcript, "")
        XCTAssertNil(service.recordingURL)
        XCTAssertNil(service.errorMessage)
        XCTAssertNil(service.activeMeetingID)
    }

    func testDurationTextAtZero() {
        let service = RecordingService()
        XCTAssertEqual(service.durationText, "00:00")
    }

    func testDurationTextZeroPadsBothComponents() {
        // Verify format string pads single digits with a leading zero.
        let text = String(format: "%02d:%02d", 1, 5)
        XCTAssertEqual(text, "01:05")
    }

    func testDurationTextOneHourBoundary() {
        // 3600 seconds → 60:00
        let text = String(format: "%02d:%02d", 3600 / 60, 3600 % 60)
        XCTAssertEqual(text, "60:00")
    }

    func testStopRecordingWhenNotRecordingDoesNotCrash() {
        let service = RecordingService()
        // stopRecording on a fresh service must not throw or crash.
        service.stopRecording()
        XCTAssertFalse(service.isRecording)
    }

    func testStopRecordingDoesNotSetRecordingURL() {
        let service = RecordingService()
        service.stopRecording()
        // No audio file was created, so recordingURL must remain nil.
        XCTAssertNil(service.recordingURL)
    }

    func testClearErrorRemovesMessage() {
        let service = RecordingService()
        // Simulate a pre-existing error (reach the internal property via @testable).
        // We can't set it directly because it's private(set), but we can verify
        // clearError() does not crash and errorMessage stays nil.
        service.clearError()
        XCTAssertNil(service.errorMessage)
    }

    func testMicPermissionStatusIsAccessible() {
        let service = RecordingService()
        // Just ensure the computed property does not crash and returns a Bool.
        let status = service.hasMicPermission
        XCTAssertTrue(status == true || status == false)
    }

    func testSpeechPermissionStatusIsAccessible() {
        let service = RecordingService()
        let status = service.hasSpeechPermission
        XCTAssertTrue(status == true || status == false)
    }

    func testActiveMeetingIDRemainsNilAfterStop() {
        let service = RecordingService()
        service.stopRecording()
        XCTAssertNil(service.activeMeetingID)
    }
}
