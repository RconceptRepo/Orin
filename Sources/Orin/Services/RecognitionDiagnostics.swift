import Foundation
import Speech

/// Shared diagnostic counter store for both recognition channels (mic + participant).
///
/// All increment methods are safe to call from any thread — the audio I/O thread
/// calls them via TapState.feed / SystemAudioTapState.feed, and the recognition
/// callback closures call them from a MainActor Task.
///
/// Usage:
///   RecognitionDiagnostics.shared.resetMicChannel(...)      // in startRecording
///   RecognitionDiagnostics.shared.resetParticipantChannel(...)  // in startCapturing
///   RecognitionDiagnostics.shared.micBufferReceived(appended:)  // in TapState.feed
///   RecognitionDiagnostics.shared.save(logPath:)            // in stopRecording
final class RecognitionDiagnostics: @unchecked Sendable {

    static let shared = RecognitionDiagnostics()
    private init() {}

    private let lock = NSLock()

    // MARK: - Session metadata (set at session start)

    private var sessionID: String = ""
    private var _micAuthStatus: String = "unknown"
    private var _micRecognizerAvailable: Bool = false
    private var _micSupportsOnDevice: Bool = false
    private var _participantAuthStatus: String = "unknown"
    private var _participantRecognizerAvailable: Bool = false
    private var _participantSupportsOnDevice: Bool = false

    // MARK: - Mic counters

    private var _micAudioBuffers: Int = 0
    private var _micBuffersAppended: Int = 0
    private var _micRecognitionCallbacks: Int = 0
    private var _micErrors1110: Int = 0
    private var _micErrorsOther: [String: Int] = [:]
    private var _micTaskCreations: Int = 0
    private var _micTaskCancellations: Int = 0

    // MARK: - Participant counters

    private var _participantAudioBuffers: Int = 0
    private var _participantBuffersAppended: Int = 0
    private var _participantRecognitionCallbacks: Int = 0
    private var _participantErrors1110: Int = 0
    private var _participantErrorsOther: [String: Int] = [:]
    private var _participantTaskCreations: Int = 0
    private var _participantTaskCancellations: Int = 0

    // MARK: - Session control

    func resetMicChannel(
        sessionID: String,
        authStatus: SFSpeechRecognizerAuthorizationStatus,
        recognizerAvailable: Bool,
        supportsOnDevice: Bool
    ) {
        lock.withLock {
            self.sessionID = sessionID
            _micAuthStatus = Self.authString(authStatus)
            _micRecognizerAvailable = recognizerAvailable
            _micSupportsOnDevice = supportsOnDevice
            _micAudioBuffers = 0
            _micBuffersAppended = 0
            _micRecognitionCallbacks = 0
            _micErrors1110 = 0
            _micErrorsOther = [:]
            _micTaskCreations = 0
            _micTaskCancellations = 0
        }
    }

    func resetParticipantChannel(
        authStatus: SFSpeechRecognizerAuthorizationStatus,
        recognizerAvailable: Bool,
        supportsOnDevice: Bool
    ) {
        lock.withLock {
            _participantAuthStatus = Self.authString(authStatus)
            _participantRecognizerAvailable = recognizerAvailable
            _participantSupportsOnDevice = supportsOnDevice
            _participantAudioBuffers = 0
            _participantBuffersAppended = 0
            _participantRecognitionCallbacks = 0
            _participantErrors1110 = 0
            _participantErrorsOther = [:]
            _participantTaskCreations = 0
            _participantTaskCancellations = 0
        }
    }

    private static func authString(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized:    return "authorized"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    // MARK: - Mic increments

    func micBufferReceived(appended: Bool) {
        lock.withLock {
            _micAudioBuffers += 1
            if appended { _micBuffersAppended += 1 }
        }
    }

    func micTaskCreated()         { lock.withLock { _micTaskCreations += 1 } }
    func micTaskCancelled()       { lock.withLock { _micTaskCancellations += 1 } }
    func micRecognitionCallback() { lock.withLock { _micRecognitionCallbacks += 1 } }

    func micError(_ code: Int) {
        lock.withLock {
            if code == 1110 { _micErrors1110 += 1 }
            else { _micErrorsOther[String(code), default: 0] += 1 }
        }
    }

    // MARK: - Participant increments

    func participantBufferReceived(appended: Bool) {
        lock.withLock {
            _participantAudioBuffers += 1
            if appended { _participantBuffersAppended += 1 }
        }
    }

    func participantTaskCreated()         { lock.withLock { _participantTaskCreations += 1 } }
    func participantTaskCancelled()       { lock.withLock { _participantTaskCancellations += 1 } }
    func participantRecognitionCallback() { lock.withLock { _participantRecognitionCallbacks += 1 } }

    func participantError(_ code: Int) {
        lock.withLock {
            if code == 1110 { _participantErrors1110 += 1 }
            else { _participantErrorsOther[String(code), default: 0] += 1 }
        }
    }

    // MARK: - Snapshot

    struct Snapshot {
        let sessionID: String
        let micAuthStatus: String
        let micRecognizerAvailable: Bool
        let micSupportsOnDevice: Bool
        let micAudioBuffers: Int
        let micBuffersAppended: Int
        let micRecognitionCallbacks: Int
        let micErrors1110: Int
        let micErrorsOther: [String: Int]
        let micTaskCreations: Int
        let micTaskCancellations: Int
        let participantAuthStatus: String
        let participantRecognizerAvailable: Bool
        let participantSupportsOnDevice: Bool
        let participantAudioBuffers: Int
        let participantBuffersAppended: Int
        let participantRecognitionCallbacks: Int
        let participantErrors1110: Int
        let participantErrorsOther: [String: Int]
        let participantTaskCreations: Int
        let participantTaskCancellations: Int
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                sessionID: sessionID,
                micAuthStatus: _micAuthStatus,
                micRecognizerAvailable: _micRecognizerAvailable,
                micSupportsOnDevice: _micSupportsOnDevice,
                micAudioBuffers: _micAudioBuffers,
                micBuffersAppended: _micBuffersAppended,
                micRecognitionCallbacks: _micRecognitionCallbacks,
                micErrors1110: _micErrors1110,
                micErrorsOther: _micErrorsOther,
                micTaskCreations: _micTaskCreations,
                micTaskCancellations: _micTaskCancellations,
                participantAuthStatus: _participantAuthStatus,
                participantRecognizerAvailable: _participantRecognizerAvailable,
                participantSupportsOnDevice: _participantSupportsOnDevice,
                participantAudioBuffers: _participantAudioBuffers,
                participantBuffersAppended: _participantBuffersAppended,
                participantRecognitionCallbacks: _participantRecognitionCallbacks,
                participantErrors1110: _participantErrors1110,
                participantErrorsOther: _participantErrorsOther,
                participantTaskCreations: _participantTaskCreations,
                participantTaskCancellations: _participantTaskCancellations
            )
        }
    }

    // MARK: - Export

    /// Writes diagnostics-TIMESTAMP.json to the same directory as the session log.
    /// Also returns a one-line summary suitable for embedding in the session log.
    @discardableResult
    func save(logPath: String?) -> String {
        let s = snapshot()
        let summary = """
            [Diagnostics] mic: \
            buffers=\(s.micAudioBuffers) appended=\(s.micBuffersAppended) \
            tasks=\(s.micTaskCreations) callbacks=\(s.micRecognitionCallbacks) \
            errors1110=\(s.micErrors1110) cancellations=\(s.micTaskCancellations)
            [Diagnostics] participant: \
            buffers=\(s.participantAudioBuffers) appended=\(s.participantBuffersAppended) \
            tasks=\(s.participantTaskCreations) callbacks=\(s.participantRecognitionCallbacks) \
            errors1110=\(s.participantErrors1110) cancellations=\(s.participantTaskCancellations)
            """

        let dict: [String: Any] = [
            "sessionID": s.sessionID,
            "mic": [
                "authorizationStatus":        s.micAuthStatus,
                "recognizerAvailable":        s.micRecognizerAvailable,
                "supportsOnDeviceRecognition": s.micSupportsOnDevice,
                "audioBuffersReceived":       s.micAudioBuffers,
                "buffersAppended":            s.micBuffersAppended,
                "recognitionCallbacks":       s.micRecognitionCallbacks,
                "errors1110":                 s.micErrors1110,
                "errorsOther":                s.micErrorsOther,
                "taskCreations":              s.micTaskCreations,
                "taskCancellations":          s.micTaskCancellations
            ] as [String: Any],
            "participant": [
                "authorizationStatus":        s.participantAuthStatus,
                "recognizerAvailable":        s.participantRecognizerAvailable,
                "supportsOnDeviceRecognition": s.participantSupportsOnDevice,
                "audioBuffersReceived":       s.participantAudioBuffers,
                "buffersAppended":            s.participantBuffersAppended,
                "recognitionCallbacks":       s.participantRecognitionCallbacks,
                "errors1110":                 s.participantErrors1110,
                "errorsOther":                s.participantErrorsOther,
                "taskCreations":              s.participantTaskCreations,
                "taskCancellations":          s.participantTaskCancellations
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return summary }

        let dir: URL
        if let logPath {
            dir = URL(fileURLWithPath: logPath).deletingLastPathComponent()
        } else if let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dir = appSupport.appendingPathComponent("Orin/Logs")
        } else {
            return summary
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "diagnostics-\(formatter.string(from: Date())).json"
        try? data.write(to: dir.appendingPathComponent(name))
        return summary
    }
}
