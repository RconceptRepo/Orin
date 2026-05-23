import Foundation
import Observation

@Observable
final class RecordingService: Service {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    var transcriptPreview = ""

    func startRecording() {
        isRecording = true
        startedAt = Date()
    }

    func stopRecording() {
        isRecording = false
        startedAt = nil
        transcriptPreview = ""
    }

    var durationText: String {
        guard let startedAt else { return "00:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
