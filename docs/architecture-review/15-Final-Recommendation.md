# Final Recommendation — Orin V1 Architecture Review

**Document version**: 1.0  
**Review date**: 2026-06-29  
**Author**: Architecture Review (incoming CTO perspective, post full-codebase analysis)  
**Verdict**: NEEDS_PATCHING — not a rewrite

---

## Opening Assessment

I have reviewed the full Orin V1 codebase: 9 subsystems, 24 test files, every service, model, and view. Here is what I found, what I think, and what I would do.

The codebase is not broken at its foundation. The recording pipeline concurrency model, the NSLock-bridged real-time audio design, the `@MainActor` isolation strategy, the SwiftData crash recovery with orphan detection — these are correct and they represent earned macOS platform knowledge. You do not rewrite correct things.

But the codebase has accumulated three specific categories of defects that are causing real production failures: one architectural mistake in the AI pipeline that is the direct root cause of every post-call freeze; a set of five targeted engineering defects in the recording and speech pipelines that cause crashes and priority inversions; and a vocabulary and multilingual system that is structurally unable to support the product's stated goals. None of these require a rewrite. All of them require honest engineering.

The following is my assessment of what to keep, what to redesign, what to delete, and what to build differently if starting today.

---

## 1. What I Would Keep

**The generation-counter recognition restart pattern**

This is the right design for managing `SFSpeechRecognizer` session lifecycle on macOS. Incrementing a generation counter before every restart and checking it in async completion handlers is the correct way to cancel in-flight work without task cancellation. The pattern is subtle, it took real iteration to get right, and it works. The only defect is a narrow TOCTOU race in the dual-Task implementation (RISK-010) — fix the implementation, keep the pattern.

**The TapState NSLock bridge**

`TapState` as an `NSLock`-protected value type that bridges the Core Audio real-time thread to the async recognition pipeline is the correct architectural pattern. The real-time thread acquires the lock for nanoseconds to copy audio frames; the main actor acquires it to install/remove taps. This is textbook Core Audio real-time-to-async design. The defect is not the pattern — it is that `disarm()` calls `recognitionRequest?.endAudio()` (an XPC call) while holding the lock. Fix the lock ordering in `disarm()`. Keep `TapState`.

**`@MainActor` isolation strategy**

The decision to annotate `RecordingService`, `TranscriptStore`, `AIService`, and `MeetingDetectorService` with `@MainActor` is correct. It eliminates entire classes of UI data race. The Swift 6 concurrency model validates this approach. The specific problems — `ServiceContainer` with no lock, `CalendarService.status` read from non-isolated contexts — are defects in the application of the strategy, not evidence against the strategy. Keep `@MainActor` isolation. Fix the specific violations.

**SwiftData with orphan recovery**

The persistence model — `MeetingItem`, `TranscriptChunk`, `TranscriptSegment`, three-second checkpoint writes, `UserDefaults` session ID for crash recovery, orphan detection on app launch — is correct and handles real edge cases. The crash recovery logic in `TranscriptStore` that detects incomplete sessions and attempts to finalize them is genuinely good engineering. Keep all of this. The performance problems (O(N²) saves, full-table scans, inline transcript blobs) are separate from the correctness of the design.

**The Phase 2A SpeechTranscriber migration direction**

Migrating from `SFSpeechRecognizer` to `SpeechTranscriber` is the right call. `SpeechTranscriber` is more accurate, lower latency, and Apple's forward investment. Phase 2A is already deployed and working. Accelerate Phase 2B validation rather than waiting for it to become the default on its own schedule. Set a hard date for removing the legacy path.

**The ServiceContainer concept**

Dependency injection via a registry is the right pattern for a SwiftUI app of this complexity. The concept of `ServiceContainer` is correct. The implementation has one defect: the dictionary is not thread-safe. Fix the thread safety; keep the pattern. Long-term, inject service-to-service dependencies at construction time rather than calling `resolve()` from callbacks — but the registry is still the right place to own root-level service instances.

**MeetingDetectorService confidence scoring**

The heuristic model for detecting meeting boundaries — audio energy, speech confidence, cross-talk detection — is a sound approach to a genuinely hard signal processing problem. The `@MainActor` annotation added in the most recent commit (4f603ea) was the right fix for the data race. Keep the detection model. The `CGWindowListCopyWindowInfo` call from a non-main thread needs verification, but the overall design is sound.

---

## 2. What I Would Redesign

**The AI pipeline: InferenceWorker + AnalysisJobQueue**

This is the single most important redesign. The current `MeetingIntelligenceService.analyzeChunked()` submits all N chunk tasks simultaneously into `withTaskGroup`. For Ollama — a single-GPU process that serializes inference — this produces N simultaneous HTTP requests that all timeout at the same moment and all retry in a synchronized wave. For a 150-minute meeting: approximately 41 concurrent requests, GPU exhaustion, and a system-wide freeze lasting 60–120 seconds.

The redesign is:

- `InferenceWorker` actor: owns a serial job queue. For local providers (Ollama, LM Studio, Apple Foundation Models), processes one job at a time. For cloud providers (OpenAI, Anthropic), uses a bounded semaphore (limit 3). This is the fundamental insight: local inference is a serial resource, not a parallel API.
- `AnalysisJobQueue` actor: serializes multi-meeting analysis. When two meetings finish recording seconds apart, their analysis jobs queue rather than spawning two independent `withTaskGroup` waves.
- `InferenceProvider` protocol: `func infer(job: InferenceJob) async throws -> InferenceResult`. Concrete implementations: `OllamaProvider`, `LMStudioProvider`, `AppleFoundationModelsProvider`, `OpenAIProvider`, `AnthropicProvider`.
- `ModelRouter` protocol: selects provider based on availability, user preference, and job priority. `LocalFirstRouter` is the default.

This design works identically whether the backend is Ollama today, Apple Foundation Models tomorrow, or a future on-device model on iOS. It is the architectural bet worth making.

**The vocabulary system: four-tier VocabularyContext**

The current system is a 103-term flat array in `VocabularyProvider.swift`, capped at 100 with `.prefix(100)` — which silently drops 6 terms today, including some of the Hindi terms added as a multilingual gesture. It has no UI, no per-meeting context, no language detection, and no path to supporting 10 languages. It is wired only to the `SpeechTranscriber` path — the default legacy path gets nothing.

The redesign is:

- `VocabularyItem` as a SwiftData `@Model` with `tier: VocabularyTier`, `language: String`, `text: String`, `frequency: Int`.
- Four tiers in priority order: `Session` (from calendar attendee names, auto-populated) > `User` (explicitly added) > `Org` (team-shared, future) > `BuiltIn[language]` (replacing the current hardcoded array).
- `CorrectionStore` that observes manual transcript edits and auto-promotes terms with frequency >= 3 to the `User` tier.
- `SettingsView` vocabulary management section: add, delete, see frequency counts.
- `NLLanguageRecognizer` post-session to detect meeting language and tag the session.
- Language-parameterized prompt builder in `MeetingIntelligenceService` — no more hardcoded English prompts.

**Recognition session management: extract RecognitionSessionManager**

The full recognition session management pattern — generation counter, 1110 error restart with 200ms/1s delay, 10-second cold-start watchdog, utterance-boundary heuristic, `generationHadSpeech` tracking — is copy-pasted verbatim between `RecordingService.swift` and `SystemAudioCaptureService.swift`. The two copies have already diverged: locale is `en-IN` in one and `en-US` in the other. Any bug fix applied to one must be found and applied to the other.

Extract a `RecognitionSessionManager` actor that owns the generation counter, all restart logic, and the watchdog. Both `RecordingService` and `SystemAudioCaptureService` hold a `RecognitionSessionManager` instance and delegate session lifecycle to it. The `ASRBackend` protocol wraps `SpeechTranscriber`, `SFSpeechRecognizer`, and eventually `WhisperBackend` — `RecognitionSessionManager` works against the protocol, not concrete types.

This is approximately 400 lines removed from the codebase, replaced by a single 200-line actor that is correct in one place.

**MeetingsView: split into 5+ files + MeetingAnalysisCoordinator**

`MeetingsView.swift` is 2,281 lines. It owns meeting list display, folder navigation, meeting detail rendering, recording state, analysis results, action items, segment timelines, swipe actions, and the `@Query` that loads all `TranscriptSegment` records from all meetings simultaneously. This is a view that has accreted everything no one wanted to make a decision about.

Split into:
- `MeetingsListView.swift` — list, folder navigation, row display
- `MeetingDetailView.swift` — detail pane, owns the `meetingId`-predicated `@Query`
- `FolderDetailView.swift` — folder contents
- `MeetingRowView.swift` + `MeetingRowActionItems.swift` — row components
- `MeetingAnalysisResultView.swift` — analysis results, action item display

Extract `MeetingAnalysisCoordinator` from `MeetingDetailView` into the service layer — a view should not be writing 12 model properties, encoding JSON, and calling `safeSave` twice. That is business logic that belongs in a coordinator or service.

---

## 3. What I Would Delete

These items exist in the codebase and should not. They are either debugging scaffolding that was never removed, privacy violations, or dead code that adds maintenance cost without value.

**`sampleCPUUsage()` and `sampleRAMMB()` in production** — `RecordingService.swift`  
These use Mach kernel APIs (`task_info`, `mach_task_self`) to poll CPU and RAM usage in production release builds. This is performance instrumentation for development. It does not belong in a shipping product. Mach API calls in a tight sampling loop add overhead and are a memory safety hazard if the task info struct layout changes between OS versions. Delete them. If performance instrumentation is needed, use `os_signpost` with a `POICategory` and profile with Instruments.

**The `/tmp/orin_phi3_raw.txt` unconditional write** — `MeetingIntelligenceService.swift` or `AIService.swift`  
This writes raw meeting transcript content and model reasoning to a world-readable path on every analysis run. It is a privacy violation. The file persists across sessions. Delete this line. If debug logging is needed in development, use `#if DEBUG` and write to the app sandbox temporary directory.

**The `[ProofRun]` and `[HallucinationReport]` print blocks**  
These are diagnostic output blocks that log internal validation results to stdout. They are still present in production builds. They produce noise in Console.app for production users and, more importantly, they log fragments of meeting content to the system log, which may persist in crash reports or diagnostic bundles that users share with Apple or the development team. Delete them. Use `os_log` with `.debug` level if these diagnostics are needed in development — `.debug` messages do not appear in release builds.

**`experimentMode nonisolated(unsafe) static var` in `RecognitionDiagnostics.swift`**  
`nonisolated(unsafe)` is the Swift 6 escape hatch for global mutable state that the developer asserts is safe. Using it for a `static var` that toggles experimental recognition behavior is the wrong tool — it suppresses the compiler's concurrency checking for a value that multiple contexts write to. If `experimentMode` is needed for development, make it an actor-isolated property or a UserDefaults value read through a `@MainActor` accessor. If it is not needed in production, delete it.

**`probeHeuristicFireCount` and `probeHeuristicExtraChars` tracking variables**  
These are counters that track internal heuristic invocations and were used during development to tune utterance boundary detection. They are still present in production code, contributing to state that must be managed on every recording session. Delete them and the logging that references them.

**`SCKitSystemAudioProvider` wrapper**  
This is a trivially thin wrapper around `SCKit` system audio capture. It adds one layer of indirection without providing any protocol boundary, testability improvement, or platform abstraction. It is not conforming to any protocol that would make it swappable. It is just an extra file. Delete it and use `SCKit` directly until a real `AudioCaptureBackend` protocol is introduced in Phase 3.

**74 bare `print()` statements in production release builds**  
There are 74 `print()` calls scattered across service files that log internal state to stdout. In release builds, `print()` is not stripped by the compiler. Every `print()` call acquires a lock on stdout, formats a string, and writes to the file descriptor. In aggregate during a recording session, this is unnecessary overhead and noise. Replace with `os_log` (`.debug` level, stripped in release) or delete.

**`MicSTSessionMetrics` class**  
This class tracks per-session metrics for the `SpeechTranscriber` migration benchmarking effort. It was built to validate that Phase 2A produces equivalent or better results than the legacy path. That validation work is done — Phase 2A is deployed. The metrics class is now benchmarking scaffolding with no production use. Delete it when the legacy path is removed. Do not add new instrumentation to it.

---

## 4. What I Would Postpone

**Windows, iOS, and Android platform work**  
Do not start. Not until `OrinCore` Swift package is extracted (Phase 3, 12–16 weeks from now) and the `ASRBackend` and `AudioCaptureBackend` protocols are in place. Starting cross-platform work before the protocol boundaries exist means rewriting all business logic for each new platform. The investment in protocol extraction now is the prerequisite for cheap cross-platform work later. Any Windows or iOS work started today will be thrown away when the protocols land.

**Arabic RTL layout support**  
Arabic requires both Whisper integration (Apple has no `hi-IN` or `ar` locale) and RTL layout work throughout the view layer. The view layer is not in a state to receive RTL layout investment — `MeetingsView.swift` needs to be split first. RTL is Phase 3+ work, after the view layer is decomposed and the `WhisperBackend` is implemented.

**Org vocabulary sync**  
The four-tier vocabulary model includes an `Org` tier for team-shared vocabulary. Do not build the org tier before the personal `User` tier is shipped and validated. Building infrastructure for a use case that is not yet validated is waste. Ship the personal vocabulary UI and CorrectionStore. Measure usage. Then decide whether org sync is worth the backend infrastructure it requires.

**Plugin architecture**  
No plugin architecture until Phase 4, after the multi-platform proof-of-concept is complete. A plugin API surface commits you to a contract you cannot break. You do not know what the right contract is until you have built the abstractions for at least two platforms and two ASR backends. Shipping a plugin API today means shipping the wrong plugin API.

**Apple Foundation Models integration**  
Apple Foundation Models is macOS 26+ only and the API was announced at WWDC 2026. The SDK is not yet stable. The on-device model capabilities and context window are not yet publicly documented in final form. Wait 6 months for API stability before investing in `AppleFoundationModelsProvider`. The `InferenceProvider` protocol design accommodates it without modification when the time comes — stub the provider, gate it behind an OS version check, and ship it when the API is stable.

---

## 5. What I Would Build Differently If Starting Today

This section is honest. Not for blame assignment — these are reasonable decisions under the constraints of early development. But if I were starting the Orin codebase from scratch today, with the knowledge from this review:

**The AI pipeline would have been InferenceWorker from day one**  
Local inference is serial. Ollama, LM Studio, llama.cpp, Apple Foundation Models — all of them serialize GPU matrix multiplications behind a single execution slot. Sending N parallel requests to a serial resource does not increase throughput; it only increases the surface area for synchronized failures. The first time I called `withTaskGroup` for Ollama requests, I should have recognized this and built a serial queue. The mental model that shaped the current design — "Ollama queues internally, so parallel requests are fine" — is true for throughput but wrong for failure modes. The code even has a comment acknowledging this, which means the tradeoff was considered and the wrong choice was made. `InferenceWorker` as a serial actor would have been three more files and two weeks of upfront work that would have prevented every post-call freeze the product has shipped.

**The vocabulary system would have been a SwiftData model from day one**  
Vocabulary needs per-user customization, per-meeting context injection, learning from corrections, and eventually multi-language support. A hardcoded array in `UserDefaults` cannot evolve to meet any of these requirements. The decision to start with a hardcoded array was reasonable for a prototype, but the prototype vocabulary system survived into production and is now structurally blocking non-English markets. Starting with `VocabularyItem` as a SwiftData `@Model` would have cost one extra day. The migration cost from the current system to the redesign is two weeks.

**The recognition session manager would have been a single class from day one**  
The generation counter, watchdog task, utterance boundary heuristic, and restart logic are complex enough to be hard to get right once. Copy-pasting them — even initially — guarantees that getting them right in one place means they are wrong in the other. The two copies have already diverged in locale configuration. A `RecognitionSessionManager` actor from the beginning would have been the same amount of code with zero duplication. This is a pattern that should be a coding standard for the team: if you find yourself copy-pasting more than 50 lines of non-trivial logic, extract an abstraction first.

**MeetingsView would have been multiple files from day one**  
A view file that owns recording orchestration is wrong. A view that owns meeting details is not the same concern as a view that owns a list of meetings. These should have been separate files from the first commit that added detail rendering. The cost of splitting a 200-line file is one hour. The cost of splitting a 2,281-line file is one week and several regression risks. The discipline of keeping view files focused is easier to maintain when the files are small.

**ServiceContainer would have had an NSLock from day one**  
Three lines of code. The `resolve()` method should always have acquired a lock. There is no performance argument against it — registry lookup happens at initialization time, not in hot paths. This is not a design failure; it is an implementation oversight that has become a latent crash risk.

---

## 6. Non-Negotiable Principles for Future Development

These are not guidelines. They are gates. New code that violates these principles does not ship.

**The real-time audio thread is sacred**  
No heap allocation. No IPC. No XPC calls. No locks that can block waiting for another thread. No `resolve()` from a service registry. If code needs to run on the Core Audio I/O thread, it must use only pre-allocated memory, lock-free data structures, and atomic operations. The `feed()` methods in `MicTranscriberFeed` and `ParticipantSTFeed` are the contract: copy frames into a pre-allocated buffer, increment an atomic counter, return. Everything else happens off the real-time thread.

**Local inference is never parallel**  
One request at a time to Ollama, LM Studio, llama.cpp, or Apple Foundation Models. Always. The `InferenceWorker` actor enforces this. Any code that submits concurrent requests to a local inference process is wrong regardless of what the inference process's documentation says about queuing. The failure mode of parallel local inference — synchronized timeouts, synchronized retries, GPU exhaustion, OOM — is too severe.

**Fix before feature**  
No new capabilities ship while RISK-001 through RISK-005 are open. This is a stability gate, not a bureaucratic process. Every new feature added to an unstable system increases the surface area for crashes and makes root cause analysis harder. The team has permission to say no to feature requests while the Phase 1 fixes are in flight.

**Privacy is architectural**  
No meeting transcript content leaves the device without explicit per-session user consent with a clearly labeled UI affordance. No transcript content is written to world-readable paths. No transcript fragments appear in crash logs or system diagnostics. The `/tmp/orin_phi3_raw.txt` write is not a small oversight — it is a symptom of a team that has not internalized privacy as a design constraint. Every new AI pipeline feature must have a privacy review before implementation, not after.

**Design for 10 languages**  
No new English-only string processing is added to the codebase after Phase 2. No hardcoded locale strings. No prompts that assume English grammar or sentence structure. No vocabulary features that work only for Latin script. Before adding any text processing feature, ask: does this work for Japanese? For Arabic? For Hindi? If the answer is "we would have to rewrite this for those languages," the architecture is wrong and must be fixed before the feature ships.

---

## 7. The 90-Day Plan

### Day 1–7: AI Pipeline Serialization (Phase 1, Part A)

**Deliverables:**

1. **Serialize Ollama inference** — Replace `withTaskGroup` loop in `analyzeChunked()` with sequential `for chunk in chunks { }` for local providers. Gate cloud providers behind a bounded semaphore. Approximately 20 lines changed.

2. **Cache Ollama health check** — Cache `isOllamaAvailable()` result for 10 seconds in a `@MainActor` stored property. Eliminates N simultaneous `/api/tags` requests at analysis start. Approximately 8 lines changed.

3. **Add ±2.5s retry jitter** — Change the 10s retry sleep to `10 + Double.random(in: -2.5...2.5)` seconds. Breaks synchronized retry waves. One line changed.

**Validation:** Record a 90-minute meeting. Confirm no system freeze during or after analysis. Monitor Ollama process memory in Activity Monitor — should stay below 2GB. Check that analysis completes within 15 minutes (sequential throughput through a local model is unchanged from parallel).

---

### Day 8–21: Audio and Persistence Safety (Phase 1, Part B)

**Deliverables:**

4. **Fix TapState.disarm() XPC-in-lock** — Move `recognitionRequest?.endAudio()` call to after the NSLock is released. Acquire lock, set state, release lock, then call `endAudio()`. Approximately 10 lines rearranged.

5. **Add NSLock to ServiceContainer** — Add `private let lock = NSLock()` and wrap `resolve()` and `register()`. Three lines added.

6. **Delete /tmp/orin_phi3_raw.txt write** — One line deleted. No migration, no feature flag.

7. **Fix AVAudioEngineConfigurationChange debounce** — Replace stored `Date` comparison with `DispatchWorkItem` cancel-and-reschedule. Approximately 15 lines changed.

8. **Batch TranscriptChunk saves** — Change `persistChunkIfNeeded()` to `context.insert(chunk)` without `context.save()`. Let the 3-second checkpoint be the only save trigger. Approximately 5 lines changed.

9. **Add meetingId predicate to buildTimelineSegments** — Replace full-table `FetchDescriptor` with predicated fetch. Approximately 8 lines changed.

**Validation:** Connect and disconnect headphones 10 times during recording — zero crashes. Run TSan on a recording session — zero data race reports for ServiceContainer. Measure main actor blocking time during recording with `os_signpost` before and after the save batching change.

---

### Day 22–63: Phase 2 Redesigns

These run in parallel across two or three engineers.

**Stream A (Weeks 4–7): InferenceWorker + AnalysisJobQueue**

- Define `InferenceJob`, `InferenceResult`, `InferenceProvider` protocol
- Implement `OllamaProvider` (wraps existing Ollama HTTP calls)
- Implement `InferenceWorker` actor with serial queue for local, bounded parallel for cloud
- Implement `AnalysisJobQueue` actor
- Wire into `AIService` and `MeetingIntelligenceService`
- Add circuit breaker: 3 failures in 90s → mark Ollama unavailable for 60s, route to cloud
- Add UI feedback: "Analysis queued (N meetings)" observable state

**Stream B (Weeks 4–7): RecognitionSessionManager extraction**

- Define `ASRBackend` protocol
- Extract `RecognitionSessionManager` actor (generation counter, watchdog, restart logic)
- Wire `MicTranscriberFeed` buffer pre-allocation through `TapState.arm()`
- Delete duplicate recognition session code from `SystemAudioCaptureService`
- Accelerate Phase 2B: make `SpeechTranscriber` the default, gate legacy behind flag
- Set legacy `SFSpeechRecognizer` path removal date: end of Phase 2

**Stream C (Weeks 4–9): MeetingsView split + vocabulary redesign**

- Split `MeetingsView.swift` into 5 files (mechanical refactor, zero behavior change)
- Extract `MeetingAnalysisCoordinator` from `MeetingDetailView`
- Move `allSegments @Query` into `MeetingDetailView` with `meetingId` predicate
- Define `VocabularyItem` SwiftData `@Model` with tiers
- Implement `CorrectionStore` for learning from edits
- Add `SettingsView` vocabulary management section
- Add `NLLanguageRecognizer` post-session language detection
- Implement `OrinSchemaV2` and `MigrationPlan` before any schema change ships

---

### Day 64–90: Spanish + ASRBackend Protocol

**Deliverables:**

- Add `es-ES` and `es-MX` locale support to `RecognitionSessionManager` (via `ASRBackend` locale parameter)
- Add Spanish vocabulary built-in tier to `VocabularyContext`
- Add Spanish AI prompt variants to `MeetingIntelligenceService` (using language parameterization built in Day 22–63)
- Validate full Spanish recording → transcription → analysis pipeline end-to-end
- Define `AudioCaptureBackend` protocol as the foundation for Phase 3 cross-platform work
- Write `OrinCore` package structure (empty Swift package, no code moved yet — this is the skeleton that Phase 3 fills)

**Validation:** Complete a 60-minute Spanish-language meeting recording with a native speaker. Validate transcript accuracy, summary quality, and action item extraction. Compare results to an equivalent English session as a quality baseline.

---

## 8. Final Verdict

**Is Orin worth continuing to invest in?**

Yes. The recording pipeline, concurrency model, and persistence layer embed hard-won macOS platform knowledge. The `@MainActor` isolation strategy, the NSLock real-time bridge, the generation counter pattern, and the SwiftData crash recovery are all correct and have been debugged against real platform behavior. This is not something you get for free by starting over — you would spend 6–12 months relearning the same lessons and making the same mistakes, except now without a working product.

**Is a rewrite warranted?**

No. The core instability is not architectural at the foundation level — it is a single defect in the AI pipeline (unbounded concurrent Ollama dispatch) and five targeted engineering defects in the audio and persistence layers. All of them are surgically fixable without touching the foundational design. A rewrite would throw away the correct things along with the incorrect things and produce a new codebase with different defects.

**What is the single most important action?**

Serialize Ollama inference. Today. Before anything else. This is a 20-line change to `MeetingIntelligenceService.analyzeChunked()`. It eliminates the thundering herd that is the direct root cause of every post-call freeze the product has shipped. It does not require any architectural work, any new abstractions, or any coordination. It ships tomorrow. Everything else — the audio safety fixes, the vocabulary redesign, the view refactor — is important but secondary to stopping the crashes that users are experiencing on every long meeting.

**What is the architectural bet to make?**

`InferenceWorker` actor + `AnalysisJobQueue`. This design works for Ollama today, LM Studio today, Apple Foundation Models on macOS 26, and every future local or cloud inference provider without modification. The `InferenceProvider` protocol and `ModelRouter` abstraction mean that adding a new model backend is one new file with one method implementation — no changes to the analysis pipeline. The serial queue for local providers and bounded parallel for cloud providers is the right mental model for the difference between local GPU inference and horizontally-scaled API services. Build this in Phase 2 and it will not need to be revisited.

**What does success look like at day 90?**

No user reports a post-call freeze. Headphone connection changes do not crash the app. The codebase has a documented path to Spanish and French support. `MeetingsView.swift` no longer exists as a single file. The legacy `SFSpeechRecognizer` path has a confirmed removal date. The team can add a new inference provider in less than a day.

That is a realistic target. Start with the Ollama serialization today.

---

*This document reflects the state of the codebase as of commit 4f603ea (2026-06-18) and the full 9-agent architectural review completed 2026-06-29. Reassess at the end of Phase 1 (target: 2026-07-20).*
