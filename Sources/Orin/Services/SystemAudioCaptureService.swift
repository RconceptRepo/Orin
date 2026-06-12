import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
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
    @ObservationIgnored private var recognitionGeneration = 0
    @ObservationIgnored private var generationHadSpeech = false
    /// Counts how many callbacks would have triggered the removed utterance-boundary
    /// heuristic this session. Reset at session start.
    @ObservationIgnored private var probeHeuristicFireCount = 0
    /// Cumulative extra characters the heuristic would have injected. Reset at start.
    @ObservationIgnored private var probeHeuristicExtraChars = 0
    private let logger = Logger(subsystem: "com.clavrit.orin", category: "SystemAudioService")

    // MARK: - Phase 2B: parallel SpeechTranscriber participant pipeline (macOS 26+)
    //
    // Properties that hold macOS-26-only types are declared as `Any?` so the class
    // can compile against a macOS 14 deployment target.

    @ObservationIgnored private var participantSTFeed: Any?          // ParticipantSTFeed
    @ObservationIgnored private var participantSTAnalyzer: Any?      // SpeechAnalyzer
    @ObservationIgnored private var participantSTTranscriber: Any?   // SpeechTranscriber
    @ObservationIgnored private var participantSTAnalyzeTask: Task<Void, Never>?
    @ObservationIgnored private var participantSTResultsTask: Task<Void, Never>?
    @ObservationIgnored private var participantSTTranscript = ""

    // MARK: - Capture Lifecycle

    /// Starts system audio capture for the given meeting session.
    ///
    /// Silently returns (without crashing or affecting mic recording) if:
    ///  - Speech recognition is not authorized
    ///  - Screen Recording permission is denied
    ///  - No display is found
    ///  - `SCStream` fails to start
    func startCapturing(for meetingID: UUID?) async {
        // Start session log before every guard so all exits are recorded.
        // startSession() is idempotent — RecordingService may have already opened it.
        SessionLogger.shared.startSession()

        guard !isCapturing else {
            SessionLogger.shared.log(
                "[Participant] EXIT_01 already capturing"
                + " auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)"
                + " recognizerAvail=\(speechRecognizer?.isAvailable ?? false)"
            )
            return
        }
        // Set isCapturing = true BEFORE the first await so a concurrent call
        // cannot slip past the guard above while SCShareableContent is fetched.
        isCapturing = true

        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        SessionLogger.shared.log(
            "[Participant] STEP_01 entered"
            + " meetingID=\(String(describing: meetingID))"
            + " auth=\(speechAuth.rawValue)"
            + " recognizerNil=\(speechRecognizer == nil)"
            + " recognizerAvail=\(speechRecognizer?.isAvailable ?? false)"
        )

        guard speechAuth == .authorized else {
            SessionLogger.shared.log(
                "[Participant] EXIT_02 speech not authorized"
                + " auth=\(speechAuth.rawValue)"
                + " recognizerAvail=\(speechRecognizer?.isAvailable ?? false)"
                + " displays=N/A SCKit=not_called"
            )
            isCapturing = false
            return
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            SessionLogger.shared.log(
                "[Participant] EXIT_03 recognizer nil or unavailable"
                + " auth=\(speechAuth.rawValue)"
                + " recognizerNil=\(speechRecognizer == nil)"
                + " recognizerAvail=\(speechRecognizer?.isAvailable ?? false)"
                + " displays=N/A SCKit=not_called"
            )
            isCapturing = false
            return
        }

        SessionLogger.shared.log(
            "[Participant] STEP_02 recognizer ready"
            + " locale=\(recognizer.locale.identifier)"
            + " available=\(recognizer.isAvailable)"
            + " supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)"
        )

        // Fetch shareable content — requires Screen Recording permission.
        // On macOS 14+ this does NOT show a permission dialog; the user must
        // enable Screen Recording in System Settings → Privacy & Security.
        let cgPreflight = CGPreflightScreenCaptureAccess()
        SessionLogger.shared.log(
            "[Participant] STEP_03 calling SCShareableContent"
            + " CGPreflightScreenCaptureAccess=\(cgPreflight)"
        )
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            let ns = error as NSError
            SessionLogger.shared.log(
                "[Participant] EXIT_04 SCShareableContent threw"
                + " auth=\(speechAuth.rawValue)"
                + " recognizerAvail=\(recognizer.isAvailable)"
                + " displays=N/A"
                + " SCKit=domain:\(ns.domain) code:\(ns.code) desc:\(ns.localizedDescription)"
            )
            isCapturing = false
            return
        }

        let displayCount = content.displays.count
        SessionLogger.shared.log(
            "[Participant] STEP_04 SCShareableContent ok"
            + " displays=\(displayCount)"
            + " windows=\(content.windows.count)"
            + " apps=\(content.applications.count)"
        )

        guard let display = content.displays.first else {
            SessionLogger.shared.log(
                "[Participant] EXIT_05 no displays found"
                + " auth=\(speechAuth.rawValue)"
                + " recognizerAvail=\(recognizer.isAvailable)"
                + " displays=0 SCKit=ok"
            )
            isCapturing = false
            return
        }

        SessionLogger.shared.log("[Participant] STEP_05 display selected id=\(display.displayID)")

        // Reset per-session state
        transcriptPrefix         = ""
        chunkCount               = 0
        transcript               = ""
        recognitionGeneration    = 0
        probeHeuristicFireCount  = 0
        probeHeuristicExtraChars = 0
        RecognitionDiagnostics.shared.resetParticipantChannel(
            authStatus: speechAuth,
            recognizerAvailable: recognizer.isAvailable,
            supportsOnDevice: recognizer.supportsOnDeviceRecognition,
            locale: recognizer.locale.identifier
        )

        // When the SpeechTranscriber pipeline is active, skip the legacy
        // SFSpeechRecognizer entirely. Running it would:
        //   1. Mutate self.transcript on every callback (1300+ times per session)
        //   2. Trigger @Observable on participantSpeakerTranscript
        //   3. Fire unguarded .onChange handlers in MainContainerView and
        //      MeetingsView that overwrite the ST pipeline's TranscriptStore entries
        //      with stale legacy content, causing the participantChars oscillation
        //      observed in session logs.
        if !FeatureFlags.useNewParticipantPipeline {
            let request = buildRecognitionRequest(recognizer: recognizer)
            tapState.arm(request: request)
            SessionLogger.shared.log(
                "[Participant] STEP_06 recognition task creating"
                + " taskHint=\(request.taskHint.rawValue)"
                + " partialResults=\(request.shouldReportPartialResults)"
                + " requiresOnDevice=\(request.requiresOnDeviceRecognition)"
            )
            startRecognitionTask(with: recognizer, request: request)
        } else {
            SessionLogger.shared.log(
                "[Participant] STEP_06 legacy recognizer disabled — useNewParticipantPipeline=YES"
            )
        }

        // Phase 2B: start parallel SpeechTranscriber participant pipeline.
        // Both pipelines receive every SCStream buffer simultaneously.
        // FeatureFlags.useNewParticipantPipeline controls which one writes to TranscriptStore.
        participantSTTranscript = ""
        if #available(macOS 26.0, *) {
            await startParticipantSTSession()
        }

        // Configure SCStream for audio only — minimal video to reduce overhead.
        // sampleRate and channelCount must be set explicitly: on macOS 26 the
        // stream fails with -3818 if the audio format is left for the runtime
        // to negotiate.  excludesCurrentProcessAudio is left at its default
        // (false) — setting it true conflicts with audio routing on macOS 26
        // and is unnecessary since Orin produces no audio output of its own.
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate    = 48000
        config.channelCount  = 2
        config.width                = 2
        config.height               = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        SessionLogger.shared.log(
            "[Participant] STEP_07 SCStream configured"
            + " capturesAudio=\(config.capturesAudio)"
            + " excludesCurrentProcess=\(config.excludesCurrentProcessAudio)"
        )

        let delegate = SystemAudioStreamDelegate(tapState: tapState, stFeed: participantSTFeed) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                SessionLogger.shared.log("[Participant] stream stopped unexpectedly: \(error)")
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
            SessionLogger.shared.log(
                "[Participant] STEP_08 stream started"
                + " auth=\(speechAuth.rawValue)"
                + " recognizerAvail=\(recognizer.isAvailable)"
                + " supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)"
                + " displays=\(displayCount)"
            )
        } catch {
            let ns = error as NSError
            SessionLogger.shared.log(
                "[Participant] EXIT_06 SCStream.startCapture failed"
                + " auth=\(speechAuth.rawValue)"
                + " recognizerAvail=\(recognizer.isAvailable)"
                + " displays=\(displayCount)"
                + " SCKit=domain:\(ns.domain) code:\(ns.code) desc:\(ns.localizedDescription)"
            )
            isCapturing = false
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
        SessionLogger.shared.log(
            "[Participant] utterance-boundary SESSION TOTAL"
            + " fires=\(probeHeuristicFireCount)"
            + " savedExtraChars=\(probeHeuristicExtraChars)"
            + " finalTranscriptChars=\(transcript.count)"
        )
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
        RecognitionDiagnostics.shared.setParticipantFinalGeneration(recognitionGeneration)
        recognitionTask?.cancel()
        RecognitionDiagnostics.shared.participantTaskCancelled()
        recognitionTask = nil
        tapState.disarm()

        // Phase 2B: tear down parallel SpeechTranscriber pipeline
        if #available(macOS 26.0, *) {
            let capturedSTAnalyzer    = participantSTAnalyzer as? SpeechAnalyzer
            let capturedSTAnalyzeTask = participantSTAnalyzeTask
            let capturedSTResultsTask = participantSTResultsTask
            (participantSTFeed as? ParticipantSTFeed)?.disarm()
            participantSTFeed        = nil
            participantSTAnalyzer    = nil
            participantSTTranscriber = nil
            participantSTAnalyzeTask = nil
            participantSTResultsTask = nil
            Task {
                if let a = capturedSTAnalyzer {
                    try? await a.finalizeAndFinishThroughEndOfInput()
                }
                await capturedSTAnalyzeTask?.value
                await capturedSTResultsTask?.value
                SessionLogger.shared.log("[Participant-ST] finalization complete")
            }
        }

        streamDelegate = nil
        print("[SystemAudio] capture stopped — final participantChars=\(transcript.count)")
    }

    // MARK: - Recognition session management

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
        RecognitionDiagnostics.shared.setParticipantRequestConfig(requiresOnDevice: true)
        return request
    }

    /// Starts a recognition task and transparently restarts at the ~60-second
    /// Apple limit.  Mirrors the generation-counter + direct-update pattern in
    /// `RecordingService` — see that service for detailed commentary.
    @MainActor
    private func startRecognitionTask(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        RecognitionDiagnostics.shared.participantTaskCreated()
        generationHadSpeech = false
        let gen = recognitionGeneration
        SessionLogger.shared.log(
            "[Participant] task created gen=\(gen)"
            + " locale=\(recognizer.locale.identifier)"
            + " available=\(recognizer.isAvailable)"
            + " supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)"
            + " auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)"
            + " taskHint=\(request.taskHint.rawValue)"
            + " partialResults=\(request.shouldReportPartialResults)"
            + " requiresOnDevice=\(request.requiresOnDeviceRecognition)"
        )
        RecognitionDiagnostics.shared.participantGenerationStarted(gen: gen, charsAtStart: transcriptPrefix.count)
        let taskCreationTime = CFAbsoluteTimeGetCurrent()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.recognitionGeneration != gen {
                    if result != nil {
                        // Task produced a result after 1110/cancel — proves callbacks continue
                        SessionLogger.shared.log("[Participant] STALE_RESULT gen=\(gen) current=\(self.recognitionGeneration)")
                        RecognitionDiagnostics.shared.participantStaleResult()
                    }
                    return
                }

                if let result {
                    RecognitionDiagnostics.shared.participantRecognitionCallback()
                    if !self.generationHadSpeech {
                        let firstCallbackTime = CFAbsoluteTimeGetCurrent()
                        let latencySeconds = firstCallbackTime - taskCreationTime
                        SessionLogger.shared.log(
                            "[Participant] firstCallbackLatency gen=\(gen)"
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
                            "[Participant] utterance-boundary fire #\(self.probeHeuristicFireCount)"
                            + " chunk=\(self.chunkCount + 1) gen=\(gen)"
                            + " prevTotal=\(prevTotal) segLen=\(segment.count)"
                            + " isFinal=\(result.isFinal)"
                        )
                    } else {
                        self.transcript = self.transcriptPrefix.isEmpty
                            ? segment
                            : self.transcriptPrefix + segment
                    }
                    RecognitionDiagnostics.shared.participantGenerationCallback(
                        gen: gen, chars: self.transcript.count,
                        snippet: String(segment.prefix(50))
                    )
                    self.chunkCount += 1
                    let delta = self.transcript.count - prevTotal
                    let retracted = max(0, prevInGen - segment.count)
                    SessionLogger.shared.log(
                        "[Participant] chunk #\(self.chunkCount) gen=\(gen)"
                        + " seg=\(segment.count) prev=\(prevTotal) total=\(self.transcript.count)"
                        + " delta=\(delta >= 0 ? "+\(delta)" : "\(delta)") retracted=\(retracted)"
                        + " isFinal=\(result.isFinal)"
                    )
                    if !FeatureFlags.useNewParticipantPipeline {
                        ServiceContainer.shared.resolve(TranscriptStore.self)
                            .updateParticipant(self.participantSpeakerTranscript)
                    } else {
                        SessionLogger.shared.log(
                            "[Participant-legacy] chunk (ST active — not forwarding to store)"
                            + " seg=\(segment.count)ch total=\(self.transcript.count)ch"
                        )
                    }
                }

                if result?.isFinal == true, self.isCapturing {
                    SessionLogger.shared.log("[Participant] isFinal gen=\(gen) total=\(self.transcript.count) — starting gen \(gen + 1)")
                    RecognitionDiagnostics.shared.participantGenerationEnded(
                        gen: gen, errorCode: 0, chars: self.transcript.count,
                        lastSnippet: String(self.transcript.suffix(50))
                    )
                    if !self.transcript.isEmpty {
                        self.transcriptPrefix = self.transcript + " "
                    }
                    self.recognitionGeneration += 1
                    let next = self.buildRecognitionRequest(recognizer: recognizer)
                    self.tapState.updateRequest(next)
                    self.recognitionTask?.cancel()
                    RecognitionDiagnostics.shared.participantTaskCancelled()
                    self.recognitionTask = nil
                    self.startRecognitionTask(with: recognizer, request: next)
                    return
                }

                if let error, self.isCapturing {
                    let ns = error as NSError
                    SessionLogger.shared.log(
                        "[Participant] error gen=\(gen)"
                        + " domain=\(ns.domain)"
                        + " code=\(ns.code)"
                        + " desc=\(ns.localizedDescription)"
                    )
                    if ns.code != 301 {
                        RecognitionDiagnostics.shared.participantGenerationEnded(
                            gen: gen, errorCode: ns.code, chars: self.transcript.count,
                            lastSnippet: String(self.transcript.suffix(50))
                        )
                        if RecognitionDiagnostics.experimentMode == "B" && ns.code == 1110 {
                            SessionLogger.shared.log("[Participant] MODE_B gen=\(gen) 1110 ignored — no restart")
                            return
                        }
                        RecognitionDiagnostics.shared.participantError(ns.code)
                        if !self.transcript.isEmpty {
                            self.transcriptPrefix = self.transcript + " "
                        }
                        let nextGen = self.recognitionGeneration + 1
                        self.recognitionGeneration = nextGen
                        let hadSpeech = self.generationHadSpeech
                        let delay: UInt64 = (ns.code == 1110 && hadSpeech) ? 200_000_000 : 1_000_000_000
                        let delayLabel = (ns.code == 1110 && hadSpeech) ? "200ms" : "1s"
                        SessionLogger.shared.log("[Participant] restarting gen=\(gen) → \(nextGen) in \(delayLabel) hadSpeech=\(hadSpeech) prefix=\(self.transcriptPrefix.count)ch")
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: delay)
                            guard let self, self.isCapturing,
                                  self.recognitionGeneration == nextGen else { return }
                            let next = self.buildRecognitionRequest(recognizer: recognizer)
                            self.tapState.updateRequest(next)
                            self.recognitionTask?.cancel()
                            RecognitionDiagnostics.shared.participantTaskCancelled()
                            self.recognitionTask = nil
                            self.startRecognitionTask(with: recognizer, request: next)
                        }
                    }
                }
            }
        }

        // Cold-start watchdog: mirrors RecordingService — cancel and restart after 10 s
        // if no callback has arrived and capture is still on the same generation.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.isCapturing,
                  self.recognitionGeneration == gen,
                  !self.generationHadSpeech else { return }
            let nextGen = self.recognitionGeneration + 1
            self.recognitionGeneration = nextGen
            SessionLogger.shared.log(
                "[Participant] watchdog fired gen=\(gen) → \(nextGen) — 0 callbacks after 10s, restarting"
            )
            RecognitionDiagnostics.shared.participantGenerationEnded(
                gen: gen, errorCode: -1, chars: self.transcript.count,
                lastSnippet: ""
            )
            RecognitionDiagnostics.shared.participantError(-1)
            let nextRequest = self.buildRecognitionRequest(recognizer: recognizer)
            self.tapState.updateRequest(nextRequest)
            self.recognitionTask?.cancel()
            RecognitionDiagnostics.shared.participantTaskCancelled()
            self.recognitionTask = nil
            self.startRecognitionTask(with: recognizer, request: nextRequest)
        }
    }

    // MARK: - SpeechTranscriber participant session (Phase 2B)

    /// Sets up the parallel SpeechTranscriber participant pipeline.
    ///
    /// Both pipelines (legacy SFSpeechRecognizer + this one) receive all SCStream
    /// audio simultaneously via `ParticipantSTFeed`. The feature flag controls
    /// which pipeline's output is forwarded to `TranscriptStore`.
    @available(macOS 26.0, *)
    private func startParticipantSTSession() async {
        let locale = VocabularyProvider.speechLocale
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let vocab = VocabularyProvider.allTerms
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocab.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = vocab
            try? await analyzer.setContext(ctx)
        }

        guard let bestFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            SessionLogger.shared.log("[Participant-ST] no compatible audio format — pipeline not started")
            return
        }

        SessionLogger.shared.log(
            "[Participant-ST] vocab=\(vocab.count)terms locale=\(locale.identifier)"
        )

        do {
            try await analyzer.prepareToAnalyze(in: bestFmt)
        } catch {
            SessionLogger.shared.log("[Participant-ST] prepareToAnalyze failed: \(error)")
            return
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let feed = ParticipantSTFeed()
        feed.arm(continuation: continuation, targetFormat: bestFmt)
        participantSTFeed        = feed
        participantSTAnalyzer    = analyzer
        participantSTTranscriber = transcriber

        participantSTAnalyzeTask = Task.detached {
            do {
                _ = try await analyzer.analyzeSequence(stream)
                await SessionLogger.shared.log("[Participant-ST] analyzeSequence returned")
            } catch {
                await SessionLogger.shared.log("[Participant-ST] analyzeSequence error: \(error)")
            }
        }

        participantSTResultsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if self.participantSTTranscript.isEmpty {
                        self.participantSTTranscript = text
                    } else {
                        self.participantSTTranscript += " " + text
                    }
                    SessionLogger.shared.log(
                        "[Participant-ST] segment \"\(String(text.prefix(50)))\""
                        + " total=\(self.participantSTTranscript.count)ch"
                    )
                    if FeatureFlags.useNewParticipantPipeline {
                        let labeled = "Participant: \(self.participantSTTranscript)"
                        ServiceContainer.shared.resolve(TranscriptStore.self)
                            .updateParticipant(labeled)
                    }
                }
            } catch {
                SessionLogger.shared.log("[Participant-ST] results error: \(error)")
            }
            SessionLogger.shared.log(
                "[Participant-ST] results complete total=\(self.participantSTTranscript.count)ch"
            )
        }

        SessionLogger.shared.log(
            "[Participant-ST] pipeline ready bestFmt=\(bestFmt.sampleRate)Hz/\(bestFmt.channelCount)ch"
        )
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
        var old: SFSpeechAudioBufferRecognitionRequest?
        lock.withLock {
            old = recognitionRequest
            recognitionRequest = request
        }
        old?.endAudio()  // outside lock — avoids blocking the SCStream audio queue
    }

    func disarm() {
        lock.withLock {
            recognitionRequest?.endAudio()
            recognitionRequest = nil
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            let didAppend = recognitionRequest != nil
            recognitionRequest?.append(buffer)
            RecognitionDiagnostics.shared.participantBufferReceived(appended: didAppend)
        }
    }
}

// MARK: - SystemAudioStreamDelegate

/// Bridges SCStreamOutput callbacks (real-time audio thread) to `SystemAudioTapState`
/// and the Phase 2B `ParticipantSTFeed`.
///
/// `@unchecked Sendable`:
///  - `tapState` is thread-safe by design (NSLock-protected).
///  - `stFeed` is `Any?` holding a `ParticipantSTFeed` on macOS 26+; cast under `#available`.
///  - `onStopped` is set once in `init` and never mutated.
private final class SystemAudioStreamDelegate: NSObject, SCStreamOutput, SCStreamDelegate,
                                               @unchecked Sendable {
    private let tapState:  SystemAudioTapState
    private let stFeed:    Any?    // ParticipantSTFeed when macOS 26+
    private let onStopped: (Error) -> Void

    init(tapState: SystemAudioTapState, stFeed: Any?, onStopped: @escaping (Error) -> Void) {
        self.tapState  = tapState
        self.stFeed    = stFeed
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
        tapState.feed(pcm)                                          // legacy pipeline (always active)
        if #available(macOS 26.0, *),
           let feed = stFeed as? ParticipantSTFeed {
            feed.feed(pcm)                                          // Phase 2B ST pipeline
        }
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

// MARK: - ParticipantSTFeed (Phase 2B)

/// Thread-safe bridge between the SCStream real-time audio delivery thread and the
/// SpeechTranscriber AsyncStream for the participant channel.
///
/// Accepts stereo 48 kHz Float32 buffers from SCStream and resamples them to the
/// format required by SpeechTranscriber (16 kHz Int16 mono). The AVAudioConverter
/// is created lazily on the first `feed` call once the source format is known;
/// subsequent calls reuse the same converter.
///
/// `@unchecked Sendable`: every property is accessed exclusively under `lock` (NSLock).
@available(macOS 26.0, *)
private final class ParticipantSTFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var converter:    AVAudioConverter?   // lazy — built on first feed

    /// Arm for a new capture session.
    /// - Parameters:
    ///   - continuation: The AsyncStream continuation to yield resampled buffers into.
    ///   - targetFormat: The SpeechTranscriber-compatible format (e.g. 16 kHz Int16 mono).
    func arm(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat
    ) {
        lock.withLock {
            self.continuation = continuation
            self.targetFormat = targetFormat
            self.converter    = nil   // reset so the converter is rebuilt from the new source format
        }
    }

    /// Finish the stream continuation and release all resources.
    func disarm() {
        var cont: AsyncStream<AnalyzerInput>.Continuation?
        lock.withLock {
            cont              = self.continuation
            self.continuation = nil
            self.targetFormat = nil
            self.converter    = nil
        }
        cont?.finish()
    }

    /// Convert and forward one SCStream audio buffer. No-ops when not armed.
    /// Called on the SCStream sample-handler queue (real-time thread).
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let cont = continuation,
                  let tgt  = targetFormat else { return }

            // Build converter once we know the source format (lazy, first call only).
            if converter == nil {
                converter = AVAudioConverter(from: buffer.format, to: tgt)
            }
            guard let conv = converter else { return }

            let ratio  = tgt.sampleRate / buffer.format.sampleRate
            let dstCap = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 64)
            guard let dst = AVAudioPCMBuffer(pcmFormat: tgt, frameCapacity: dstCap) else { return }

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
