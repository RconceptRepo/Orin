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

    /// True when recording has been initiated (`.starting`) or is actively running (`.recording`).
    /// Including `.starting` prevents `startRecordingFromDetectedMeeting()` from racing past the
    /// guard and creating a new auto-titled meeting while a MeetingDetailView-initiated recording
    /// is still in its setup phase.
    var isRecording: Bool { phase == .recording || phase == .starting }

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
    /// Counts how many callbacks would have triggered the removed utterance-boundary
    /// heuristic this session. Reset at session start.
    @ObservationIgnored private var probeHeuristicFireCount = 0
    /// Cumulative extra characters the heuristic would have injected. Reset at start.
    @ObservationIgnored private var probeHeuristicExtraChars = 0
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

    // MARK: - SpeechTranscriber mic pipeline (Phase 2A — feature-flagged, macOS 26+)
    //
    // Properties that hold macOS-26-only types are declared as `Any?` so the class
    // can compile against a macOS 14 deployment target. Actual SpeechAnalyzer /
    // SpeechTranscriber / MicTranscriberFeed objects are created and accessed only
    // inside `if #available(macOS 26.0, *)` guards.

    @ObservationIgnored private var micSTFeed: Any?              // MicTranscriberFeed
    @ObservationIgnored private var micSTAnalyzer: Any?          // SpeechAnalyzer
    @ObservationIgnored private var micSTTranscriber: Any?       // SpeechTranscriber
    @ObservationIgnored private var micSTAnalyzeTask: Task<Void, Never>?
    @ObservationIgnored private var micSTResultsTask: Task<Void, Never>?
    @ObservationIgnored private var micSTSamplingTask: Task<Void, Never>?
    @ObservationIgnored private var micSTMetrics: MicSTSessionMetrics?

    /// Token returned by `NotificationCenter.addObserver(forName:...)` for the
    /// AVAudioEngineConfigurationChange handler. Stored so it can be removed in
    /// `stopRecording` and `teardownAudioEngine` — forgetting to remove a block-based
    /// observer leaks the closure and keeps `self` alive indefinitely.
    @ObservationIgnored private var audioEngineConfigObserver: NSObjectProtocol?

    /// Debounce timestamp for AVAudioEngineConfigurationChange. macOS fires two
    /// notifications in rapid succession when earbuds connect (device change + sample
    /// rate change). The second arrives ~4ms after the first handler restarts the engine;
    /// calling installTap on a running engine crashes Core Audio. Suppress any second
    /// notification that arrives within 500ms of the previous one.
    @ObservationIgnored private var lastRouteChangeTime: ContinuousClock.Instant?

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

        // Permission requirements differ per pipeline:
        // - Legacy (SFSpeechRecognizer): both mic + speech recognition permission required.
        // - New (SpeechTranscriber): only mic; the sandbox entitlement covers speech access.
        if FeatureFlags.useNewMicPipeline {
            if !hasMicPermission {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
        } else {
            if !hasMicPermission || !hasSpeechPermission {
                print("STEP 1: requesting permissions (suspended)")
                await requestPermissions()
                print("STEP 1: permissions returned hasMic=\(hasMicPermission) hasSpeech=\(hasSpeechPermission)")
            }
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

        // Legacy only: verify speech recognition permission + recognizer availability.
        // SpeechTranscriber uses a sandbox entitlement; no runtime authorization is needed.
        let legacyRecognizer: SFSpeechRecognizer?
        if FeatureFlags.useNewMicPipeline {
            legacyRecognizer = nil
            print("STEP 1: SpeechTranscriber pipeline selected — no speech permission required")
        } else {
            guard hasSpeechPermission else {
                print("STEP 1: speech recognition access denied")
                errorMessage = "Speech Recognition access denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
                phase = .idle
                return
            }
            guard let r = speechRecognizer, r.isAvailable else {
                print("STEP 1: speech recognizer unavailable")
                errorMessage = "Speech recognition is unavailable on this device."
                phase = .idle
                return
            }
            legacyRecognizer = r
            print("STEP 1: permissions OK — mic=\(hasMicPermission) speech=\(hasSpeechPermission)")
        }

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

        activeMeetingID          = meetingID
        transcriptPrefix         = ""
        transcriptChunkCount     = 0
        recognitionGeneration    = 0
        probeHeuristicFireCount  = 0
        probeHeuristicExtraChars = 0
        SessionLogger.shared.startSession()
        SessionLogger.shared.log("[Mic] session started meetingID=\(String(describing: meetingID))")
        if let recognizer = legacyRecognizer {
            RecognitionDiagnostics.shared.resetMicChannel(
                sessionID: meetingID?.uuidString ?? "none",
                authStatus: SFSpeechRecognizer.authorizationStatus(),
                recognizerAvailable: recognizer.isAvailable,
                supportsOnDevice: recognizer.supportsOnDeviceRecognition,
                locale: recognizer.locale.identifier
            )
            SessionLogger.shared.log("[Mic] recognizer available=\(recognizer.isAvailable) supportsOnDevice=\(recognizer.supportsOnDeviceRecognition) auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        } else {
            RecognitionDiagnostics.shared.resetMicChannel(
                sessionID: meetingID?.uuidString ?? "none",
                authStatus: .notDetermined,
                recognizerAvailable: false,
                supportsOnDevice: true,
                locale: "en-US"
            )
            SessionLogger.shared.log("[Mic-ST] SpeechTranscriber pipeline active — no SFSpeechRecognizer")
        }

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
        // immediately after installation, so audioFile must be valid at that moment.
        if let recognizer = legacyRecognizer {
            // Legacy path: arm with both audioFile and recognition request.
            let initialRequest = buildRecognitionRequest(recognizer: recognizer)
            tapState.arm(audioFile: audioFile, recognitionRequest: initialRequest)
            startRecognitionTask(with: recognizer, request: initialRequest)

            // ── STEP 5: install tap (legacy) ──────────────────────────────────
            print("STEP 5: installing tap [legacy SFSpeechRecognizer]")
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [tapState] buffer, _ in
                tapState.feed(buffer: buffer)
            }
        } else {
            // New path: arm tapState for file-only recording, then set up ST pipeline.
            tapState.arm(audioFile: audioFile)
            if #available(macOS 26.0, *) {
                do {
                    try await startMicSTSession(inputFormat: format)
                } catch {
                    print("STEP 5: SpeechTranscriber setup failed — \(error)")
                    teardownAudioEngine()
                    errorMessage = "SpeechTranscriber setup failed: \(error.localizedDescription)"
                    phase = .idle
                    return
                }
            } else {
                print("STEP 5: SpeechTranscriber requires macOS 26 — falling back to idle")
                teardownAudioEngine()
                errorMessage = "SpeechTranscriber requires macOS 26 or later."
                phase = .idle
                return
            }

            // ── STEP 5: install tap (SpeechTranscriber) ───────────────────────
            // Tap closure captures tapState (file write) and micSTFeed (ST feed) —
            // neither touches self, keeping the real-time thread off @Observable state.
            // The `micSTFeed` Any? cast under #available is a single O(1) check per buffer.
            print("STEP 5: installing tap [SpeechTranscriber]")
            let capturedSTFeed = micSTFeed
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [tapState, capturedSTFeed] buffer, _ in
                tapState.feed(buffer: buffer)
                if #available(macOS 26.0, *),
                   let feed = capturedSTFeed as? MicTranscriberFeed {
                    feed.feed(buffer)
                }
            }
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

        // When the user switches audio devices mid-session (e.g. plugging in earbuds),
        // macOS changes the default input device and AVAudioEngine automatically stops,
        // posting AVAudioEngineConfigurationChange. Without a handler the tap goes silent
        // for the rest of the session. handleAudioEngineConfigChange reinstalls the tap
        // on the new device and restarts the engine without tearing down SpeechTranscriber.
        audioEngineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAudioEngineConfigChange()
            }
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
        SessionLogger.shared.log(
            "[Mic] utterance-boundary SESSION TOTAL"
            + " fires=\(probeHeuristicFireCount)"
            + " savedExtraChars=\(probeHeuristicExtraChars)"
            + " finalTranscriptChars=\(transcript.count)"
        )
        phase = .stopping

        durationTimer?.invalidate()
        durationTimer = nil

        if let obs = audioEngineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            audioEngineConfigObserver = nil
        }

        audioEngine.stop()

        // `removeTap` must precede `disarm` so that `feed` cannot be executing
        // on the audio thread while the tap state is being cleared.
        audioEngine.inputNode.removeTap(onBus: 0)

        // Stop CPU/RAM sampling and write the benchmark summary to the session log
        // before `endSession()` closes it. The sampling task is cancelled first so
        // no new samples race with `summary(sessionEndTime:)`.
        micSTSamplingTask?.cancel()
        micSTSamplingTask = nil
        if FeatureFlags.useNewMicPipeline, let metrics = micSTMetrics {
            let snapshot = metrics.summary(sessionEndTime: CFAbsoluteTimeGetCurrent())
            for line in snapshot.components(separatedBy: "\n") where !line.isEmpty {
                SessionLogger.shared.log(line)
            }
        }
        micSTMetrics = nil

        // Cancel the recognition task **before** `disarm` calls `endAudio` so
        // the final-result callback sees `isRecording == false` and does not
        // attempt a transparent session restart.
        if FeatureFlags.useNewMicPipeline, #available(macOS 26.0, *) {
            let capturedAnalyzer    = micSTAnalyzer as? SpeechAnalyzer
            let capturedAnalyzeTask = micSTAnalyzeTask
            let capturedResultsTask = micSTResultsTask
            (micSTFeed as? MicTranscriberFeed)?.disarm()
            micSTFeed        = nil
            micSTAnalyzer    = nil
            micSTTranscriber = nil
            micSTAnalyzeTask = nil
            micSTResultsTask = nil
            Task {
                if let a = capturedAnalyzer {
                    try? await a.finalizeAndFinishThroughEndOfInput()
                }
                await capturedAnalyzeTask?.value
                await capturedResultsTask?.value
                SessionLogger.shared.log("[Mic-ST] finalization complete")
            }
        } else {
            recognitionTask?.cancel()
            RecognitionDiagnostics.shared.micTaskCancelled()
            recognitionTask = nil
        }

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
        RecognitionDiagnostics.shared.setMicFinalGeneration(recognitionGeneration)
        let diagSummary = RecognitionDiagnostics.shared.save(logPath: SessionLogger.shared.currentLogPath)
        RecognitionDiagnostics.shared.saveCoverageReport(
            logPath: SessionLogger.shared.currentLogPath,
            elapsedSeconds: elapsedSeconds
        )
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
        // Force on-device recognition — eliminates error 1110.
        // The framework default (false) uses Apple's servers; two concurrent channels
        // (mic + participant) compete for one device slot → continuous 1110 errors and
        // system slowdown. On-device has no concurrency limit and no network overhead.
        request.requiresOnDeviceRecognition = true
        RecognitionDiagnostics.shared.setMicRequestConfig(requiresOnDevice: true)
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
        RecognitionDiagnostics.shared.micGenerationStarted(gen: gen, charsAtStart: transcriptPrefix.count)
        let taskCreationTime = CFAbsoluteTimeGetCurrent()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.recognitionGeneration != gen {
                    if result != nil {
                        // Task produced a result after 1110/cancel — proves callbacks continue
                        SessionLogger.shared.log("[Mic] STALE_RESULT gen=\(gen) current=\(self.recognitionGeneration)")
                        RecognitionDiagnostics.shared.micStaleResult()
                    }
                    return
                }

                if let result {
                    RecognitionDiagnostics.shared.micRecognitionCallback()
                    if !self.generationHadSpeech {
                        let firstCallbackTime = CFAbsoluteTimeGetCurrent()
                        let latencySeconds = firstCallbackTime - taskCreationTime
                        SessionLogger.shared.log(
                            "[Mic] firstCallbackLatency gen=\(gen)"
                            + " taskCreated=\(String(format: "%.3f", taskCreationTime))"
                            + " firstCallback=\(String(format: "%.3f", firstCallbackTime))"
                            + " latencySeconds=\(String(format: "%.3f", latencySeconds))"
                        )
                    }
                    self.generationHadSpeech = true
                    let segment = result.bestTranscription.formattedString
                    let prevTotal = self.transcript.count
                    let prevInGen = prevTotal - self.transcriptPrefix.count
                    let candidateTotal = self.transcriptPrefix.count + segment.count

                    // On macOS 26 server recognition, Apple resets the recognition
                    // window at sentence boundaries without firing isFinal. When this
                    // happens, formattedString shrinks back to a tiny partial of the
                    // next sentence — if not caught, the full accumulated transcript
                    // collapses to those few chars. Save the full accumulated text to
                    // prefix before the window resets.
                    // For partial results: discard the tiny segment rather than appending
                    // it — appending would duplicate tail words of the committed prefix.
                    // The segment reappears and grows naturally in the next callback.
                    if !self.transcript.isEmpty,
                       candidateTotal < self.transcript.count,
                       segment.count <= 20 {
                        self.probeHeuristicFireCount  += 1
                        self.probeHeuristicExtraChars += (prevInGen + 1)
                        self.transcriptPrefix = self.transcript + " "
                        self.transcript = result.isFinal
                            ? self.transcriptPrefix + segment
                            : self.transcriptPrefix
                        SessionLogger.shared.log(
                            "[Mic] utterance-boundary fire #\(self.probeHeuristicFireCount)"
                            + " chunk=\(self.transcriptChunkCount + 1) gen=\(gen)"
                            + " prevTotal=\(prevTotal) segLen=\(segment.count)"
                            + " isFinal=\(result.isFinal)"
                        )
                    } else {
                        self.transcript = self.transcriptPrefix.isEmpty
                            ? segment
                            : self.transcriptPrefix + segment
                    }
                    RecognitionDiagnostics.shared.micGenerationCallback(
                        gen: gen, chars: self.transcript.count,
                        snippet: String(segment.prefix(50))
                    )
                    self.transcriptChunkCount += 1
                    let delta = self.transcript.count - prevTotal
                    let retracted = max(0, prevInGen - segment.count)
                    SessionLogger.shared.log(
                        "[Mic] chunk #\(self.transcriptChunkCount) gen=\(gen)"
                        + " seg=\(segment.count) prev=\(prevTotal) total=\(self.transcript.count)"
                        + " delta=\(delta >= 0 ? "+\(delta)" : "\(delta)") retracted=\(retracted)"
                        + " isFinal=\(result.isFinal)"
                    )
                    ServiceContainer.shared.resolve(TranscriptStore.self)
                        .updateMic(self.speakerTranscript)
                }

                if result?.isFinal == true, self.isRecording {
                    SessionLogger.shared.log("[Mic] isFinal gen=\(gen) total=\(self.transcript.count) — starting gen \(gen + 1)")
                    RecognitionDiagnostics.shared.micGenerationEnded(
                        gen: gen, errorCode: 0, chars: self.transcript.count,
                        lastSnippet: String(self.transcript.suffix(50))
                    )
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
                        RecognitionDiagnostics.shared.micGenerationEnded(
                            gen: gen, errorCode: nsError.code, chars: self.transcript.count,
                            lastSnippet: String(self.transcript.suffix(50))
                        )
                        // Mode B: do NOT restart on 1110 — observe whether the task
                        // continues producing callbacks after Apple fires the error.
                        // staleResults counter in diagnostics will show if any arrive.
                        if RecognitionDiagnostics.experimentMode == "B" && nsError.code == 1110 {
                            SessionLogger.shared.log("[Mic] MODE_B gen=\(gen) 1110 ignored — no restart")
                            return
                        }
                        RecognitionDiagnostics.shared.micError(nsError.code)
                        if !self.transcript.isEmpty {
                            self.transcriptPrefix = self.transcript + " "
                        }
                        let nextGen = self.recognitionGeneration + 1
                        self.recognitionGeneration = nextGen
                        // 1110 = on-device VAD boundary.
                        // - Speech heard this gen (segment boundary): restart in 200ms.
                        // - No speech yet (startup silence): back off 1 s to avoid a
                        //   tight create→1110→restart spiral that blocks all transcription.
                        let hadSpeech = self.generationHadSpeech
                        let delay: UInt64 = (nsError.code == 1110 && hadSpeech) ? 200_000_000 : 1_000_000_000
                        let delayLabel = (nsError.code == 1110 && hadSpeech) ? "200ms" : "1s"
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

        // Cold-start watchdog: on-device model can hang indefinitely on first load,
        // producing 0 callbacks despite active audio. Cancel and restart after 10 s
        // if no callback has arrived and the session is still on the same generation.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.isRecording,
                  self.recognitionGeneration == gen,
                  !self.generationHadSpeech else { return }
            let nextGen = self.recognitionGeneration + 1
            self.recognitionGeneration = nextGen
            SessionLogger.shared.log(
                "[Mic] watchdog fired gen=\(gen) → \(nextGen) — 0 callbacks after 10s, restarting"
            )
            RecognitionDiagnostics.shared.micGenerationEnded(
                gen: gen, errorCode: -1, chars: self.transcript.count,
                lastSnippet: ""
            )
            RecognitionDiagnostics.shared.micError(-1)
            let nextRequest = self.buildRecognitionRequest(recognizer: recognizer)
            self.tapState.updateRequest(nextRequest)
            self.recognitionTask?.cancel()
            RecognitionDiagnostics.shared.micTaskCancelled()
            self.recognitionTask = nil
            self.startRecognitionTask(with: recognizer, request: nextRequest)
        }
    }

    // MARK: - Helpers

    /// Tears down the audio engine after a mid-startup failure.
    /// Safe to call when no tap is installed (removeTap on an untapped bus is a no-op).
    private func teardownAudioEngine() {
        if let obs = audioEngineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            audioEngineConfigObserver = nil
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        micSTSamplingTask?.cancel()
        micSTSamplingTask = nil
        micSTMetrics = nil
        if FeatureFlags.useNewMicPipeline, #available(macOS 26.0, *) {
            (micSTFeed as? MicTranscriberFeed)?.disarm()
            micSTFeed        = nil
            micSTAnalyzeTask?.cancel()
            micSTAnalyzeTask = nil
            micSTResultsTask?.cancel()
            micSTResultsTask = nil
            micSTAnalyzer    = nil
            micSTTranscriber = nil
        } else {
            recognitionTask?.cancel()
            RecognitionDiagnostics.shared.micTaskCancelled()
            recognitionTask = nil
        }
        tapState.disarm()
    }

    // MARK: - Audio device hot-swap handler

    /// Called when AVAudioEngine posts AVAudioEngineConfigurationChange — i.e. the user
    /// plugged in earbuds, changed the default input device, or the system re-routed audio.
    /// The engine is already stopped by the time this fires. We reinstall the tap on the
    /// (potentially new) input node and restart the engine without touching SpeechTranscriber,
    /// so transcription continues uninterrupted on the new device.
    @MainActor
    private func handleAudioEngineConfigChange() {
        guard phase == .recording else { return }

        let now = ContinuousClock.now
        if let last = lastRouteChangeTime, now - last < .milliseconds(500) {
            SessionLogger.shared.log("[Mic] route change: duplicate notification suppressed (< 500ms since last)")
            return
        }
        lastRouteChangeTime = now

        let inputNode = audioEngine.inputNode
        let newFormat = inputNode.outputFormat(forBus: 0)
        SessionLogger.shared.log(
            "[Mic] audio route changed — reinstalling tap"
            + " newFmt=\(newFormat.sampleRate)Hz/\(newFormat.channelCount)ch"
        )

        guard newFormat.sampleRate > 0 else {
            SessionLogger.shared.log("[Mic] route change: new device has invalid format — not re-arming")
            return
        }

        // Remove the stale tap. The engine is already stopped; removeTap is a no-op
        // on an untapped bus, so this is safe whether or not the tap survived the stop.
        inputNode.removeTap(onBus: 0)

        if FeatureFlags.useNewMicPipeline, #available(macOS 26.0, *) {
            // Rebuild the resampling converter for the new device's input format.
            // This is necessary when earbuds have a different native sample rate than
            // the built-in mic (e.g. 16 kHz earbuds vs 48 kHz built-in).
            if let feed = micSTFeed as? MicTranscriberFeed {
                let rebuilt = feed.rebuildConverter(inputFormat: newFormat)
                SessionLogger.shared.log(
                    "[Mic] route change: converter rebuild=\(rebuilt)"
                    + " fmt=\(Int(newFormat.sampleRate))Hz/\(newFormat.channelCount)ch"
                )
            }
            let capturedSTFeed = micSTFeed
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: newFormat) { [tapState, capturedSTFeed] buffer, _ in
                tapState.feed(buffer: buffer)
                if #available(macOS 26.0, *),
                   let feed = capturedSTFeed as? MicTranscriberFeed {
                    feed.feed(buffer)
                }
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: newFormat) { [tapState] buffer, _ in
                tapState.feed(buffer: buffer)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            SessionLogger.shared.log("[Mic] route change: engine restarted successfully")
        } catch {
            SessionLogger.shared.log("[Mic] route change: engine restart failed — \(error)")
        }
    }

    // MARK: - SpeechTranscriber mic session (Phase 2A)

    /// Sets up the SpeechTranscriber analysis pipeline for the mic channel.
    ///
    /// `tapState.arm(audioFile:)` must be called before this method. The method
    /// arms `micSTFeed`, starts the `SpeechAnalyzer`, and launches two tasks:
    ///  - `micSTAnalyzeTask`: feeds the AsyncStream into the analyzer.
    ///  - `micSTResultsTask`: drains `transcriber.results` and pushes to TranscriptStore.
    ///
    /// - Parameter inputFormat: The AVAudioEngine tap format (e.g. 48 kHz Float32).
    /// - Throws: `MicSTError` if no compatible audio format or converter is available.
    @available(macOS 26.0, *)
    private func startMicSTSession(inputFormat: AVAudioFormat) async throws {
        let locale = VocabularyProvider.speechLocale
        // .progressiveTranscription emits isFinal results every ~1-2s rather than waiting
        // for a full utterance boundary (~14s with .transcription). This eliminates the
        // long-buffer window that caused hallucinations on the first chunk.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let vocab = VocabularyProvider.allTerms
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocab.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = vocab
            try await analyzer.setContext(ctx)
        }

        guard let bestFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MicSTError.noAvailableFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: bestFmt) else {
            throw MicSTError.converterFailed(inputFormat: inputFormat, outputFormat: bestFmt)
        }

        SessionLogger.shared.log(
            "[Mic-ST] preparing"
            + " inputFmt=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch"
            + " targetFmt=\(bestFmt.sampleRate)Hz/\(bestFmt.channelCount)ch"
            + " locale=\(locale.identifier)"
            + " vocab=\(vocab.count)terms"
        )

        try await analyzer.prepareToAnalyze(in: bestFmt)
        SessionLogger.shared.log("[Mic-ST] prepareToAnalyze complete")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let feed = MicTranscriberFeed()
        feed.arm(continuation: continuation, converter: converter, targetFormat: bestFmt)
        micSTFeed        = feed
        micSTAnalyzer    = analyzer
        micSTTranscriber = transcriber

        let metrics = MicSTSessionMetrics()
        micSTMetrics = metrics
        micSTSamplingTask = Task.detached { [weak metrics] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                metrics?.record(cpu: sampleCPUUsage(), ram: sampleRAMMB())
            }
        }

        micSTAnalyzeTask = Task.detached {
            do {
                _ = try await analyzer.analyzeSequence(stream)
                await SessionLogger.shared.log("[Mic-ST] analyzeSequence returned")
            } catch {
                await SessionLogger.shared.log("[Mic-ST] analyzeSequence error: \(error)")
            }
        }

        micSTResultsTask = Task { @MainActor [weak self, metrics] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    // Skip progressive (non-final) results — they are intermediate
                    // refinements of an in-progress utterance. Only isFinal results
                    // represent a committed, stable transcription segment.
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if self.transcript.isEmpty {
                        self.transcript = text
                    } else {
                        self.transcript += " " + text
                    }
                    self.transcriptChunkCount += 1
                    metrics.recordResult(text: text, time: CFAbsoluteTimeGetCurrent())
                    SessionLogger.shared.log(
                        "[Mic-ST] chunk #\(self.transcriptChunkCount)"
                        + " seg=\(text.count)ch total=\(self.transcript.count)ch"
                        + " snippet=\"\(String(text.prefix(50)))\""
                    )
                    RecognitionDiagnostics.shared.micGenerationCallback(
                        gen: 0, chars: self.transcript.count,
                        snippet: String(text.prefix(50))
                    )
                    ServiceContainer.shared.resolve(TranscriptStore.self)
                        .updateMic(self.speakerTranscript)
                }
            } catch {
                SessionLogger.shared.log("[Mic-ST] results error: \(error)")
            }
            SessionLogger.shared.log(
                "[Mic-ST] results sequence complete total=\(self.transcript.count)ch"
            )
        }

        SessionLogger.shared.log("[Mic-ST] session ready")
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

// MARK: - MicSTError (Phase 2A)

@available(macOS 26.0, *)
private enum MicSTError: LocalizedError {
    case noAvailableFormat
    case converterFailed(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat)

    var errorDescription: String? {
        switch self {
        case .noAvailableFormat:
            return "SpeechTranscriber: no compatible audio format available on this device."
        case let .converterFailed(i, o):
            return "SpeechTranscriber: cannot build converter from \(i.sampleRate)Hz to \(o.sampleRate)Hz."
        }
    }
}

// MARK: - MicTranscriberFeed (Phase 2A)

/// Thread-safe bridge between the Core-Audio real-time tap and the SpeechTranscriber
/// AsyncStream. Resamples each captured buffer to the analyser's required format
/// (16 kHz Int16 mono) and yields it as an `AnalyzerInput`.
///
/// `@unchecked Sendable`: every property is accessed exclusively under `lock` (NSLock),
/// which serialises the Core-Audio I/O thread (`feed`) and the MainActor (`arm`/`disarm`).
@available(macOS 26.0, *)
private final class MicTranscriberFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter:    AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    func arm(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        converter:    AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        lock.withLock {
            self.continuation = continuation
            self.converter    = converter
            self.targetFormat = targetFormat
        }
    }

    /// Finish the stream continuation and release all resources.
    /// Finishing the continuation triggers `analyzeSequence` to return once the
    /// stream drains; call `finalizeAndFinishThroughEndOfInput()` after that to
    /// close `transcriber.results`.
    func disarm() {
        var cont: AsyncStream<AnalyzerInput>.Continuation?
        lock.withLock {
            cont              = self.continuation
            self.continuation = nil
            self.converter    = nil
            self.targetFormat = nil
        }
        cont?.finish()
    }

    /// Rebuilds the AVAudioConverter for a new input format after an audio route change.
    /// Called from the main actor before the new tap is installed.
    /// Returns true if a new converter was successfully created; false if not armed or
    /// the converter cannot be built (e.g. incompatible format pair).
    func rebuildConverter(inputFormat: AVAudioFormat) -> Bool {
        lock.withLock {
            guard let tf = self.targetFormat,
                  let newConverter = AVAudioConverter(from: inputFormat, to: tf) else {
                return false
            }
            self.converter = newConverter
            return true
        }
    }

    /// Convert and forward one audio buffer. No-ops when not armed.
    /// Called on the Core-Audio real-time I/O thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let cont = continuation,
                  let conv = converter,
                  let fmt  = targetFormat else { return }

            let ratio  = fmt.sampleRate / buffer.format.sampleRate
            let dstCap = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 64)
            guard let dst = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: dstCap) else { return }

            var srcConsumed = false
            let status = conv.convert(to: dst, error: nil) { _, outStatus in
                if srcConsumed { outStatus.pointee = .noDataNow; return nil }
                srcConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, dst.frameLength > 0 else { return }
            cont.yield(AnalyzerInput(buffer: dst))
        }
    }
}

// MARK: - MicSTSessionMetrics (Phase 2A benchmark)

/// Accumulates performance metrics for the SpeechTranscriber mic pipeline.
/// Written to SessionLogger as a `[Mic-ST Summary]` block at the end of each session.
///
/// All mutation is serialised under `lock`; safe to call from both MainActor
/// (result callbacks) and Task.detached (CPU/RAM sampling).
final class MicSTSessionMetrics: @unchecked Sendable {

    private let lock = NSLock()

    /// Wall-clock reference for latency and duration calculations.
    /// Set once at init; never mutated.
    let sessionStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    private var _firstResultTime: CFAbsoluteTime?
    private var _lastResultTime:  CFAbsoluteTime?
    private var _segmentCount  = 0
    private var _totalWords    = 0
    private var _totalChars    = 0
    private var _maxGap:       Double = 0
    private var _totalGapTime: Double = 0
    private var _gapCount      = 0
    private var _cpuSamples:   [Double] = []
    private var _ramSamples:   [Double] = []

    /// Record one transcription result. Call from the results task on MainActor.
    func recordResult(text: String, time: CFAbsoluteTime) {
        lock.withLock {
            if _firstResultTime == nil { _firstResultTime = time }
            if let prev = _lastResultTime {
                let gap = time - prev
                _totalGapTime += gap
                _gapCount     += 1
                if gap > _maxGap { _maxGap = gap }
            }
            _lastResultTime  = time
            _segmentCount   += 1
            _totalChars     += text.count
            _totalWords     += text.split(whereSeparator: \.isWhitespace).count
        }
    }

    /// Record one CPU/RAM sample. Call from the periodic sampling Task.detached.
    func record(cpu: Double, ram: Double) {
        lock.withLock {
            _cpuSamples.append(cpu)
            _ramSamples.append(ram)
        }
    }

    /// Build the formatted `[Mic-ST Summary]` string. Call once at session end.
    func summary(sessionEndTime: CFAbsoluteTime) -> String {
        lock.withLock {
            let duration = sessionEndTime - sessionStartTime
            let durMins  = Int(duration) / 60
            let durSecs  = Int(duration) % 60

            let latency = _firstResultTime.map { $0 - sessionStartTime }

            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss.SSS"
            let firstCallbackStr = _firstResultTime
                .map { fmt.string(from: Date(timeIntervalSinceReferenceDate: $0)) } ?? "n/a"
            let lastCallbackStr  = _lastResultTime
                .map { fmt.string(from: Date(timeIntervalSinceReferenceDate: $0)) } ?? "n/a"

            let wpm = duration > 0 ? Double(_totalWords) / (duration / 60.0) : 0

            let avgGap  = _gapCount > 0 ? _totalGapTime / Double(_gapCount) : 0
            let cpuAvg  = _cpuSamples.isEmpty ? 0.0 : _cpuSamples.reduce(0, +) / Double(_cpuSamples.count)
            let cpuPeak = _cpuSamples.max() ?? 0.0
            let ramAvg  = _ramSamples.isEmpty ? 0.0 : _ramSamples.reduce(0, +) / Double(_ramSamples.count)
            let ramPeak = _ramSamples.max() ?? 0.0

            let latStr  = latency.map { String(format: "%.2fs", $0) } ?? "n/a"
            let gapLong = _maxGap > 0 ? String(format: "%.2fs", _maxGap) : "n/a"
            let gapAvg  = _gapCount > 0 ? String(format: "%.2fs", avgGap) : "n/a"

            return """
            [Mic-ST Summary]
              SpeechTranscriber enabled = true
              SFSpeechRecognizer enabled = false
              duration = \(durMins)m \(durSecs)s
              first result latency = \(latStr)
              first transcript callback = \(firstCallbackStr)
              last transcript callback = \(lastCallbackStr)
              total words = \(_totalWords)
              total characters = \(_totalChars)
              total segments = \(_segmentCount)
              words per minute = \(String(format: "%.1f", wpm))
              longest result gap = \(gapLong)
              average result gap = \(gapAvg)
              CPU average = \(String(format: "%.1f%%", cpuAvg))
              CPU peak = \(String(format: "%.1f%%", cpuPeak))
              RAM average = \(String(format: "%.0f MB", ramAvg))
              RAM peak = \(String(format: "%.0f MB", ramPeak))
            """
        }
    }
}

// MARK: - System metrics sampling

/// Returns the current process CPU usage summed across all threads.
/// Based on `thread_basic_info.cpu_usage` scaled by `TH_USAGE_SCALE`.
private func sampleCPUUsage() -> Double {
    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
          let list = threadList else { return 0 }
    defer {
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
    }
    var total = 0.0
    for i in 0..<Int(threadCount) {
        var info  = thread_basic_info()
        var count = mach_msg_type_number_t(THREAD_INFO_MAX)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
        }
    }
    return total
}

/// Returns the current process resident memory in megabytes via `mach_task_basic_info`.
private func sampleRAMMB() -> Double {
    var info  = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / (1024.0 * 1024.0)
}
