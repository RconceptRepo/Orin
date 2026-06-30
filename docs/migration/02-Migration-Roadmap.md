# Document M-02: Migration Roadmap

**Series**: Orin V2 Migration Planning  
**Document**: 2 of 8  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Principles

1. **No big-bang rewrite**. Every phase is independently shippable. The app builds, tests pass, and recording works after every step.
2. **Fix before extend**. Critical audio-thread and concurrency defects ship before any new features.
3. **Protocols first**. Introduce protocol boundaries around existing concretions before extracting packages.
4. **Side-effect events**. When introducing the `EventBus`, new services emit events alongside existing direct calls — not instead of them — until all consumers have migrated.
5. **Rollback = revert the protocol wrapper**. Because concretions are never deleted until the next phase confirms stability, every step is reversible by removing the wrapper layer.

---

## Phase Overview

```
Phase 0 (1-2 weeks)  — Critical Audio + Concurrency Fixes (BLOCKER)
Phase 1 (4-6 weeks)  — Protocol Boundaries + InferenceWorker
Phase 2 (6-8 weeks)  — Event Bus + Coordinator Layer + State Machines
Phase 3 (8-10 weeks) — OrinCore Package + Multilingual + Vocabulary V2
Phase 4 (8-10 weeks) — Knowledge Graph + Learning Engine
Phase 5 (8-10 weeks) — Plugin SDK + Enterprise Workspace
Phase 6 (ongoing)    — Cross-Platform (Windows POC → iOS → Android)
```

Total to Phase 4 (core V2): approximately 7 months.

---

## Phase 0: Critical Fixes (1–2 weeks)

### Objective

Eliminate the four CRITICAL defects that could cause audio dropout, system freeze, or crash in production before any architectural work proceeds. These are pre-requisite to Phase 1.

### Scope

| # | Fix | File | Lines |
|---|-----|------|-------|
| P0-01 | Pre-allocate `AVAudioPCMBuffer` in `TapState.arm()`; reuse in `feed()` | `TapState.swift` | ~40 |
| P0-02 | Capture `recognitionRequest` ref under NSLock; call `endAudio()` after lock release | `TapState.swift` | ~10 |
| P0-03 | Move lazy `AVAudioConverter` initialization from `feed()` to `arm()` | `SystemAudioCaptureService.swift` | ~20 |
| P0-04 | Introduce `InferenceWorker` actor with serial queue; replace `withTaskGroup` in `MeetingIntelligenceService.analyzeChunked()` | `MeetingIntelligenceService.swift` + new `InferenceWorker.swift` | ~150 new |
| P0-05 | Remove `Task.sleep(1_500_000_000)` from `RecordingService.finalize()`; replace with `SpeechTranscriber` completion await or fixed delay via non-blocking `try await Task.sleep` off-@MainActor | `RecordingService.swift` | ~15 |

### Files Affected

- `Sources/Orin/Services/TapState.swift`
- `Sources/Orin/Services/SystemAudioCaptureService.swift`
- `Sources/Orin/Services/MeetingIntelligenceService.swift`
- `Sources/Orin/Services/RecordingService.swift`
- New: `Sources/Orin/Services/InferenceWorker.swift`

### Services Affected

- Audio pipeline (TapState, ParticipantSTFeed)
- `RecordingService`
- `MeetingIntelligenceService`

### Risks

- P0-04 changes the analysis concurrency model. The observable effect is longer total analysis time (sequential chunks instead of parallel) combined with **elimination of the post-meeting system freeze**. This is the correct trade-off.
- P0-05: if the 1.5s sleep was masking a real ASR finalization timing issue, removing it may expose that issue. Mitigation: replace with `try await Task.sleep(nanoseconds: 500_000_000)` off-@MainActor as a temporary measure, then eliminate in Phase 1 when the ASR state machine is introduced.

### Rollback Strategy

- P0-01/02/03: trivially revert (pre-allocation is pure additive)
- P0-04: `InferenceWorker` wraps the existing `analyzeChunk()` method. Rolling back means calling `analyzeChunk()` directly again.
- P0-05: restore the `Task.sleep` call (bad, but recoverable)

### Exit Criteria

- [ ] `TapState.feed()` measured at < 0.1ms P99 in Instruments (no allocation on callback)
- [ ] `recognitionRequest?.endAudio()` never called while NSLock is held (code audit)
- [ ] Post-meeting system freeze not reproducible in a 1-hour test recording
- [ ] App builds and all existing tests pass

---

## Phase 1: Protocol Boundaries (4–6 weeks)

### Objective

Introduce protocol wrappers around every existing concrete service that corresponds to a V2 hexagonal port. No behaviour change. The app remains fully functional.

### Scope

| # | Protocol | Existing Concrete | New Protocol | New Adapter |
|---|----------|-----------------|--------------|-------------|
| P1-01 | `InferenceProvider` | `AIService` Ollama calls | `InferenceProvider` protocol | `OllamaInferenceAdapter` wrapping `AIService` |
| P1-02 | `ASRBackend` | `SpeechTranscriber` in `RecordingService` | `ASRBackend` protocol | `SpeechTranscriberASRAdapter` |
| P1-03 | `ASRBackend` (legacy) | `SFSpeechRecognizer` in `RecordingService` | same `ASRBackend` protocol | `SFSpeechASRAdapter` |
| P1-04 | `AudioCaptureProvider` | `AVAudioEngine` in `RecordingService` | `AudioCaptureProvider` protocol | `AVAudioEngineAdapter` |
| P1-05 | `SystemAudioCaptureProvider` | `SystemAudioCaptureService` + `SCKit` | Rename existing `SystemAudioProvider` → `SystemAudioCaptureProvider` | `SCKitSystemAudioAdapter` (rename `SCKitSystemAudioProvider`) |
| P1-06 | `PersistenceStore` | `TranscriptStore` + SwiftData `ModelContext` | `PersistenceStore` protocol | `SwiftDataPersistenceAdapter` wrapping `TranscriptStore` |
| P1-07 | `MeetingDetector` | `MeetingDetectorService` + `MeetingDetectorProvider` | Rename `MeetingDetectorProvider` → `MeetingDetector` | No new adapter (existing provider is already an adapter) |
| P1-08 | Typed `FeatureFlags` struct | `FeatureFlags` enum with computed properties | Keep enum; add `FeatureFlagStore` protocol for testability | Thin wrapper |

Additional Phase 1 work:
- P1-09: Replace `ServiceContainer.shared.resolve()` calls with constructor injection at `OrinApp.init()`
- P1-10: Move `sampleCPUUsage()` call in `RecordingService` to `#if DEBUG` guard
- P1-11: Apply `@Attribute(.externalStorage)` to `MeetingItem.rawTranscript` and any other large blob fields

### Files Affected

- New: `Sources/Orin/Providers/Protocols/InferenceProvider.swift`
- New: `Sources/Orin/Providers/Protocols/ASRBackend.swift`
- New: `Sources/Orin/Providers/Protocols/AudioCaptureProvider.swift`
- New: `Sources/Orin/Providers/Protocols/PersistenceStore.swift`
- New: `Sources/Orin/Providers/macOS/OllamaInferenceAdapter.swift`
- New: `Sources/Orin/Providers/macOS/SpeechTranscriberASRAdapter.swift`
- New: `Sources/Orin/Providers/macOS/SFSpeechASRAdapter.swift`
- New: `Sources/Orin/Providers/macOS/AVAudioEngineAdapter.swift`
- New: `Sources/Orin/Providers/macOS/SwiftDataPersistenceAdapter.swift`
- Rename: `SCKitSystemAudioProvider.swift` → `SCKitSystemAudioAdapter.swift`
- Modify: `Sources/Orin/App/OrinApp.swift` — composition root
- Modify: `Sources/Orin/App/ServiceContainer.swift` — mark deprecated
- Modify: `Sources/Orin/Models/OrinModels.swift` — @Attribute(.externalStorage)
- Modify: `Sources/Orin/Services/RecordingService.swift` — inject ASRBackend + AudioCaptureProvider
- Modify: `Sources/Orin/Services/MeetingIntelligenceService.swift` — inject InferenceProvider
- Modify: `Sources/Orin/Services/FeatureFlags.swift` — add testability

### Services Affected

All services that currently call `ServiceContainer.shared.resolve()`. Protocol injection replaces these calls.

### Risks

- `RecordingService` currently accesses `SpeechTranscriber` APIs directly with Apple-specific types. The adapter must bridge these type differences without breaking existing behaviour.
- `SwiftDataPersistenceAdapter` must replicate exactly the current `TranscriptStore` SwiftData logic; any divergence risks data corruption.

### Rollback Strategy

Every new protocol adapter has the existing concretion as its fallback. Rolling back means removing the adapter files and reverting the injection point. The concretion is never deleted in Phase 1.

### Exit Criteria

- [ ] All 8 port protocols defined and documented
- [ ] `ServiceContainer` has zero call sites (`grep -r "ServiceContainer.shared" Sources/` returns empty)
- [ ] `OrinApp.init()` is the single composition root
- [ ] App builds, all existing tests pass, manual recording test successful
- [ ] No `ServiceContainer.resolve()` in any production call path

---

## Phase 2: Event Bus + State Machines + Coordinator Layer (6–8 weeks)

### Objective

Introduce the `EventBus`, move cross-context communication to events (side-by-side with existing direct calls initially), introduce explicit state machines for Session and Analysis, and split `RecordingService` into `RecordingSessionCoordinator` + `SessionStateMachine`.

### Scope

**Sprint 2a (3 weeks): EventBus + Events**
- P2-01: Implement `EventBus` actor + `DomainEvent` protocol
- P2-02: Emit Phase-1 events as **side effects**: `SessionStarted`, `SessionStopped`, `SessionFinalized`, `AnalysisQueued`, `AnalysisCompleted`, `AnalysisFailed` (emit these alongside existing direct calls — do not remove direct calls yet)
- P2-03: Introduce new features as event subscribers (e.g., `AnalysisPerfLogger` subscribes to `AnalysisCompleted` instead of being called directly)
- P2-04: Emit `SegmentAdded` from `TranscriptStore`

**Sprint 2b (3 weeks): State Machines + Coordinator Split**
- P2-05: Introduce `SessionStateMachine` actor — replace boolean flag checks in `RecordingService`
- P2-06: Introduce `AnalysisStatus` typed enum on `MeetingItem` — replace string-based status
- P2-07: Split `RecordingService` (1,355 lines) into:
  - `RecordingSessionCoordinator`: session lifecycle orchestration (no business logic)
  - `SessionStateMachine`: owned by `RecordingSessionCoordinator`
  - Audio pipeline code extracted to adapter layer (Phase 1 adapters receive this logic)
- P2-08: Fix ASR restart: replace `generationHadSpeech` / generation counter race with `ASRSessionStateMachine`

**Sprint 2c (2 weeks): Polish + Fix remaining high-severity defects**
- P2-09: Fix `persistChunkIfNeeded` — move `context.save()` off @MainActor to `SwiftDataPersistenceAdapter`
- P2-10: Fix `allSegments @Query` — add predicate + pagination in `MeetingsListViewModel`
- P2-11: Add `VocabularyBudgetExceeded` logging (explicit allocation instead of silent `.prefix(100)`)

### Files Affected

- New: `Sources/Orin/Services/EventBus.swift`
- New: `Sources/Orin/Services/DomainEvents.swift` (all event types)
- New: `Sources/Orin/Services/SessionStateMachine.swift`
- New: `Sources/Orin/Services/RecordingSessionCoordinator.swift`
- New: `Sources/Orin/Services/ASRSessionStateMachine.swift`
- Modify: `Sources/Orin/Services/RecordingService.swift` → eventually deprecated, logic extracted
- Modify: `Sources/Orin/Services/MeetingIntelligenceService.swift` — emit events, use typed AnalysisStatus
- Modify: `Sources/Orin/Services/TranscriptStore.swift` — emit SegmentAdded, fix save
- Modify: `Sources/Orin/Models/OrinModels.swift` — typed AnalysisStatus enum
- Modify: `Sources/Orin/Views/Meetings/MeetingsView.swift` — fix @Query predicate

### Risks

- `RecordingService` split is the highest-risk operation in Phase 2. A test recording must be run after each split step to verify audio pipeline correctness.
- `SessionStateMachine` introduces compile-time protection against invalid transitions; existing code that makes invalid transitions (if any exist) will fail to compile. These must be identified and fixed.

### Rollback Strategy

- Events are emitted as side effects alongside existing direct calls. Rolling back means removing the event emission calls — the direct calls remain functional.
- `SessionStateMachine` wraps the existing phase enum; rolling back means unwrapping.

### Exit Criteria

- [ ] `EventBus` actor implemented and dispatching events
- [ ] `SessionStarted`, `SessionStopped`, `SessionFinalized`, `AnalysisCompleted` events emitted in production code
- [ ] `SessionStateMachine` owns all session state transitions; no boolean flag checks in `RecordingSessionCoordinator`
- [ ] `RecordingService.swift` is either deleted or reduced to < 200 lines (coordinator only)
- [ ] Generation counter replaced by `ASRSessionStateMachine`
- [ ] `persistChunkIfNeeded` runs off @MainActor
- [ ] App builds, manual recording + analysis test successful end-to-end

---

## Phase 3: OrinCore Package + Multilingual + Vocabulary V2 (8–10 weeks)

### Objective

Extract `OrinCore` Swift Package (zero platform imports), making Windows portability technically possible. Implement the multilingual architecture — fix locale hardcoding, introduce `ASRBackend` protocol, begin Whisper integration, parameterize AI prompts.

### Scope

**Sprint 3a (3 weeks): OrinCore Package Extraction**
- P3-01: Create `OrinCore` Swift Package in the repository root
- P3-02: Move all domain models, event types, protocols, state machines into `OrinCore`
- P3-03: CI check: `swift build --target OrinCore` with forbidden import scanner
- P3-04: Update `OrinMacOS` target to import `OrinCore`; all adapters stay in `OrinMacOS`

**Sprint 3b (4 weeks): Multilingual**
- P3-05: Fix locale hardcoding: both channels read `VocabularyProvider.speechLocale`
- P3-06: `ASRBackend` protocol introduced (from Phase 1 spec); wrap SpeechTranscriber + SFSpeech
- P3-07: `ASRBackendRouter` selects backend per locale
- P3-08: Per-channel locale independence: mic and system audio can use different locales
- P3-09: Language-parameterized prompts: `responseLanguage` parameter in `buildComprehensivePrompt()`
- P3-10: Language-neutral section markers in `parseComprehensiveResponse()`
- P3-11: `NLLanguageRecognizer` post-recording detection
- P3-12: Implement `WhisperASRBackend` (whisper.cpp HTTP server, same pattern as Ollama)

**Sprint 3c (3 weeks): Vocabulary V2**
- P3-13: `VocabularyItem` SwiftData model with tiers and language namespace
- P3-14: `LanguagePack` structs for en and hi-Latn (bundled)
- P3-15: `VocabularyContext` builder with explicit tier allocation and `VocabularyBudgetExceeded` event
- P3-16: Migrate existing `VocabularyProvider` terms to `VocabularyItem` records

### Files Affected

- New Swift Package: `OrinCore/Package.swift` + all domain code
- New: `Sources/Orin/Providers/macOS/SpeechTranscriberASRAdapter.swift` (from Phase 1 stub → full implementation)
- New: `Sources/Orin/Providers/macOS/WhisperASRBackend.swift`
- New: `Sources/Orin/Services/ASRBackendRouter.swift`
- New: `Sources/Orin/Services/VocabularyContext.swift`
- New: `Sources/Orin/Models/VocabularyItem.swift` (SwiftData model)
- New: `Sources/Orin/Models/LanguagePack.swift`
- Modify: `Sources/Orin/Services/RecordingService.swift` (or `RecordingSessionCoordinator.swift`) — locale from user preference
- Modify: `Sources/Orin/Services/SystemAudioCaptureService.swift` — locale from user preference
- Modify: `Sources/Orin/Services/MeetingIntelligenceService.swift` — `responseLanguage` + language-neutral markers
- Modify: `Sources/Orin/Services/VocabularyProvider.swift` — deprecated after migration
- Modify: `Sources/Orin/App/ServiceContainer.swift` or composition root — inject `ASRBackendRouter`

### Risks

- OrinCore package extraction may require breaking circular dependencies that currently exist across files. These must be resolved before extraction.
- Multilingual prompt changes affect analysis quality for existing English users. Test against a library of reference meeting recordings before shipping.
- Whisper integration requires users to install and run a separate server process; setup flow in Settings must be clear.

### Rollback Strategy

- OrinCore extraction: revert `Package.swift`; all code reverts to original target
- Multilingual: locale fix is additive; reverting means restoring hardcoded values
- Vocabulary V2: old `VocabularyProvider` remains until fully migrated

### Exit Criteria

- [ ] `swift build --target OrinCore` succeeds with zero forbidden imports (AVFoundation, SwiftData, etc.)
- [ ] Both channels read locale from user preference (no hardcoded `en-IN` / `en-US`)
- [ ] AI prompts include `responseLanguage` parameter
- [ ] `parseComprehensiveResponse()` uses only language-neutral markers
- [ ] Whisper HTTP server integration tested with hi-IN meeting recording
- [ ] `VocabularyItem` SwiftData model deployed; existing vocabulary migrated

---

## Phase 4: Knowledge Graph + Learning Engine (8–10 weeks)

### Objective

Implement the Knowledge Context and Learning Context — the two entirely new subsystems in V2. Both are additive and do not modify existing functionality.

### Scope

**Sprint 4a (4 weeks): Knowledge Graph**
- P4-01: SQLite adjacency list schema (nodes, edges, facts tables with indexes)
- P4-02: `KnowledgeGraph` actor + `KnowledgeQueryService` implementation
- P4-03: `NLTaggerEntityExtractor` implementation
- P4-04: `EntityResolver` implementation
- P4-05: Subscribe to `AnalysisCompleted` event → run entity extraction → write to graph
- P4-06: Background migration: process existing meeting history → seed knowledge graph
- P4-07: Basic knowledge graph UI (entity detail view, relationship browser)

**Sprint 4b (4 weeks): Learning Engine**
- P4-08: `VocabularyCorrection` SwiftData model + `CorrectionStore` actor
- P4-09: Correction UI in transcript detail view (tap to correct a word)
- P4-10: `PromotionEngine` actor with frequency ≥ 3 promotion logic
- P4-11: Promotion suggestion UI
- P4-12: `DecayEngine` actor (daily background task)
- P4-13: `MeetingPatternLearner` — Bayesian meeting type pattern
- P4-14: `AnalysisFeedbackProcessor` — record user edits to summaries and action items

### Files Affected

- New: `Sources/Orin/Services/Knowledge/KnowledgeGraph.swift`
- New: `Sources/Orin/Services/Knowledge/KnowledgeGraphSchema.swift`
- New: `Sources/Orin/Services/Knowledge/EntityExtractor.swift`
- New: `Sources/Orin/Services/Knowledge/EntityResolver.swift`
- New: `Sources/Orin/Services/Knowledge/KnowledgeQueryService.swift`
- New: `Sources/Orin/Services/Learning/CorrectionStore.swift`
- New: `Sources/Orin/Services/Learning/PromotionEngine.swift`
- New: `Sources/Orin/Services/Learning/DecayEngine.swift`
- New: `Sources/Orin/Services/Learning/MeetingPatternLearner.swift`
- New: `Sources/Orin/Services/Learning/AnalysisFeedbackProcessor.swift`
- New: `Sources/Orin/Views/Knowledge/KnowledgeGraphView.swift`
- New: `Sources/Orin/Models/KnowledgeModels.swift`
- New: `Sources/Orin/Models/LearningModels.swift`

### Risks

- Knowledge graph background migration of existing meetings could be slow for power users with thousands of meetings. Must be batched at low priority with progress indicator.
- `AnalysisFeedbackProcessor` must not interfere with existing analysis saving. Subscribe to events, do not modify analysis save path.

### Rollback Strategy

- All Phase 4 work is additive. Nothing in Phase 4 modifies existing recording, transcription, or analysis code. Rolling back means removing the new files and event subscriptions.

### Exit Criteria

- [ ] `KnowledgeGraph` actor stores entities and relationships extracted from `AnalysisCompleted` events
- [ ] `KnowledgeQueryService.meetings(involving:)` returns correct results
- [ ] Background migration processes all existing meetings and seeds the graph
- [ ] `CorrectionStore` records corrections from transcript editing
- [ ] `PromotionEngine` suggests promotions at frequency ≥ 3
- [ ] App builds, all tests pass

---

## Phase 5: Plugin SDK (8–10 weeks)

### Objective

Implement the XPC-based plugin system, ship the first three first-party plugins (Linear, Notion, Slack), and publish the developer SDK.

### Scope

- P5-01: XPC service template and Orin entitlements for plugin hosting
- P5-02: Plugin manifest schema and `PluginRecord` SwiftData model
- P5-03: `OrinPluginAPI` protocol + XPC bridge implementation
- P5-04: `IntentRouter` for plugin-to-core communication
- P5-05: `PluginRegistryService` + lifecycle management
- P5-06: Plugin Settings UI (install, enable, disable, permission review)
- P5-07: First-party plugin: Linear Integration
- P5-08: First-party plugin: Notion Integration
- P5-09: First-party plugin: Slack Integration
- P5-10: Plugin developer SDK documentation and example plugin

### Exit Criteria

- [ ] Linear plugin creates a Linear issue from each `AnalysisCompleted` action item
- [ ] Plugin crash does not affect live recording (verified by force-crashing plugin XPC service)
- [ ] Plugin network access is restricted to declared domains (App Sandbox test)
- [ ] Plugin Settings UI shows installed plugins, their capabilities, and revoke controls

---

## Phase 6: Cross-Platform (Ongoing)

### Objective

Windows POC → Windows GA → iOS → Android, gated on Phase 3 (OrinCore package extraction).

### Gate Check Before Starting

All Phase 3 exit criteria must be met. Specifically:
- [ ] `OrinCore` Swift Package builds with zero platform imports
- [ ] All 8 port protocols are defined and all macOS adapters implement them
- [ ] `OrinCoreTests` passes at ≥ 80% coverage

### Windows POC (Phase 6a, 6 months)

- WASAPI audio capture adapter (Swift on Windows)
- GRDB persistence adapter
- Windows STT ASR adapter + WhisperASRBackend (reuse from Phase 3)
- OllamaInferenceAdapter (reuse from Phase 1)
- WinUI 3 basic UI (meeting list + recording control)

### iOS Beta (Phase 6b, 4 months, parallel with Windows)

- `AVAudioSession` mic adapter (reuse mic pattern from macOS)
- `CallKit` meeting detector adapter
- `BGProcessingTask` for analysis
- SwiftUI shared components from macOS
- iCloud sync tested cross-device

### Android (Phase 6c, 8 months)

- OrinCore Kotlin Multiplatform reimplementation
- `AudioRecord` audio adapter
- `Room` persistence adapter
- `Gemini Nano` inference adapter
- Jetpack Compose UI

---

## Migration Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|-----------|
| `RecordingService` split breaks audio pipeline | Medium | Critical | Step-by-step extraction with manual audio test after each step |
| `SessionStateMachine` exposes existing invalid transition in production path | Medium | High | Static analysis before introducing; fix all violations before deploying |
| OrinCore package extraction introduces circular dependency | High | Medium | Dependency graph audit before starting P3-01 |
| Multilingual prompt change degrades English analysis quality | Low | High | A/B test on reference meeting library before shipping |
| Phase 0 InferenceWorker increases analysis wall-clock time noticeably | High | Medium | Communicate change to users; progressive result delivery mitigates perception |
| SwiftData migration (VocabularyItem, corrections) corrupts existing data | Low | Critical | Run migration in background; keep old model until migration verified |
| Whisper HTTP server adoption friction | High | Medium | Clear Settings onboarding; optional (falls back to SpeechTranscriber for English) |

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| Phase 0 before any architecture work | Critical audio defects must not ship; ordering non-negotiable |
| Protocols in Phase 1 before OrinCore extraction | Protocol boundaries must be stable before package split; otherwise the split moves too much at once |
| Events as side effects before replacing direct calls | Preserves existing behaviour while incrementally migrating subscribers |
| Learning engine in Phase 4, not Phase 2 | No user data to learn from until core stability is resolved; building a learning system on an unstable foundation wastes effort |
| Plugin system in Phase 5 | No external plugin developers until OrinCore API is stable (Phase 3+) |
