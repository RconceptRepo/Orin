# Document M-04: Refactoring Backlog

**Series**: Orin V2 Migration Planning  
**Document**: 4 of 8  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Overview

This document converts the Migration Roadmap (M-02) and Technical Debt Register (M-03) into engineering epics. Each epic is a self-contained unit of work that can be estimated, assigned, and tracked independently. Epics within a phase may be parallelized by different engineers; cross-phase dependencies are explicit.

**Total epics**: 24  
**Phase 0**: 3 epics (critical fixes)  
**Phase 1**: 7 epics (protocol boundaries)  
**Phase 2**: 7 epics (event bus, state machines, coordinators)  
**Phase 3**: 4 epics (OrinCore package, multilingual, vocabulary)  
**Phase 4**: 3 epics (knowledge graph, learning engine)

---

## Phase 0 Epics — Critical Fixes

---

### EPIC-01: Audio Pipeline Real-Time Safety

**Goal**: Eliminate all heap allocation, IPC, and blocking lock usage from the Core Audio I/O thread path.

**V2 Reference**: Document 11 §3, ADR-003  
**Tech Debt**: TD-C01, TD-C02, TD-C06, TD-H10  
**Phase**: 0  
**Estimated effort**: 3–5 days

**Files**:
- `Sources/Orin/Services/TapState.swift`
- `Sources/Orin/Services/SystemAudioCaptureService.swift` (participant feed)
- `Sources/Orin/Services/RecognitionDiagnostics.swift`

**Acceptance Criteria**:
- [ ] `TapState.arm()` pre-allocates `AVAudioPCMBuffer` with capacity matching the audio engine's buffer size
- [ ] `TapState.feed()` copies audio into the pre-allocated buffer; zero heap allocation on the RT thread (verified by `malloc_logger` in Instruments)
- [ ] `TapState.stop()` captures `recognitionRequest` reference under NSLock and releases the lock before calling `endAudio()`
- [ ] `AVAudioConverter` in participant audio feed initialized in `arm()` not in `feed()`
- [ ] `RecognitionDiagnostics` counter increments use `os_unfair_lock` or OSAtomic, not NSLock, on the audio callback path
- [ ] Instruments Allocations trace shows zero allocations in the RT thread during a 60-second recording

**Dependencies**: None

**Test Strategy**:
- Instruments Allocations template: run with `malloc_logger` on RT thread for 60 seconds; zero allocation confirmed
- Manual: record a 5-minute meeting; verify no audio dropout; verify no crash

**Rollback Strategy**: Revert all changes in this epic. The existing allocation pattern continues until re-applied.

---

### EPIC-02: InferenceWorker — Serialized Local Inference

**Goal**: Introduce the `InferenceWorker` actor to eliminate the Ollama thundering herd. Analysis of multi-chunk meetings must serialize, not parallelize, chunk inference calls to local providers.

**V2 Reference**: Document 05 §2–3, ADR-004  
**Tech Debt**: TD-C03  
**Phase**: 0  
**Estimated effort**: 5–7 days

**Files**:
- New: `Sources/Orin/Services/InferenceWorker.swift`
- Modify: `Sources/Orin/Services/MeetingIntelligenceService.swift` — replace `withTaskGroup` with `InferenceWorker.enqueue()`

**Key Design**:
```swift
actor InferenceWorker {
  private var queue: [InferenceJob] = []
  private var isProcessing = false

  func enqueue(_ job: InferenceJob) async -> String {
    // Add to queue; process serially
    return await withCheckedContinuation { continuation in
      queue.append(job.withContinuation(continuation))
      if !isProcessing { Task { await processNext() } }
    }
  }

  private func processNext() async {
    guard !queue.isEmpty else { isProcessing = false; return }
    isProcessing = true
    let job = queue.removeFirst()
    let result = await callOllama(job)
    job.continuation.resume(returning: result)
    await processNext()
  }
}
```

**Acceptance Criteria**:
- [ ] `InferenceWorker` actor created with serial job queue
- [ ] `MeetingIntelligenceService.analyzeChunked()` no longer uses `withTaskGroup`; uses `InferenceWorker.enqueue()` for each chunk
- [ ] Post-meeting system freeze not reproducible in a 90-minute test recording (was: reliably reproducible)
- [ ] Analysis of 8-chunk meeting completes within 8 minutes on M2 (sequential, each chunk ~20-40s)
- [ ] `InferenceWorker` circuit breaker: 3 consecutive failures → refuse new jobs for 60s

**Dependencies**: None (can run parallel to EPIC-01)

**Test Strategy**:
- Integration test: submit 8 concurrent `enqueue()` calls; verify they execute serially (measure start/end timestamps)
- Manual: record a 90-minute meeting; verify no freeze during analysis

**Rollback Strategy**: Remove `InferenceWorker.swift`; restore `withTaskGroup` in `MeetingIntelligenceService`. Tag the commit before starting this epic.

---

### EPIC-03: Remove @MainActor Sleep in Finalize

**Goal**: Remove the 1.5-second `Task.sleep` from `RecordingService.finalize()` without introducing a regression in ASR finalization timing.

**V2 Reference**: Document 11 §4, Document 04 §5  
**Tech Debt**: TD-C05  
**Phase**: 0  
**Estimated effort**: 2–3 days

**Files**:
- `Sources/Orin/Services/RecordingService.swift`

**Acceptance Criteria**:
- [ ] `Task.sleep(1_500_000_000)` removed from finalize path
- [ ] ASR final results still received correctly (no transcript truncation)
- [ ] Session stop to `TranscriptFinalized` P99 < 10s (was: always > 1.5s just from the sleep)
- [ ] UI remains responsive during session stop (no 1.5s freeze)

**Dependencies**: None (can run parallel to EPIC-01 and EPIC-02)

**Test Strategy**:
- Record a 5-minute meeting; stop recording; verify final 10–15 seconds of transcript are captured correctly
- Measure session-stop-to-finalized latency: must be < 10s P99

**Rollback Strategy**: Restore `Task.sleep` call.

---

## Phase 1 Epics — Protocol Boundaries

---

### EPIC-04: InferenceProvider Protocol + OllamaInferenceAdapter

**Goal**: Wrap `AIService` in the `InferenceProvider` protocol. All AI inference calls go through the protocol. Hardcoded model IDs become configurable.

**V2 Reference**: Document 05 §4, ADR-001, ADR-004  
**Tech Debt**: TD-H12, TD-H13, TD-M07  
**Phase**: 1  
**Estimated effort**: 5–7 days

**Files**:
- New: `Sources/Orin/Providers/Protocols/InferenceProvider.swift`
- New: `Sources/Orin/Providers/macOS/OllamaInferenceAdapter.swift`
- Modify: `Sources/Orin/Services/MeetingIntelligenceService.swift` — inject `InferenceProvider` instead of `AIService`
- Modify: `Sources/Orin/Services/AIService.swift` — refactor to be called only by `OllamaInferenceAdapter`
- Modify: `Sources/Orin/Services/AIProviderTestService.swift` — use `InferenceProvider.isAvailable()`; add 10s result cache

**Acceptance Criteria**:
- [ ] `InferenceProvider` protocol defined with `isAvailable()`, `infer(job:)`, `providerID`, `capabilities`
- [ ] `OllamaInferenceAdapter` wraps existing `AIService` HTTP calls; all Ollama-specific code contained here
- [ ] `MeetingIntelligenceService` accepts `any InferenceProvider` via constructor injection
- [ ] Ollama model ID read from `UserDefaults` (Settings), not hardcoded
- [ ] `isAvailable()` result cached for 10 seconds in `ProviderHealthCache`
- [ ] Existing analysis tests pass unchanged

**Dependencies**: EPIC-02 (InferenceWorker already uses a provider)

**Test Strategy**:
- Unit test: inject a mock `InferenceProvider` into `MeetingIntelligenceService`; verify analysis completes
- Unit test: verify `isAvailable()` returns cached result within 10s window
- Integration test: swap Ollama model ID in Settings; verify new model used in next analysis

**Rollback Strategy**: Remove protocol files; revert `MeetingIntelligenceService` injection to direct `AIService` usage.

---

### EPIC-05: ASRBackend Protocol + SpeechTranscriber Adapter

**Goal**: Define `ASRBackend` protocol; wrap existing `SpeechTranscriber` and `SFSpeechRecognizer` usage in adapters; inject via protocol in `RecordingService`.

**V2 Reference**: Document 07 §3, ADR-001, ADR-014  
**Tech Debt**: TD-H14, TD-H08  
**Phase**: 1  
**Estimated effort**: 7–10 days

**Files**:
- New: `Sources/Orin/Providers/Protocols/ASRBackend.swift`
- New: `Sources/Orin/Providers/macOS/SpeechTranscriberASRAdapter.swift`
- New: `Sources/Orin/Providers/macOS/SFSpeechASRAdapter.swift`
- New: `Sources/Orin/Providers/macOS/WhisperASRBackend.swift` (stub implementing protocol; full implementation Phase 3)
- Modify: `Sources/Orin/Services/RecordingService.swift` — accept `any ASRBackend` via injection

**Acceptance Criteria**:
- [ ] `ASRBackend` protocol defined: `prepare(locale:vocabulary:)`, `transcribe(audioStream:locale:)`, `finalize()`, `cancel()`
- [ ] `SpeechTranscriberASRAdapter` wraps existing SpeechTranscriber code with no behaviour change
- [ ] `SFSpeechASRAdapter` wraps existing SFSpeechRecognizer code with no behaviour change
- [ ] `RecordingService` accepts `any ASRBackend` via constructor injection
- [ ] `WhisperASRBackend` stub compiles and implements protocol (returns empty segments until Phase 3)
- [ ] Recording test: mic channel transcription unchanged after refactor

**Dependencies**: None (can run parallel to EPIC-04)

**Test Strategy**:
- Record a 2-minute meeting; compare transcript before and after refactor (should be identical)
- Unit test: inject mock `ASRBackend` into `RecordingService`; verify session lifecycle methods are called in correct order

**Rollback Strategy**: Remove adapter files; revert `RecordingService` to direct SpeechTranscriber usage.

---

### EPIC-06: PersistenceStore Protocol + SwiftDataPersistenceAdapter

**Goal**: Abstract all `ModelContext`/SwiftData calls behind a `PersistenceStore` protocol. Move `context.save()` off `@MainActor`.

**V2 Reference**: ADR-012, Document 03 §2, Document 11 §8  
**Tech Debt**: TD-M04, TD-H05, TD-H15, TD-H09  
**Phase**: 1  
**Estimated effort**: 7–10 days

**Files**:
- New: `Sources/Orin/Providers/Protocols/PersistenceStore.swift`
- New: `Sources/Orin/Providers/macOS/SwiftDataPersistenceAdapter.swift`
- Modify: `Sources/Orin/Services/TranscriptStore.swift` — use `PersistenceStore` protocol
- Modify: `Sources/Orin/Models/OrinModels.swift` — add `@Attribute(.externalStorage)` to large fields
- Add: SwiftData `ModelVersion` and `MigrationPlan` for the `@Attribute(.externalStorage)` change

**Acceptance Criteria**:
- [ ] `PersistenceStore` protocol defined: `save(meeting:)`, `fetchMeeting(by:)`, `fetchRecentMeetings(limit:offset:)`, `delete(meeting:)`, `saveAnalysis(_:for:)`
- [ ] `SwiftDataPersistenceAdapter` wraps all `ModelContext` operations
- [ ] `context.save()` runs on a background `ModelActor`, never on `@MainActor`
- [ ] `MeetingItem.rawTranscript` (or equivalent large field) tagged `@Attribute(.externalStorage)`
- [ ] Migration tested: existing data not lost after schema change
- [ ] `@Query` in `MeetingsView` scoped to current session (no all-meetings load)

**Dependencies**: None

**Test Strategy**:
- Integration test: create 1,000 synthetic meetings; `fetchRecentMeetings(limit: 50)` must complete in < 100ms
- Migration test: install V1 build with data; upgrade to V1+EPIC-06; verify all existing meetings still accessible

**Rollback Strategy**: Remove protocol files; revert `TranscriptStore` and `OrinModels`. Note: `@Attribute(.externalStorage)` migration is NOT reversible without a migration plan. Plan the rollback migration before starting.

---

### EPIC-07: Composition Root — Replace ServiceContainer

**Goal**: Replace `ServiceContainer.shared.resolve()` service locator with constructor injection at `OrinApp.init()`. Delete `ServiceContainer.swift`.

**V2 Reference**: ADR-001, Document 03 §5  
**Tech Debt**: TD-C07  
**Phase**: 1  
**Estimated effort**: 3–5 days

**Files**:
- Modify: `Sources/Orin/App/OrinApp.swift` — becomes the composition root
- Delete: `Sources/Orin/App/ServiceContainer.swift` (after all call sites removed)
- Modify: Every file that calls `ServiceContainer.shared.resolve()` — inject via constructor

**Acceptance Criteria**:
- [ ] `grep -r "ServiceContainer.shared" Sources/` returns empty
- [ ] `OrinApp.init()` creates all services and injects dependencies
- [ ] `ServiceContainer.swift` deleted
- [ ] App builds without `ServiceContainer`
- [ ] All existing functionality verified with manual recording test

**Dependencies**: EPIC-04, EPIC-05, EPIC-06 (protocols must exist before injection can be typed)

**Test Strategy**:
- Compile-time: build succeeds with no `ServiceContainer` references
- Manual: full recording and analysis test

**Rollback Strategy**: Restore `ServiceContainer.swift`; revert `OrinApp.init()`.

---

### EPIC-08: Protocol Renames + Feature Flag Testability

**Goal**: Rename `SystemAudioProvider` → `SystemAudioCaptureProvider`; rename `MeetingDetectorProvider` → `MeetingDetector`. Add testability to `FeatureFlags`.

**V2 Reference**: Document 03 §2, ADR-001  
**Tech Debt**: TD-M15, TD-M16, TD-M05  
**Phase**: 1  
**Estimated effort**: 1–2 days

**Files**:
- Rename: `Sources/Orin/Providers/Protocols/SystemAudioProvider.swift`
- Rename: `Sources/Orin/Providers/macOS/SCKitSystemAudioProvider.swift` → `SCKitSystemAudioAdapter.swift`
- Add: `FeatureFlagStore` protocol to `FeatureFlags.swift`
- Modify: All call sites of renamed protocols

**Acceptance Criteria**:
- [ ] Protocol names match V2 architecture documents exactly
- [ ] `FeatureFlags` can be injected in tests via `FeatureFlagStore` protocol
- [ ] Build succeeds; no functional change

**Dependencies**: None (can start before EPIC-04)

**Test Strategy**:
- Compile-time test: build with renamed types
- Unit test: inject mock `FeatureFlagStore` into a service that reads feature flags

**Rollback Strategy**: Revert renames (low risk).

---

### EPIC-09: AudioCaptureProvider Protocol + AVAudioEngine Adapter

**Goal**: Define `AudioCaptureProvider` protocol; wrap existing `AVAudioEngine` audio capture logic.

**V2 Reference**: Document 03 §2, Document 10 §3  
**Tech Debt**: TD-H14 (partial, audio capture side)  
**Phase**: 1  
**Estimated effort**: 5–7 days

**Files**:
- New: `Sources/Orin/Providers/Protocols/AudioCaptureProvider.swift`
- New: `Sources/Orin/Providers/macOS/AVAudioEngineAdapter.swift`
- Modify: `Sources/Orin/Services/RecordingService.swift` — accept `any AudioCaptureProvider` for mic capture

**Acceptance Criteria**:
- [ ] `AudioCaptureProvider` protocol defined: `start(format:)`, `stop()`, `audioStream: AsyncStream<AudioBuffer>`
- [ ] `AVAudioEngineAdapter` wraps mic capture; no behaviour change
- [ ] Recording test passes with adapter in place

**Dependencies**: EPIC-01 (RT safety fixes should be in the adapter code)

**Test Strategy**:
- Manual: 5-minute recording test; verify transcript quality unchanged after adapter wrapping

**Rollback Strategy**: Remove adapter; revert `RecordingService` to direct `AVAudioEngine` use.

---

### EPIC-10: MeetingRetentionService Actor Isolation Fix (TICKET-001)

**Goal**: Resolve the actor isolation issue in `MeetingRetentionService` (TICKET-001 from the hardening backlog).

**V2 Reference**: ADR-003  
**Tech Debt**: TD-M10  
**Phase**: 1  
**Estimated effort**: 1–2 days

**Files**:
- `Sources/Orin/Services/MeetingRetentionService.swift`

**Acceptance Criteria**:
- [ ] No `@unchecked Sendable` in `MeetingRetentionService`
- [ ] All state mutations are actor-isolated
- [ ] No compiler warnings suppressed with `nonisolated(unsafe)` or `@unchecked Sendable`

**Dependencies**: None

**Test Strategy**:
- Build with `-strict-concurrency=complete`; zero new warnings

---

## Phase 2 Epics — Event Bus + State Machines

---

### EPIC-11: EventBus Actor + Core Domain Events

**Goal**: Implement the `EventBus` actor and define the initial set of domain events. Emit events as side effects alongside existing direct calls.

**V2 Reference**: Document 02, ADR-005  
**Phase**: 2  
**Estimated effort**: 7–10 days

**Files**:
- New: `Sources/Orin/Services/EventBus.swift`
- New: `Sources/Orin/Services/DomainEvents.swift` (all event type definitions)
- Modify: `Sources/Orin/Services/RecordingService.swift` — emit `SessionStarted`, `SessionStopped`, `SessionFinalized`
- Modify: `Sources/Orin/Services/MeetingIntelligenceService.swift` — emit `AnalysisQueued`, `AnalysisStarted`, `ChunkAnalyzed`, `AnalysisCompleted`, `AnalysisFailed`
- Modify: `Sources/Orin/Services/TranscriptStore.swift` — emit `SegmentAdded`

**Acceptance Criteria**:
- [ ] `EventBus` actor: `publish<E: DomainEvent>()`, `subscribe<E: DomainEvent>(to:handler:) -> SubscriptionID`, `unsubscribe()`
- [ ] All Phase-2 events defined as value types conforming to `DomainEvent`
- [ ] Events emitted alongside existing direct calls (no direct call removed yet)
- [ ] `AnalysisPerfLogger` migrated to `EventBus` subscriber (remove direct call)
- [ ] `SessionLogger` migrated to `EventBus` subscriber
- [ ] Build passes; no change to recording or analysis behaviour

**Dependencies**: EPIC-07 (composition root for injecting EventBus)

**Test Strategy**:
- Unit test: subscribe to `SessionStarted`; trigger session start; verify handler called
- Unit test: subscribe to `AnalysisCompleted`; run analysis; verify handler called with correct payload
- Integration test: verify `AnalysisPerfLogger` receives `AnalysisCompleted` via EventBus

**Rollback Strategy**: Remove event emissions (side-effect only; existing direct calls still work). EventBus can be removed without breaking anything if events were only side effects.

---

### EPIC-12: SessionStateMachine Actor

**Goal**: Replace boolean flag checks and `phase` enum in `RecordingService` with a guarded `SessionStateMachine` actor. Illegal state transitions must fail at compile time or throw at runtime.

**V2 Reference**: Document 04 §2, ADR-003  
**Tech Debt**: TD-C04 (partial), TD-M01 (partial)  
**Phase**: 2  
**Estimated effort**: 7–10 days

**Files**:
- New: `Sources/Orin/Services/SessionStateMachine.swift`
- Modify: `Sources/Orin/Services/RecordingService.swift` — use `SessionStateMachine` for all state transitions

**Acceptance Criteria**:
- [ ] `SessionStateMachine` actor with all 13 states from Document 04 §2
- [ ] `transition(to:trigger:) throws` validates each transition against the valid transition table
- [ ] `SessionStateMachine` emits `SessionStarted`, `SessionStopped`, etc. via `EventBus` on state transition
- [ ] `isRecording`, `isCapturing` boolean flags removed from `RecordingService`
- [ ] Invalid transitions (e.g., `Active` → `Starting`) throw `SessionError.invalidTransition`
- [ ] State is persisted to SwiftData so crash recovery restores last known state

**Dependencies**: EPIC-11 (EventBus must exist for state machine to emit events)

**Test Strategy**:
- Unit test: every valid transition from Document 04 §2 state diagram
- Unit test: every invalid transition throws `SessionError.invalidTransition`
- Property test: random valid event sequence; verify state machine invariants hold

**Rollback Strategy**: Keep `RecordingService.phase` enum in parallel until `SessionStateMachine` is verified. Flag-guard the state machine with a feature flag.

---

### EPIC-13: AnalysisStatus Typed Enum

**Goal**: Replace `MeetingItem.analysisStatus` string field with a typed `AnalysisStatus` enum with all 8 states from Document 04.

**V2 Reference**: Document 04 §3  
**Phase**: 2  
**Estimated effort**: 2–3 days

**Files**:
- Modify: `Sources/Orin/Models/OrinModels.swift` — `analysisStatus: AnalysisStatus`
- Modify: `Sources/Orin/Services/MeetingIntelligenceService.swift` — use typed enum
- Modify: All views that read/display analysis status

**Acceptance Criteria**:
- [ ] `AnalysisStatus` enum: `pending, queued, running, synthesizing, completed, failed, deferred, cancelled`
- [ ] SwiftData migration handles existing string values correctly (map old strings → new enum cases)
- [ ] All status transitions in `MeetingIntelligenceService` use the typed enum
- [ ] UI displays status correctly for all 8 states

**Dependencies**: EPIC-06 (persistence changes include this)

**Test Strategy**:
- Migration test: run on device with existing string-status meetings; verify correct mapping
- Unit test: each `AnalysisStatus` state displays correct UI label

---

### EPIC-14: RecordingService Split → RecordingSessionCoordinator

**Goal**: Split `RecordingService` (1,355 lines) into `RecordingSessionCoordinator` (orchestration only) + extracted audio logic in adapters.

**V2 Reference**: Document 03 §4  
**Tech Debt**: TD-M01  
**Phase**: 2  
**Estimated effort**: 10–14 days (highest-risk Phase 2 operation)

**Files**:
- New: `Sources/Orin/Services/RecordingSessionCoordinator.swift`
- Shrink: `Sources/Orin/Services/RecordingService.swift` → target < 100 lines or delete
- Ensure adapters (EPIC-05, EPIC-09) contain the extracted audio logic

**Acceptance Criteria**:
- [ ] `RecordingSessionCoordinator` contains only orchestration code (no direct AVAudioEngine / SpeechTranscriber calls)
- [ ] All audio engine calls are in `AudioCaptureProvider` adapter
- [ ] All ASR calls are in `ASRBackend` adapter
- [ ] Session lifecycle events flow through `SessionStateMachine`
- [ ] `RecordingService.swift` either deleted or < 100 lines (thin coordinator remaining)
- [ ] Full recording + analysis test passes end-to-end

**Dependencies**: EPIC-05 (ASRBackend), EPIC-09 (AudioCaptureProvider), EPIC-12 (SessionStateMachine)

**Test Strategy**:
- Full end-to-end recording test after each extraction step (extract one adapter at a time, not all at once)
- Compare transcript quality before and after split (regression check)

**Rollback Strategy**: Keep the original `RecordingService.swift` as a Git backup. The split is done by extraction (new files created, not in-place mutation), so reverting means removing the new files.

---

### EPIC-15: Fix @MainActor Data and Performance Violations

**Goal**: Fix `persistChunkIfNeeded`, `allSegments @Query`, and `filterMeetings` performance issues.

**V2 Reference**: Document 11 §6, §8  
**Tech Debt**: TD-H05, TD-H06, TD-H15, TD-M08  
**Phase**: 2  
**Estimated effort**: 4–5 days

**Files**:
- Modify: `Sources/Orin/Services/TranscriptStore.swift` — batch saves via background `ModelActor`
- Modify: `Sources/Orin/Views/Meetings/MeetingsView.swift` — add predicate to `@Query`; add pagination
- Modify: `Sources/Orin/Services/MeetingDataService.swift` — add debounce to filter

**Acceptance Criteria**:
- [ ] `context.save()` never called on `@MainActor` during active recording
- [ ] `@Query` in MeetingsView scoped (not all-meetings); 1,000 meetings loads in < 100ms
- [ ] `filterMeetings()` debounced at 300ms
- [ ] No CPU spikes on main thread during active recording (Instruments verify)

**Dependencies**: EPIC-06 (PersistenceStore, background context setup)

**Test Strategy**:
- Performance test: 1,000 seeded meetings; measure @Query latency
- Instruments: Main Thread Checker shows no disk I/O on @MainActor during recording

---

### EPIC-16: ASRSessionStateMachine — Fix Generation Counter Race

**Goal**: Replace the generation counter TOCTOU race in `RecordingService` with an `ASRSessionStateMachine` actor that owns the ASR restart lifecycle.

**V2 Reference**: Document 04 §5  
**Tech Debt**: TD-C04  
**Phase**: 2  
**Estimated effort**: 5–7 days

**Files**:
- New: `Sources/Orin/Services/ASRSessionStateMachine.swift`
- Modify: `Sources/Orin/Services/RecordingSessionCoordinator.swift` — use `ASRSessionStateMachine`

**Acceptance Criteria**:
- [ ] `ASRSessionStateMachine` actor with states: `Uninitialized`, `Initializing`, `Ready`, `Restarting`, `Finalizing`, `Completed`, `Failed`
- [ ] Generation counter replaced by state machine state checks
- [ ] Watchdog timer: if `Initializing` for > 10s with no speech → force `Restarting`
- [ ] Stale callbacks rejected by checking actor state, not a shared integer
- [ ] Error 1110 (ASR restart trigger) handled in `Restarting` state entry

**Dependencies**: EPIC-14 (RecordingSessionCoordinator must exist)

**Test Strategy**:
- Unit test: simulate ASR error 1110; verify state machine transitions to Restarting
- Unit test: simulate stale callback after restart; verify it is rejected
- Manual: 30-minute recording; verify no transcript corruption from stale callbacks

---

### EPIC-17: MeetingIntelligenceService Split → AnalysisCoordinator + PromptBuilder

**Goal**: Extract `MeetingIntelligenceService` (1,010 lines) into `AnalysisCoordinator` (orchestration) + `PromptBuilder` (prompt construction) + `ResponseParser` (output parsing).

**V2 Reference**: Document 05 §7–9, Document 03 §4  
**Tech Debt**: TD-M02, TD-H03  
**Phase**: 2  
**Estimated effort**: 10–12 days

**Files**:
- New: `Sources/Orin/Services/AnalysisCoordinator.swift`
- New: `Sources/Orin/Services/PromptBuilder.swift`
- New: `Sources/Orin/Services/ResponseParser.swift`
- Shrink/delete: `Sources/Orin/Services/MeetingIntelligenceService.swift`

**Acceptance Criteria**:
- [ ] `AnalysisCoordinator` subscribes to `SessionFinalized` event; enqueues to `AnalysisJobQueue`
- [ ] `PromptBuilder` accepts `responseLanguage` parameter; builds language-aware prompts
- [ ] `ResponseParser` uses language-neutral section markers only (no hardcoded English keywords)
- [ ] Hallucination detection runs on a background `Task`, not on @MainActor
- [ ] All existing analysis test cases produce equivalent output
- [ ] `MeetingIntelligenceService.swift` either deleted or < 50 lines

**Dependencies**: EPIC-11 (EventBus), EPIC-04 (InferenceProvider)

**Test Strategy**:
- Unit test `PromptBuilder`: verify `responseLanguage: "es"` produces Spanish prompt header
- Unit test `ResponseParser`: verify language-neutral markers parsed correctly for English, Spanish, Hindi samples
- Integration test: full analysis of a reference meeting recording; compare output to V1 baseline

---

## Phase 3 Epics

---

### EPIC-18: OrinCore Swift Package Extraction

**Goal**: Extract all domain models, protocols, state machines, and event types into `OrinCore` Swift Package with zero platform imports.

**V2 Reference**: Document 03 §2, Document 10 §2, ADR-001  
**Phase**: 3  
**Estimated effort**: 14–21 days

**Files**:
- New: `OrinCore/Package.swift`
- Move: All domain models, protocols, events, state machines from `Sources/Orin/` to `OrinCore/Sources/OrinCore/`
- Add CI: forbidden import scanner (`AVFoundation`, `SwiftData`, `Speech`, etc.)

**Acceptance Criteria**:
- [ ] `swift build --target OrinCore` succeeds
- [ ] CI scanner reports zero forbidden imports in `OrinCore` target
- [ ] `OrinMacOS` target imports `OrinCore` and provides all adapters
- [ ] All existing tests pass unchanged
- [ ] iPhone Simulator target builds (compilation only; functionality separate)

**Dependencies**: All Phase 1 + Phase 2 epics complete (adapters and protocols must be stable)

**Test Strategy**:
- Build target on macOS, iOS Simulator, and (optionally) Linux CI to verify zero platform imports

---

### EPIC-19: Multilingual — Locale Fix + Parameterized Prompts

**Goal**: Fix hardcoded locale in both audio channels. Parameterize AI prompts. Use language-neutral section markers.

**V2 Reference**: Document 07 §2, §5, §7, §10  
**Tech Debt**: TD-H01, TD-H02, TD-H03  
**Phase**: 3  
**Estimated effort**: 7–10 days

**Files**:
- Modify: `Sources/Orin/Services/RecordingService.swift` or `RecordingSessionCoordinator.swift`
- Modify: `Sources/Orin/Services/SystemAudioCaptureService.swift`
- Modify: `Sources/Orin/Services/PromptBuilder.swift` (from EPIC-17)
- Modify: `Sources/Orin/Services/ResponseParser.swift` (from EPIC-17)
- New: `Sources/Orin/Services/ASRBackendRouter.swift`
- New: `Sources/Orin/Services/LanguageDetectionPipeline.swift`

**Acceptance Criteria**:
- [ ] Both channels read locale from `VocabularyProvider.speechLocale` (user preference)
- [ ] `ASRBackendRouter` selects correct backend for configured locale
- [ ] `PromptBuilder` accepts and uses `responseLanguage`
- [ ] `ResponseParser` parses `[SUMMARY]`, `[ACTION_ITEMS]` (not English keywords)
- [ ] `NLLanguageRecognizer` runs post-recording on transcript text
- [ ] English-locale analysis output unchanged from V1 baseline (regression test)

**Dependencies**: EPIC-05 (ASRBackend protocol), EPIC-17 (PromptBuilder/ResponseParser)

---

### EPIC-20: WhisperASRBackend Implementation

**Goal**: Implement `WhisperASRBackend` as a real, functional ASR backend connecting to a whisper.cpp HTTP server.

**V2 Reference**: Document 07 §9, ADR-014  
**Tech Debt**: TD-H08  
**Phase**: 3  
**Estimated effort**: 7–10 days

**Files**:
- Implement: `Sources/Orin/Providers/macOS/WhisperASRBackend.swift` (from EPIC-05 stub)
- New: `Sources/Orin/Views/Settings/WhisperSetupView.swift`
- Modify: `Sources/Orin/Views/Settings/SettingsView.swift` — Whisper server configuration

**Acceptance Criteria**:
- [ ] `WhisperASRBackend.transcribe()` sends audio to `localhost:[port]/transcribe` and streams results
- [ ] hi-IN locale routes to `WhisperASRBackend` via `ASRBackendRouter`
- [ ] Settings UI shows Whisper server path, connection status, model size selection
- [ ] If Whisper server not running: graceful fallback to next available backend with user notification
- [ ] hi-IN meeting recording produces readable transcript (human QA with Hindi speaker)

**Dependencies**: EPIC-19 (ASRBackendRouter must exist)

---

### EPIC-21: Vocabulary V2 — LanguagePack + VocabularyContext

**Goal**: Replace `VocabularyProvider` with the full V2 vocabulary system: `VocabularyItem` SwiftData model, `LanguagePack`, `VocabularyContext` builder with explicit tier allocation.

**V2 Reference**: Document 07 §8, Document 06 §3, ADR-016  
**Tech Debt**: TD-H04, TD-M06  
**Phase**: 3  
**Estimated effort**: 7–10 days

**Files**:
- New: `Sources/Orin/Models/VocabularyItem.swift`
- New: `Sources/Orin/Models/LanguagePack.swift`
- New: `Sources/Orin/Services/VocabularyContext.swift`
- Modify: `Sources/Orin/Services/VocabularyProvider.swift` → deprecate after migration
- Migration: move existing terms to `VocabularyItem` records on first launch

**Acceptance Criteria**:
- [ ] `VocabularyItem` SwiftData model with `languageCode`, `tier`, `frequency`, `decayScore`
- [ ] `LanguagePack` for `en` (80 terms) and `hi-Latn` (50 terms), both bundled
- [ ] `VocabularyContext.build()` allocates 100-term budget across tiers; emits `VocabularyBudgetExceeded` if any tier truncated
- [ ] No silent `.prefix(100)` truncation
- [ ] Existing custom vocabulary from V1 `UserDefaults` migrated to Tier 2 `VocabularyItem` records
- [ ] Hindi session uses only hi-Latn terms; English session uses only en terms (no cross-contamination)

**Dependencies**: EPIC-19 (locale is required to select correct language pack)

---

## Phase 4 Epics

---

### EPIC-22: Knowledge Graph Implementation

**Goal**: Implement the Knowledge Context: SQLite adjacency list, `KnowledgeGraph` actor, `EntityExtractor`, `EntityResolver`, `KnowledgeQueryService`.

**V2 Reference**: Document 08, ADR-007  
**Phase**: 4  
**Estimated effort**: 21–28 days

**Acceptance Criteria**:
- [ ] SQLite schema: `nodes`, `edges`, `facts` tables with all indexes defined in Document 08 §3
- [ ] `KnowledgeGraph` actor: thread-safe read/write operations
- [ ] `NLTaggerEntityExtractor` extracts `Person`, `Organization`, `Project` entities from transcript chunks
- [ ] `EntityResolver` resolves extracted entities against existing graph nodes
- [ ] `KnowledgeQueryService.meetings(involving:)` returns correct results
- [ ] `AnalysisCoordinator` (EPIC-17) triggers entity extraction after `AnalysisCompleted`
- [ ] Background migration processes existing meetings (progress indicator in UI)

**Dependencies**: EPIC-11 (EventBus for `AnalysisCompleted` subscription), EPIC-17 (AnalysisCoordinator)

---

### EPIC-23: Learning Engine — Corrections + Promotion

**Goal**: Implement `CorrectionStore`, `PromotionEngine`, and correction UI.

**V2 Reference**: Document 06 §3–5  
**Phase**: 4  
**Estimated effort**: 14–18 days

**Acceptance Criteria**:
- [ ] `VocabularyCorrection` SwiftData model with all fields from Document 06 §3
- [ ] Transcript detail view: tap a word → correction modal → correction saved to `CorrectionStore`
- [ ] `PromotionEngine` evaluates after each `CorrectionRecorded` event
- [ ] Promotion suggestion UI appears in Settings after threshold met
- [ ] Accepted promotion creates `VocabularyItem` at Tier 2

**Dependencies**: EPIC-21 (VocabularyItem model must exist for promotion to write to it)

---

### EPIC-24: Learning Engine — Decay + Meeting Patterns

**Goal**: Implement `DecayEngine` and `MeetingPatternLearner`.

**V2 Reference**: Document 06 §5, §7  
**Phase**: 4  
**Estimated effort**: 7–10 days

**Acceptance Criteria**:
- [ ] `DecayEngine` runs daily background task; applies 0.98 daily decay to all non-builtin `VocabularyItems`
- [ ] Items below 0.1 decay score flagged in Settings as stale
- [ ] `MeetingPatternLearner` updates `MeetingPattern` struct after each `SessionFinalized` event
- [ ] Meeting detection confidence uses patterns (more accurate after 5+ meetings of same type)

**Dependencies**: EPIC-23 (CorrectionStore, VocabularyItem)

---

## Backlog Summary

| Epic | Phase | Effort | Dependencies |
|------|-------|--------|-------------|
| EPIC-01 Audio RT Safety | 0 | 3–5d | — |
| EPIC-02 InferenceWorker | 0 | 5–7d | — |
| EPIC-03 Remove sleep | 0 | 2–3d | — |
| EPIC-04 InferenceProvider | 1 | 5–7d | EPIC-02 |
| EPIC-05 ASRBackend | 1 | 7–10d | — |
| EPIC-06 PersistenceStore | 1 | 7–10d | — |
| EPIC-07 Composition Root | 1 | 3–5d | EPIC-04/05/06 |
| EPIC-08 Renames + FeatureFlags | 1 | 1–2d | — |
| EPIC-09 AudioCaptureProvider | 1 | 5–7d | EPIC-01 |
| EPIC-10 RetentionService fix | 1 | 1–2d | — |
| EPIC-11 EventBus | 2 | 7–10d | EPIC-07 |
| EPIC-12 SessionStateMachine | 2 | 7–10d | EPIC-11 |
| EPIC-13 AnalysisStatus enum | 2 | 2–3d | EPIC-06 |
| EPIC-14 RecordingService split | 2 | 10–14d | EPIC-05/09/12 |
| EPIC-15 Performance fixes | 2 | 4–5d | EPIC-06 |
| EPIC-16 ASRSessionStateMachine | 2 | 5–7d | EPIC-14 |
| EPIC-17 MIS split | 2 | 10–12d | EPIC-11/04 |
| EPIC-18 OrinCore package | 3 | 14–21d | All Phase 1+2 |
| EPIC-19 Multilingual | 3 | 7–10d | EPIC-05/17 |
| EPIC-20 WhisperASRBackend | 3 | 7–10d | EPIC-19 |
| EPIC-21 Vocabulary V2 | 3 | 7–10d | EPIC-19 |
| EPIC-22 Knowledge Graph | 4 | 21–28d | EPIC-11/17 |
| EPIC-23 Learning: Corrections | 4 | 14–18d | EPIC-21 |
| EPIC-24 Learning: Decay | 4 | 7–10d | EPIC-23 |

**Total estimated effort (Phases 0–4): 28–38 weeks for a single engineer; 14–20 weeks with 2 engineers working parallel non-dependent epics.**
