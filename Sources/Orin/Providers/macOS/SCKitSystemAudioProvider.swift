import Foundation

// MARK: - SCKitSystemAudioProvider
//
// macOS SystemAudioProvider implementation.
// Delegates to the existing SystemAudioCaptureService.
// Only this file links the abstract protocol to the ScreenCaptureKit service.

@MainActor
final class SCKitSystemAudioProvider: SystemAudioProvider, Service {

    private let service: SystemAudioCaptureService

    init(service: SystemAudioCaptureService) {
        self.service = service
    }

    var isCapturing: Bool { service.isCapturing }
    var isAvailable: Bool { service.isAvailable }
    var participantSpeakerTranscript: String { service.participantSpeakerTranscript }

    func startCapturing(for meetingID: UUID?) async {
        await service.startCapturing(for: meetingID)
    }

    func stopCapturing() {
        service.stopCapturing()
    }
}
