# Document M-01: Architecture Gap Analysis

**Series**: Orin V2 Migration Planning  
**Document**: 1 of 8  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Overview

This document maps every V2 architecture requirement (Documents 01–13 in `docs/architecture-v2/`) against the current V1 implementation. For each domain, it identifies what exists, what is missing, what can be reused, and what must be deprecated or replaced.

**Source of truth**: `docs/architecture-v2/` for the target. `Sources/Orin/` for the current state.

---

## Gap Analysis by Domain

### 1. Product Domain Architecture (V2 Doc 01)

**Target**: 10 bounded contexts with explicit ownership, domain invariants, domain events, and a ubiquitous language.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| Bounded context boundaries | 10 contexts, each owns its data | Single monolith; `ServiceContainer` wires everything together | **Full gap** — no context boundaries enforced |
| Session Context | `SessionStatus` enum, `SessionStateMachine` actor | Boolean flags: `isRecording`, `phase` enum in `RecordingService` | **Partial** — `phase` enum exists but is not a guarded state machine |
| Transcription Context | Owns `TranscriptSegment`, immutable once final | `TranscriptStore` owns segments; segments are `@Model` (mutable) | **Partial** — mutable when they must be immutable |
| Intelligence Context | `MeetingIntelligenceService`, `InferenceWorker`, `AnalysisJobQueue` | `MeetingIntelligenceService` exists; `InferenceWorker` and `AnalysisJobQueue` missing | **Partial** — core service exists, concurrency control absent |
| Knowledge Context | `KnowledgeGraph`, `EntityExtractor`, `KnowledgeNode`, `KnowledgeEdge` | Not implemented | **Full gap** |
| Learning Context | `CorrectionStore`, `PromotionEngine`, `DecayEngine` | Not implemented | **Full gap** |
| Vocabulary Context | `VocabularyProfile`, `VocabularyContext` builder, `LanguagePack` | `VocabularyProvider` (142 lines, 103 terms, no language namespace) | **Partial** — exists but far from target |
| Identity Context | `User`, `Organization`, `Contact` domain objects | `CalendarService`, `EventKitCalendarProvider` exist | **Partial** — calendar integration exists, identity model absent |
| Observability Context | `EventBus`-aware passive telemetry, `PerformanceBudgetViolation` events | `SessionLogger`, `AnalysisPerfLogger`, `RecognitionDiagnostics` | **Partial** — ad-hoc logging exists, structured observability absent |
| Plugin Context | XPC plugin registry, capability system | Not implemented | **Full gap** |
| Integration Context | Webhook, export, external connections | Not implemented | **Full gap** |
| Domain invariants | 14 coded invariants (INV-001 through INV-014) | Not enforced in code | **Full gap** |
| Ubiquitous language | 18-term glossary in codebase | Mixed terminology (e.g., "meeting" vs "session" used interchangeably) | **Partial** |

**Reusable**: `RecordingService.phase` enum, `MeetingIntelligenceService`, `CalendarService`, `TranscriptStore`.  
**Deprecate**: Nothing yet — wrap in protocols first, then deprecate concretions.  
**Estimated effort**: 16 weeks (entire Phase 2 sprint).

---

### 2. Event-Driven Architecture (V2 Doc 02)

**Target**: An `EventBus` actor with in-process domain event dispatch; XPC bridge for plugins; a complete 40+ event catalogue.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| `EventBus` actor | In-process actor-based event bus | Does not exist | **Full gap** |
| Domain event types | 40+ typed `DomainEvent` structs | Does not exist | **Full gap** |
| Publisher/subscriber pattern | Typed subscriptions by event type | Services call each other directly | **Full gap** |
| XPC plugin bridge | Tier-2 event delivery to plugins | Does not exist | **Full gap** |
| Durable events | EventStore for events requiring persistence | Does not exist | **Full gap** |
| Back-pressure handling | Per-subscriber bounded buffers | Not applicable (no event bus) | **Full gap** |
| Observability hooks | Event throughput metrics | Not applicable | **Full gap** |

**Reusable**: Nothing directly. The event catalogue (Document 02) was designed to match what the current services already do — each existing direct call becomes an event.  
**Estimated effort**: 6 weeks to introduce `EventBus` + emit first events as side effects alongside existing direct calls.

---

### 3. Core Architecture V2 (V2 Doc 03)

**Target**: Hexagonal architecture with `OrinCore` Swift Package (zero platform imports), `OrinMacOS` adapter layer, and a composition-root dependency injection replacing `ServiceContainer`.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| `OrinCore` Swift Package | Zero platform imports; portable to Windows/Android | Single Xcode target; all code in `Sources/Orin/` | **Full gap** — no package extraction yet |
| Hexagonal ports (protocols) | 8 protocols: `AudioCaptureProvider`, `SystemAudioCaptureProvider`, `ASRBackend`, `InferenceProvider`, `PersistenceStore`, `CalendarProvider`, `MeetingDetector`, `SyncProvider` | 5 of 8 exist partially: `CalendarProvider` ✓, `AccessibilityProvider` ✓, `SystemAudioProvider` ✓ (wrong name), `MeetingDetectorProvider` ✓, `DiarizationProvider` ✓ | **Partial** — some protocols exist; `ASRBackend`, `InferenceProvider`, `PersistenceStore`, `SyncProvider` absent |
| `AudioCaptureProvider` | Protocol for mic capture | Not defined | **Full gap** |
| `ASRBackend` | Protocol for speech recognition | Not defined; `SpeechTranscriber` and `SFSpeechRecognizer` used directly | **Full gap** |
| `InferenceProvider` | Protocol for AI inference | Not defined; `AIService` calls Ollama directly | **Full gap** |
| `PersistenceStore` | Protocol abstracting SwiftData | Not defined; SwiftData used directly | **Full gap** |
| `SyncProvider` | Protocol for multi-device sync | Not defined | **Full gap** |
| Composition root | `OrinApp.init()` wires all adapters | `ServiceContainer.shared` service locator, no thread safety, `fatalError` on failed resolve | **Full gap** — ServiceContainer must be replaced |
| Adapter layer (`OrinMacOS`) | Wraps all platform APIs in protocol adapters | Concrete implementations exist but not wrapped | **Partial** — concretions exist; need protocol wrapping |
| `RecordingSessionCoordinator` | Orchestrates session without business logic | `RecordingService` (1,355 lines) mixes orchestration and business logic | **Partial** — must be split |

**Reusable**: `AVAudioEngine` code in `RecordingService`, `ScreenCaptureKit` code in `SystemAudioCaptureService`, `EventKitCalendarProvider`, `MeetingDetectorService` core detection logic.  
**Deprecate**: `ServiceContainer.swift` (replace with composition root).  
**Estimated effort**: 12 weeks for package extraction + all adapter wrapping.

---

### 4. State Machine Architecture (V2 Doc 04)

**Target**: Six explicit state machines replacing all boolean flag combinations; actor-owned, compiler-enforced.

| State Machine | V2 Requirement | Current State | Gap |
|---------------|---------------|--------------|-----|
| Session SM | `SessionStatus` enum with 13 states + `SessionStateMachine` actor | `RecordingService.phase` (6 states: `.idle`, `.starting`, `.recording`, `.stopping`, `.stopping`, `.finalising`) + `isRecording` boolean | **Partial** — partial states, no guard enforcement, no actor isolation |
| Analysis SM | `AnalysisStatus` (8 states) on `MeetingItem` | `MeetingItem.analysisStatus` string field exists; transitions unguarded | **Partial** — field exists, state machine logic absent |
| InferenceWorker SM | `InferenceWorkerState` (5 states), circuit breaker | Does not exist | **Full gap** |
| ASR Session SM | `ASRSessionState` (7 states), watchdog timer | Generation counter in `RecordingService` (race-prone, not a state machine) | **Partial** — generation counter addresses restart but lacks state encoding |
| Plugin Lifecycle SM | `PluginState` (8 states) | Plugin system does not exist | **Full gap** |
| Vocabulary Session SM | 4 states (Building → Ready → Stale → Rebuilt) | Vocabulary built once at session start; no stale/rebuild path | **Partial** — initial build exists; stale/rebuild absent |

**Reusable**: `RecordingService.phase` transitions (map to Session SM states). `MeetingItem.analysisStatus` string field (replace with typed enum).  
**Deprecate**: `isRecording` boolean, `generationHadSpeech` boolean, separate `isCapturing` booleans.  
**Estimated effort**: 4 weeks for Session + Analysis state machines; 6 weeks for full suite.

---

### 5. AI Orchestration Architecture (V2 Doc 05)

**Target**: `InferenceWorker` actor serializing all local inference; `AnalysisJobQueue` serializing multi-meeting analysis; `InferenceProvider` protocol abstracting AI backend; circuit breaker; health check caching.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| `InferenceWorker` actor | Serial job queue, one job at a time | Does not exist — `withTaskGroup` parallelizes all chunks | **Critical gap** — root cause of system freeze |
| `AnalysisJobQueue` actor | Per-meeting queue | Does not exist | **Full gap** |
| `InferenceProvider` protocol | Model-agnostic AI backend | `AIService` class calls Ollama HTTP directly, hardcoded model IDs | **Full gap** |
| `OllamaInferenceAdapter` | Wraps AIService HTTP calls | `AIService` (281 lines) provides HTTP client | **Partial** — logic reusable, needs wrapping |
| `ModelRouter` | Provider selection strategy | Not defined; AIService selects Ollama by hardcoded URL | **Full gap** |
| Health check caching | `ProviderHealthCache`, 10s TTL | `AIProviderTestService` does connectivity check but not cached | **Partial** — check exists, caching absent |
| `PromptStrategy` protocol | Meeting-type-specific prompt building | Monolithic `buildComprehensivePrompt()` in `MeetingIntelligenceService` | **Partial** — prompt logic exists, not protocolized |
| Progressive result delivery | `AsyncStream<InferenceToken>` | Results delivered only after full analysis | **Full gap** |
| Circuit breaker | 3 failures → CircuitOpen | Not implemented | **Full gap** |
| Hallucination detection | Off-@MainActor comparison | Runs on @MainActor (performance defect) | **Partial** — logic exists, wrong thread |
| Synthesis | Separate synthesis call after all chunks | Single call combines chunks | **Partial** — approach exists, not separated cleanly |

**Reusable**: `AIService` HTTP client code, `TranscriptChunker` (645 lines, reusable directly), `MeetingIntelligenceService` prompt construction logic, `AnalysisPerfLogger`.  
**Deprecate**: `withTaskGroup` unbounded parallelism pattern in `MeetingIntelligenceService.analyzeChunked()`.  
**Estimated effort**: 6 weeks for InferenceWorker + InferenceProvider + refactor MeetingIntelligenceService.

---

### 6. Learning Engine Architecture (V2 Doc 06)

**Target**: `CorrectionStore`, `PromotionEngine`, `DecayEngine`, `MeetingPatternLearner`, `AnalysisFeedbackProcessor`.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| `CorrectionStore` | SwiftData model for transcript corrections | Does not exist | **Full gap** |
| `PromotionEngine` | Algorithm: frequency ≥ 3 → suggest promotion | Does not exist | **Full gap** |
| `DecayEngine` | Daily decay of vocabulary items | Does not exist | **Full gap** |
| `VocabularyItem` SwiftData model | Tiered, language-namespaced, with decayScore | Not in SwiftData; vocabulary is a hardcoded array in `VocabularyProvider` | **Full gap** |
| `MeetingPatternLearner` | Bayesian meeting type pattern update | Does not exist | **Full gap** |
| `AnalysisFeedbackProcessor` | Records user feedback on analysis quality | Does not exist | **Full gap** |

**Reusable**: Nothing from V1 for this domain.  
**Estimated effort**: 8 weeks for full Learning Engine. Lower-priority than core infrastructure fixes.

---

### 7. Multilingual Architecture (V2 Doc 07)

**Target**: `ASRBackend` protocol; `ASRBackendRouter`; per-channel locale independence; `NLLanguageRecognizer` post-recording detection; language-parameterized AI prompts; `LanguagePack` system; `WhisperASRBackend`.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| `ASRBackend` protocol | Platform-agnostic speech recognition | Not defined; SpeechTranscriber + SFSpeechRecognizer used directly | **Full gap** |
| `SpeechTranscriberASRBackend` | Wraps `SpeechTranscriber` | `RecordingService` calls `SpeechTranscriber` directly | **Partial** — logic reusable, wrap needed |
| `SFSpeechASRBackend` | Wraps `SFSpeechRecognizer` | `RecordingService` calls `SFSpeechRecognizer` directly | **Partial** — logic reusable, wrap needed |
| `WhisperASRBackend` | Connects to whisper.cpp HTTP server | `WhisperTranscriptionService` exists as **stub only** (no real implementation) | **Stub** — must implement |
| `ASRBackendRouter` | Selects best backend for locale | Not defined | **Full gap** |
| Mic channel locale | Reads `VocabularyProvider.speechLocale` | **Hardcoded `en-IN`** in `RecordingService` | **Violation** |
| System audio channel locale | Reads user preference | **Hardcoded `en-US`** in `SystemAudioCaptureService` | **Violation** |
| Per-channel locale independence | Each channel gets its own `ASRBackend` instance | Same hardcoded locale on both channels | **Full gap** |
| Language detection | `NLLanguageRecognizer` post-recording | Not implemented | **Full gap** |
| Language-parameterized prompts | `responseLanguage` parameter in prompt builder | `buildComprehensivePrompt()` has hardcoded English headers | **Violation** |
| Language-neutral section markers | `[SUMMARY]`, `[ACTION_ITEMS]`, etc. | `parseComprehensiveResponse()` parses English keywords | **Violation** |
| `LanguagePack` system | Downloadable per-language vocabulary | Single hardcoded array in `VocabularyProvider` | **Full gap** |

**Reusable**: `VocabularyProvider` terms (migrate to `LanguagePack` en + hi-Latn). Existing SpeechTranscriber integration in `RecordingService` lines 200-650.  
**Estimated effort**: 10 weeks for full multilingual architecture including Whisper.

---

### 8. Knowledge Graph Architecture (V2 Doc 08)

**Target**: SQLite adjacency list; `KnowledgeNode`, `KnowledgeEdge`, `Fact` models; `EntityExtractor` protocol; `EntityResolver`; `KnowledgeQueryService`.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| `KnowledgeNode` / `KnowledgeEdge` / `Fact` | SQLite adjacency list schema | Does not exist | **Full gap** |
| `EntityExtractor` | `NLTaggerEntityExtractor` + `LLMEntityExtractor` | Does not exist | **Full gap** |
| `EntityResolver` | Disambiguation of extracted entities | Does not exist | **Full gap** |
| `KnowledgeQueryService` | Query API for all bounded contexts | Does not exist | **Full gap** |
| Knowledge graph build migration | Background processing of existing meetings | N/A (first-time build) | **Full gap** |

**Reusable**: `NaturalLanguage` framework is already imported in the project (check).  
**Estimated effort**: 10 weeks. Knowledge graph is a significant new subsystem, not a refactor.

---

### 9. Plugin & Extension SDK (V2 Doc 09)

**Target**: XPC plugin sandboxing; plugin manifest; `PluginRecord` SwiftData model; `OrinPluginAPI` protocol; `IntentRouter`; Plugin Marketplace distribution.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| XPC plugin architecture | All of it | Does not exist | **Full gap** |
| Plugin capability system | All of it | Does not exist | **Full gap** |
| `IntentRouter` | Registers and routes `UserIntent` | `OrinAppIntents.swift` has App Intents (Siri) | **Partial** — App Intents infrastructure exists, not the internal Intent router |

**Reusable**: `OrinAppIntents.swift` patterns (App Intents are the iOS equivalent of the intent system).  
**Estimated effort**: 12 weeks. Phase 3 work.

---

### 10. Cross-Platform Architecture (V2 Doc 10)

**Target**: `OrinCore` Swift Package; adapter matrix per platform; Windows/iOS/Android adapters.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| `OrinCore` Swift Package | Zero platform imports, portable | Single Xcode target | **Full gap** (prerequisite for all other platforms) |
| macOS adapters | Protocol-wrapped existing concretions | Concretions exist unwrapped | **Partial** |
| Windows adapters | New implementations | Does not exist | Future work |
| iOS adapters | New implementations | Does not exist | Future work |
| Android (Kotlin) | OrinCore Kotlin Multiplatform | Does not exist | Future work |

**Estimated effort**: OrinCore extraction = 8 weeks. Subsequent platforms per Document 12 timeline.

---

### 11. Performance & Resource Budget (V2 Doc 11)

**Target**: All operations within defined budgets; zero RT-thread heap allocation; no IPC while holding audio locks.

| Defect | Budget | Current State | Severity |
|--------|--------|--------------|----------|
| Heap allocation in `TapState.feed()` | < 0.1ms | `AVAudioPCMBuffer` allocated per callback | CRITICAL |
| XPC while holding NSLock in `TapState.stop()` | Never on RT thread | `recognitionRequest?.endAudio()` called under lock | CRITICAL |
| Lazy `AVAudioConverter` init in `ParticipantSTFeed.feed()` | < 0.05ms | Lazy init may run on RT thread | HIGH |
| `Task.sleep(1.5s)` on `@MainActor` in `finalize()` | < 3s session stop | Deliberate 1.5s sleep blocking main actor | HIGH |
| `persistChunkIfNeeded context.save()` on `@MainActor` | Off main thread | Direct `context.save()` on main thread | HIGH |
| `allSegments @Query` loads all meetings | < 100ms | Unbounded @Query | HIGH |
| Ollama thundering herd | Sequential | 41 parallel requests | CRITICAL |
| `sampleCPUUsage()` Mach API in production | `#if DEBUG` only | Runs every 5s in production | MEDIUM |

---

### 12. Scalability Roadmap (V2 Doc 12)

**Target**: Design gates for Windows, iOS, Android; data volume design for 10k meetings; language priority queue.

| Component | V2 Requirement | Current State | Gap |
|-----------|---------------|--------------|-----|
| Data volume design | `@Attribute(.externalStorage)` on blobs | `MeetingItem.transcript` not tagged | **Violation** |
| Platform expansion gate | All macOS adapters behind protocols | Partial protocol coverage | **Partial** |
| AI model evolution gate | `InferenceProvider` protocol | Not defined | **Full gap** |

---

### 13. Architecture Decision Records (V2 Doc 13)

**Target**: 18 ADRs documented and accessible to all engineers.

| Requirement | Current State | Gap |
|-------------|--------------|-----|
| ADRs documented | Not documented | **Full gap** — `docs/architecture-v2/13-Architecture-Decision-Records.md` is the first formal ADR set |

---

## Gap Summary Table

| Domain | Overall Gap | Severity | Phase |
|--------|-------------|----------|-------|
| Bounded context boundaries | Full gap | Critical | Phase 2 |
| Event bus | Full gap | High | Phase 2 |
| Hexagonal / OrinCore package | Full gap | Critical | Phase 2-3 |
| State machines | Partial | Critical | Phase 1-2 |
| AI orchestration (InferenceWorker) | Partial — critical piece missing | Critical | Phase 1 |
| Learning engine | Full gap | Medium | Phase 3 |
| Multilingual (locale hardcoding) | Partial + violations | High | Phase 1-2 |
| Knowledge graph | Full gap | Medium | Phase 3 |
| Plugin system | Full gap | Low | Phase 3 |
| Cross-platform | Full gap | Low | Phase 3-4 |
| Performance defects | Multiple violations | Critical | Phase 1 |
| Scalability data design | Partial violation | High | Phase 1 |

---

## Existing Protocol Coverage (Positive Finding)

The codebase already has 5 meaningful protocols in `Sources/Orin/Providers/Protocols/`:
- `CalendarProvider` — directly maps to V2 `CalendarProvider` port
- `AccessibilityProvider` + `AudioActivityProvider` — maps to V2 detection adapter
- `SystemAudioProvider` — maps to V2 `SystemAudioCaptureProvider` (rename needed)
- `MeetingDetectorProvider` — maps to V2 `MeetingDetector` port (rename needed)
- `DiarizationProvider` / `SpeakerIdentificationProvider` — future port

**This is the strongest V1 asset for V2 migration.** The team has already adopted the protocol pattern for platform-specific adapters. The migration extends this pattern to the remaining domains (ASR, inference, persistence, sync).

---

## Code Quality by File

| File | Lines | Quality | V2 Reuse |
|------|-------|---------|----------|
| `RecordingService.swift` | 1,355 | Good @MainActor design, generation counter is problematic | Reuse audio engine code; extract state machine |
| `MeetingIntelligenceService.swift` | 1,010 | Good prompt logic; `withTaskGroup` pattern is the critical defect | Reuse prompt logic; replace concurrency pattern |
| `SystemAudioCaptureService.swift` | 909 | Solid SCKit integration; locale hardcoded | Reuse SCKit code; fix locale; wrap in adapter |
| `MeetingDetectorService.swift` | 816 | Complex but functional; @MainActor | Reuse detection logic; extract to adapter |
| `TranscriptStore.swift` | 579 | O(N²) save pattern; functional otherwise | Reuse; fix save batching |
| `TranscriptChunker.swift` | 645 | Good chunking logic; reusable as-is | **High reuse value** — move to OrinCore |
| `AIService.swift` | 281 | Thin HTTP client; reusable | Wrap as `OllamaInferenceAdapter` |
| `VocabularyProvider.swift` | 142 | Simplistic; prefix(100) bug | Replace with `LanguagePack` + `VocabularyContext` |
| `ServiceContainer.swift` | 23 | Service locator, no thread safety | **Deprecate and replace** with composition root |
| `FeatureFlags.swift` | ~50 | Functional; UserDefaults-based | Evolve to typed struct; keep approach |
| `WhisperTranscriptionService.swift` | ~80 | Stub only | **Implement** as `WhisperASRBackend` |
| `OrinModels.swift` | 659 | Core data models; generally good | Migrate to `@Attribute(.externalStorage)` where needed |
