# Architecture Decision Records — Orin V1

**Document status**: Active  
**Last updated**: 2026-06-29  
**Authors**: Principal Engineering Review (9-agent architectural audit)  
**Scope**: macOS client — all subsystems from audio capture through AI analysis and persistence

---

## How to Read This Document

Each ADR documents a decision that has lasting consequences for the codebase. "Accepted" means the decision stands and the codebase conforms to it. "Superseded" means the decision was made, is present in current code, and must be replaced — the current code is the liability, the superseding ADR is the target. "Proposed" means the decision has been agreed to architecturally but no code has been written yet.

Superseded ADRs are kept verbatim. Deleting them would lose the record of why the original approach was taken — which is exactly the knowledge that prevents future engineers from repeating the same mistake.

---

## ADR-001: Use AVAudioEngine + TapState NSLock Bridge for Real-Time Audio Routing

**Status**: Accepted  
**Date**: 2025-Q3 (estimated initial implementation)  
**Review Date**: 2027-06-01

### Context

Orin captures two audio streams simultaneously: the local microphone and system audio from video conferencing applications (Zoom, Meet, Teams). Both streams must be delivered to an ASR pipeline with low latency and must not drop frames, as dropped frames create gaps in the transcript.

macOS provides two capture APIs:

- `AVCaptureDevice` / `AVCaptureSession` — designed for camera+audio recording, adds latency and is not appropriate for real-time speech
- `AVAudioEngine` with `installTap(onBus:bufferSize:format:block:)` — delivers raw PCM buffers on the Core Audio I/O thread, appropriate for real-time speech

The fundamental engineering challenge is that Core Audio I/O callbacks run on a dedicated high-priority real-time thread. Any code running in the callback block must complete in microseconds and must never call APIs that allocate memory, take locks, perform I/O, or make XPC calls. Yet the ASR pipeline (`SFSpeechRecognizer`, `SpeechTranscriber`) is not real-time-safe — it processes on cooperative-pool threads and communicates with the speech daemon via XPC.

### Decision

Introduce `TapState`, a lock-protected value-type bridge between the Core Audio I/O thread and the `@MainActor` session lifecycle:

- `TapState.arm()` is called on `@MainActor` before `installTap`, populating references to `AVAudioFile` (for recording) and `SFSpeechAudioBufferRecognitionRequest` (for ASR). The contract is: `arm` completes before the first I/O callback fires.
- `TapState.feed()` is called on the Core Audio I/O thread. It acquires `NSLock`, reads the pre-populated references, appends the buffer to the recognition request, and writes it to the audio file. No allocations, no XPC calls under the lock.
- `TapState.updateRequest()` allows the `@MainActor` to swap in a new `SFSpeechAudioBufferRecognitionRequest` during a session restart without stopping the tap. It captures the old reference under lock, releases the lock, then calls `endAudio()` outside the lock.
- `TapState.disarm()` is called on `@MainActor` after `removeTap` returns, ensuring no `feed()` call can be in-flight during teardown.

The use of `NSLock` (not an actor, not `DispatchQueue`) is deliberate: the Core Audio I/O thread is a real-time thread and cannot participate in Swift's cooperative concurrency system. Actor hops and async suspension points are not permissible on this thread.

### Alternatives Considered

**AVCaptureSession for both streams**: Rejected. `AVCaptureSession` adds 50-100ms of capture latency and is designed for camera-centric workflows. It cannot be mixed with `AVAudioEngine` for simultaneous mic + system audio capture without significant complexity.

**Direct SFSpeechRecognizer calls from I/O thread**: Rejected. `SFSpeechAudioBufferRecognitionRequest.append(_:)` internally dispatches to the speech daemon via XPC. Calling it on the real-time I/O thread would cause priority inversion and intermittent audio dropout.

**Lock-free ring buffer**: Considered for the future. A lock-free SPSC ring buffer between the I/O thread and a consumer thread would eliminate the NSLock entirely and is the most correct real-time design. Not adopted in V1 due to complexity; the NSLock approach is safe because the critical section is extremely short (two pointer dereferences and one method call).

**GCD serial queue instead of NSLock**: Rejected. A GCD `sync {}` call from the real-time thread is not permitted — GCD may context-switch, which violates real-time constraints.

### Consequences

**Positive**:
- Clean ownership contract: `arm`/`feed`/`disarm` lifecycle maps directly to recording session start/restart/stop
- `@unchecked Sendable` is justified: all stored properties are exclusively accessed under `lock`
- Supports session restart (swapping the recognition request) without stopping the audio tap, which is critical for the generation-counter restart pattern (see ADR-002)
- The audio file write is on the I/O thread (fast, sequential), which is appropriate for `AVAudioFile`

**Negative / Known Issues**:
- `TapState.disarm()` currently calls `recognitionRequest?.endAudio()` while holding `NSLock` (see TD-003). `endAudio()` dispatches to the speech daemon via XPC, blocking the Core Audio I/O thread for the duration of the IPC round-trip. This is a priority inversion bug. Fix: move `endAudio()` outside the lock, following the same pattern already used in `updateRequest()`. Estimated fix: hours.
- `RecognitionDiagnostics.shared.micBufferReceived()` is called from `TapState.feed()` on the I/O thread using `NSLock`. Under priority inversion this NSLock can block. Should be replaced with `os_unfair_lock` or atomic counters (see TD-019).
- `AVAudioPCMBuffer` allocation in `MicTranscriberFeed.feed()` happens on the I/O thread inside NSLock, which violates real-time safety (see ADR-002 consequences and TD-002). This is separate from `TapState` itself.

---

## ADR-002: Use SFSpeechRecognizer with Generation-Counter Restart Pattern for ASR Reliability

**Status**: Accepted (legacy path; will be superseded once ADR-003 Phase 2B is promoted)  
**Date**: 2025-Q3  
**Review Date**: 2026-09-01

### Context

`SFSpeechRecognizer` produces a single `SFSpeechRecognitionTask` per session. This task is not restartable — when it ends (due to silence timeout, error 1110 "audio session interrupted", Siri rate limits, or the 60-second streaming limit on older OS versions), a new task must be created from a new `SFSpeechAudioBufferRecognitionRequest`. Creating a new request mid-session requires stopping the old one while the audio tap continues running.

Two failure modes needed explicit handling:

1. **Error 1110 (audio session interrupted)**: occurs when another app captures the microphone, when the system changes audio routing, or after approximately 60 seconds of inactivity. Must restart within 200ms–1s to avoid transcript gaps.
2. **Cold-start stall**: `SFSpeechRecognitionTask` is created but produces no results for 10+ seconds. This occurs when the speech daemon is busy (e.g., Siri is active) or when the system is under memory pressure. Must detect and restart.

The additional complication is that `SFSpeechRecognizer` callbacks (`onRecognitionTaskDidFail`, `onRecognitionTaskFinished`) can fire from arbitrary threads, and the watchdog that monitors for cold-start stalls runs as a Swift structured concurrency Task. Both the watchdog and the error callback can decide to restart within the same generation window.

### Decision

Implement a generation-counter pattern:

- `recognitionGeneration: Int` tracks the current "generation" of the recognition session. Initialized to 0, incremented atomically on every restart.
- Every long-running Task (watchdog, error-callback restart) captures the current generation at the point it decides to restart. Before executing the restart, it checks `self.recognitionGeneration == capturedGeneration`. If the generation has advanced, another restart already fired and this one is a no-op.
- Error 1110: restart after a 200ms delay (first occurrence) or 1s delay (subsequent). The delay allows pending recognition results to drain before the new session begins.
- Cold-start watchdog: if no result arrives within 10 seconds of task creation, log a diagnostic and restart.
- `generationHadSpeech: Bool` tracks whether the current generation produced any recognized speech. Used to distinguish a no-speech timeout (normal) from a stall (unexpected).

### Alternatives Considered

**Single persistent SFSpeechRecognitionTask**: Rejected. `SFSpeechRecognizer` does not support indefinitely long sessions. Error 1110 is unavoidable in production (audio route changes, Siri interaction, system memory pressure). A single task without restart logic produces complete transcript loss on first error.

**AVSpeechRecognizer local-only mode**: Evaluated. The local-only flag (`requiresOnDeviceRecognition: true`) avoids the 60-second limit but produces lower accuracy on English variants and does not support contextual vocabulary (`contextualStrings`). Not adopted as the primary path.

**Exponential backoff on error**: Partially adopted. The first restart uses 200ms; the second uses 1s. True exponential backoff (1s, 2s, 4s...) was considered but rejected because speech gaps are noticeable to users at >500ms. The tradeoff is slightly more Siri daemon chatter in failure conditions.

**Separate thread for recognition callback dispatch**: Considered to simplify the TOCTOU window. Not adopted; the generation counter is sufficient if implemented correctly.

### Consequences

**Positive**:
- Highly resilient to production failure modes (error 1110, Siri interference, audio route changes)
- Supports indefinitely long meetings (tested to 4+ hours in internal use)
- Cold-start watchdog catches the specific macOS failure mode where the speech daemon accepts the session but stalls

**Negative / Known Issues**:
- There is a TOCTOU window (see TD-007, root cause item 7): the watchdog Task and the error callback Task can both pass the `recognitionGeneration == gen` check before either increments the counter, spawning two simultaneous `SFSpeechRecognitionTask` instances whose results interleave. Fix: use a dedicated serial actor (`RecognitionSessionManager`, see MT-001 and ADR-011) to serialize all restart decisions.
- The entire recognition session management (~400 lines) is duplicated verbatim between `RecordingService.swift` and `SystemAudioCaptureService.swift` (see ADR-011). Bugs fixed in one file must be manually applied to the other. This duplication has already caused a locale divergence (en-IN in `RecordingService` vs en-US in `SystemAudioCaptureService`).
- `MicTranscriberFeed.feed()` and `ParticipantSTFeed.feed()` allocate `AVAudioPCMBuffer` on every Core Audio I/O callback (~46/sec) inside `NSLock`. This is a real-time safety violation (see TD-002). Fix: pre-allocate the buffer in `arm()` and reuse it in `feed()`.

---

## ADR-003: Migrate to SpeechTranscriber (Phase 2A / Phase 2B) Behind Feature Flags

**Status**: Accepted (Phase 2A: mic channel active; Phase 2B: participant channel, benchmark-only)  
**Date**: 2026-Q1  
**Review Date**: 2026-10-01

### Context

`SFSpeechRecognizer` is a mature but constrained API: it requires a `SFSpeechAudioBufferRecognitionRequest` wrapper, does not support modern vocabulary injection APIs, requires Speech Recognition permission even for on-device processing, has a known 60-second streaming limit on older macOS versions, and involves repeated XPC round-trips to the speech daemon. The generation-counter restart complexity in ADR-002 exists entirely to work around `SFSpeechRecognizer`'s limitations.

Apple introduced `SpeechTranscriber` (via `SpeechAnalysis` framework, macOS 15+) as the modern replacement: streaming API, on-device only, no Speech Recognition TCC permission required (only Microphone), supports `AnalysisContext.contextualStrings` for vocabulary injection, and produces higher accuracy on en-IN and en-AU variants.

### Decision

Introduce two runtime feature flags backed by `UserDefaults`:

- `FeatureFlags.useNewMicPipeline` (`orin.useNewMicPipeline`): Phase 2A. When `true`, the mic channel uses `SpeechAnalyzer(modules: [SpeechTranscriber])` instead of `SFSpeechRecognizer`. The entire generation-counter restart machinery is inactive on this path — `SpeechTranscriber` does not error in the same ways. Vocabulary from `VocabularyProvider` is injected via `AnalysisContext.contextualStrings`.
- `FeatureFlags.useNewParticipantPipeline` (`orin.useNewParticipantPipeline`): Phase 2B. When `true`, the participant channel routes SCStream audio through `SpeechTranscriber`. Both pipelines still run simultaneously but the legacy output is written only to `SessionLogger` (for diagnostic comparison), not to `TranscriptStore`.

Flags default to `false` (legacy behaviour). Engineers toggle them via `defaults write com.rconcept.orin <key> -bool YES` and restart the app.

**Critical gating rule for Phase 2B**: `useNewParticipantPipeline` must not be promoted to default-`true` until Phase 2A (`useNewMicPipeline`) has been validated as stable across at least 50 real meeting recordings covering a range of audio environments (meeting room, AirPods, wired headset). Participant audio (SCStream) has more acoustic variability than mic audio. Promoting both channels simultaneously risks a regression in both pipelines with no fallback.

### Alternatives Considered

**Big-bang cutover (replace both channels at once, no flags)**: Rejected. `SpeechTranscriber` is new API with unknown production behaviour on the range of hardware and audio configurations Orin users have. A failed rollout of the mic channel with no fallback would cause complete transcript loss for all users.

**A/B test flag via remote config**: Considered but rejected for V1. Orin is a local-first product with no server infrastructure. Adding remote config solely for this rollout would introduce unnecessary server dependency. `UserDefaults`-based flags are sufficient — the developer population testing Phase 2A is small and can be addressed individually.

**Gradual percentage rollout**: Not feasible without server-side flag evaluation. Deferred to a future release infrastructure decision.

**Ship both pipelines permanently (dual-write)**: Rejected. Maintaining two full ASR pipelines indefinitely doubles the code surface and the bug-fix burden. Phase 2B in benchmark mode is acceptable as a temporary validation step. Once `useNewParticipantPipeline` is promoted to default-`true`, the legacy `SFSpeechRecognizer` participant path should be deleted.

### Consequences

**Positive**:
- Safe incremental migration with zero downtime risk
- Per-channel rollback: if Phase 2A shows regressions, toggle off `useNewMicPipeline` without affecting participant
- Vocabulary injection is architecturally enabled for the first time (legacy `SFSpeechRecognizer` cannot use `contextualStrings`)
- Speech Recognition TCC permission is not required for Phase 2A-only users

**Negative / Known Issues**:
- The legacy `SFSpeechRecognizer` participant path hardcodes `en-US` locale and receives zero vocabulary hints (see TD-012). This divergence will persist until Phase 2B is promoted.
- The `AsyncStream` buffer in the `SpeechTranscriber` path has unbounded capacity. On thermally throttled devices where inference is slow, the buffer can grow without bound, risking OOM. Add a bounded capacity (e.g., 100 segments) with back-pressure before Phase 2B promotion.
- Running both pipelines simultaneously in Phase 2B doubles CPU usage for speech recognition during the benchmark period. This must be disclosed in developer documentation and must not ship to production users.

---

## ADR-004: Use SwiftData as the Persistence Layer

**Status**: Accepted  
**Date**: 2025-Q3  
**Review Date**: 2027-01-01

### Context

Orin stores meetings (`MeetingItem`), transcript chunks (`TranscriptChunk`, used for crash recovery), transcript segments (`TranscriptSegment`, used for timeline display), and folders (`FolderItem`). The data model has relationships (meeting-to-chunks, meeting-to-segments, folder-to-meetings) and requires crash recovery — if the app crashes mid-recording, transcript chunks written to disk must survive and be recoverable on next launch.

Orin is macOS-only in V1 and the team has Swift expertise. The primary alternatives for persistent storage on Apple platforms in 2025 are Core Data, SwiftData, SQLite (direct or via a library), and plain file I/O.

### Decision

Use SwiftData (`@Model`, `ModelContext`, `ModelContainer`) as the sole persistence backend. All models (`MeetingItem`, `TranscriptChunk`, `TranscriptSegment`, `FolderItem`) are annotated with `@Model`. Querying is done via `@Query` property wrappers in SwiftUI views and `FetchDescriptor` in services.

### Alternatives Considered

**Core Data**: SwiftData is Core Data under the hood (same SQLite stack, same WAL journal) but with a Swift-native API. Using Core Data directly would require `NSManagedObject` subclasses, `NSFetchRequest` with string-typed predicates, and manual `NSPersistentContainer` lifecycle management. SwiftData's `#Predicate` macro is type-safe. Given no pre-existing Core Data model, SwiftData was strictly preferable.

**SQLite via GRDB or SQLite.swift**: Would provide better query control, explicit batch insert APIs, and cross-platform portability (relevant for the Windows roadmap — see cross-platform section). Not adopted in V1 because the team had no prior SQLite library experience and SwiftData provides crash recovery (`TranscriptChunk` persistence) with minimal boilerplate. GRDB remains the recommended adapter for the future `OrinWindows` port.

**Plain file I/O (JSON or binary)**: Considered only for prototype. Crash recovery requires atomic writes, which file I/O does not provide without significant additional infrastructure. Relationships and querying are impractical. Rejected.

**Realm**: Third-party dependency, no official Apple support, licensing concerns. Rejected.

### Consequences

**Positive**:
- `@Model` / `@Query` integration with SwiftUI is idiomatic and reduces boilerplate
- SQLite WAL journal provides atomic writes — `TranscriptChunk` crash recovery works reliably
- `FetchDescriptor` with `#Predicate` is type-safe at compile time
- The orphan detection and best-of-N finalization logic in `TranscriptStore` builds naturally on SwiftData's session model

**Negative / Known Issues**:
- SwiftData is Apple-platform-only. A Windows port requires replacing the SwiftData layer entirely (see cross-platform roadmap). This was a known tradeoff at adoption time.
- `MeetingItem.transcript` is stored as an inline `String` SQLite column with no `@Attribute(.externalStorage)` annotation. The full transcript blob (up to 50,000+ chars for a 2-hour meeting) is loaded for every meeting in list-view `@Query` fetches, even though the list view only needs title, date, and summary. Fix: add `@Attribute(.externalStorage)` to `transcript`, requiring a `ModelMigrationPlan` (see TD-013, QW-014).
- `persistChunkIfNeeded()` calls `context.save()` synchronously on `@MainActor` for every 10-character transcript growth, producing multiple SQLite WAL writes per second during active recording. Fix: separate insert from save; the existing 3-second checkpoint cycle handles flushing (see TD-006, QW-008).
- `buildTimelineSegments()` and `deleteMeetingFully()` use unpredicated `FetchDescriptor` — full-table scans — and filter by `meetingId` in Swift after loading all rows. Fix: add `meetingId` predicates to both `FetchDescriptor` instances (see TD-016, QW-009).
- `allSegments @Query` in `MeetingsView` has no predicate, loading all `TranscriptSegment` rows from all meetings (see TD-010). At 100 meetings × 500 segments, this is 50,000 in-memory rows on every `MeetingsView` render. Fix: move to `MeetingDetailView` with a predicate (see QW-010).

---

## ADR-005: Use withTaskGroup for Parallel Chunk Analysis

**Status**: Superseded by ADR-014  
**Date**: 2025-Q4 (original decision)  
**Superseded**: 2026-06-29  
**Review Date**: N/A (superseded)

### Context

Long meetings (>15 minutes) produce transcripts that exceed the context window of local LLM models (phi3 at 4096 tokens, mistral at 8192 tokens). `TranscriptChunker` splits the transcript into overlapping chunks of approximately 5,000 characters each. A 150-minute meeting produces roughly 20 chunks. Each chunk must be independently analyzed (extracting action items, decisions, risks) before a synthesis step combines the per-chunk results.

The original decision was to submit all chunk analysis tasks simultaneously via `withTaskGroup`.

### The Original Rationale (preserved for context)

The comment in `MeetingIntelligenceService.analyzeChunked()` at the time of writing read:

> "Cloud APIs process requests in parallel; Ollama queues and serializes internally so total inference time is the same but network overhead overlaps."

This reasoning is correct for the success path: if all 20 Ollama requests succeed, the total inference time is determined by the single longest chunk (since Ollama serializes them), and the parallel submission does not increase that time. For cloud APIs (OpenAI, Anthropic), genuine parallelism does provide a speedup.

### Why This Decision Is Wrong for Local Inference

The reasoning is catastrophically wrong for the failure path.

Ollama is a single-process, single-GPU runtime. It accepts concurrent HTTP connections but queues inference behind a single execution slot. When 20 requests arrive simultaneously:

- Request 0 begins inference immediately
- Requests 1–19 queue inside Ollama, holding open HTTP connections

At t=60 seconds, `URLSession` fires its timeout for all 19 waiting requests simultaneously (they all started at approximately t=0). All 19 tasks then sleep for exactly `10_000_000_000` nanoseconds (10 seconds, no jitter) and fire a second wave at approximately t=70 seconds.

**Wave 1**: 20 requests. **Wave 2**: 19–20 retry requests. **Total observed**: ~41 concurrent requests.

This is the direct root cause of:
- Post-call system-wide GPU exhaustion lasting 60–120 seconds
- Ollama process OOM crashes (requiring manual restart)
- System-wide freezes observed by users after every long meeting
- The 41-request thundering herd documented in the architectural review

The code comment's assumption — "total inference time is the same" — holds only if every request succeeds. The failure mode is synchronized catastrophic collapse.

### Decision (Superseding)

See ADR-014. The `withTaskGroup` dispatch is replaced by sequential processing for local inference providers (Ollama, LM Studio, Apple Foundation Models) via an `InferenceWorker` actor with a serial job queue. Cloud providers retain bounded parallelism (semaphore, limit: 3).

The existing chunking, synthesis, deduplication, and action-item extraction logic is correct and is not changed.

### Immediate Quick Wins (while ADR-014 is being implemented)

The following can be applied in hours with no architectural change:
- **QW-001**: Replace `withTaskGroup` with a sequential `for` loop when the resolved provider is `.ollama`
- **QW-002**: Cache the `isOllamaAvailable()` health check result for 10 seconds
- **QW-003**: Replace the fixed `10_000_000_000 ns` retry sleep with `UInt64.random(in: 8_000_000_000...15_000_000_000)` to break synchronized retry waves

### Consequences of the Original Decision

- Post-call system freezes after every long meeting (primary user complaint)
- Ollama process OOM crashes requiring manual restart
- 41 concurrent `/api/generate` requests during the worst case
- 16 simultaneous `/api/tags` health check requests at analysis start
- The `[ProofRun]` diagnostic output written to `/tmp/orin_phi3_raw.txt` (world-readable) during debugging of this problem — itself a privacy violation (see TD-014, QW-006)

---

## ADR-006: Use Ollama for Local Inference

**Status**: Accepted  
**Date**: 2025-Q3  
**Review Date**: 2026-12-01

### Context

Orin's core privacy commitment is that meeting transcripts and analysis remain on-device by default. This requires a local LLM inference runtime capable of running instruction-tuned models (phi3, mistral, llama3) on macOS with acceptable performance on Apple Silicon. The runtime must accept HTTP requests (to enable future provider abstraction) and must support the macOS model sizes that run on 8GB M-series machines.

### Decision

Use Ollama (`ollama.ai`) as the default local inference backend. Ollama:
- Provides a REST API compatible with the OpenAI `v1/chat/completions` format
- Manages model download, storage, and loading automatically
- Supports Apple Silicon GPU acceleration via Metal
- Is free, open-source, and runs entirely on-device
- Supports phi3 (3.8B), mistral (7B), llama3 (8B), and other models appropriate for meeting analysis on 8GB RAM machines

`AIService.swift` calls Ollama at `http://localhost:11434/api/generate`. `OllamaInstallerService` handles installation detection and guided setup.

### Alternatives Considered

**LM Studio**: Equivalent to Ollama in capability and also provides a local REST API. Not adopted as the default because Ollama has a simpler headless-server model (no GUI required, more suitable for background service operation). LM Studio is supported as a secondary provider via `AIService.generate()` provider selection. Both will be formalized as `InferenceProvider` implementations in ADR-014.

**Apple Foundation Models (WWDC 2025)**: Apple announced on-device foundation models available via `FoundationModels.framework` on macOS 26. These run entirely on-device with no Ollama dependency. Not adopted as the default in V1 because: (1) macOS 26 was not yet shipping at the time of the original architecture; (2) Apple Foundation Models have limited context windows (initially); (3) meeting analysis requires instruction following across long transcripts where phi3/mistral perform better. Will be added as a first-class `AppleFoundationModelsProvider` in ADR-014.

**OpenAI / Anthropic API (cloud-only)**: Available as opt-in providers for users who consent to transcript upload. Not the default because Orin's product promise is local-first (see ADR-013).

**llama.cpp directly**: Lower-level than Ollama; requires managing model loading, quantization, and GPU scheduling directly. Ollama wraps llama.cpp. No advantage over Ollama for this use case.

### Consequences

**Positive**:
- Zero cloud dependency for AI analysis by default
- Transcript data never leaves the device unless the user explicitly enables a cloud provider
- Model updates (phi3 → phi3.5, mistral → mistral-nemo) require only `ollama pull`, not an app update
- The Ollama REST API is compatible with the OpenAI wire protocol, simplifying provider abstraction

**Negative / Known Issues**:
- Ollama is a separate process that must be running before analysis can begin. `AIService` must detect Ollama availability and guide the user through installation. This adds a first-run friction point.
- Model IDs are currently hardcoded in `AIService.swift` source (`"phi3"`, `"mistral"`, `"claude-haiku-4-5-20251001"`, `"gpt-4o-mini"`). Provider model deprecations require a code change and app release. Fix: make model IDs runtime-configurable via `UserDefaults` or a settings struct (see TD-020).
- Ollama serializes inference — parallel requests do not increase throughput but do cause the thundering herd described in ADR-005. This is a property of local inference generally, not specific to Ollama. The InferenceWorker design (ADR-014) addresses this.
- Ollama is not available on Windows or iOS. These platforms will require `LMStudioProvider`, `CoreMLProvider`, or `OllamaProvider` (if Ollama ships for Windows) as `InferenceProvider` implementations.

---

## ADR-007: Use a Flat 103-Term Vocabulary Array

**Status**: Superseded by the Layered VocabularyContext Proposal (MT-004)  
**Date**: 2025-Q3 (original decision)  
**Superseded**: 2026-06-29  
**Review Date**: N/A (superseded)

### Context

`SpeechTranscriber` (and `SFSpeechRecognizer` in some configurations) accepts a list of contextual strings — domain-specific words and phrases that the recognition engine biases toward when they are acoustically ambiguous. Meeting intelligence products benefit significantly from vocabulary that includes product names, technical jargon, attendee names, and acronyms specific to the organization.

### The Original Decision

Implement vocabulary as a static Swift enum `VocabularyProvider` with:
- `builtInTerms`: 103 hardcoded English and romanized-Hindi terms compiled into the binary
- `userTerms`: read from `UserDefaults.standard.stringArray(forKey: "orin.customVocabulary")`, settable via `defaults write` in Terminal (developer-only)
- `allTerms`: computed as `(builtInTerms + userTerms).prefix(100).map { $0 }`

### Why This Decision Is Inadequate

The flat-array approach has five structural problems that make it a blocker for any non-English market:

**1. The 100-term cap is already overflowed in V1.** `builtInTerms` contains 103 terms. `.prefix(100)` silently drops 3 built-in terms before any user terms are added. When a user adds any custom terms, those terms replace built-in terms — the user never sees which built-in terms were dropped. No warning, no log, no UI indication.

**2. No language namespace.** The 103-term list mixes English business jargon with 48 romanized-Hindi terms in a flat array. For a Spanish-language meeting, the 48 Hinglish terms are irrelevant noise consuming vocabulary budget. For a Hindi meeting, the English terms are irrelevant. There is no way to select language-appropriate terms.

**3. No per-meeting context.** Attendee names (from `EKEvent.attendees`) are the single most high-value vocabulary for a meeting — ASR systems reliably confuse names. There is no mechanism to inject attendee names into the vocabulary at session start.

**4. No user interface.** The only way to add custom vocabulary is `defaults write com.rconcept.orin orin.customVocabulary -array "term1" "term2"` in Terminal. This is a developer-only affordance. Business users cannot access it.

**5. The vocabulary only works on Phase 2A.** `contextualStrings` is a `SpeechTranscriber`-only API. The legacy `SFSpeechRecognizer` path (still the default) has no equivalent API and receives zero vocabulary hints. The vocabulary system provides no benefit for the majority of current users.

### Superseding Decision

The layered `VocabularyContext` system (MT-004):

**Four tiers with explicit priority ordering:**
- Tier 1 (Session): attendee names from `EKEvent.attendees` at session start — always included, highest priority
- Tier 2 (User): terms managed via `SettingsView` vocabulary section, stored in SwiftData `VocabularyItem @Model`
- Tier 3 (Org): future — team-shared terms via CloudKit private database
- Tier 4 (Built-in): language-partitioned packs (English-Business, Hinglish, Spanish-Business, etc.)

**`VocabularyContext.build(forMeeting: meeting, language: locale)`** fills from Tier 1 through Tier 4 until the 100-term budget is exhausted. Higher-tier terms are never displaced by lower-tier terms.

**`VocabularyItem` SwiftData `@Model`**: `{ id: UUID, term: String, languageCode: String?, source: VocabularySource, frequency: Int, createdAt: Date, lastUsedAt: Date }`. Enables filtering by source and language in the `SettingsView` UI.

**`CorrectionStore`**: learns from user transcript edits, auto-promotes at correction frequency ≥ 3. All on-device, never transmitted.

### Consequences of the Original Decision

- 3 built-in vocabulary terms silently dropped in V1 (and more as the list grows)
- Zero vocabulary benefit for legacy-pipeline users (the majority)
- No attendee name injection despite attendee names being available via EventKit
- No path to Spanish/French/German vocabulary without modifying source code

---

## ADR-008: Use ServiceContainer as a Service Locator Pattern

**Status**: Accepted (with mandatory thread-safety fix pending)  
**Date**: 2025-Q3  
**Review Date**: 2026-10-01

### Context

Orin has approximately 20 service classes that need to collaborate: `RecordingService` needs `TranscriptStore`, `MeetingDetectorService` needs `CalendarService` and `TranscriptStore`, `MeetingIntelligenceService` needs `AIService`, and so on. These services are instantiated once at app launch in `OrinApp.init()` and must be accessible throughout the app lifecycle.

### Decision

Implement `ServiceContainer` as a global service locator: a singleton (`ServiceContainer.shared`) with a `[String: Any]` dictionary mapping type names to instances. `register<T>(_ service: T, for type: T.Type)` populates the dictionary; `resolve<T>(_ type: T.Type) -> T` retrieves and type-casts.

### Alternatives Considered

**SwiftUI `@Environment`**: Appropriate for injecting values into the SwiftUI view hierarchy but not accessible from service-layer code that does not have access to `EnvironmentValues`. `@Environment` objects cannot be read from `Task.detached` closures or from the `AVAudioEngine` tap block. Rejected as the sole mechanism.

**Constructor injection everywhere**: The architecturally correct approach. Each service receives its dependencies via its initializer, making the dependency graph explicit and testable. Rejected for V1 due to the bootstrapping complexity when 20 services have mutual dependencies and shared state. Constructor injection is the recommended migration path for service-to-service dependencies, especially those accessed from audio callbacks.

**Combine `CurrentValueSubject` service bus**: Over-engineered for this use case. Rejected.

**Swift 6 `@MainActor` static properties**: Could serve as a simple registry. Not adopted because it conflates the service lifecycle with the main actor, making services inaccessible from `Task.detached` contexts.

### Consequences

**Positive**:
- Simple to use: `ServiceContainer.shared.resolve(TranscriptStore.self)` from any call site
- Services are registered once and available immediately after `OrinApp.init()`

**Negative / Known Issues**:
- **Critical thread-safety gap (TD-005)**: `services: [String: Any]` has no lock. `ServiceContainer.shared.resolve()` is called from `Task.detached` closures in `MeetingDetectorService.poll()` which run on the cooperative thread pool concurrently with `OrinApp.init()` writing to the dictionary via `register()`. This is a real data race that TSan would flag. Fix: add `private let lock = NSLock()` and wrap both `register()` and `resolve()` in `lock.withLock {}` (two lines, hours of effort — see QW-005).
- `resolve()` calls `fatalError` on missing keys. A registration-order bug or a service that fails to register produces a crash with no diagnostic information. Should be changed to return an optional and log a structured error.
- `ServiceContainer.shared.resolve()` is called from inside audio recognition callbacks in `RecordingService` and `SystemAudioCaptureService`. Service locator calls from real-time or near-real-time contexts are an architectural smell: the service should be captured at session start (constructor injection or stored property), not resolved on every callback. Migration path: resolve services once at `startRecording()` and store them as local variables for the session's duration.
- Long-term: replace service-to-service `resolve()` calls with constructor injection. The view layer (`@Environment`) can continue to use `ServiceContainer` as a SwiftUI bridge. Services should receive their dependencies at initialization time.

---

## ADR-009: Store Transcripts as Inline SwiftData String Columns

**Status**: Superseded — add @Attribute(.externalStorage)  
**Date**: 2025-Q3 (original decision)  
**Superseded**: 2026-06-29  
**Review Date**: N/A (superseded)

### Context

`MeetingItem.transcript` stores the full meeting transcript as a `String` property on the `@Model`. SwiftData stores this as a `TEXT` column in the SQLite database. The transcript is the largest field on `MeetingItem`, ranging from a few hundred characters for a short standup to 50,000+ characters for a 2-hour meeting.

### The Original Decision

Store `transcript` as a plain `String` property with no storage attribute annotation. This is the default SwiftData behavior — the value is stored inline in the SQLite row.

### Why This Is a Performance Problem

SwiftData's `@Query` property wrapper fetches entire model objects from SQLite. When `MeetingsView` executes `@Query var allMeetings: [MeetingItem]`, SwiftData loads every column of every `MeetingItem` row, including the `transcript` `TEXT` column.

`MeetingsView` does not display the transcript — it displays title, date, duration, and summary. Yet it forces a full load of the transcript blob for every meeting on every render pass.

At 50 meetings averaging 25,000 characters each, this is approximately 1.25 MB of transcript text loaded into memory on every meetings-list render. At 100 meetings at 2 hours each (50,000 chars), this is ~5 MB — enough to contribute to system memory pressure that causes Ollama OOM crashes on 8GB machines.

### Superseding Decision

Add `@Attribute(.externalStorage)` to `MeetingItem.transcript` in `OrinModels.swift`:

```swift
@Attribute(.externalStorage) var transcript: String = ""
```

SwiftData stores the value as an external binary file in the app's Application Support container and stores only a file reference in the SQLite row. The property is lazy-loaded: it is fetched from disk only when explicitly accessed, not during `@Query` batch fetches. This is the correct SwiftData mechanism for large blob columns.

**Migration required**: Changing a column's storage attribute requires a `VersionedSchema` and `ModelMigrationPlan`. The migration is additive — existing data is moved to external storage files automatically by SwiftData's migration engine. A `MigrationStage.lightweight` is sufficient.

### Consequences of the Original Decision

- ~5 MB of transcript text loaded into RAM on every meetings-list render for a user with 100 meetings
- Memory pressure from this load contributes to Ollama OOM events
- `allMeetings @Query` performance degrades linearly with meeting count and transcript length

---

## ADR-010: Use @MainActor for RecordingService

**Status**: Accepted  
**Date**: 2025-Q3  
**Review Date**: 2027-06-01

### Context

`RecordingService` owns the recording lifecycle: it starts/stops `AVAudioEngine`, manages the `TapState`, tracks recording state, and communicates with `TranscriptStore` and `MeetingDetectorService`. Its state is observed by SwiftUI views (via `@Observable`) and must be consistent with the view render cycle.

Swift 6's strict concurrency model requires that `@Observable` classes accessed from SwiftUI be isolated to a single actor (typically `@MainActor`) or be explicitly `Sendable`. The alternative — using an actor — would require `await` on every property access from SwiftUI, which is architecturally awkward and introduces the risk of priority inversion when the main thread awaits a non-main-actor service.

### Decision

Annotate `RecordingService` as `@MainActor`. All methods are called from the main actor. The bridge to the Core Audio real-time thread is exclusively through `TapState` (see ADR-001), which is `@unchecked Sendable` and manages its own `NSLock`.

### Alternatives Considered

**Actor isolation (not `@MainActor`)**: A generic `actor RecordingService` would require `await` at every SwiftUI call site. The recording state machine (start/stop/restart) involves rapid sequential state changes that, as async operations, would be prone to interleaving if awaited independently. `@MainActor` provides a simpler and more predictable execution model for a UI-facing service.

**No actor annotation (unstructured concurrency)**: Rejected by Swift 6's strict concurrency checking. Any `@Observable` class accessed from SwiftUI that is not actor-isolated will produce compile errors or runtime crashes in Swift 6 mode.

**`nonisolated` with manual synchronization**: Would require manual locking for every property access and method call. More error-prone than `@MainActor`. Rejected.

### Consequences

**Positive**:
- `RecordingService` state is always consistent with the SwiftUI render cycle — no race between SwiftUI observation and service state mutation
- No `await` required at SwiftUI call sites (direct property access)
- Swift 6 strict concurrency compliance for the `@Observable` observation system
- `DispatchQueue.main.async` patterns from GCD-era code were already migrated to `Task { @MainActor in }` in commit 4f603ea, eliminating the `EXC_BREAKPOINT swift_task_isCurrentExecutorWithFlagsImpl` crash on macOS 26

**Negative / Known Issues**:
- Heavy work on `@MainActor` blocks the UI. `RecordingService` must never perform blocking I/O, slow computation, or synchronous waits on `@MainActor`. The 1.5-second `Task.sleep(nanoseconds: 1_500_000_000)` in `TranscriptStore.finalize()` that awaits trailing recognition chunks blocks the entire main actor for 1.5 seconds on every meeting stop (see TD-021). Fix: replace the time-based wait with an explicit signal from `RecordingService` when recognition is confirmed complete.
- `sampleCPUUsage()` and `sampleRAMMB()` use raw Mach APIs (`task_threads`, `thread_info`, `task_info`) in a `Task.detached` every 5 seconds during recording. These syscalls were added for Phase 2A benchmarking and are not gated behind `#if DEBUG`. They have no place in production builds (see TD-018).
- `DebugResetView` uses `DispatchQueue.main.asyncAfter` and `DispatchQueue.main.async` instead of `Task { @MainActor in }`, creating the same GCD/Swift concurrency mismatch that was fixed in `RecordingService`. This will produce `EXC_BREAKPOINT` crashes in `DebugResetView` on macOS 26 under Swift 6 (see TD-023).

---

## ADR-011: Duplicate Recognition Session Management in RecordingService and SystemAudioCaptureService

**Status**: Accepted as technical debt; extraction to RecognitionSessionManager is planned  
**Date**: 2025-Q3 (original duplication)  
**Planned Extraction**: Q3 2026 (MT-001)  
**Review Date**: 2026-10-01

### Context

Both `RecordingService` (mic channel) and `SystemAudioCaptureService` (participant/system audio channel) need to manage an `SFSpeechRecognitionTask` session: starting tasks, handling error 1110 restarts with the generation counter, running a cold-start watchdog, detecting utterance-boundary shrinkage, and tracking per-generation speech presence.

### Decision (Original)

Copy the recognition session management code verbatim from `RecordingService` into `SystemAudioCaptureService`. Both files contain the same generation counter, the same 200ms/1s restart delay logic, the same 10-second watchdog, and the same utterance-boundary heuristic. Total duplication: approximately 400 lines.

### Why This Was Done

The participant audio channel (system audio via SCStream) was added after the mic channel was already working. The fastest path to a working implementation was to copy the proven recognition management code rather than extract it into a shared type — at the time, it was unclear how similar the two channels' restart behaviours would actually need to be in practice.

### Why This Must Be Extracted

The duplication has already caused one production bug: the locale configurations have diverged. `RecordingService` hardcodes `en-IN` for the mic channel's `SFSpeechRecognizer`. `SystemAudioCaptureService` hardcodes `en-US` for the participant channel. Both should read from `VocabularyProvider.speechLocale`. The fix was applied to `RecordingService` but not `SystemAudioCaptureService` — because it is easy to forget that a bug fix must be applied in two places.

The generation counter TOCTOU race (ADR-002 consequences) also exists in both files and would need to be fixed independently in both. Any future improvement to recognition restart logic (smarter error classification, adaptive restart delays, better cold-start detection) must be implemented twice.

### Planned Extraction (MT-001)

Extract a `RecognitionSessionManager` actor:

- Properties: `recognitionGeneration: Int`, `generationHadSpeech: Bool`
- Methods: `startSession(recognizer:request:delegate:)`, `handleError(_:)`, `handleResult(_:)`, `invalidate()`
- Internal: restarts with generation guard, watchdog Task, utterance-boundary detection
- Protocol: `RecognitionSessionDelegate` — callbacks for `sessionDidProduce(result:)`, `sessionDidRestart(generation:)`, `sessionDidFail(permanently:)`

`RecordingService` and `SystemAudioCaptureService` each hold one `RecognitionSessionManager` instance and delegate all restart logic to it. The generation counter race is fixed in one place. The locale bug cannot recur because locale is a parameter to `startSession()`, not a local constant.

### Consequences of the Current Duplication

- Any bug fix must be applied twice (already caused the locale divergence)
- The generation counter TOCTOU race exists in both files
- The two pipelines have diverged in locale handling (`en-IN` vs `en-US`) and will likely diverge further over time
- 400+ lines of code that must be read and understood twice to comprehend the recording pipeline

---

## ADR-012: Use Feature Flags via UserDefaults for Phase 2A / 2B Migration Gating

**Status**: Accepted  
**Date**: 2026-Q1  
**Review Date**: 2026-10-01 (review when Phase 2B is ready for promotion)

### Context

The migration from `SFSpeechRecognizer` to `SpeechTranscriber` (see ADR-003) involves replacing two audio processing pipelines that cannot be validated identically in a test environment — real-world audio (accents, background noise, video conferencing codecs) produces qualitatively different results from a controlled test. The team needs the ability to enable the new pipeline for specific users (developers, beta testers), measure accuracy and stability, and roll back instantly if a regression is found.

### Decision

Use `UserDefaults`-backed boolean flags in a `FeatureFlags` enum:

```swift
static var useNewMicPipeline: Bool {
    UserDefaults.standard.bool(forKey: "orin.useNewMicPipeline")
}

static var useNewParticipantPipeline: Bool {
    UserDefaults.standard.bool(forKey: "orin.useNewParticipantPipeline")
}
```

Flags default to `false`. Engineers and beta testers toggle them via `defaults write com.rconcept.orin <key> -bool YES` and restart Orin. The flags are not exposed in the settings UI — they are intentionally developer-facing in Phase 2A/2B.

### Alternatives Considered

**Remote feature flag service (LaunchDarkly, Statsig)**: Would enable percentage rollouts and A/B testing. Rejected for V1: Orin has no server infrastructure, and a local-first product should not require a network connection to determine which audio pipeline to use. The flag evaluation happens at app launch; requiring network round-trips at that point would add startup latency and fragility.

**Build-time compilation flag (`#if NEW_PIPELINE`)**: Would require separate builds for each pipeline configuration. Rejected — makes it impossible to compare pipelines on the same binary, which is essential for the Phase 2B benchmark (both pipelines run simultaneously with only the output routing swapped).

**Settings UI toggle**: Rejected for Phase 2A/2B. These flags change fundamental audio processing behaviour. Exposing them in the user-facing settings UI risks users accidentally enabling an unvalidated pipeline. The flags will be promoted to settings-UI toggles once Phase 2B is validated.

**Hardcoded** (no flag): Rejected. A failed migration with no rollback path would force an emergency app release to restore the working pipeline.

### Consequences

**Positive**:
- Zero code change required to enable or disable either pipeline
- Rollback is instant: one Terminal command, no app release
- Phase 2B benchmark mode (both pipelines running simultaneously) requires only the flag swap — no architectural change
- `FeatureFlags` is a compile-time type check for valid flag names, preventing typos

**Negative / Known Issues**:
- `UserDefaults.bool(forKey:)` returns `false` for missing keys — the default-off behavior is correct but requires explicit documentation (which `FeatureFlags.swift` provides in comments)
- The flags are read at app launch (lazy initialization of services). Toggling a flag while Orin is running has no effect until restart. This must be documented clearly in the migration runbook.
- Phase 2B currently runs both pipelines simultaneously (doubling CPU for speech recognition). This must not ship to production users in this form. Promotion of `useNewParticipantPipeline` to default-`true` must switch off the legacy participant pipeline entirely.
- The `FeatureFlags` enum does not provide observability — there is no telemetry when a flag is active. Add `os_signpost` or `Logger` calls at flag evaluation points to make pipeline selection visible in Instruments traces.

---

## ADR-013: Local-First, Offline-First, Privacy-First as Non-Negotiable Product Constraints

**Status**: Accepted (foundational; does not require review)  
**Date**: 2025-Q3 (product inception)  
**Review Date**: Revisit only if product direction changes

### Context

Orin records, transcribes, and analyzes private meeting conversations. The content of these recordings — business strategies, personnel discussions, financial information, customer data — is among the most sensitive data a professional generates. The competitive landscape includes cloud-based meeting intelligence products (Otter.ai, Fireflies.ai, Zoom AI) that require meeting transcripts to be uploaded to third-party servers.

Orin's core product differentiation is that meeting intelligence can be delivered without any of this data leaving the user's device.

### Decision

Establish three non-negotiable constraints that every architecture decision must satisfy:

**1. Local-first**: All core functionality (recording, transcription, AI analysis, search, export) works without an internet connection. The app must be fully functional on an airplane.

**2. Offline-first**: The default configuration requires no accounts, no API keys, and no server connectivity. A new user installs Orin, installs Ollama, and has full functionality — no sign-up, no email address, no credit card.

**3. Privacy-first**: No meeting content (audio, transcripts, analysis results, vocabulary terms, attendee names) is transmitted to any external service unless the user explicitly opts in and understands what is being sent. Orin's servers (if any exist) never receive meeting content. Cloud AI providers (OpenAI, Anthropic) are opt-in with explicit consent.

### Consequences for Architecture

Every decision in this document is constrained by these three principles:

- **ADR-006 (Ollama)**: Ollama was chosen over cloud-only LLMs precisely because it runs on-device. Cloud providers are opt-in secondary paths.
- **ADR-004 (SwiftData)**: Meeting data is stored in the app's sandboxed Application Support container, not in iCloud (unless the user enables it), not in any server database.
- **ADR-007 consequences**: Vocabulary data (including attendee names, company-specific terms) is stored in SwiftData on-device. The `CorrectionStore` (learned vocabulary) is never transmitted.
- **TD-014 (privacy violation)**: `MeetingIntelligenceService` currently writes raw AI output (which includes transcript fragments) to `/tmp/orin_phi3_raw.txt`, which is world-readable on macOS. This is a direct violation of the privacy-first constraint and must be deleted (QW-006).
- **Future cloud sync**: If Orin ever adds iCloud sync, it must use CloudKit private database (encrypted, user-controlled) and never a Orin-controlled server. Meeting content in CloudKit is only decryptable by the user's own devices.
- **Vocabulary system (ADR-007 supersession)**: The proposed `VocabularyItem` SwiftData model stores all terms on-device. The org-tier vocabulary (Tier 3) syncs via CloudKit private database, not Orin servers.
- **Cross-platform roadmap**: The `OrinCore` Swift package (cross-platform business logic) must not depend on any cloud service. The `InferenceProvider` protocol must work identically with Ollama (local) and OpenAI (cloud-opt-in). The persistence layer must be replaceable with GRDB for platforms without SwiftData.

### Boundaries

These constraints do not prohibit:
- Optional cloud AI providers (OpenAI, Anthropic) with explicit user consent and clear in-product disclosure of what is transmitted
- Optional iCloud sync via CloudKit private database with user-controlled encryption
- Crash reporting (with meeting content excluded from crash payloads)
- Anonymous usage analytics with explicit opt-in and no meeting content

---

## ADR-014: Design for Sequential Local Inference via InferenceWorker Actor

**Status**: Proposed (target implementation: Q3 2026)  
**Date**: 2026-06-29  
**Depends on**: ADR-005 (supersedes), ADR-006  
**Review Date**: 2026-12-01 (review after InferenceWorker ships)

### Context

The thundering herd problem documented in ADR-005 is the primary root cause of post-call system freezes. The fix requires more than a `semaphore(value: 1)` patch — it requires a principled model of how local inference differs from cloud inference and how that difference must be reflected in the concurrency design.

Local inference (Ollama, LM Studio, Apple Foundation Models, llama.cpp) is fundamentally a single-threaded worker with a job queue. These runtimes:
- Accept concurrent HTTP connections but serialize GPU matrix multiplication behind a single execution slot
- Compete with the operating system, UI rendering, and other apps for shared GPU/ANE memory
- Have no horizontal scaling — sending 20 requests does not increase throughput
- Have a fixed-size VRAM budget — concurrent requests increase peak memory pressure and can trigger OOM crashes in the inference process

Cloud inference (OpenAI, Anthropic, Gemini) is genuinely horizontally scaled — sending N concurrent requests does process them in parallel and reduces wall-clock time.

These two models require different concurrency strategies.

### Decision

Introduce `InferenceWorker` as a Swift actor that is the single point of contact for all LLM inference in Orin:

**For local providers (Ollama, LM Studio, Apple Foundation Models)**:
- `InferenceWorker` maintains a serial `AsyncStream<InferenceJob>` job queue
- Jobs are processed one at a time (pop, infer, post result, pop next)
- Total throughput is identical to parallel dispatch (local inference serializes anyway) but the failure mode is isolated: one job fails, that job retries, other jobs continue unaffected
- The thundering herd cannot occur: there is always exactly one in-flight request to the local runtime

**For cloud providers (OpenAI, Anthropic)**:
- `InferenceWorker` uses a `AsyncSemaphore(value: 3)` to allow bounded parallelism
- 3 concurrent requests is sufficient to saturate cloud API throughput without triggering rate limits

**`AnalysisJobQueue` actor**:
- Serializes multi-meeting analysis requests at the meeting level
- When two meetings finish recording seconds apart, analysis of the second meeting waits until the first is complete
- Prevents 2N concurrent inference requests from two simultaneous analyses
- Exposes `currentDepth: Int` for UI display ("Analysis queued — 2 meetings")
- Priority: user-initiated analysis (Analyze button) is inserted ahead of automatic post-recording analysis

**`InferenceProvider` protocol**:
```swift
protocol InferenceProvider {
    var providerType: InferenceProviderType { get }
    func infer(job: InferenceJob) async throws -> InferenceResult
}

enum InferenceProviderType { case local, cloud }
```

Concrete implementations: `OllamaProvider`, `LMStudioProvider`, `AppleFoundationModelsProvider`, `OpenAIProvider`, `AnthropicProvider`. `InferenceWorker` selects the concurrency strategy (serial vs bounded-parallel) based on `provider.providerType`.

**`ModelRouter` protocol**:
```swift
protocol ModelRouter {
    func route(job: InferenceJob) -> any InferenceProvider
}
```

Concrete routers: `LocalFirstRouter` (Ollama/LM Studio → cloud fallback), `CloudOnlyRouter`, `SpecializedRouter` (routes large analysis to a capable model, small summarization to a fast model).

**Health check caching**: The `isOllamaAvailable()` check (currently an uncached live HTTP request to `/api/tags`) is cached for 10 seconds. All concurrent callers within the 10-second window share one result. This eliminates the 16 simultaneous `/api/tags` requests at analysis start.

**Retry with jitter**: The fixed 10-second retry sleep is replaced with `UInt64.random(in: 8_000_000_000...15_000_000_000)`, spreading retry waves across a 7-second window (Poisson distribution instead of synchronized burst).

**Circuit breaker**: After 3 consecutive Ollama failures within a 90-second window, `InferenceWorker` marks Ollama as unavailable for 60 seconds and routes jobs to cloud providers. Prevents the retry storm from continuously hammering a crashed or OOM'd Ollama process.

**Progressive result delivery**: `analyzeChunked()` receives an `AsyncStream<(chunkIndex: Int, ChunkAnalysis)>` from `InferenceWorker`. As each chunk completes, partial results are stored in SwiftData and displayed in the UI progressively. The synthesis step fires after all chunks complete. Users see growing analysis results rather than a spinner for the entire analysis duration.

### Alternatives Considered

**Simple `semaphore(value: 1)` patch to `withTaskGroup`**: This is the immediate fix (QW-001) and should be applied now while `InferenceWorker` is being built. The semaphore patch eliminates the thundering herd but does not address: the AnalysisJobQueue (two meetings simultaneously), the health check stampede, or the provider abstraction needed for multi-model support. The semaphore is a tactical fix; `InferenceWorker` is the strategic solution.

**Actor per provider**: Could use one actor per `InferenceProvider` instance (e.g., `OllamaActor`). Rejected because it scatters concurrency policy across multiple types and makes it impossible to enforce a global "only one local inference job at a time" invariant across providers.

**Queue-based dispatch on a background thread**: GCD `DispatchQueue.async` would serialize jobs but cannot be awaited from Swift structured concurrency. Rejected.

**Retain existing `withTaskGroup` with parallel dispatch for Ollama**: Rejected. The comment in the original code (`"Ollama queues and serializes internally so total inference time is the same"`) is true for throughput but wrong for failure mode. The thundering herd is the #1 user-visible bug. The parallel design must be replaced.

### Consequences

**Positive**:
- Eliminates the thundering herd — the primary root cause of post-call system freezes
- Progressive result delivery improves perceived performance for long meetings
- `InferenceProvider` protocol enables model-agnostic code paths: adding Apple Foundation Models requires only a new `AppleFoundationModelsProvider` implementation
- `AnalysisJobQueue` prevents double load when meetings finish back-to-back
- Circuit breaker prevents cascading Ollama failures from causing indefinite retry storms
- Health check caching eliminates the `/api/tags` stampede

**Negative / Known Issues**:
- Sequential local inference means that for long meetings (20 chunks), the UI shows "Analyzing chunk 1 of 20" for the full duration. This is a UX change from the current behavior (where all chunks appear to start simultaneously). Progressive result display mitigates this — users see partial results appearing progressively rather than a single long wait.
- `InferenceWorker` is a new actor that must be instantiated once in `OrinApp.init()` and injected into all callers. This requires updating the injection chain from `OrinApp` through `ServiceContainer` (or direct constructor injection) to `AIService` and `MeetingIntelligenceService`.
- The `AnalysisJobQueue` observable state (queue depth) needs to be surfaced in the UI. `MeetingsView` must observe `AnalysisJobQueue.currentDepth` to display queued state.

### Implementation Sequence

1. **Hours**: Apply QW-001 (sequential for-loop or semaphore in `analyzeChunked` for Ollama) and QW-002 (health check cache) and QW-003 (jitter). Ship these immediately — they eliminate the thundering herd without any architectural change.
2. **Days**: Introduce `InferenceProvider` protocol and wrap `OllamaProvider` and existing cloud providers behind it. No behavior change.
3. **Weeks**: Build `InferenceWorker` actor with serial queue for local and bounded semaphore for cloud. Migrate `AIService` to use it.
4. **Weeks**: Build `AnalysisJobQueue` actor. Wire to `MeetingIntelligenceService`.
5. **Ongoing**: Add `AppleFoundationModelsProvider`, `LMStudioProvider` as new `InferenceProvider` implementations.

---

## Summary Table

| ADR | Title | Status | Severity |
|-----|-------|--------|----------|
| ADR-001 | AVAudioEngine + TapState NSLock Bridge | Accepted | — |
| ADR-002 | SFSpeechRecognizer Generation-Counter Restart | Accepted (legacy path) | Known races to fix |
| ADR-003 | SpeechTranscriber Phase 2A/2B Feature Flags | Accepted | Active migration |
| ADR-004 | SwiftData Persistence | Accepted | Performance fixes needed |
| ADR-005 | withTaskGroup Parallel Chunk Analysis | **Superseded by ADR-014** | **Critical bug** |
| ADR-006 | Ollama for Local Inference | Accepted | Model IDs need externalization |
| ADR-007 | Flat 103-Term Vocabulary Array | **Superseded by Layered VocabularyContext** | Structural blocker |
| ADR-008 | ServiceContainer Service Locator | Accepted | Thread safety fix required |
| ADR-009 | Inline Transcript String Column | **Superseded — add @Attribute(.externalStorage)** | Performance fix |
| ADR-010 | @MainActor for RecordingService | Accepted | — |
| ADR-011 | Duplicated Recognition Session Management | Accepted as tech debt | Extract to RecognitionSessionManager |
| ADR-012 | UserDefaults Feature Flags for Pipeline Migration | Accepted | — |
| ADR-013 | Local-First / Offline-First / Privacy-First | Accepted | Foundational |
| ADR-014 | Sequential Local Inference via InferenceWorker | **Proposed** | Addresses ADR-005 root cause |

---

## Appendix: Quick Reference — Technical Debt Cross-Reference

The following critical technical debts map directly to the ADRs above. Engineers addressing these bugs should read the relevant ADR for full context before making changes.

| Debt ID | Description | ADR | Effort |
|---------|-------------|-----|--------|
| TD-001 | Unbounded concurrent Ollama dispatch | ADR-005, ADR-014 | Hours (QW-001) |
| TD-002 | Real-time heap allocation in audio callbacks | ADR-001, ADR-002 | Days (QW-011) |
| TD-003 | TapState.disarm() XPC-in-lock | ADR-001 | Hours (QW-004) |
| TD-004 | AVAudioEngineConfigurationChange debounce race | ADR-002 | Hours (QW-007) |
| TD-005 | ServiceContainer no thread safety | ADR-008 | Hours (QW-005) |
| TD-006 | O(N²) SwiftData writes during recording | ADR-004 | Hours (QW-008) |
| TD-007 | 400-line recognition management duplication | ADR-011 | Weeks (MT-001) |
| TD-013 | MeetingItem.transcript inline SQLite column | ADR-009 | Days (QW-014) |
| TD-014 | /tmp/orin_phi3_raw.txt privacy violation | ADR-013 | Hours (QW-006) |
| TD-016 | Full-table scans in buildTimelineSegments | ADR-004 | Hours (QW-009) |

Engineers making architectural changes that affect any decision in this document should update the relevant ADR rather than creating new documentation. The decision record is only valuable if it stays current.
