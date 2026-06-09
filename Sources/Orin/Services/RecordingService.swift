import AVFoundation
import CoreAudio
import Foundation
import OSLog
import Observation
import Speech

// MARK: - RecordingService

/// `@MainActor` isolates every property and method to the Swift main actor.
///
/// This is the correct model for an `@Observable` service whose state is consumed
/// exclusively by SwiftUI views.  macOS 26 enforces that `@Query.update()` (called
/// whenever any `@Observable` mutation triggers a view re-render) executes within a
/// Swift Concurrency main actor task — not merely on the main *thread* via GCD or a
/// run-loop callback.  `RecordingService` previously held `@unchecked Sendable` to
/// silence compiler warnings while using `DispatchQueue.main.async` for mutations;
/// that combination produced `EXC_BREAKPOINT` / `swift_task_isCurrentExecutorWithFlagsImpl`
/// crashes on macOS 26 at the `@Query` update point in `MeetingsView`.
///
/// With `@MainActor` on the class:
/// - The compiler prevents off-actor mutations at compile time.
/// - All `DispatchQueue.main.async` calls are replaced with `Task { @MainActor in }`.
/// - Timer callbacks use `Task { @MainActor in }` for the same reason.
/// - `@unchecked Sendable` is removed — `@MainActor`-isolated types are implicitly
///   `Sendable` because the isolation constraint guarantees single-actor access.
@MainActor
@Observable
final class RecordingService: Service {

    // MARK: - Recording phase

    /// Deterministic four-state lifecycle for a recording session.
    ///
    /// Allowed transitions:
    ///   idle → starting  (`startRecording` accepted)
    ///   starting → recording  (engine running)
    ///   starting → idle  (permission denied, hardware error)
    ///   recording → stopping  (`stopRecording` called)
    ///   stopping → idle  (teardown complete)
    ///
    /// Any call to `startRecording` when `phase != .idle` is a no-op.
    /// Any call to `stopRecording` when `phase` is `.idle` or `.stopping` is a no-op.
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    // MARK: - Public state

    private(set) var phase: Phase = .idle

    /// Convenience alias; equivalent to `phase == .recording`.
    /// Computed so it is always consistent with `phase`.
    var isRecording: Bool { phase == .recording }

    private(set) var elapsedSeconds: Int = 0
    private(set) var transcript = ""

    /// Speaker-labeled version of `transcript`.
    ///
    /// Labels all microphone-captured speech as "Me:". True per-speaker
    /// diarization (separating "Me" from "Participant" using system audio)
    /// requires ScreenCaptureKit and is tracked for a future iteration.
    /// If transcript is empty, returns "" so callers never store a "Me: "
    /// prefix stub in the database.
    ///
    /// Safe to call from any @Observable observer — reads `transcript` only.
    var speakerTranscript: String {
        guard !transcript.isEmpty else { return "" }
        return "Me: \(transcript)"
    }

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

    // MARK: - Private — main-actor-only state

    /// Lazy so `AVAudioEngine` does not spin up Core-Audio background threads
    /// until the first `startRecording` call.  Eager initialisation caused a
    /// signal-6 crash in the test suite ~9 test-durations after creation, when
    /// the HAL's background thread fired an assertion.
    /// `stopRecording` returns early via the phase guard before accessing this
    /// property, so lazy initialisation is safe for the idle → recording path.
    @ObservationIgnored
    private lazy var audioEngine = AVAudioEngine()

    /// Lazy for the same reason: `SFSpeechRecognizer(locale:)` also starts
    /// background framework work that corrupts the allocator in test environments.
    /// Only accessed from `@MainActor` paths so the non-thread-safe `lazy` is safe.
    @ObservationIgnored
    private lazy var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private var recognitionTask: SFSpeechRecognitionTask?

    /// `nonisolated(unsafe)` allows `deinit` (which is `nonisolated`) to call
    /// `invalidate()` without a concurrency violation.  This is correct because
    /// `Timer.invalidate()` is documented thread-safe from any thread, and
    /// `stopRecording()` always sets this to `nil` before the service is released
    /// under normal operation — `deinit` is purely a safety net.
    ///
    /// `@ObservationIgnored` prevents `@Observable` from generating observation
    /// accessors for an internal implementation detail that views never observe.
    @ObservationIgnored
    private nonisolated(unsafe) var durationTimer: Timer?

    private var transcriptPrefix = ""
    @ObservationIgnored private var transcriptChunkCount = 0
    /// Monotonically-increasing counter; incremented on every recognition restart.
    /// Each `startRecognitionTask` call captures the current value as `gen`.
    /// Callbacks from superseded tasks (stale gen) are discarded before they
    /// can schedule duplicate restarts that kill the in-flight session.
    @ObservationIgnored private var recognitionGeneration = 0
    /// Set to true when the current generation receives its first speech result.
    /// Used to distinguish a segment-boundary 1110 (speech was heard → restart fast)
    /// from a startup-silence 1110 (no speech yet → back off 2 s to avoid tight loop).
    @ObservationIgnored private var generationHadSpeech = false
    private let logger = Logger(subsystem: "com.clavrit.orin", category: "RecordingService")

    // MARK: - Private — cross-thread state

    /// All state shared between the MainActor and the real-time Core-Audio I/O
    /// thread is funnelled through this lock-protected container.
    ///
    /// `@ObservationIgnored` prevents the `@Observable` macro from wrapping
    /// this constant with observation accessors — it is a `let` and therefore
    /// never re-assigned, but the annotation makes the intent explicit.
    @ObservationIgnored
    private let tapState = TapState()

    // MARK: - Lifecycle

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
        guard phase == .idle else { return }
        phase = .starting

        errorMessage = nil
        recordingURL = nil

        // ── STEP 1: permissions ───────────────────────────────────────────────
        print("STEP 1: checking mic permission")

        // `requestPermissions()` suspends and allows other @MainActor work to run.
        // Re-confirm phase is still `.starting` after the await.
        if !hasMicPermission || !hasSpeechPermission {
            print("STEP 1: requesting permissions (suspended)")
            await requestPermissions()
            print("STEP 1: permissions returned hasMic=\(hasMicPermission) hasSpeech=\(hasSpeechPermission)")
        }

        guard phase == .starting else {
            print("STEP 1: phase changed during permission request — aborting (phase=\(phase))")
            return
        }

        guard hasMicPermission else {
            print("STEP 1: microphone access denied")
            errorMessage = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
            phase = .idle
            return
        }
        guard hasSpeechPermission else {
            print("STEP 1: speech recognition access denied")
            errorMessage = "Speech Recognition access denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
            phase = .idle
            return
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("STEP 1: speech recognizer unavailable")
            errorMessage = "Speech recognition is unavailable on this device."
            phase = .idle
            return
        }
        print("STEP 1: permissions OK — mic=\(hasMicPermission) speech=\(hasSpeechPermission)")

        // ── STEP 2: audio device check + engine guard ─────────────────────────
        // Root cause of EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS 0x0:
        //
        // `AVAudioEngine.prepare()` initialises AVAudioEngineGraph, which calls
        // into the CoreAudio Hardware Abstraction Layer (HAL) to open the default
        // input device. If no default input device exists (Mac mini without a
        // microphone, Bluetooth device disconnected mid-session, etc.), the HAL
        // returns kAudioObjectUnknown (0) and the graph stores a null device ID.
        // When the graph then tries to dereference that device pointer, the process
        // crashes with KERN_INVALID_ADDRESS 0x0000000000000000.
        //
        // Fix: query the default input device ID via CoreAudio BEFORE touching
        // AVAudioEngine. This is lightweight (a single HAL property read) and does
        // not open any hardware. We fail fast with a user-visible error.
        print("STEP 2: creating AVAudioEngine")

        var defaultInputDeviceID: AudioDeviceID = kAudioObjectUnknown
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let halStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &propSize, &defaultInputDeviceID
        )
        guard halStatus == noErr, defaultInputDeviceID != kAudioObjectUnknown else {
            print("STEP 2: no default audio input device (halStatus=\(halStatus) deviceID=\(defaultInputDeviceID))")
            errorMessage = "No audio input device detected. Connect a microphone and try again."
            phase = .idle
            return
        }
        print("STEP 2: audio input device found (halStatus=\(halStatus) deviceID=\(defaultInputDeviceID))")

        // Safety: remove any tap left over from a previous session that was not
        // cleaned up cleanly (e.g. crash, force-quit, or failed stopRecording).
        // `removeTap(onBus:)` on an untapped bus is a documented no-op.
        audioEngine.inputNode.removeTap(onBus: 0)
        print("STEP 2: stale tap removed (or was already absent)")

        // ── STEP 3: input node ────────────────────────────────────────────────
        // Accessing `inputNode` after the HAL device check is safe: the lazy
        // property connects to the now-confirmed default device. Do NOT call
        // `audioEngine.prepare()` here — that is deferred until STEP 6 so the
        // graph is configured with the tap already in place.
        print("STEP 3: getting input node")
        let inputNode = audioEngine.inputNode

        // ── STEP 4: format validation ─────────────────────────────────────────
        // `outputFormat(forBus:)` on the input node returns the hardware capture
        // format. A zero sample rate means the driver did not initialise (e.g.
        // the device was removed between the HAL check and this point).
        let format = inputNode.outputFormat(forBus: 0)
        print("STEP 4: format = \(format)")
        guard format.sampleRate > 0 else {
            print("STEP 4: invalid format — sampleRate=0, aborting")
            errorMessage = "Audio input format is invalid (sample rate 0). Check your microphone connection and try again."
            phase = .idle
            return
        }
        print("STEP 4: format valid — sampleRate=\(format.sampleRate) channels=\(format.channelCount)")

        activeMeetingID      = meetingID
        transcriptPrefix     = ""
        transcriptChunkCount = 0
        recognitionGeneration = 0
        SessionLogger.shared.startSession()
        SessionLogger.shared.log("[Mic] session started meetingID=\(String(describing: meetingID))")
        RecognitionDiagnostics.shared.resetMicChannel(
            sessionID: meetingID?.uuidString ?? "none",
            authStatus: SFSpeechRecognizer.authorizationStatus(),
            recognizerAvailable: recognizer.isAvailable,
            supportsOnDevice: recognizer.supportsOnDeviceRecognition
        )
        SessionLogger.shared.log("[Mic] recognizer available=\(recognizer.isAvailable) supportsOnDevice=\(recognizer.supportsOnDeviceRecognition) auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")

        // Create the on-disk file before arming the tap state.  If this fails,
        // no tap is installed and no hardware is left in a partial state.
        let audioFile: AVAudioFile
        do {
            audioFile = try makeAudioFile(format: format)
        } catch {
            print("STEP 4: audio file creation failed — \(error)")
            errorMessage = "Could not create audio file: \(error.localizedDescription)"
            phase = .idle
            return
        }

        // Arm tap state BEFORE installTap — the Core-Audio callback may fire
        // immediately after installation, so both audioFile and recognitionRequest
        // must be valid at that moment.
        let initialRequest = buildRecognitionRequest(recognizer: recognizer)
        tapState.arm(audioFile: audioFile, recognitionRequest: initialRequest)
        startRecognitionTask(with: recognizer, request: initialRequest)

        // ── STEP 5: install tap ───────────────────────────────────────────────
        // The tap closure captures `tapState` (not `self`) to avoid touching
        // @Observable state from the Core-Audio real-time I/O thread.
        print("STEP 5: installing tap")
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [tapState] buffer, _ in
            tapState.feed(buffer: buffer)
        }
        print("STEP 5: tap installed")

        // ── STEP 6: prepare + start ───────────────────────────────────────────
        // `prepare()` is called AFTER installTap so the engine graph is
        // configured with the tap already in place. Calling prepare() earlier
        // (before the tap) required a second implicit re-initialisation inside
        // start(), which was the observed crash site.
        print("STEP 6: preparing engine")
        audioEngine.prepare()
        print("STEP 6: engine prepared — calling start()")

        do {
            try audioEngine.start()
            print("STEP 6: engine started successfully")
        } catch {
            print("STEP 6: engine start FAILED — \(error)")
            teardownAudioEngine()
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            phase = .idle
            return
        }

        phase = .recording
        elapsedSeconds = 0
        transcript = ""

        // Timer fires on the main-thread run loop. Wrap mutation in
        // Task { @MainActor in } to create a proper Swift Concurrency
        // task context — required by macOS 26 executor isolation checks.
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedSeconds += 1
            }
        }
        print("STEP 6: recording started — phase=\(phase)")
    }

    @MainActor
    func stopRecording() {
        // Idempotency guard — safe to call from any code path, including error
        // handlers, without risking a double-teardown or double-removeTap crash.
        guard phase == .recording || phase == .starting else { return }
        print("[Recording] stopRecording called phase=\(phase) chunks=\(transcriptChunkCount) transcriptChars=\(transcript.count)")
        phase = .stopping

        durationTimer?.invalidate()
        durationTimer = nil

        audioEngine.stop()

        // `removeTap` must precede `disarm` so that `feed` cannot be executing
        // on the audio thread while the tap state is being cleared.
        audioEngine.inputNode.removeTap(onBus: 0)

        // Cancel the recognition task **before** `disarm` calls `endAudio` so
        // the final-result callback sees `isRecording == false` and does not
        // attempt a transparent session restart.
        recognitionTask?.cancel()
        RecognitionDiagnostics.shared.micTaskCancelled()
        recognitionTask = nil

        // `disarm` signals end-of-audio to the recogniser and releases the file.
        // Releasing `AVAudioFile` here closes and flushes all pending writes to disk,
        // so the file-size validation below reflects the final committed state.
        tapState.disarm()

        // `audioFileURL` is preserved inside TapState after `disarm`; read it now.
        recordingURL    = tapState.audioFileURL
        activeMeetingID = nil

        // Surface any audio-file write failures that were recorded during the session.
        // Checked here (after disarm) because disarm flushes the file — only after
        // the file handle is closed can the on-disk size reflect reality.
        if tapState.hadWriteFailure {
            errorMessage = "Recording saved, but some audio data could not be written. "
                         + "The file may be incomplete — check available disk space."
        } else if let url = recordingURL,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size  = attrs[.size] as? Int, size == 0 {
            errorMessage = "Recording completed but the audio file is empty. "
                         + "Check available disk space and try again."
        }

        phase = .idle
        let finalChars = transcript.count
        logger.info("stopped url=\(self.recordingURL?.lastPathComponent ?? "nil", privacy: .public) chars=\(finalChars)")
        SessionLogger.shared.log("[Mic] stopped url=\(self.recordingURL?.lastPathComponent ?? "nil") chars=\(finalChars)")
        let diagSummary = RecognitionDiagnostics.shared.save(logPath: SessionLogger.shared.currentLogPath)
        for line in diagSummary.components(separatedBy: "\n") where !line.isEmpty {
            SessionLogger.shared.log(line)
        }
        SessionLogger.shared.endSession()
    }

    @MainActor
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Recognition session management

    /// Constructs a new recognition request configured for the given recogniser.
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

    /// Starts a `SFSpeechRecognitionTask` for `request`.
    ///
    /// **Generation counter** (`recognitionGeneration`): each call captures the
    /// current generation as `gen`.  Any callback that fires after a restart has
    /// already incremented the counter will see `gen != recognitionGeneration` and
    /// return immediately.  This prevents the duplicate-restart race where multiple
    /// stale error callbacks each schedule a 1-second-delayed restart, and those
    /// restarts then kill the live session — producing only 1-2 words per meeting.
    ///
    /// **Direct TranscriptStore update**: transcript is pushed to `TranscriptStore`
    /// on every partial result directly from this service, bypassing SwiftUI's
    /// `onChange` handlers.  This ensures updates are delivered even when the main
    /// window is closed or the view is not in the render tree.
    @MainActor
    private func startRecognitionTask(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        RecognitionDiagnostics.shared.micTaskCreated()
        generationHadSpeech = false
        let gen = recognitionGeneration
        SessionLogger.shared.log(
            "[Mic] task created gen=\(gen)"
            + " locale=\(recognizer.locale.identifier)"
            + " available=\(recognizer.isAvailable)"
            + " supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)"
            + " auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)"
            + " taskHint=\(request.taskHint.rawValue)"
            + " partialResults=\(request.shouldReportPartialResults)"
            + " requiresOnDevice=\(request.requiresOnDeviceRecognition)"
        )
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.recognitionGeneration == gen else {
                    return  // stale callback from a superseded recognition session
                }

                if let result {
                    RecognitionDiagnostics.shared.micRecognitionCallback()
                    self.generationHadSpeech = true
                    let segment = result.bestTranscription.formattedString
                    let candidateTotal = self.transcriptPrefix.count + segment.count
                    if !self.transcript.isEmpty,
                       candidateTotal < self.transcript.count,
                       segment.count <= 20 {
                        SessionLogger.shared.log("[Mic] utterance boundary: saved \(self.transcript.count)ch → prefix, new seg=\(segment.count)ch")
                        self.transcriptPrefix = self.transcript + " "
                    }
                    self.transcript = self.transcriptPrefix.isEmpty
                        ? segment
                        : self.transcriptPrefix + segment
                    self.transcriptChunkCount += 1
                    SessionLogger.shared.log("[Mic] chunk #\(self.transcriptChunkCount) gen=\(gen) chars=\(segment.count) isFinal=\(result.isFinal) total=\(self.transcript.count)")
                    ServiceContainer.shared.resolve(TranscriptStore.self)
                        .updateMic(self.speakerTranscript)
                }

                if result?.isFinal == true, self.isRecording {
                    SessionLogger.shared.log("[Mic] isFinal gen=\(gen) total=\(self.transcript.count) — starting gen \(gen + 1)")
                    if !self.transcript.isEmpty {
                        self.transcriptPrefix = self.transcript + " "
                    }
                    self.recognitionGeneration += 1
                    let nextRequest = self.buildRecognitionRequest(recognizer: recognizer)
                    self.tapState.updateRequest(nextRequest)
                    self.recognitionTask?.cancel()
                    RecognitionDiagnostics.shared.micTaskCancelled()
                    self.recognitionTask = nil
                    self.startRecognitionTask(with: recognizer, request: nextRequest)
                    return
                }

                if let error, self.isRecording {
                    let nsError = error as NSError
                    SessionLogger.shared.log(
                        "[Mic] error gen=\(gen)"
                        + " domain=\(nsError.domain)"
                        + " code=\(nsError.code)"
                        + " desc=\(nsError.localizedDescription)"
                    )
                    if nsError.code != 301 {
                        RecognitionDiagnostics.shared.micError(nsError.code)
                        if !self.transcript.isEmpty {
                            self.transcriptPrefix = self.transcript + " "
                        }
                        let nextGen = self.recognitionGeneration + 1
                        self.recognitionGeneration = nextGen
                        // 1110 = on-device VAD boundary.
                        // - Speech heard this gen (segment boundary): restart in 50 ms.
                        // - No speech yet (startup silence): back off 2 s to avoid a
                        //   tight create→1110→restart spiral that blocks all transcription.
                        let hadSpeech = self.generationHadSpeech
                        let delay: UInt64 = nsError.code == 1110
                            ? (hadSpeech ? 50_000_000 : 2_000_000_000)
                            : 1_000_000_000
                        let delayLabel = nsError.code == 1110 ? (hadSpeech ? "50ms" : "2s") : "1s"
                        SessionLogger.shared.log("[Mic] restarting gen=\(gen) → \(nextGen) in \(delayLabel) hadSpeech=\(hadSpeech) prefix=\(self.transcriptPrefix.count)ch")
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: delay)
                            guard let self, self.isRecording,
                                  self.recognitionGeneration == nextGen else { return }
                            let nextRequest = self.buildRecognitionRequest(recognizer: recognizer)
                            self.tapState.updateRequest(nextRequest)
                            self.recognitionTask?.cancel()
                            RecognitionDiagnostics.shared.micTaskCancelled()
                            self.recognitionTask = nil
                            self.startRecognitionTask(with: recognizer, request: nextRequest)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Tears down the audio engine after a mid-startup failure.
    /// Safe to call when no tap is installed (removeTap on an untapped bus is a no-op).
    private func teardownAudioEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        RecognitionDiagnostics.shared.micTaskCancelled()
        recognitionTask = nil
        tapState.disarm()
    }

    /// Creates the CAF file that audio buffers are written to during recording.
    ///
    /// - Throws: `RecordingError.noApplicationSupportDirectory` if the standard
    ///   directory cannot be resolved (e.g. sandbox container not yet provisioned).
    /// - Throws: Any `AVAudioFile` or `FileManager` error on I/O failure.
    private func makeAudioFile(format: AVAudioFormat) throws -> AVAudioFile {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw RecordingError.noApplicationSupportDirectory
        }
        let dir = support.appendingPathComponent("Orin/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let name = "meeting-\(formatter.string(from: Date())).caf"
        return try AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: format.settings)
    }

    // MARK: - Testing support

#if DEBUG
    /// Simulates the recognition-task callback applying a transcript update.
    ///
    /// In production this is done inside `Task { @MainActor in }` inside
    /// `startRecognitionTask`.  The test hook exercises the identical state
    /// mutation path — from `@MainActor` context — so the compiler can verify
    /// the isolation at build time.
    func _testApplyTranscript(_ text: String) {
        transcript = transcriptPrefix.isEmpty ? text : transcriptPrefix + text
    }

    /// Simulates a 60-second session-boundary accumulation (finalises the current
    /// transcript segment into `transcriptPrefix` for the next session).
    func _testFinalizeTranscriptSegment() {
        if !transcript.isEmpty {
            transcriptPrefix = transcript + " "
        }
    }

    /// Resets transcript and prefix — call in test `setUp`/`tearDown`.
    func _testResetTranscriptState() {
        transcript      = ""
        transcriptPrefix = ""
    }

    /// Simulates one Timer tick updating `elapsedSeconds`.
    ///
    /// In production this is done inside `Task { @MainActor in }` inside the
    /// Timer callback.  Calling it from `@MainActor` test context proves the
    /// compiler enforces the isolation invariant.
    func _testFireTimerTick() {
        elapsedSeconds += 1
    }

    /// Resets `elapsedSeconds` to zero — call in test `setUp`/`tearDown`.
    func _testResetElapsedSeconds() {
        elapsedSeconds = 0
    }
#endif

    // MARK: - Error type

    enum RecordingError: LocalizedError {
        case noApplicationSupportDirectory

        var errorDescription: String? {
            "Unable to locate the Application Support directory. "
            + "Ensure the app is signed and running in its expected sandbox container."
        }
    }
}
