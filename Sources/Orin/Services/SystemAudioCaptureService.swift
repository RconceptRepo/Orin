import AVFoundation
import CoreMedia
import Foundation
import Observation
import ScreenCaptureKit
import Speech

// MARK: - SystemAudioCaptureService

/// Captures system-wide audio via ScreenCaptureKit and produces a speaker-labeled
/// transcript for meeting participants ("Participant:").
///
/// This service is the complement to `RecordingService`, which captures microphone
/// input ("Me:"). Together they enable two-channel diarization:
///
///  - `RecordingService.speakerTranscript`             → "Me: …"
///  - `SystemAudioCaptureService.participantSpeakerTranscript` → "Participant: …"
///
/// **Permissions:** Screen Recording (System Settings → Privacy → Screen Recording).
/// `com.apple.security.screen-recording` is already present in both entitlements
/// files; only `NSScreenCaptureUsageDescription` in `Info.plist` is needed.
///
/// **Fallback:** If permission is denied, hardware is absent, or `SCStream` fails,
/// `isAvailable` is set to `false` and capture is silently skipped. The main mic
/// recording pipeline (`RecordingService`) is **never** affected.
@MainActor
@Observable
final class SystemAudioCaptureService: Service {

    // MARK: - Public State

    /// `true` once `SCStream` has successfully started.
    private(set) var isCapturing = false

    /// `true` if Screen Recording permission was obtained and the service can
    /// attempt capture. Set asynchronously during `startCapturing`.
    private(set) var isAvailable = false

    /// Raw transcript text from the system audio stream (participants' speech).
    private(set) var transcript = ""

    /// Speaker-labeled version of `transcript`.
    ///
    /// Returns `""` when `transcript` is empty so callers do not persist a
    /// bare "Participant: " prefix stub in the database.
    var participantSpeakerTranscript: String {
        guard !transcript.isEmpty else { return "" }
        return "Participant: \(transcript)"
    }

    // MARK: - Private — main-actor-only state

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var streamDelegate: SystemAudioStreamDelegate?

    /// Lock-protected bridge between the SCStream real-time audio thread and the
    /// `SFSpeechAudioBufferRecognitionRequest` owned by the main actor.
    @ObservationIgnored private let tapState = SystemAudioTapState()

    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    /// Separate recognizer instance from `RecordingService`'s — two concurrent
    /// on-device recognizers work fine on modern Apple Silicon Macs.
    @ObservationIgnored private lazy var speechRecognizer =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private var transcriptPrefix = ""
    @ObservationIgnored private var chunkCount = 0

    // MARK: - Capture Lifecycle

    /// Starts system audio capture for the given meeting session.
    ///
    /// Silently returns (without crashing or affecting mic recording) if:
    ///  - Speech recognition is not authorized
    ///  - Screen Recording permission is denied
    ///  - No display is found
    ///  - `SCStream` fails to start
    func startCapturing(for meetingID: UUID?) async {
        guard !isCapturing else {
            print("[SystemAudio] startCapturing already in progress — ignored")
            return
        }

        print("[SystemAudio] starting system audio capture meetingID=\(String(describing: meetingID))")

        // Speech recognizer must be ready before we open the stream
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            print("[SystemAudio] speech not authorized — system audio skipped (mic-only)")
            return
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[SystemAudio] speech recognizer unavailable — system audio skipped")
            return
        }

        // Fetch shareable content — triggers Screen Recording permission prompt if needed
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            print("[SystemAudio] SCShareableContent failed (Screen Recording permission denied?): \(error) — mic-only fallback")
            return
        }

        guard let display = content.displays.first else {
            print("[SystemAudio] no displays found — system audio skipped")
            return
        }

        // Reset per-session state
        transcriptPrefix = ""
        chunkCount       = 0
        transcript       = ""

        // Arm tap state with first recognition request BEFORE stream starts,
        // so the first audio buffer is not lost.
        let request = buildRecognitionRequest(recognizer: recognizer)
        tapState.arm(request: request)
        startRecognitionTask(with: recognizer, request: request)

        // Configure SCStream for audio only — minimal video dimensions to reduce overhead
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // exclude Orin's own playback (if any)
        config.width                = 2             // 2 × 2 px video — keeps CPU usage near zero
        config.height               = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps max video

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let delegate = SystemAudioStreamDelegate(tapState: tapState) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[SystemAudio] stream stopped unexpectedly: \(error)")
                isCapturing = false
            }
        }
        streamDelegate = delegate

        let newStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        do {
            try newStream.addStreamOutput(
                delegate,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(
                    label: "com.orin.system-audio",
                    qos: .userInitiated
                )
            )
            try await newStream.startCapture()
            stream      = newStream
            isCapturing = true
            isAvailable = true
            print("[SystemAudio] capture started — screen recording active")
        } catch {
            // Non-fatal: clean up and fall back to mic-only transcription
            print("[SystemAudio] SCStream start failed (mic-only fallback): \(error)")
            tapState.disarm()
            recognitionTask?.cancel()
            recognitionTask = nil
            streamDelegate  = nil
        }
    }

    /// Stops system audio capture and finalises the participant transcript.
    ///
    /// Safe to call when not capturing (no-op). Does NOT touch `RecordingService`.
    func stopCapturing() {
        guard isCapturing else {
            print("[SystemAudio] stopCapturing called while not capturing — ignored")
            return
        }
        print("[SystemAudio] stopping — transcriptChars=\(transcript.count)")
        isCapturing = false

        // Stop stream asynchronously; errors are logged but non-fatal
        if let stream {
            let capturedStream = stream
            Task {
                do { try await capturedStream.stopCapture() }
                catch { print("[SystemAudio] stream stop error (non-fatal): \(error)") }
            }
            self.stream = nil
        }

        // End recognition before clearing tap state
        recognitionTask?.cancel()
        recognitionTask = nil
        tapState.disarm()
        streamDelegate = nil

        print("[SystemAudio] capture stopped — final participantChars=\(transcript.count)")
    }

    // MARK: - Recognition session management

    private func buildRecognitionRequest(
        recognizer: SFSpeechRecognizer
    ) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        return request
    }

    /// Starts a recognition task and transparently restarts at the ~60-second
    /// Apple network limit, identical to the pattern in `RecordingService`.
    @MainActor
    private func startRecognitionTask(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    let segment = result.bestTranscription.formattedString
                    self.transcript = self.transcriptPrefix.isEmpty
                        ? segment
                        : self.transcriptPrefix + " " + segment
                    self.chunkCount += 1
                    print("[SystemAudio] chunk #\(self.chunkCount) segChars=\(segment.count) isFinal=\(result.isFinal) totalChars=\(self.transcript.count)")
                }

                // Transparent ~60-second session restart
                if result?.isFinal == true, self.isCapturing {
                    print("[SystemAudio] segment finalized — restarting recognition totalChars=\(self.transcript.count)")
                    if !self.transcript.isEmpty {
                        self.transcriptPrefix = self.transcript
                    }
                    let next = self.buildRecognitionRequest(recognizer: recognizer)
                    self.tapState.updateRequest(next)
                    self.recognitionTask = nil
                    self.startRecognitionTask(with: recognizer, request: next)
                }

                if let error, self.isCapturing {
                    let ns = error as NSError
                    // Code 301 = cancellation — not a real error; swallow it.
                    if ns.code != 301 {
                        print("[SystemAudio] recognition error (non-fatal — mic recording unaffected): code=\(ns.code) \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

// MARK: - SystemAudioTapState (thread-safe)

/// Lock-protected container that bridges the SCStream real-time audio delivery
/// thread and the `SFSpeechAudioBufferRecognitionRequest` owned by the main actor.
///
/// Modelled after `TapState` (used by `RecordingService` for mic audio).
/// All methods are safe to call from any thread.
private final class SystemAudioTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    func arm(request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock { recognitionRequest = request }
    }

    func updateRequest(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock { recognitionRequest = request }
    }

    func disarm() {
        lock.withLock {
            recognitionRequest?.endAudio()
            recognitionRequest = nil
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { recognitionRequest?.append(buffer) }
    }
}

// MARK: - SystemAudioStreamDelegate

/// Bridges SCStreamOutput callbacks (real-time audio thread) to `SystemAudioTapState`.
///
/// `@unchecked Sendable`:
///  - `tapState` is thread-safe by design (NSLock-protected).
///  - `onStopped` is set once in `init` and never mutated.
private final class SystemAudioStreamDelegate: NSObject, SCStreamOutput, SCStreamDelegate,
                                               @unchecked Sendable {
    private let tapState: SystemAudioTapState
    private let onStopped: (Error) -> Void

    init(tapState: SystemAudioTapState, onStopped: @escaping (Error) -> Void) {
        self.tapState  = tapState
        self.onStopped = onStopped
    }

    // MARK: SCStreamOutput — real-time audio thread

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        guard let pcm = convertToAVAudioPCMBuffer(sampleBuffer) else { return }
        tapState.feed(pcm)
    }

    // MARK: SCStreamDelegate — system stops stream

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped(error)
    }

    // MARK: CMSampleBuffer → AVAudioPCMBuffer

    /// Converts a CoreMedia audio sample buffer delivered by SCStream to an
    /// `AVAudioPCMBuffer` that `SFSpeechAudioBufferRecognitionRequest` can accept.
    ///
    /// Returns `nil` on any conversion failure; the tap silently drops the buffer
    /// rather than crashing or stopping the recording pipeline.
    private func convertToAVAudioPCMBuffer(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample) else { return nil }
        guard var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return nil }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0 else { return nil }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames

        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        ) == noErr else { return nil }

        return pcm
    }
}
