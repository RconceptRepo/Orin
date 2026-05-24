import AVFoundation
import Foundation
import Observation
import Speech

@Observable
final class RecordingService: Service {

    // MARK: - Public State

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// Full running transcript updated in near-real-time by SFSpeechRecognizer.
    private(set) var transcript = ""
    /// Alias used by RecordingWidgetView and MeetingIntelligenceService callers.
    var transcriptPreview: String { transcript }
    /// Set when permission is denied or the audio engine fails to start.
    private(set) var errorMessage: String?

    // MARK: - Private

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    // MARK: - Permissions

    var hasMicPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasSpeechPermission: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func requestPermissions() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Recording lifecycle

    @MainActor
    func startRecording() async {
        errorMessage = nil

        if !hasMicPermission || !hasSpeechPermission {
            await requestPermissions()
        }

        guard hasMicPermission else {
            errorMessage = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
            return
        }
        guard hasSpeechPermission else {
            errorMessage = "Speech Recognition access denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
            return
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable on this device."
            return
        }

        // Build recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            // Local-first: keep audio on device when the model is available.
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self?.recognitionTask = nil
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            recognitionRequest = nil
            recognitionTask = nil
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            return
        }

        isRecording = true
        startedAt = Date()
        transcript = ""
    }

    @MainActor
    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        startedAt = nil
    }

    @MainActor
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Helpers

    var durationText: String {
        guard let startedAt else { return "00:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
