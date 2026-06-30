# Document M-06: Service Ownership Matrix

**Series**: Orin V2 Migration Planning  
**Document**: 6 of 8  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Overview

This document maps every current service, provider, and significant source file to exactly one V2 bounded context. Services that currently violate bounded-context boundaries are identified as ownership violations. The target state is one owner per service, with all cross-context communication flowing through the `EventBus` or via protocol injection.

**V2 Reference**: Document 01 (Product Domain Architecture — 10 bounded contexts, 14 domain invariants)

### V2 Bounded Contexts

| ID | Context | Type | Responsibility |
|----|---------|------|---------------|
| BC-01 | Session | Core | Recording session lifecycle |
| BC-02 | Transcription | Core | Speech-to-text, segment management |
| BC-03 | Intelligence | Core | AI analysis, action items, decisions |
| BC-04 | Knowledge | Core | Entity graph, cross-meeting relationships |
| BC-05 | Learning | Supporting | Corrections, vocabulary promotion, decay |
| BC-06 | Vocabulary | Supporting | Term management, language packs |
| BC-07 | Identity | Supporting | Participant detection, diarization |
| BC-08 | Observability | Supporting | Metrics, logging, diagnostics |
| BC-09 | Plugin | Generic | Third-party extension sandbox |
| BC-10 | Integration | Generic | Calendar, accessibility, notifications |

---

## Current Service Inventory

### Sources/Orin/Services/

| File | Lines | Assigned Context | Owner BC | V1 Violations |
|------|-------|-----------------|----------|---------------|
| `RecordingService.swift` | 1,355 | Session | BC-01 | **VIOLATION**: contains audio engine logic (BC-01), ASR management (BC-02), participant handling (BC-07), analysis trigger (BC-03) — god object, 4 contexts in one file |
| `MeetingIntelligenceService.swift` | 1,010 | Intelligence | BC-03 | **VIOLATION**: builds ASR vocabulary context (BC-06 responsibility); reads and writes `MeetingItem` directly (should use PersistenceStore) |
| `TranscriptStore.swift` | ~250 | Transcription | BC-02 | **VIOLATION**: calls `context.save()` on `@MainActor`; references `MeetingItem` (BC-03 model) directly |
| `AIService.swift` | ~200 | Intelligence | BC-03 | None (correctly scoped to inference) |
| `AIProviderTestService.swift` | ~100 | Intelligence | BC-03 | **VIOLATION**: performs health check without cache (BC-08 concern); polls on every call |
| `MeetingDetectorService.swift` | ~150 | Integration | BC-10 | None (correctly uses `MeetingDetectorProvider` protocol) |
| `VocabularyProvider.swift` | ~200 | Vocabulary | BC-06 | **VIOLATION**: vocabulary terms stored in `UserDefaults` (no SwiftData model — BC-06 should own its persistence) |
| `FeatureFlags.swift` | ~50 | — (cross-cutting) | — | **VIOLATION**: reads `UserDefaults` directly; not injected; not testable; shared state |
| `HealthCheckService.swift` | ~100 | Observability | BC-08 | None |
| `MeetingDataService.swift` | ~150 | Intelligence | BC-03 | **VIOLATION**: filter/search logic belongs to BC-04 (Knowledge) once knowledge graph exists; currently co-located with analysis |
| `AnalysisPerfLogger.swift` | ~150 | Observability | BC-08 | None |
| `SessionLogger.swift` | ~100 | Observability | BC-08 | None |
| `WhisperTranscriptionService.swift` | stub | Transcription | BC-02 | **VIOLATION**: stub only; BC-02 unimplemented |
| `MeetingRetentionService.swift` | ~100 | Session | BC-01 | **VIOLATION**: actor isolation issue (TICKET-001); shared mutable state |
| `DebugResetService.swift` | ~50 | Observability | BC-08 | Minor: mixes debug commands with observability |

### Sources/Orin/Providers/Protocols/

| File | Assigned Context | Owner BC | V1 Violations |
|------|-----------------|----------|---------------|
| `CalendarProvider.swift` | Integration | BC-10 | None |
| `AccessibilityProvider.swift` | Integration | BC-10 | None |
| `SystemAudioProvider.swift` | Session | BC-01 | **VIOLATION**: naming mismatch — V2 calls this `AudioCaptureProvider`; must rename (EPIC-08) |
| `MeetingDetectorProvider.swift` | Integration | BC-10 | **VIOLATION**: naming mismatch — V2 calls this `MeetingDetector`; must rename (EPIC-08) |
| `DiarizationProvider.swift` | Identity | BC-07 | None |
| `NotificationProvider.swift` | Integration | BC-10 | None |
| `OverlayProvider.swift` | Integration | BC-10 | None |

### Sources/Orin/Providers/macOS/

| File | Assigned Context | Owner BC | V1 Violations |
|------|-----------------|----------|---------------|
| `EventKitCalendarProvider.swift` | Integration | BC-10 | None |
| `AXAccessibilityProvider.swift` | Integration | BC-10 | None |
| `SCKitSystemAudioProvider.swift` | Session | BC-01 | **VIOLATION**: naming mismatch — V2 calls this `SCKitSystemAudioAdapter` |
| `SpeechTranscriber.swift` | Transcription | BC-02 | None (implementation detail; will be wrapped in EPIC-05) |
| `RecognitionDiagnostics.swift` | Observability | BC-08 | **VIOLATION**: uses NSLock on RT audio path (TD-C02); atomic operation required |
| `SystemAudioCaptureService.swift` | Session | BC-01 | **VIOLATION**: hardcoded `en-US` locale (TD-H01); should read from `VocabularyProvider.speechLocale` |

### Sources/Orin/App/

| File | Assigned Context | Owner BC | V1 Violations |
|------|-----------------|----------|---------------|
| `ServiceContainer.swift` | — (infrastructure) | — | **VIOLATION**: service locator anti-pattern; not thread-safe; `fatalError` on miss — delete (EPIC-07) |
| `OrinApp.swift` | — (composition root) | — | Will become composition root in EPIC-07 |

### Sources/Orin/Models/

| File | Assigned Context | Owner BC | V1 Violations |
|------|-----------------|----------|---------------|
| `OrinModels.swift` | — (shared models) | — | **VIOLATION**: all domain models in one file; `MeetingItem.analysisStatus` is a stringly-typed String; no `@Attribute(.externalStorage)` on large fields; all models shared across all contexts (breaks bounded context encapsulation) |

### Sources/Orin/Views/

| File | Assigned Context | Owner BC | V1 Violations |
|------|-----------------|----------|---------------|
| `MeetingsView.swift` | Intelligence | BC-03 | **VIOLATION**: `@Query` over all meetings with no predicate (TD-H06); large dataset load |
| `TranscriptDetailView.swift` | Transcription | BC-02 | None |
| `SettingsView.swift` | Cross-cutting | — | None |
| `OverlayView.swift` | Integration | BC-10 | None |

---

## Ownership Violations Register

| ID | File | Violation | Owning Epic |
|----|------|-----------|------------|
| OV-01 | `RecordingService.swift` | Audio engine (BC-01), ASR management (BC-02), participant handling (BC-07), analysis trigger (BC-03) in one file | EPIC-14 |
| OV-02 | `MeetingIntelligenceService.swift` | Builds ASR vocabulary context (BC-06); direct `ModelContext` writes (should be BC-02 + PersistenceStore) | EPIC-17 |
| OV-03 | `TranscriptStore.swift` | `context.save()` on @MainActor; direct `MeetingItem` (BC-03 model) access | EPIC-06, EPIC-15 |
| OV-04 | `AIProviderTestService.swift` | Health check without cache; BC-08 concern leaking into BC-03 | EPIC-04 (add cache) |
| OV-05 | `VocabularyProvider.swift` | Vocabulary terms in `UserDefaults` (no BC-06 persistence model) | EPIC-21 |
| OV-06 | `FeatureFlags.swift` | Global mutable `UserDefaults` reads; no injection; breaks all bounded context isolation | EPIC-08 |
| OV-07 | `MeetingDataService.swift` | Filter/search co-located with BC-03; should migrate to BC-04 (Knowledge) | EPIC-22 |
| OV-08 | `ServiceContainer.swift` | Anti-pattern; no thread safety; `fatalError`; global shared state | EPIC-07 |
| OV-09 | `OrinModels.swift` | All models in one file; no context encapsulation; no `@Attribute(.externalStorage)` | EPIC-06, EPIC-13 |
| OV-10 | `SystemAudioCaptureService.swift` | Hardcoded `en-US` (BC-06 locale decision); violation of BC-01/BC-06 boundary | EPIC-19 |
| OV-11 | `MeetingRetentionService.swift` | Actor isolation violation (TICKET-001); shared mutable state in BC-01 service | EPIC-10 |
| OV-12 | `RecognitionDiagnostics.swift` | NSLock on RT audio path (BC-08 code violating BC-01 RT constraint) | EPIC-01 |
| OV-13 | `SystemAudioProvider.swift` | Protocol naming mismatch vs. V2 spec | EPIC-08 |
| OV-14 | `MeetingDetectorProvider.swift` | Protocol naming mismatch vs. V2 spec | EPIC-08 |
| OV-15 | `MeetingsView.swift` | `@Query` over all meetings (no BC-03 scope); performance violation | EPIC-15 |

**Total violations: 15**

---

## Target Ownership Map (V2)

The following table shows the target state after all migration epics complete. Each service/component is owned by exactly one bounded context.

### BC-01: Session Context

| Component | New Name | Notes |
|-----------|----------|-------|
| `RecordingSessionCoordinator` | `RecordingSessionCoordinator` | Orchestration only; no audio/ASR logic |
| `SessionStateMachine` | `SessionStateMachine` | New actor (EPIC-12) |
| `MeetingRetentionService` | `MeetingRetentionService` | After EPIC-10 fix |
| `AVAudioEngineAdapter` | `AVAudioEngineAdapter` | Wraps AVAudioEngine; new (EPIC-09) |
| `SCKitSystemAudioAdapter` | `SCKitSystemAudioAdapter` | Renamed from `SCKitSystemAudioProvider` (EPIC-08) |

### BC-02: Transcription Context

| Component | New Name | Notes |
|-----------|----------|-------|
| `SpeechTranscriberASRAdapter` | `SpeechTranscriberASRAdapter` | Wraps `SpeechTranscriber` (EPIC-05) |
| `SFSpeechASRAdapter` | `SFSpeechASRAdapter` | New (EPIC-05) |
| `WhisperASRBackend` | `WhisperASRBackend` | Implemented in EPIC-20 |
| `ASRSessionStateMachine` | `ASRSessionStateMachine` | New actor (EPIC-16) |
| `ASRBackendRouter` | `ASRBackendRouter` | New (EPIC-19) |
| `TranscriptStore` | `TranscriptStore` | After EPIC-06 (no @MainActor writes) |

### BC-03: Intelligence Context

| Component | New Name | Notes |
|-----------|----------|-------|
| `AnalysisCoordinator` | `AnalysisCoordinator` | Split from MIS (EPIC-17) |
| `PromptBuilder` | `PromptBuilder` | New (EPIC-17) |
| `ResponseParser` | `ResponseParser` | New (EPIC-17) |
| `InferenceWorker` | `InferenceWorker` | New actor (EPIC-02) |
| `OllamaInferenceAdapter` | `OllamaInferenceAdapter` | Wraps `AIService` (EPIC-04) |
| `AIService` | `AIService` | Demoted to implementation detail of adapter |

### BC-04: Knowledge Context

| Component | New Name | Notes |
|-----------|----------|-------|
| `KnowledgeGraph` | `KnowledgeGraph` | New actor (EPIC-22) |
| `NLTaggerEntityExtractor` | `NLTaggerEntityExtractor` | New (EPIC-22) |
| `EntityResolver` | `EntityResolver` | New (EPIC-22) |
| `KnowledgeQueryService` | `KnowledgeQueryService` | New (EPIC-22); absorbs search from `MeetingDataService` |

### BC-05: Learning Context

| Component | New Name | Notes |
|-----------|----------|-------|
| `CorrectionStore` | `CorrectionStore` | New SwiftData model + service (EPIC-23) |
| `PromotionEngine` | `PromotionEngine` | New (EPIC-23) |
| `DecayEngine` | `DecayEngine` | New (EPIC-24) |
| `MeetingPatternLearner` | `MeetingPatternLearner` | New (EPIC-24) |

### BC-06: Vocabulary Context

| Component | New Name | Notes |
|-----------|----------|-------|
| `VocabularyProvider` | `VocabularyProvider` | After EPIC-21 (backed by SwiftData not UserDefaults) |
| `VocabularyContext` | `VocabularyContext` | New (EPIC-21); replaces `.prefix(100)` truncation |
| `LanguagePack` | `LanguagePack` | New model (EPIC-21) |
| `VocabularyItem` | `VocabularyItem` | New SwiftData model (EPIC-21) |

### BC-07: Identity Context

| Component | New Name | Notes |
|-----------|----------|-------|
| `DiarizationProvider` | `DiarizationProvider` | Protocol exists; adapter to be implemented (Phase 5+) |

### BC-08: Observability Context

| Component | New Name | Notes |
|-----------|----------|-------|
| `AnalysisPerfLogger` | `AnalysisPerfLogger` | Migrated to EventBus subscriber (EPIC-11) |
| `SessionLogger` | `SessionLogger` | Migrated to EventBus subscriber (EPIC-11) |
| `HealthCheckService` | `HealthCheckService` | Provider health check; 10s cache added (EPIC-04) |
| `RecognitionDiagnostics` | `RecognitionDiagnostics` | After EPIC-01 (OSAtomic, not NSLock) |
| `ProviderHealthCache` | `ProviderHealthCache` | New (EPIC-04) |

### BC-10: Integration Context

| Component | New Name | Notes |
|-----------|----------|-------|
| `EventKitCalendarProvider` | `EventKitCalendarProvider` | No change |
| `AXAccessibilityProvider` | `AXAccessibilityProvider` | No change |
| `MeetingDetectorService` | `MeetingDetectorService` | No change |
| `NotificationProvider` | `NotificationProvider` | No change |
| `OverlayProvider` | `OverlayProvider` | No change |

### Infrastructure (cross-cutting, no BC owner)

| Component | Notes |
|-----------|-------|
| `OrinApp.swift` | Composition root after EPIC-07 |
| `SwiftDataPersistenceAdapter` | New; implements `PersistenceStore`; owned by infrastructure layer |
| `EventBus` | Single global actor; infrastructure layer |
| `FeatureFlagStore` (protocol) | Injectable; backed by `UserDefaults` in production; mock in tests |

---

## Cross-Context Communication Rules

All cross-context calls must use one of these mechanisms:

| From BC | To BC | Allowed mechanism | Prohibited |
|---------|-------|------------------|-----------|
| BC-01 Session | BC-02 Transcription | Inject `ASRBackend` protocol; emit `SessionStarted` | Direct call to SpeechTranscriber |
| BC-01 Session | BC-03 Intelligence | Emit `SessionFinalized` via EventBus | Direct call to `AnalysisCoordinator` |
| BC-02 Transcription | BC-01 Session | Emit `TranscriptFinalized` via EventBus | Retain reference to `RecordingSessionCoordinator` |
| BC-02 Transcription | BC-06 Vocabulary | Inject `VocabularyProvider` via `ASRBackend.prepare(vocabulary:)` | Direct import of `VocabularyProvider` |
| BC-03 Intelligence | BC-06 Vocabulary | Inject `VocabularyProvider` into `PromptBuilder` for language detection | Direct import of vocabulary storage |
| BC-03 Intelligence | BC-04 Knowledge | Emit `AnalysisCompleted` via EventBus | Direct call to `KnowledgeGraph` |
| BC-04 Knowledge | BC-05 Learning | Emit `EntityLinked` via EventBus | Import `CorrectionStore` |
| BC-05 Learning | BC-06 Vocabulary | Emit `VocabularyPromotionAccepted` → `VocabularyProvider` subscribes | Direct mutation of vocabulary storage |
| Any BC | BC-08 Observability | Emit observability events via EventBus | Direct import of `SessionLogger` |
| Any BC | BC-10 Integration | Inject provider protocol at composition root | Access `EventKitCalendarProvider` directly |

---

## Violation Priority for Remediation

| Priority | Violation IDs | Reason |
|----------|-------------|--------|
| P0 (Critical) | OV-12 (RecognitionDiagnostics NSLock), OV-01 (RecordingService god object) | Active crash / freeze risk |
| P1 (High) | OV-08 (ServiceContainer), OV-09 (OrinModels shared), OV-10 (hardcoded locale) | Blocks all protocol work |
| P2 (Medium) | OV-02 (MIS context bleed), OV-03 (TranscriptStore @MainActor), OV-05 (VocabularyProvider no model), OV-06 (FeatureFlags global) | Blocks Phase 2+ work |
| P3 (Low) | OV-04, OV-07, OV-11, OV-13, OV-14, OV-15 | Correctness and naming cleanup |
