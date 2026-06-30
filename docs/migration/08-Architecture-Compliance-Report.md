# Document M-08: Architecture Compliance Report

**Series**: Orin V2 Migration Planning  
**Document**: 8 of 8  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Overview

This document audits the current V1 codebase against all 13 V2 architecture documents. Each subsystem is scored:

- **Fully Compliant**: Implementation matches V2 spec; no gaps or violations
- **Partially Compliant**: Some V2 requirements met; gaps or violations identified
- **Non-Compliant**: V2 requirements not met; significant rework needed
- **Not Implemented**: Feature described in V2 spec has no V1 counterpart

---

## Audit Against Document 01: Product Domain Architecture

**V2 Reference**: `docs/architecture-v2/01-Product-Domain-Architecture.md`

### Bounded Context Isolation

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| Each service owned by exactly one bounded context | Violated — `RecordingService` spans 4 contexts; `MeetingIntelligenceService` spans 2 | ❌ |
| Cross-context communication via EventBus or protocol injection | Direct service-to-service calls throughout | ❌ |
| No shared mutable state across bounded context boundaries | `ServiceContainer.shared` violates this | ❌ |
| 10 bounded contexts fully implemented | 4 of 10 contexts have any implementation | Partial |

### Domain Invariants

| Invariant (from Document 01 §4) | V1 Status |
|--------------------------------|-----------|
| INV-001 Local-first processing | ✅ All AI inference is local (Ollama) |
| INV-002 Privacy-first data handling | ✅ No remote telemetry; all data on-device |
| INV-003 Offline-first operation | ✅ App functions without network |
| INV-004 Session atomicity | ❌ Crash mid-session → partial transcript, no recovery path |
| INV-005 Analysis idempotency | ❌ No guard on re-analysis; `Completed → Running` transition allowed |
| INV-006 Vocabulary determinism | ❌ Silent `.prefix(100)` truncation is non-deterministic across vocabulary edits |
| INV-007 Plugin sandboxing | ❌ Not implemented |
| INV-008 Cross-platform purity of domain layer | ❌ No `OrinCore` package; domain models import `SwiftData` (platform-specific) |
| INV-009 Event ordering | ❌ No EventBus; no ordering guarantees |
| INV-010 Actor isolation for all mutable state | ❌ Multiple race conditions documented in M-07 |

**Subsystem Score: Partially Compliant (3/10 invariants met; 4/10 bounded contexts implemented)**

---

## Audit Against Document 02: Event-Driven Architecture

**V2 Reference**: `docs/architecture-v2/02-Event-Driven-Architecture.md`

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| `EventBus` actor with Tier 1 in-process bus | Not implemented | ❌ |
| Tier 2 XPC bus for plugin events | Not implemented | ❌ |
| All domain events defined as value types | Not implemented | ❌ |
| All cross-context communication via EventBus | Not implemented (direct calls everywhere) | ❌ |
| Event subscription/unsubscription lifecycle | Not implemented | ❌ |
| Dead-letter queue for Critical-tier events | Not implemented | ❌ |
| Event ordering guarantees per causal chain | Not implemented | ❌ |
| `AnalysisPerfLogger` as EventBus subscriber | Direct call injection (not event-based) | ❌ |

**Subsystem Score: Non-Compliant (0/8 requirements met)**

> **Note**: The event-driven architecture is the single largest architectural gap in V1. It is a prerequisite for Phase 2 work and will unblock all other compliance gaps through EPIC-11.

---

## Audit Against Document 03: Core Architecture V2

**V2 Reference**: `docs/architecture-v2/03-Core-Architecture-V2.md`

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| Hexagonal architecture (ports and adapters) | 5 protocols exist; 2 need renaming; core logic mixed with adapters | Partial |
| `OrinCore` Swift Package with zero platform imports | Not implemented | ❌ |
| Platform-agnostic domain models | Models import `SwiftData` (platform-specific) | ❌ |
| `InferenceProvider` protocol | Not implemented (direct `AIService`) | ❌ |
| `ASRBackend` protocol | Not implemented (direct `SpeechTranscriber`) | ❌ |
| `PersistenceStore` protocol | Not implemented (direct `ModelContext`) | ❌ |
| `AudioCaptureProvider` protocol | Not implemented | ❌ |
| Constructor injection at composition root | `ServiceContainer` service locator used | ❌ |
| No `fatalError` in service resolution | `ServiceContainer.resolve()` has `fatalError` | ❌ |
| Protocol naming matches V2 spec | `SystemAudioProvider` and `MeetingDetectorProvider` need renaming | Partial |

**Subsystem Score: Partially Compliant (protocol foundation exists; core architecture not yet implemented)**

---

## Audit Against Document 04: State Machine Architecture

**V2 Reference**: `docs/architecture-v2/04-State-Machine-Architecture.md`

*(Full detail in M-07; summarized here)*

| State Machine | V1 Compliance |
|--------------|---------------|
| Session (13 states) | Non-Compliant — 4/13 states, 2/13 transitions |
| Analysis Status (8 states) | Non-Compliant — unguarded string field |
| InferenceWorker (5 states) | Not Implemented |
| ASR Session (7 states) | Non-Compliant — 2/7 states, 1 race condition |
| Plugin Lifecycle (8 states) | Not Implemented (Phase 5) |
| Vocabulary Session (4 states) | Non-Compliant — 0/4 states |

**Subsystem Score: Non-Compliant (0/6 state machines compliant; 2/6 partially implemented)**

---

## Audit Against Document 05: AI Orchestration Architecture

**V2 Reference**: `docs/architecture-v2/05-AI-Orchestration-Architecture.md`

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| `InferenceWorker` actor with serial job queue | Not implemented — `withTaskGroup` in use | ❌ |
| Circuit breaker (3-failure threshold) | Not implemented | ❌ |
| `InferenceProvider` protocol | Not implemented | ❌ |
| Configurable model IDs (not hardcoded) | Hardcoded `phi3` | ❌ |
| Language-aware prompts via `PromptBuilder` | Not implemented — prompts hardcoded in English | ❌ |
| Language-neutral section markers for parsing | Not implemented — parsing uses English keywords | ❌ |
| `structuredActionItemsJSON` as canonical output | ✅ Implemented (per M-03/prior session context) |
| `effectiveActionItemCount` | ✅ Implemented |
| Hallucination detection | Partial (some detection; not on background Task) |
| Dedup of action items | ✅ Implemented (anti-verbatim instructions applied) |
| Synthesis across chunks | Partial (single-pass, not multi-stage synthesis) |

**Subsystem Score: Partially Compliant (3/11 requirements met)**

---

## Audit Against Document 06: Learning Engine Architecture

**V2 Reference**: `docs/architecture-v2/06-Learning-Engine-Architecture.md`

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| `VocabularyCorrection` SwiftData model | Not implemented | ❌ |
| `CorrectionStore` actor | Not implemented | ❌ |
| Inline transcript correction UI | Not implemented | ❌ |
| `PromotionEngine` with frequency threshold | Not implemented | ❌ |
| `DecayEngine` with 0.98 daily decay | Not implemented | ❌ |
| Promotion suggestion UI in Settings | Not implemented | ❌ |
| `MeetingPatternLearner` | Not implemented | ❌ |
| Per-language correction tracking | Not implemented | ❌ |

**Subsystem Score: Not Implemented (0/8 requirements)**

---

## Audit Against Document 07: Multilingual Architecture

**V2 Reference**: `docs/architecture-v2/07-Multilingual-Architecture.md`

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| `ASRBackend` protocol (pluggable ASR) | Not implemented | ❌ |
| `ASRBackendRouter` (locale-based selection) | Not implemented | ❌ |
| Configurable speech locale (mic channel) | Hardcoded `en-US` | ❌ |
| Configurable speech locale (system audio channel) | Hardcoded `en-US` | ❌ |
| Whisper integration (hi-IN support) | Stub only | Partial |
| `LanguagePack` model for en and hi-Latn | Not implemented | ❌ |
| `VocabularyContext` with explicit tier allocation | Not implemented (`.prefix(100)` used) | ❌ |
| `NLLanguageRecognizer` post-recording detection | Not implemented | ❌ |
| Language-neutral section markers for parsing | Not implemented | ❌ |
| Hinglish (hi-Latn) term support | en-IN locale + 48 Hindi terms in vocabulary | Partial |
| 10-language roadmap in locale selector | Not implemented | ❌ |

**Subsystem Score: Partially Compliant (Hinglish vocabulary foundation exists; architecture missing)**

---

## Audit Against Document 08: Knowledge Graph Architecture

**V2 Reference**: `docs/architecture-v2/08-Knowledge-Graph-Architecture.md`

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| SQLite knowledge graph (adjacency list) | Not implemented | ❌ |
| `KnowledgeGraph` actor | Not implemented | ❌ |
| `NLTaggerEntityExtractor` | Not implemented | ❌ |
| `EntityResolver` | Not implemented | ❌ |
| `KnowledgeQueryService` | Not implemented | ❌ |
| Cross-meeting entity relationships | Not implemented | ❌ |
| Full-text search index | Not implemented | ❌ |
| Background migration of existing meetings | Not applicable | N/A |

**Subsystem Score: Not Implemented (0/7 requirements)**

---

## Audit Against Document 09: Plugin Extension SDK

**V2 Reference**: `docs/architecture-v2/09-Plugin-Extension-SDK.md`

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| XPC sandbox per plugin | Not implemented | ❌ |
| Capability system (read-only vs. write permissions) | Not implemented | ❌ |
| Plugin lifecycle state machine | Not implemented | ❌ |
| EventBus Tier 2 for plugin events | Not implemented | ❌ |
| Plugin SDK package | Not implemented | ❌ |

**Subsystem Score: Not Implemented (0/5 requirements; Phase 5 work)**

---

## Audit Against Document 10: Cross-Platform Architecture

**V2 Reference**: `docs/architecture-v2/10-Cross-Platform-Architecture.md`

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| `OrinCore` Swift Package (zero platform imports) | Not implemented | ❌ |
| Platform adapters wrapping all platform APIs | Not implemented (APIs called directly) | ❌ |
| Domain models free of `Foundation`/`SwiftData` | Domain models import `SwiftData` | ❌ |
| iOS target compilable | No iOS target | ❌ |
| Windows target path (via Swift on Windows) | No Windows target | ❌ |
| Android OrinCore in Kotlin Multiplatform | Not applicable for Phase 3 | N/A |

**Subsystem Score: Not Implemented (0/5 requirements; Phase 3–6 work)**

---

## Audit Against Document 11: Performance and Resource Budget

**V2 Reference**: `docs/architecture-v2/11-Performance-Resource-Budget.md`

| Budget | V2 Limit | V1 Status | Compliant? |
|--------|---------|-----------|-----------|
| RT thread callback budget | < 0.1ms | Violated by heap allocation, NSLock XPC call | ❌ |
| RSS during idle | < 150MB | Unknown; not measured | Unknown |
| RSS during recording | < 400MB | Unknown; not measured | Unknown |
| RSS during analysis | < 800MB | Unknown; not measured | Unknown |
| Analysis latency per chunk | < 90s P95 | Unknown; no timing instrumentation | Unknown |
| Session start to Active | < 3s P95 | Unknown | Unknown |
| `@MainActor` time during recording | < 5% | Violated by TranscriptStore save | ❌ |
| SwiftData `externalStorage` on large fields | Required | Not applied | ❌ |
| Instrumentation via `os_signpost` | Required | Partial (AnalysisPerfLogger exists) | Partial |
| InferenceWorker serial execution | Required | Violated (thundering herd) | ❌ |

**Subsystem Score: Non-Compliant (4 confirmed violations; most budgets unmeasured)**

---

## Audit Against Document 12: Scalability Roadmap

**V2 Reference**: `docs/architecture-v2/12-Scalability-Roadmap.md`

| Requirement | V1 Status | Score |
|-------------|-----------|-------|
| 1,000+ meeting SwiftData performance | ❌ `@Query` without predicate loads all meetings |
| Paginated meeting list | ❌ Not implemented |
| Background analysis queue | ❌ Not implemented (synchronous on foreground) |
| Incremental knowledge graph updates | ❌ Not applicable (KG not implemented) |
| Plugin concurrency control | ❌ Not applicable (plugins not implemented) |

**Subsystem Score: Non-Compliant (core scalability patterns missing)**

---

## Audit Against Document 13: Architecture Decision Records

**V2 Reference**: `docs/architecture-v2/13-Architecture-Decision-Records.md`

| ADR | Decision | V1 Compliance |
|-----|---------|--------------|
| ADR-001 Hexagonal Architecture | Ports and adapters pattern | Partial — 5 protocols exist; OrinCore not extracted |
| ADR-002 SwiftData as persistence layer | SwiftData for domain models | ✅ SwiftData in use |
| ADR-003 Actor concurrency | @MainActor for session; actors for services | Partial — RecordingService is @MainActor; others not actors |
| ADR-004 Local-first LLM | Ollama only; no cloud AI | ✅ Ollama in use |
| ADR-005 Two-tier EventBus | In-process + XPC | ❌ Not implemented |
| ADR-006 SQLite for knowledge graph | Not SwiftData for KG | ❌ KG not implemented |
| ADR-007 NL framework for entity extraction | Apple NLTagger | ❌ Not implemented |
| ADR-008 InferenceWorker serial queue | Fix thundering herd | ❌ Not implemented |
| ADR-009 Language-neutral section markers | Not English keywords | ❌ English keywords in ResponseParser |
| ADR-010 XPC for plugin sandbox | Security boundary | ❌ Not implemented |
| ADR-011 Capability system for plugins | Read-only vs. write | ❌ Not implemented |
| ADR-012 SwiftData migration plan | Versioned migrations | Partial — migrations exist but `externalStorage` not applied |
| ADR-013 LanguagePack model | Bundle language packs | ❌ Not implemented |
| ADR-014 Whisper for hi-IN | whisper.cpp HTTP | Partial — stub exists |
| ADR-015 OrinCore package | Zero platform imports | ❌ Not implemented |
| ADR-016 VocabularyContext budget allocation | 100-term explicit tiers | ❌ `.prefix(100)` used |
| ADR-017 Kotlin Multiplatform for Android | Phase 6 | N/A |
| ADR-018 Composition root injection | No service locator | ❌ ServiceContainer in use |

**ADR Compliance**: 4/18 fully compliant (ADR-002, ADR-003 partial, ADR-004)

---

## Overall Compliance Summary

| V2 Document | Subsystem | Score |
|-------------|-----------|-------|
| 01 Product Domain Architecture | Bounded contexts + invariants | **Partially Compliant** |
| 02 Event-Driven Architecture | EventBus + domain events | **Non-Compliant** |
| 03 Core Architecture V2 | Hexagonal architecture + OrinCore | **Partially Compliant** |
| 04 State Machine Architecture | 6 state machines | **Non-Compliant** |
| 05 AI Orchestration | InferenceWorker + prompts | **Partially Compliant** |
| 06 Learning Engine | Corrections + promotion + decay | **Not Implemented** |
| 07 Multilingual Architecture | ASRBackend + locales + vocabulary | **Partially Compliant** |
| 08 Knowledge Graph | SQLite graph + entity extraction | **Not Implemented** |
| 09 Plugin Extension SDK | XPC sandbox + capabilities | **Not Implemented** |
| 10 Cross-Platform Architecture | OrinCore + adapters + iOS | **Not Implemented** |
| 11 Performance and Resource Budget | RT safety + memory + latency | **Non-Compliant** |
| 12 Scalability Roadmap | SwiftData scale + queue | **Non-Compliant** |
| 13 Architecture Decision Records | 18 ADRs | **Partially Compliant** |

### Score Breakdown

| Score | Count | Documents |
|-------|-------|----------|
| Fully Compliant | 0 | — |
| Partially Compliant | 5 | 01, 03, 05, 07, 13 |
| Non-Compliant | 4 | 02, 04, 11, 12 |
| Not Implemented | 4 | 06, 08, 09, 10 |

**No V2 document is fully compliant in V1.** This is expected for a V1 codebase; the architecture documents define the target, not the current state.

---

## Compliance Improvement Trajectory by Phase

| Phase | Subsystems Addressed | Expected Improvement |
|-------|---------------------|---------------------|
| Phase 0 | Doc 11 (RT safety, InferenceWorker) | Non-Compliant → Partially Compliant |
| Phase 1 | Doc 03 (protocols, injection) | Partially Compliant → Mostly Compliant |
| Phase 2 | Doc 02 (EventBus), Doc 04 (state machines), Doc 12 (performance) | Non-Compliant → Partially/Mostly Compliant |
| Phase 3 | Doc 07 (multilingual), Doc 10 (OrinCore, partial) | Partially → Mostly Compliant |
| Phase 4 | Doc 06 (learning engine), Doc 08 (knowledge graph) | Not Implemented → Partially Compliant |
| Phase 5 | Doc 09 (plugin SDK) | Not Implemented → Partially Compliant |
| Phase 6 | Doc 10 (iOS, Windows, Android) | Partially → Fully Compliant |

**First phase to achieve any "Fully Compliant" subsystems: Phase 2 (Document 02 EventBus, if fully implemented per spec).**

---

## Critical Path to First Compliant Subsystem

To achieve the first **Fully Compliant** score (Document 02: Event-Driven Architecture):

1. **EPIC-07** (Composition Root) — makes EventBus injectable
2. **EPIC-11** (EventBus actor + domain events) — implements the specification
3. **EPIC-12** (SessionStateMachine) — emits session events via EventBus
4. **EPIC-17** (AnalysisCoordinator) — emits analysis events via EventBus

All four epics are Phase 1–2 work. Estimated 16–22 weeks for a single engineer.

At that point, Document 02 achieves Fully Compliant, and Documents 01, 03, 04, 05, and 11 all improve to Partially Compliant.
