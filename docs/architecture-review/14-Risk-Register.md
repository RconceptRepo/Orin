# Risk Register — Orin V1 Architecture Review

**Document version**: 1.0  
**Review date**: 2026-06-29  
**Prepared by**: Architecture Review Team (9-agent analysis)  
**Status**: Active — reassess after Phase 1 fixes are shipped

---

## Overview

This register captures all risks identified during the full-codebase architectural review. Risks are scored using a simple 3×4 grid: Probability (LOW / MEDIUM / HIGH) × Impact (LOW / MEDIUM / HIGH / CRITICAL). Entries are ordered by combined urgency, not alphabetically.

Ownership is Engineering across the board — this is not a document for stakeholder reassurance. It is an operational tracker for the team.

---

## Risk Summary Table

| ID | Title | Category | Probability | Impact | Score | Status |
|---|---|---|---|---|---|---|
| RISK-001 | System freeze on every long meeting | Technical | HIGH | CRITICAL | P3-I4 = **12** | OPEN |
| RISK-002 | Core Audio crash on device route change | Technical | MEDIUM | CRITICAL | P2-I4 = **8** | OPEN |
| RISK-003 | Data race crash in ServiceContainer | Architectural | MEDIUM | HIGH | P2-I3 = **6** | OPEN |
| RISK-004 | Real-time thread priority inversion | Technical | HIGH | HIGH | P3-I3 = **9** | OPEN |
| RISK-005 | Main actor blocking during recording | Technical | HIGH | HIGH | P3-I3 = **9** | OPEN |
| RISK-006 | Privacy violation in production | Privacy/Compliance | MEDIUM | HIGH | P2-I3 = **6** | OPEN |
| RISK-007 | Legacy SFSpeechRecognizer permanent | Technical | HIGH | HIGH | P3-I3 = **9** | OPEN |
| RISK-008 | Vocabulary blocks non-English markets | Strategic | HIGH | HIGH | P3-I3 = **9** | OPEN |
| RISK-009 | MeetingsView becoming unmaintainable | Architectural | HIGH | HIGH | P3-I3 = **9** | OPEN |
| RISK-010 | Generation counter race — duplicate tasks | Technical | LOW | HIGH | P1-I3 = **3** | OPEN |
| RISK-011 | Windows/iOS rewrite cost if deferred | Strategic | HIGH | MEDIUM | P3-I2 = **6** | OPEN |
| RISK-012 | Whisper dependency gap for hi-IN | Operational | HIGH | MEDIUM | P3-I2 = **6** | OPEN |
| RISK-013 | Ollama OOM crash from concurrent requests | Technical | MEDIUM | HIGH | P2-I3 = **6** | OPEN |
| RISK-014 | TranscriptChunk disk pressure | Operational | MEDIUM | MEDIUM | P2-I2 = **4** | OPEN |
| RISK-015 | SwiftData migration failure | Technical | LOW | HIGH | P1-I3 = **3** | OPEN |

---

## Risk Priority Matrix

```
         LOW Impact   MEDIUM Impact   HIGH Impact   CRITICAL Impact
          (Score 1)    (Score 2)       (Score 3)     (Score 4)

HIGH        —          011, 012        004, 005,      001
Prob (3)                               007, 008,
                                       009

MEDIUM      —          014             003, 006,      002
Prob (2)                               013

LOW         —          —               010, 015       —
Prob (1)
```

**Immediate action zone (Score 8+):** RISK-001, RISK-004, RISK-005, RISK-007, RISK-008, RISK-009

---

## Critical Risks

---

### RISK-001: System freeze on every long meeting (>90 min) — Ollama thundering herd

**Category**: Technical  
**Probability**: HIGH  
**Impact**: CRITICAL  
**Risk Score**: 12 (highest in register)  
**Description**: `MeetingIntelligenceService.analyzeChunked()` uses `withTaskGroup` with no concurrency cap. For a 150-minute meeting, `TranscriptChunker` produces approximately 20 chunks at 5000 chars each. All 20 tasks submit simultaneously and call `isOllamaAvailable()` (a live HTTP `/api/tags` request) followed by `/api/generate` (60-second timeout). Ollama is a single-GPU process that serializes inference — it accepts all 20 TCP connections but only executes one at a time. The remaining 19 tasks queue at the OS layer. At t=60s all queued requests hit `URLSession`'s timeout threshold simultaneously. All 19 failed tasks then sleep `10_000_000_000` nanoseconds (no jitter) and fire a second wave at t=70s. Wave 1: ~20 requests. Wave 2: ~19–20 retry requests. Total: approximately 41 simultaneous `/api/generate` calls. This saturates the Ollama process, exhausts GPU VRAM, triggers system-wide GPU memory pressure, and manifests to the user as a post-call system freeze lasting 60–120 seconds.  
**Evidence**: `MeetingIntelligenceService.swift` `analyzeChunked()` — `group.addTask` called in a loop with no semaphore or concurrency limit. The code comment explicitly states "Ollama queues and serializes internally so total inference time is the same" — this is correct for throughput in the success path but completely ignores the failure mode. Users consistently report freezes immediately after ending long meetings.  
**Current Mitigation**: None. The 10-second retry delay exists but has no jitter, which transforms random failures into synchronized retry waves.  
**Recommended Mitigation**:  
1. Replace `withTaskGroup` loop with sequential `for chunk in chunks { let result = try await inferChunk(chunk) }` for local providers. This is a two-line change.  
2. Add `±2.5s` jitter to the 10s retry sleep: `try await Task.sleep(nanoseconds: UInt64((10 + Double.random(in: -2.5...2.5)) * 1e9))`.  
3. Cache the Ollama health check result for 10 seconds in a `@MainActor` stored property — eliminates 16 simultaneous `/api/tags` requests at analysis start.  
4. Medium-term: build `InferenceWorker` actor with a serial job queue for local providers and a bounded semaphore (limit 3) for cloud providers.  
**Owner**: Engineering  
**Review Date**: After QW-001, QW-002, QW-003 are shipped (target: within 7 days)

---

### RISK-002: Core Audio crash on device route change — debounce race

**Category**: Technical  
**Probability**: MEDIUM  
**Impact**: CRITICAL  
**Risk Score**: 8  
**Description**: The `AVAudioEngineConfigurationChange` observer fires on an arbitrary thread. `RecordingService` wraps the handler in `Task { @MainActor in }`. The debounce guard reads `lastRouteChangeTime` and compares to `Date()`. Two notifications arriving within 500ms of each other both read `lastRouteChangeTime` as `nil` (or an old value) before either `Task` executes. Both tasks pass the debounce guard. Both tasks call `removeTap()` followed by `installTap()` on a running AVAudioEngine. Calling `installTap` on an engine that already has a tap crashes with an `AVAudioEngine` exception. This is a classic TOCTOU race between the notification thread and the main actor.  
**Evidence**: `RecordingService.swift` — `AVAudioEngineConfigurationChange` notification handler. The `lastRouteChangeTime` property is written inside the `Task { @MainActor }` closure, which means the write happens after the Task executes, not when the notification fires. The guard check and the write are not atomic from the notification thread's perspective.  
**Current Mitigation**: The `500ms` debounce window is the intended mitigation, but the implementation is incorrect because the debounce timestamp is written asynchronously, not synchronously at notification receipt.  
**Recommended Mitigation**: Replace the stored `Date` check with a `DispatchWorkItem`. On notification receipt (on the arbitrary thread), cancel any pending `DispatchWorkItem` and schedule a new one with a 500ms delay. The work item executes the route change handler. `DispatchWorkItem.cancel()` is thread-safe. This eliminates the TOCTOU race entirely — only the most recent work item ever fires.  
**Owner**: Engineering  
**Review Date**: After QW-007 is shipped (target: within 14 days)

---

### RISK-003: Data race crash in ServiceContainer — concurrent dictionary access with no lock

**Category**: Architectural  
**Probability**: MEDIUM  
**Impact**: HIGH  
**Risk Score**: 6  
**Description**: `ServiceContainer.shared` holds a `[String: Any]` dictionary. Services are registered on the main thread in `OrinApp.init()`. Services are resolved from `Task.detached` closures in `MeetingDetectorService.poll()` and from recognition callbacks in `RecordingService` and `SystemAudioCaptureService`. There is no `NSLock`, `actor` isolation, or `Sendable` enforcement protecting dictionary reads. Swift dictionaries are not thread-safe for concurrent access. A crash under Swift's runtime exclusivity enforcement or a memory corruption under concurrent reads and writes is the failure mode. The `fatalError` on missing key adds a second crash vector when registration order is violated.  
**Evidence**: `ServiceContainer.swift` — `[String: Any]` with no synchronization primitive. `RecordingService.swift` lines 697, 992 call `ServiceContainer.shared.resolve(TranscriptStore.self)` from recognition callback closures, which execute on a background thread. `MeetingDetectorService.swift` `poll()` runs in `Task.detached`, which executes on the cooperative thread pool.  
**Current Mitigation**: None. Registration happens before first use in the current startup sequence, so the race has not been observed in practice. This is luck, not safety.  
**Recommended Mitigation**: Add `NSLock` to `ServiceContainer.resolve()` and `ServiceContainer.register()` — three lines of code. Separately, remove `ServiceContainer.shared.resolve()` calls from audio callbacks and inject `TranscriptStore` at construction time instead. Long-term: replace `ServiceContainer` with constructor injection for service-to-service dependencies.  
**Owner**: Engineering  
**Review Date**: After QW-005 is shipped (target: within 7 days)

---

## High Risks

---

### RISK-004: Real-time thread priority inversion — heap allocation in audio callback

**Category**: Technical  
**Probability**: HIGH  
**Impact**: HIGH  
**Risk Score**: 9  
**Description**: `MicTranscriberFeed.feed()` and `ParticipantSTFeed.feed()` allocate a new `AVAudioPCMBuffer` on every Core Audio I/O callback. Core Audio I/O callbacks execute on a real-time thread at ~46 invocations per second. Heap allocation (`malloc`) on a real-time thread is prohibited by Core Audio's contract because `malloc` acquires an internal lock that can block. Under memory pressure, `malloc` can take arbitrarily long. Both callbacks also hold `NSLock` during the allocation — meaning the real-time thread holds both the `malloc` lock and the NSLock simultaneously. Any other thread waiting on the NSLock is fine, but if the real-time thread itself blocks in `malloc`, the audio render cycle misses its deadline, producing audio dropout and potentially stalling the speech recognition engine.  
**Evidence**: `RecordingService.swift` `MicTranscriberFeed.feed()` — `AVAudioPCMBuffer(pcmFormat:frameCapacity:)` called unconditionally on every callback invocation. `SystemAudioCaptureService.swift` `ParticipantSTFeed.feed()` — identical pattern. Both do this while holding `NSLock`.  
**Current Mitigation**: None. Buffer allocation has not caused observed crashes in isolation, but it compounds with memory pressure from the Ollama thundering herd (RISK-001).  
**Recommended Mitigation**: Pre-allocate `AVAudioPCMBuffer` in `arm()` with the format and capacity known at tap-install time. Store the pre-allocated buffer in `TapState`. In `feed()`, copy incoming frames into the pre-allocated buffer using `memcpy` on the raw `audioBufferList.mBuffers` pointers — no allocation, no lock escalation beyond what is already there.  
**Owner**: Engineering  
**Review Date**: After Phase 1 audio fixes are shipped (target: within 21 days)

---

### RISK-005: Main actor blocking during recording — O(N²) SwiftData saves

**Category**: Technical  
**Probability**: HIGH  
**Impact**: HIGH  
**Risk Score**: 9  
**Description**: `TranscriptStore.persistChunkIfNeeded()` calls `context.save()` on `@MainActor` every time transcript text grows by 10 characters. At 130 words per minute (normal speech pace), this triggers multiple saves per second. Each `context.save()` is a synchronous SQLite WAL write on the main actor. Simultaneously, a 3-second checkpoint timer fires `context.save()` independently. During active recording, the main actor is blocked on disk I/O for a meaningful fraction of every second. This causes dropped animation frames, delayed UI response, and the perception of the app being frozen during recording. For a 90-minute meeting, this accumulates to thousands of SQLite writes that serve no recovery purpose beyond what a 3-second checkpoint would provide.  
**Evidence**: `TranscriptStore.swift` `persistChunkIfNeeded()` — unconditional `context.save()` after every text delta exceeding 10 characters. The 3-second timer checkpoint exists alongside this, making the per-character save entirely redundant from a crash recovery perspective.  
**Current Mitigation**: The 3-second checkpoint timer is the intended durability mechanism. The per-10-char save is redundant and harmful.  
**Recommended Mitigation**: Change `persistChunkIfNeeded()` to call `context.insert(chunk)` without `save()`. Let the 3-second checkpoint timer be the exclusive save trigger. This reduces write frequency from multiple-per-second to once per 3 seconds — a 10–50x reduction in main actor disk I/O during recording. Add `meetingId` predicates to all `FetchDescriptor` calls in `buildTimelineSegments()` and `deleteMeetingFully()` to eliminate full-table scans.  
**Owner**: Engineering  
**Review Date**: After QW-008, QW-009 are shipped (target: within 14 days)

---

### RISK-006: Privacy violation in production — unconditional /tmp write of raw transcript

**Category**: Privacy/Compliance  
**Probability**: MEDIUM  
**Impact**: HIGH  
**Risk Score**: 6  
**Description**: Orin unconditionally writes raw Phi-3 model output to `/tmp/orin_phi3_raw.txt` on every analysis run. This file is world-readable on macOS (mode 0644 by default). It contains verbatim meeting transcript content and model reasoning. Any process running as the same user — or a sandboxed app with `com.apple.security.temporary-exception.files.absolute-path.read-write` — can read this file. If Orin is submitted to the Mac App Store or distributed to enterprise customers with IT-managed machines, this is a reportable privacy incident. The file is never deleted between sessions, meaning the most recent meeting's transcript persists on disk indefinitely.  
**Evidence**: `MeetingIntelligenceService.swift` or `AIService.swift` — unconditional `FileManager.default.createFile(atPath: "/tmp/orin_phi3_raw.txt", ...)` call. This appears to be debugging scaffolding that was never gated behind a debug flag or removed before production builds.  
**Current Mitigation**: None. The write runs unconditionally in both debug and release builds.  
**Recommended Mitigation**: Delete the `/tmp/orin_phi3_raw.txt` write unconditionally. If transcript debugging is needed in development, gate behind `#if DEBUG` and write to the app's sandbox container (`FileManager.default.temporaryDirectory`) rather than world-readable `/tmp`. This is a one-line deletion for the production fix.  
**Owner**: Engineering  
**Review Date**: Immediate — ship as QW-006 in the first release

---

### RISK-007: Legacy SFSpeechRecognizer path becoming permanent — no sunset plan

**Category**: Technical  
**Probability**: HIGH  
**Impact**: HIGH  
**Risk Score**: 9  
**Description**: `RecordingService` retains the full legacy `SFSpeechRecognizer` recognition pipeline as the default path (when `useNewParticipantPipeline` feature flag is disabled). The new `SpeechTranscriber` path (Phase 2A) is gated and not the default. Both paths implement recognition session management independently, resulting in 400+ lines of duplicated code that has already diverged (locale is hardcoded as `en-IN` in one path and `en-US` in the other). As long as the legacy path exists, any bug fix must be applied twice. Any new feature (vocabulary hints, language detection) must be built twice. The longer this persists, the less likely engineers are to keep both in sync. The legacy path will accumulate the defects that the new path avoids, making it impossible to safely remove.  
**Evidence**: `RecordingService.swift` — dual recognition pipeline branches. Feature flag `useNewParticipantPipeline` defaults to `false`. The locale divergence between `en-IN` and `en-US` in the two files confirms they are already drifting apart.  
**Current Mitigation**: The Phase 2A/2B migration plan exists. Phase 2B is explicitly gated pending stability validation.  
**Recommended Mitigation**: Accelerate Phase 2B validation. Set a hard removal date for the legacy `SFSpeechRecognizer` path (target: end of Phase 2, 10 weeks from now). Extract `RecognitionSessionManager` actor (MT-001) as the prerequisite that makes removal safe — once the shared actor exists, the legacy path is just a provider configuration, not a separate code branch. Do not ship new features to the legacy path after the extraction is complete.  
**Owner**: Engineering  
**Review Date**: Phase 2 kickoff (target: 3 weeks from now)

---

### RISK-008: Vocabulary system structural limitation blocking non-English markets

**Category**: Strategic  
**Probability**: HIGH  
**Impact**: HIGH  
**Risk Score**: 9  
**Description**: The current vocabulary system is architecturally incapable of supporting the product's stated 10+ language ambition. The 103-term built-in list exceeds the 100-term cap enforced by `.prefix(100)` — 6 terms are silently dropped today. Vocabulary is wired only to the `SpeechTranscriber` path; the legacy `SFSpeechRecognizer` path (still the default) receives zero vocabulary hints. There is no UI for users to manage vocabulary. There is no per-meeting context injection from calendar attendees. There is no language detection. All AI prompts are hardcoded English. `UserDefaults` storage cannot support multi-language, multi-tenant, or org-level vocabulary requirements. Expanding to Spanish, French, or German today would require a complete rewrite of the vocabulary layer — there is no incremental path from the current architecture.  
**Evidence**: `VocabularyProvider.swift` — `[String]` flat array, `.prefix(100)` truncation, `UserDefaults` storage. `MeetingIntelligenceService.swift` — English-only prompt strings with no parameterization. `SystemAudioCaptureService.swift` — `en-US` locale hardcoded. No `SettingsView` vocabulary section exists.  
**Current Mitigation**: None. The Hindi vocabulary patch (48 terms) was added to the built-in list as a stopgap and exceeded the cap, making it counterproductive.  
**Recommended Mitigation**: Implement the four-tier `VocabularyContext` redesign (MT-004): `VocabularyItem` as a `SwiftData` `@Model`, tiers ordered `Session(attendees) > User > Org > BuiltIn[language]`, `CorrectionStore` for learning from edits. Add a `SettingsView` vocabulary management section. Add `NLLanguageRecognizer` post-session detection. Parameterize all AI prompts with detected language. This is 8–10 weeks of work but it is the only path to non-English markets.  
**Owner**: Engineering (Product input required on tier prioritization)  
**Review Date**: Phase 2 planning (target: 3 weeks from now)

---

### RISK-009: MeetingsView.swift becoming unmaintainable — 2281-line SRP violation

**Category**: Architectural  
**Probability**: HIGH  
**Impact**: HIGH  
**Risk Score**: 9  
**Description**: `MeetingsView.swift` is 2,281 lines long and violates the Single Responsibility Principle in every dimension. It owns: meeting list display, folder navigation, meeting detail rendering, recording state display, analysis result rendering, action item display, segment timeline, and swipe action logic. It also drives the `@Query` that loads all `TranscriptSegment` records from all meetings with no predicate — meaning a user with 100 meetings loads all their segment data every time `MeetingsView` renders. At the current pace of feature addition, this file will be 3,000+ lines within three months. Beyond a certain threshold, engineers will avoid modifying it out of fear of regressions, and changes that should take an hour will take a day.  
**Evidence**: `Sources/Orin/Views/Meetings/MeetingsView.swift` — 2,281 lines. The `allSegments` `@Query` at the top of the file has no `predicate`, which is confirmed by the performance review finding PB-004.  
**Current Mitigation**: None.  
**Recommended Mitigation**: Split into at minimum five files as part of MT-003: `MeetingsListView.swift`, `MeetingDetailView.swift`, `FolderDetailView.swift`, `MeetingRowView.swift` (with subcomponent views), and `MeetingAnalysisResultView.swift`. Move `allSegments @Query` into `MeetingDetailView` with a `meetingId` predicate. Extract recording orchestration into `RecordingSessionCoordinator` (MT-006). This is a mechanical refactor — no behavior changes.  
**Owner**: Engineering  
**Review Date**: Phase 2 kickoff (target: 3 weeks from now)

---

### RISK-010: Generation counter race — duplicate recognition tasks spawning simultaneously

**Category**: Technical  
**Probability**: LOW  
**Impact**: HIGH  
**Risk Score**: 3  
**Description**: In `RecordingService.startRecognitionTask()`, the generation counter watchdog `Task` and the error callback `Task` both check `self.recognitionGeneration == gen` before incrementing. There is a time-of-check/time-of-use window where both tasks read the same generation value, both pass the guard, and both increment independently. The result is two simultaneous `SFSpeechRecognitionTask` instances running on the same audio tap. These two tasks interleave partial results, producing garbled or duplicated transcript segments. The probability is LOW because the race window is narrow — it requires the watchdog timer and an error callback to fire within the same Task scheduling quantum — but it has been observed in logs as unexpected duplicate transcript content.  
**Evidence**: `RecordingService.swift` `startRecognitionTask()` — two `Task` blocks both guarded by `self.recognitionGeneration == gen` with no mutual exclusion between the check and the increment.  
**Current Mitigation**: The generation counter pattern itself is the intended fix for this problem; the implementation has a narrow race in the dual-Task design.  
**Recommended Mitigation**: Serialize the generation check and increment with the `RecognitionSessionManager` actor extraction (MT-001). Within the actor, the check-and-increment is inherently atomic. Short-term: consolidate the watchdog and error restart into a single `Task` that is cancelled and replaced rather than racing.  
**Owner**: Engineering  
**Review Date**: Phase 2 — RecognitionSessionManager extraction

---

## Medium Risks

---

### RISK-011: Windows/iOS rewrite cost if platform abstraction is deferred

**Category**: Strategic  
**Probability**: HIGH  
**Impact**: MEDIUM  
**Risk Score**: 6  
**Description**: Orin's codebase has zero separation between platform-specific audio APIs (`AVAudioEngine`, `SCKit`, `SFSpeechRecognizer`, `SpeechTranscriber`) and platform-agnostic meeting intelligence logic. If the team begins Windows or iOS development before extracting an `OrinCore` Swift package, they will face one of two outcomes: (a) a complete rewrite of all business logic for the new platform, or (b) a messy platform-conditional codebase that becomes impossible to maintain. Every month of delay increases the migration cost because more macOS-specific API calls accumulate in the service layer.  
**Evidence**: `Sources/Orin/Services/` — direct `AVAudioEngine`, `SCKitSystemAudioProvider`, `SFSpeechRecognizer`, and `CalendarService` (wrapping `EventKit`) usage throughout service classes. No `ASRBackend` or `AudioCapture` protocol boundary exists between platform code and business logic.  
**Current Mitigation**: None. The macOS-specific APIs are used directly in service implementations.  
**Recommended Mitigation**: Introduce `ASRBackend` and `AudioCaptureBackend` protocols in Phase 3 (12–16 weeks). Extract `OrinCore` Swift package with zero platform-specific imports as the prerequisite for any cross-platform work. Do not start Windows or iOS development before this extraction is complete — it will cost more, not less.  
**Owner**: Engineering (Product roadmap decision required)  
**Review Date**: Phase 3 planning

---

### RISK-012: Whisper dependency gap for hi-IN — no path without Apple support

**Category**: Operational  
**Probability**: HIGH  
**Impact**: MEDIUM  
**Risk Score**: 6  
**Description**: Hindi (`hi-IN`) speech recognition is not supported by Apple's `SpeechTranscriber` or `SFSpeechRecognizer` on macOS. The current workaround (adding Hindi vocabulary terms to the English recognizer) is not a functional solution — it improves name recognition marginally but cannot handle Hindi phonemes through an English acoustic model. The only viable path to real Hindi support is Whisper integration as an `ASRBackend`. Whisper requires a separate model download (~140MB for medium, ~1.5GB for large), a C++ bridge, and real-time streaming support that the base Whisper library does not provide without additional engineering. Until this is built, Hindi is not a supported language regardless of vocabulary additions.  
**Evidence**: `RecognitionEngine` memory file — "Hinglish gap remains (Apple no hi-IN)". `VocabularyProvider.swift` — 48 Hindi terms added to an English recognizer. Apple's supported locales list does not include `hi-IN` for `SpeechTranscriber`.  
**Current Mitigation**: Hindi vocabulary terms in the English recognizer. This is cosmetic, not functional.  
**Recommended Mitigation**: Implement `WhisperBackend` conforming to `ASRBackend` protocol (requires Phase 3 `ASRBackend` extraction first). Target Whisper medium model for quality/size balance. Gate `WhisperBackend` activation on user opt-in due to model download size. Timeline: 12 months from now if Phase 3 proceeds on schedule.  
**Owner**: Engineering  
**Review Date**: Phase 3 ASRBackend implementation

---

### RISK-013: Ollama process OOM crash from concurrent inference requests

**Category**: Technical  
**Probability**: MEDIUM  
**Impact**: HIGH  
**Risk Score**: 6  
**Description**: The 41-request thundering herd (RISK-001) does not just freeze the Orin process — it can crash the Ollama process itself. Ollama loads the model into GPU VRAM on first request and keeps it resident. When 20+ concurrent `/api/generate` requests arrive, Ollama's internal queue allocates per-request context buffers in addition to the model weights. On machines with 8GB unified memory (the minimum supported), the combination of Orin's process, the macOS kernel, and Ollama with 20 queued contexts can exhaust physical RAM, triggering the macOS OOM killer. If Ollama is killed, all pending analysis requests fail permanently (no retry after process death), and users lose analysis results for the entire meeting without any error surfaced to the UI.  
**Evidence**: User reports of Ollama process disappearing from Activity Monitor after long-meeting analysis. RISK-001's root cause analysis of 41 concurrent requests. Ollama per-request context allocation behavior documented in Ollama issue tracker.  
**Current Mitigation**: None beyond what mitigates RISK-001.  
**Recommended Mitigation**: The RISK-001 fix (serialize inference) eliminates the primary trigger. Additionally, add an `InferenceWorker` circuit breaker: after 3 consecutive Ollama failures within 90 seconds, mark Ollama unavailable for 60 seconds and route to cloud fallback. Surface "Analysis queued — local model recovering" in the UI rather than silent failure.  
**Owner**: Engineering  
**Review Date**: After QW-001 is shipped

---

### RISK-014: TranscriptChunk accumulation causing disk pressure on long-term users

**Category**: Operational  
**Probability**: MEDIUM  
**Impact**: MEDIUM  
**Risk Score**: 4  
**Description**: `TranscriptChunk` records are persisted during recording as crash recovery points and are not pruned after `finalize()` completes successfully. A user recording 3 hours of meetings per day for 6 months accumulates approximately 180 hours × (60/3) chunks per hour × ~5000 chars per chunk = roughly 18 million characters of `TranscriptChunk` data in SwiftData, on top of the finalized `MeetingItem.transcript`. These chunks serve no purpose after finalization but continue to be loaded on `allSegments @Query` renders. On machines with limited storage, this causes SwiftData to slow down and eventually the `persistChunkIfNeeded()` saves begin failing silently.  
**Evidence**: `TranscriptStore.swift` — no `TranscriptChunk` pruning after `finalizeTranscript()`. `MeetingsView.swift` `allSegments @Query` — loads all chunks from all meetings.  
**Current Mitigation**: None.  
**Recommended Mitigation**: After `finalizeTranscript()` succeeds and the finalized text is verified non-empty, delete all `TranscriptChunk` records for that meeting from the `ModelContext`. Implement MT-008. Add this to the Phase 2 data persistence work.  
**Owner**: Engineering  
**Review Date**: Phase 2 data persistence refactor

---

### RISK-015: SwiftData migration failure when adding @Attribute(.externalStorage) to MeetingItem

**Category**: Technical  
**Probability**: LOW  
**Impact**: HIGH  
**Risk Score**: 3  
**Description**: Adding `@Attribute(.externalStorage)` to `MeetingItem.transcript` (recommended for large blob storage) requires a SwiftData schema migration. If the migration is not declared with a `VersionedSchema` and `MigrationPlan`, SwiftData will detect the schema change and either (a) fail to open the store, crashing on startup, or (b) silently discard the old data and create an empty store. Neither outcome is acceptable. This risk is LOW probability because it only materializes if the `@Attribute(.externalStorage)` change is shipped without a migration plan — which is a process failure, not an inherent defect.  
**Evidence**: `OrinModels.swift` — `MeetingItem.transcript: String` without `@Attribute(.externalStorage)`. SwiftData's migration behavior for attribute option changes is not clearly documented for all edge cases.  
**Current Mitigation**: None. No versioned schema or migration plan exists in the codebase.  
**Recommended Mitigation**: Before adding `@Attribute(.externalStorage)`, implement `OrinSchemaV1` and `OrinSchemaV2` conforming to `VersionedSchema`, and a `MigrationPlan` using `MigrationStage.lightweight`. Test migration on a device with real meeting data before shipping. Add schema versioning as an Engineering process gate: any `@Model` change requires a migration plan entry.  
**Owner**: Engineering  
**Review Date**: Phase 2 data persistence refactor (before any schema changes ship)

---

## Risk Disposition by Phase

**Phase 1 (Weeks 1–3) — close or reduce these risks:**  
RISK-001 (QW-001/002/003), RISK-002 (QW-007), RISK-003 (QW-005), RISK-006 (QW-006), RISK-005 (QW-008/009)

**Phase 2 (Weeks 4–13) — close or reduce these risks:**  
RISK-004 (MT-001 pre-allocated buffers), RISK-007 (MT-001 + legacy sunset), RISK-009 (MT-003 MeetingsView split), RISK-010 (MT-001 RecognitionSessionManager), RISK-014 (MT-008 TranscriptChunk pruning)

**Phase 3 (Weeks 14–30) — close or reduce these risks:**  
RISK-008 (MT-004 vocabulary redesign + MT-005 language prompts), RISK-011 (ASRBackend + OrinCore extraction), RISK-012 (WhisperBackend)

**Phase 4+ — monitor:**  
RISK-013 (circuit breaker in InferenceWorker), RISK-015 (migration plan process gate, implement before any schema change)

---

*Next review: after Phase 1 ships. Update RISK-001, RISK-002, RISK-003, RISK-005, RISK-006 status to MITIGATED if fixes are confirmed in testing.*
