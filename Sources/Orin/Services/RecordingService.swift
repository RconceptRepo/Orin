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
    var transcriptPreview: String { transcript }
    /// URL of the locally-stored audio file after recording stops. Nil if storage failed.
    private(set) var recordingURL: URL?
    /// Set when permission is denied or the audio engine fails to start.
    private(set) var errorMessage: String?

    // MARK: - Private

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioFile: AVAudioFile?

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
        recordingURL = nil

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

        // Set up recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
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

        // Prepare local audio file for storage
        audioFile = makeAudioFile(format: format)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            try? self?.audioFile?.write(from: buffer)
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
            audioFile = nil
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
        // recordingURL stays set after stop so callers can attach it to a meeting
        recordingURL = audioFile?.url
        audioFile = nil
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

    private func makeAudioFile(format: AVAudioFormat) -> AVAudioFile? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Orin/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let name = "meeting-\(formatter.string(from: Date())).caf"
        let fileURL = dir.appendingPathComponent(name)
        return try? AVAudioFile(forWriting: fileURL, settings: format.settings)
    }
}
