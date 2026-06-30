# Document M-07: State Validation Report

**Series**: Orin V2 Migration Planning  
**Document**: 7 of 8  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Overview

This document verifies every implemented state machine in the V1 codebase against the V2 state machine specifications in Document 04. For each state machine, the report identifies:

- States present in V2 spec but missing in V1 implementation
- Transitions present in V2 spec but missing or incorrectly implemented in V1
- Invalid transitions that V1 allows but V2 spec prohibits
- Race conditions in the V1 implementation
- Recovery gaps where failure states have no defined recovery path

**V2 Reference**: Document 04 (State Machine Architecture) — 6 state machines specified

---

## SM-01: Session State Machine

**V2 Spec location**: Document 04 §2  
**V1 Implementation**: `RecordingService.swift` (boolean flags + `phase` enum, not a formal state machine)

### V2 Specified States (13)

| State | V2 Description | V1 Implementation | Status |
|-------|---------------|-------------------|--------|
| `Idle` | No session active | `isRecording == false && phase == .idle` | Implicit |
| `Starting` | Session startup in progress | No explicit state; `startRecording()` is synchronous call | **MISSING** |
| `Initializing` | Audio engine initializing | Merged with `Starting` | **MISSING** |
| `Active` | Recording in progress | `isRecording == true` | Partial |
| `Paused` | Recording paused | Not implemented | **MISSING** |
| `Stopping` | Stop requested | No explicit state; gap between user tap and ASR end | **MISSING** |
| `Finalizing` | Saving to persistence | Implicit during `finalize()` | Partial |
| `Completed` | Session persisted | Implicit on successful save | Partial |
| `Failed` | Unrecoverable error | `isRecording = false` (no error state tracked) | **MISSING** |
| `Restarting` | Recovering from error | Not implemented | **MISSING** |
| `Suspended` | Background app suspension | Not implemented | **MISSING** |
| `Resuming` | Returning from suspended | Not implemented | **MISSING** |
| `Migrating` | Data migration in progress | Not applicable in V1 | N/A |

**V1 states present**: 4 of 13 (partial or implicit)  
**V1 states missing**: 7 of 13

### V2 Specified Transitions — Validation

| From | To | Trigger | V1 Status | Notes |
|------|----|---------|-----------|-------|
| `Idle` → `Starting` | User taps record | `startRecording()` executes immediately (no `Starting` state) | **MISSING** |
| `Starting` → `Initializing` | Audio engine started | No separate states; both collapsed | **MISSING** |
| `Initializing` → `Active` | ASR ready, audio flowing | No guard; can "succeed" even if ASR failed to initialize | **INVALID** |
| `Active` → `Paused` | User pauses | Not implemented | **MISSING** |
| `Paused` → `Active` | User resumes | Not implemented | **MISSING** |
| `Active` → `Stopping` | User stops | Direct to `Finalizing` behavior | **MISSING** |
| `Stopping` → `Finalizing` | All audio flushed | Merged | **MISSING** |
| `Finalizing` → `Completed` | Persistence succeeds | Implicit | Partial |
| `Finalizing` → `Failed` | Persistence fails | No explicit failure state | **MISSING** |
| `Active` → `Failed` | Unrecoverable audio error | `isRecording = false` only | **INCOMPLETE** |
| `Failed` → `Idle` | User dismisses error | No error state; nothing to dismiss | **MISSING** |
| `Active` → `Suspended` | App backgrounded | Not handled | **MISSING** |
| `Suspended` → `Resuming` | App foregrounded | Not handled | **MISSING** |

### Race Conditions Identified

**RC-01: isRecording flag is not actor-isolated**  
`RecordingService` is `@MainActor final class`. Reading `isRecording` from background tasks (e.g., `MeetingDetectorService`) is a data race. The flag is not protected by the actor boundary because background tasks may hold a reference to `RecordingService` and call non-isolated methods.

**RC-02: generationHadSpeech counter TOCTOU**  
The generation counter used to determine if ASR restart is needed is a non-atomic mutable integer on `@MainActor`. When `RecordingService` is accessed from both `@MainActor` (UI) and background `Task` contexts (audio callbacks), increments can interleave. Specifically: a stale ASR callback from a previous generation can observe a generation counter that has already been incremented, and incorrectly append its transcript to the new session.

### Recovery Gaps

| Gap | Description | Impact |
|-----|-------------|--------|
| RG-01 | No `Failed` state | On audio engine failure, `isRecording` is set to `false` with no error stored; user sees recording stopped with no explanation |
| RG-02 | No `Suspended` state | App backgrounding during recording has undefined behavior; system may terminate without finalizing session |
| RG-03 | Partial transcript on `Failed → Idle` | If failure occurs mid-session, partial transcript may or may not be saved depending on execution path |

**V2 Compliance Score: 2/13 states, 2/13 transitions — Non-Compliant**

---

## SM-02: Analysis Status State Machine

**V2 Spec location**: Document 04 §3  
**V1 Implementation**: `MeetingItem.analysisStatus: String` — a stringly-typed field, not a state machine

### V2 Specified States (8)

| State | V2 Description | V1 Status |
|-------|---------------|-----------|
| `Pending` | Session ended; waiting for queue | String `"pending"` (inferred from code) |
| `Queued` | Enqueued in InferenceWorker | String `"queued"` (inferred) |
| `Running` | In-flight inference | String `"running"` (inferred) |
| `Synthesizing` | Multi-chunk synthesis in progress | Not implemented |
| `Completed` | Analysis persisted | String `"completed"` |
| `Failed` | Analysis failed | String `"failed"` |
| `Deferred` | Retries exhausted; user must retry | Not implemented |
| `Cancelled` | User cancelled in-flight analysis | Not implemented |

**V1 states present**: 4 of 8 (as unvalidated strings)  
**V1 states missing**: 4 of 8

### V2 Specified Transitions — Validation

| Transition | V1 Status | Notes |
|------------|-----------|-------|
| `Pending → Queued` | Implicit string assignment | No validation; any string can be written |
| `Queued → Running` | Implicit string assignment | |
| `Running → Synthesizing` | **MISSING** | No multi-chunk synthesis state |
| `Synthesizing → Completed` | **MISSING** | |
| `Running → Completed` | Implicit string assignment | Bypasses `Synthesizing` for single-chunk |
| `Running → Failed` | Implicit string assignment | |
| `Failed → Queued` | Not implemented | Manual retry not possible (no way to re-queue) |
| `Running → Cancelled` | **MISSING** | Cannot cancel in-flight analysis |
| `Completed → Running` | Should be blocked | **INVALID**: string field can be overwritten to `"running"` after completion |

### Invalid Transitions Allowed

| Invalid Transition | V1 Allows? | Correct Behavior |
|-------------------|-----------|-----------------|
| `Completed → Running` | Yes (string can be overwritten) | Prohibited; completed analysis must not restart without explicit user action |
| `Failed → Running` | Yes | Must go through `Failed → Queued → Running` |
| Any state → Any state | Yes (unguarded string write) | All transitions must be guarded by `AnalysisStatus` state machine |

### Recovery Gaps

| Gap | Description |
|-----|-------------|
| RG-01 | No `Deferred` state; after failure, user cannot retry; must manually trigger analysis |
| RG-02 | No `Cancelled` state; cancelling in-flight analysis leaves `analysisStatus == "running"` permanently |

**V2 Compliance Score: Non-Compliant (stringly-typed; no guarded transitions)**

---

## SM-03: InferenceWorker State Machine

**V2 Spec location**: Document 04 §4  
**V1 Implementation**: Not implemented — `MeetingIntelligenceService.analyzeChunked()` uses unguarded `withTaskGroup`

### V2 Specified States (5)

| State | V2 Description | V1 Status |
|-------|---------------|-----------|
| `Idle` | No jobs queued | **MISSING** (no queue) |
| `Processing` | Executing a job | **MISSING** (parallel, not serial) |
| `CircuitOpen` | 3 consecutive failures; refusing new jobs | **MISSING** |
| `Draining` | Completing current job before shutdown | **MISSING** |
| `Shutdown` | No new jobs accepted | **MISSING** |

**V1 states present**: 0 of 5

### Critical Finding

The `withTaskGroup` pattern in `MeetingIntelligenceService.analyzeChunked()` (lines 162-170) submits all chunks simultaneously. This means:

1. There is no `InferenceWorker` actor; the concept does not exist in V1
2. There is no circuit breaker (3-failure threshold)
3. There is no `Draining` state (in-flight jobs cannot be gracefully wound down)
4. The thundering herd (41 concurrent Ollama requests) is a direct consequence of this absent state machine

**V2 Compliance Score: 0/5 states — Not Implemented**

---

## SM-04: ASR Session State Machine

**V2 Spec location**: Document 04 §5  
**V1 Implementation**: `RecordingService.swift` — generation counter + boolean flags; no formal state machine

### V2 Specified States (7)

| State | V2 Description | V1 Status |
|-------|---------------|-----------|
| `Uninitialized` | Before first `prepare()` | Implicit |
| `Initializing` | `prepare()` called; awaiting ready signal | No separate state; merged with `Ready` |
| `Ready` | ASR backend ready for audio | `isCapturing` flag (partial) |
| `Restarting` | Error 1110 recovery in progress | `generationHadSpeech` counter (partial, racy) |
| `Finalizing` | `endAudio()` called; awaiting last results | No explicit state |
| `Completed` | All final results received | No explicit state |
| `Failed` | Unrecoverable ASR failure | `isCapturing = false` only |

**V1 states present**: 2 of 7 (partial/racy implementations)

### V2 Specified Transitions — Validation

| Transition | V1 Status |
|------------|-----------|
| `Uninitialized → Initializing` | **MISSING** (start is synchronous, no initializing state) |
| `Initializing → Ready` | **MISSING** |
| `Ready → Restarting` | Partial (generation counter increment, not actor-guarded) |
| `Restarting → Ready` | Partial (no guard that prevents stale callbacks from prior generation) |
| `Ready → Finalizing` | **MISSING** (endAudio called without state tracking) |
| `Finalizing → Completed` | **MISSING** |
| `Any → Failed` | Incomplete (state not recorded; only flag cleared) |
| `Failed → Uninitialized` | Not implemented |

### Race Conditions

**RC-01: Stale callback TOCTOU (TD-C04)**  
Generation counter is read and incremented in separate operations. Between the read and increment, an audio callback from the previous generation can fire, read the old generation number, and append its transcript to the new session.

**V2 Compliance Score: 2/7 states, 1/8 transitions (partial) — Non-Compliant**

---

## SM-05: Plugin Lifecycle State Machine

**V2 Spec location**: Document 04 §6 (Plugin states)  
**V1 Implementation**: Not implemented — Plugin SDK is Phase 5 work

### V2 Specified States (8)

| State | V1 Status |
|-------|-----------|
| `Unregistered` | **NOT IMPLEMENTED** |
| `Registered` | **NOT IMPLEMENTED** |
| `Loading` | **NOT IMPLEMENTED** |
| `Active` | **NOT IMPLEMENTED** |
| `Suspended` | **NOT IMPLEMENTED** |
| `Unloading` | **NOT IMPLEMENTED** |
| `Failed` | **NOT IMPLEMENTED** |
| `Quarantined` | **NOT IMPLEMENTED** |

**V2 Compliance Score: 0/8 states — Not Implemented (Phase 5)**

---

## SM-06: Vocabulary Session State Machine

**V2 Spec location**: Document 04 §7 (Vocabulary Session states)  
**V1 Implementation**: `VocabularyProvider.swift` — provides a list; no session lifecycle

### V2 Specified States (4)

| State | V2 Description | V1 Status |
|-------|---------------|-----------|
| `Unloaded` | No vocabulary in memory | Not tracked |
| `Loading` | Building vocabulary context | Not tracked; `.prefix(100)` runs synchronously |
| `Ready` | Vocabulary context available for ASR | Not tracked |
| `Stale` | Underlying data changed; reload needed | **MISSING** |

**V1 states present**: 0 of 4 (vocabulary is read synchronously on demand, no session concept)

### Critical Finding

The silent `.prefix(100)` truncation in V1 means the vocabulary is loaded in a non-observable way. There is no `Stale` state, so if a correction is accepted mid-session, the ASR backend is never notified to reload its vocabulary. The new term only takes effect on the next app launch.

**V2 Compliance Score: 0/4 states — Non-Compliant**

---

## Cross-Cutting Issues

### Missing Crash Recovery for All State Machines

V2 Document 04 §1 specifies that all state machines must persist their last known state to durable storage so that crash recovery restores the correct state on next launch. V1 implements none of this:

- If the app crashes during `Active` session state, next launch starts fresh with no knowledge of the interrupted session
- Partial transcript from crash session may or may not be in `TranscriptStore` depending on crash timing
- `MeetingItem.analysisStatus` stringly-typed field is the only durable state — it may be left as `"running"` after a crash (zombie analysis state)

### Missing Watchdog Timers

V2 Document 04 §1 specifies watchdog timers for each state machine. V1 implements none:

| State Machine | V2 Watchdog | V1 Status |
|--------------|-------------|-----------|
| Session | `Initializing > 10s` → `Failed` | **MISSING** |
| ASR Session | `Initializing > 10s with no speech` → `Restarting` | **MISSING** |
| Analysis | `Running > 5min per chunk` → `Failed` | **MISSING** |

### State Machine Isolation

V2 Document 04 §1 specifies that each state machine must be an actor. V1 state management is in `@MainActor final class RecordingService` — not a dedicated state machine actor. This means:

1. All state transitions run on the main thread, blocking UI
2. State machine logic is interleaved with audio engine, ASR management, and persistence code
3. Reasoning about state transitions requires reading 1,355 lines of `RecordingService.swift`

---

## Compliance Summary

| State Machine | V2 States | V1 States Present | Transitions OK | Race Conditions | Score |
|--------------|-----------|-------------------|----------------|----------------|-------|
| SM-01 Session | 13 | 4 (partial) | 2/13 | 2 | Non-Compliant |
| SM-02 Analysis Status | 8 | 4 (strings) | 0 guarded | 0 | Non-Compliant |
| SM-03 InferenceWorker | 5 | 0 | 0/5 | N/A (not implemented) | Not Implemented |
| SM-04 ASR Session | 7 | 2 (partial) | 1/8 (partial) | 1 | Non-Compliant |
| SM-05 Plugin Lifecycle | 8 | 0 | 0/8 | N/A | Not Implemented (Phase 5) |
| SM-06 Vocabulary Session | 4 | 0 | 0/4 | 0 | Non-Compliant |

**Overall V2 State Machine Compliance: 0 of 6 state machines compliant**

All 4 implemented state machines (SM-01 through SM-04 and SM-06) are non-compliant. SM-03 and SM-05 are not yet implemented (expected — SM-03 is Phase 0/2 work; SM-05 is Phase 5 work).

---

## Remediation Mapping

| State Machine | Implementing Epic | Target Phase |
|--------------|------------------|-------------|
| SM-01 Session | EPIC-12 `SessionStateMachine` | Phase 2 |
| SM-02 Analysis Status | EPIC-13 `AnalysisStatus` typed enum | Phase 2 |
| SM-03 InferenceWorker | EPIC-02 `InferenceWorker` actor | Phase 0 |
| SM-04 ASR Session | EPIC-16 `ASRSessionStateMachine` | Phase 2 |
| SM-05 Plugin Lifecycle | Post-Phase 5 (not in current roadmap) | Phase 5 |
| SM-06 Vocabulary Session | EPIC-21 `VocabularyContext` | Phase 3 |
