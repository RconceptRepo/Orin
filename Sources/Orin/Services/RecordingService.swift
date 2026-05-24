import AVFoundation
import Foundation
import Observation
import Speech

@Observable
final class RecordingService: Service, @unchecked Sendable {

    // MARK: - Public state

    private(set) var isRecording = false
    private(set) var elapsedSeconds: Int = 0
    private(set) var transcript = ""
    private(set) var recordingURL: URL?
    private(set) var errorMessage: String?
    private(set) var activeMeetingID: UUID?

    var durationText: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    // MARK: - Permissions

    var hasMicPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasSpeechPermission: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - Private

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioFile: AVAudioFile?
    private var durationTimer: Timer?
    private var transcriptPrefix = ""

    deinit {
        durationTimer?.invalidate()
    }

    // MARK: - Permissions

    func requestPermissions() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Recording lifecycle

    @MainActor
    func startRecording(for meetingID: UUID? = nil) async {
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

        activeMeetingID = meetingID
        transcriptPrefix = ""

        // prepare() must be called before querying inputNode format so the hardware
        // is initialised and outputFormat(forBus:) returns a valid non-zero format.
        audioEngine.prepare()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        do {
            audioFile = try makeAudioFile(format: format)
        } catch {
            errorMessage = "Could not create audio file: \(error.localizedDescription)"
            return
        }

        startRecognitionSession(with: recognizer)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            try? self?.audioFile?.write(from: buffer)
        }

        do {
            try audioEngine.start()
        } catch {
            teardownAudioEngine()
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            return
        }

        isRecording = true
        elapsedSeconds = 0
        transcript = ""

        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.elapsedSeconds += 1
        }
    }

    @MainActor
    func stopRecording() {
        durationTimer?.invalidate()
        durationTimer = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        // Set recordingURL before clearing the file reference so callers can persist it.
        recordingURL = audioFile?.url
        audioFile = nil
        isRecording = false
        activeMeetingID = nil
    }

    @MainActor
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Recognition session management

    // Starts (or restarts after ~60 s network limit) a SFSpeechRecognitionTask.
    // Called on MainActor so all @Observable state mutations stay on the main thread.
    @MainActor
    private func startRecognitionSession(with recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let result {
                    let segment = result.bestTranscription.formattedString
                    self.transcript = self.transcriptPrefix.isEmpty
                        ? segment
                        : self.transcriptPrefix + segment
                }

                if result?.isFinal == true, self.isRecording {
                    // Apple's network recognizer ends sessions around 60 s.
                    // Accumulate the finalised text and restart transparently.
                    if !self.transcript.isEmpty {
                        self.transcriptPrefix = self.transcript + " "
                    }
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    self.startRecognitionSession(with: recognizer)
                }

                if let error, self.isRecording {
                    let nsError = error as NSError
                    // Code 301 (kAFAssistantErrorDomain) fires when we cancel — not a real error.
                    if nsError.code != 301 {
                        self.errorMessage = "Speech recognition error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func teardownAudioEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioFile = nil
    }

    private func makeAudioFile(format: AVAudioFormat) throws -> AVAudioFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Orin/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let name = "meeting-\(formatter.string(from: Date())).caf"
        return try AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: format.settings)
    }
}
