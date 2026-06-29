# Orin Architecture Review — Package README

**Document:** 00-README.md  
**Package:** Orin Architecture Review (June 2026)  
**Status:** Final  
**Audience:** Engineers, architects, technical leads, AI engineers onboarding to the Orin codebase

---

## 1. Purpose

This package is the output of a full architectural review of the Orin macOS meeting intelligence platform, conducted in June 2026. The review was performed by nine parallel analytical agents, each assigned a specific subsystem: recording pipeline, speech pipeline, AI pipeline, data persistence, concurrency model, vocabulary system, app architecture, cross-platform feasibility, and long-term roadmap.

The goal was to produce an honest engineering assessment of the current system — what is working correctly and must be preserved, what has specific fixable defects, and what requires redesign before the product can support its stated multilingual and cross-platform goals.

The overall verdict is **NEEDS_PATCHING**. Orin is not broken at its foundation. The recording pipeline concurrency model, the real-time-to-async bridge, the SwiftData session recovery logic, and the layered transcript finalization design are all correct and represent hard-won platform knowledge. However, the codebase has accumulated a set of specific defects that are currently causing production crashes and freezes. These defects are surgical: they do not require architectural rewrites. They require targeted code changes, delivered in the right order.

The most urgent finding: a two-line fix to the AI pipeline eliminates the root cause of the majority of observed system freezes. That finding, and the full engineering context behind it, is documented here.

---

## 2. How to Read These Documents

The documents in this package are structured to be read in layers. A new engineer can read documents 01-05 to understand the system as it exists today. Documents 07-09 are deep-dives into specific subsystems and can be read independently once you have the system overview. Documents 10-15 are forward-looking and should be read in order, as each builds on the previous.

### Recommended Reading Order

**Layer 1 — System Understanding (read these first)**

| Doc | Title | What You Learn |
|-----|-------|----------------|
| `01-executive-summary.md` | Executive Summary | Overall verdict, root causes, and the recommended fix order |
| `02-system-overview.md` | System Overview | What Orin does, how the major subsystems interact, key data flows |
| `03-codebase-map.md` | Codebase Map | File-by-file responsibilities, ownership, line counts, key entry points |
| `04-current-architecture.md` | Current Architecture | The design decisions that are correct and must be preserved |
| `05-critical-defects.md` | Critical Defects | TD-001 through TD-005 in full detail, with reproduction paths and fixes |

**Layer 2 — Stability Context (read if diagnosing a crash)**

| Doc | Title | What You Learn |
|-----|-------|----------------|
| `06-crash-and-stability-history.md` | Crash and Stability History | Observed failure modes, the 41-request thundering herd, audio dropout patterns |

**Layer 3 — Subsystem Deep-Dives (read for a specific area)**

| Doc | Title | What You Learn |
|-----|-------|----------------|
| `07-recording-and-speech-pipeline.md` | Recording and Speech Pipeline | TapState, MicTranscriberFeed, generation counter, Phase 2A/2B migration |
| `08-ai-pipeline.md` | AI Pipeline | analyzeChunked() defect, InferenceWorker design, AnalysisJobQueue |
| `09-data-persistence.md` | Data Persistence | SwiftData model, O(N^2) writes, @Attribute(.externalStorage), predicate gaps |

**Layer 4 — Forward-Looking (read for roadmap and planning)**

| Doc | Title | What You Learn |
|-----|-------|----------------|
| `10-quick-wins.md` | Quick Wins | The 9 highest-impact, lowest-effort changes with exact file and line references |
| `11-medium-term-redesigns.md` | Medium-Term Redesigns | MT-001 through MT-008, scoped to 8-10 weeks |
| `12-vocabulary-and-multilingual.md` | Vocabulary and Multilingual | VocabularyContext redesign, ASRBackend protocol, language expansion roadmap |
| `13-cross-platform-strategy.md` | Cross-Platform Strategy | OrinCore package extraction, Windows POC, iOS/Android path |
| `14-ai-pipeline-redesign.md` | AI Pipeline Redesign | InferenceWorker actor, InferenceProvider protocol, ModelRouter |
| `15-roadmap.md` | Roadmap | Phase 1-4 timeline, decision gates, sequencing rationale |

**Visual Reference**

| Path | Contents |
|------|----------|
| `diagrams/` | Architecture diagrams, data flow charts, concurrency model illustrations |

---

## 3. Document Dependency Map

The arrows below represent "you should have read X before reading Y" dependencies. Documents with no incoming arrows can be read standalone.

```
01-executive-summary
        |
        +---> 02-system-overview
        |           |
        |           +---> 03-codebase-map
        |           |
        |           +---> 04-current-architecture
        |                       |
        |                       +---> 05-critical-defects
        |                                   |
        |                       +---------> 06-crash-and-stability-history
        |
        +---> 05-critical-defects
                    |
                    +---> 07-recording-and-speech-pipeline
                    |
                    +---> 08-ai-pipeline ---------> 14-ai-pipeline-redesign
                    |                                       |
                    +---> 09-data-persistence               |
                                                           v
                    +---> 10-quick-wins            15-roadmap <--- 11-medium-term-redesigns
                                                        ^                   |
                                                        |                   |
                                              12-vocabulary-and-multilingual |
                                                        ^                   |
                                                        |                   v
                                              13-cross-platform-strategy <--+
```

Documents `10-quick-wins` through `13-cross-platform-strategy` all feed into `15-roadmap`. If you are reading this package to plan a sprint, read `01`, `05`, `10`, and `15` in that order.

---

## 4. Glossary

The following terms are used throughout this package. They are defined here to establish a single authoritative reference. Where a term refers to a proposed component that does not yet exist in the codebase, it is marked **(proposed)**.

---

### AI Pipeline Terms

**InferenceWorker** *(proposed)*  
A Swift actor that serves as the single point of contact for all LLM inference requests. It maintains a serial job queue for local inference providers (Ollama, LM Studio, Apple Foundation Models) and a bounded-concurrent queue (limit: 3) for cloud providers. InferenceWorker replaces the current pattern of calling provider endpoints directly from `withTaskGroup`. It processes one local job at a time, eliminating the thundering herd.

**AnalysisJobQueue** *(proposed)*  
A Swift actor that serializes post-recording analysis requests across multiple concurrent meetings. When two meetings finish recording within seconds of each other, AnalysisJobQueue ensures their analysis jobs run sequentially rather than launching two simultaneous `withTaskGroup` waves into Ollama. It exposes a priority mechanism so user-initiated analysis (`Analyze` button) jumps ahead of automatic post-recording analysis.

**InferenceProvider** *(proposed)*  
A Swift protocol with a single method: `func infer(job: InferenceJob) async throws -> InferenceResult`. Concrete implementations: `OllamaProvider`, `LMStudioProvider`, `AppleFoundationModelsProvider`, `OpenAIProvider`, `AnthropicProvider`, `GeminiProvider`. InferenceProvider replaces the current hardcoded provider-selection logic in `AIService.swift`.

**ModelRouter** *(proposed)*  
A Swift protocol that selects an `InferenceProvider` given a job's requirements. Concrete routers: `LocalFirstRouter` (prefers local providers, falls back to cloud), `CloudOnlyRouter`, `SpecializedRouter` (routes analysis to a large model, summarization to a small model). ModelRouter replaces the flat `if/else` provider selection currently embedded in `AIService`.

**Thundering Herd (Ollama-specific)**  
The failure mode triggered by `analyzeChunked()` in `MeetingIntelligenceService.swift`. `withTaskGroup` submits all N chunk tasks simultaneously before any single task completes. For a 150-minute meeting, N ≈ 20. All 20 tasks call the Ollama `/api/generate` endpoint concurrently. Ollama is a single-process, single-GPU runtime that serializes inference internally. The 19 tasks that cannot be served immediately wait and hit the 60-second `URLSession` timeout simultaneously. All 19 then sleep 10 seconds (no jitter) and retry simultaneously. Wave 1: 20 requests. Wave 2: 19-20 requests. Total: ~41. This is the direct cause of post-recording system freezes and GPU exhaustion.

---

### ASR and Speech Terms

**ASRBackend** *(proposed)*  
A Swift protocol that abstracts the automatic speech recognition implementation behind a platform-agnostic interface. Concrete implementations: `SpeechTranscriberBackend` (wraps Apple's `SpeechTranscriber` API, macOS 26+), `SFSpeechRecognizerBackend` (legacy), `WhisperBackend` (wraps whisper.cpp, used for locales Apple does not support). ASRBackend is the abstraction that enables cross-platform and multilingual support without rewriting the recording pipeline.

**WhisperBackend** *(proposed)*  
A concrete implementation of `ASRBackend` that uses whisper.cpp (or a Swift wrapper) for speech recognition. Required for Hindi (`hi-IN`) and other locales that Apple's `SpeechTranscriber` does not support. WhisperBackend runs fully on-device. It is slower than Apple's native ASR but produces acceptable quality for post-meeting transcript correction.

**SpeechTranscriberBackend** *(proposed)*  
A concrete implementation of `ASRBackend` wrapping Apple's `SpeechTranscriber` API (available macOS 26+). This is the target backend for the Phase 2B migration. It provides significantly better accuracy than `SFSpeechRecognizer` for English variants and is the first step toward a structured ASR abstraction layer.

**Phase 2A**  
The first phase of the SpeechTranscriber migration, currently active. The `useNewSpeechTranscriber` feature flag is enabled. `SpeechTranscriber` handles the microphone channel only. The participant (system audio) channel remains on the legacy `SFSpeechRecognizer` path. Phase 2A is gated: the legacy path is removed only after Phase 2B is validated.

**Phase 2B**  
The second phase of the SpeechTranscriber migration, currently gated behind the `useNewParticipantPipeline` feature flag. `SpeechTranscriber` takes over the participant (system audio) channel in `SystemAudioCaptureService`. Phase 2B must not be enabled until the `SpeechTranscriber` path has been validated to produce equivalent or better transcript quality across a representative set of real meetings.

---

### Real-Time Audio Terms

**TapState**  
A value type (struct) in `Sources/Orin/Services/TapState.swift` that wraps an `SFSpeechAudioBufferRecognitionRequest` and manages the lifecycle of an audio tap. It is protected by `NSLock` because it is accessed from both the Core Audio real-time I/O thread and the `@MainActor` service layer. The current implementation has a critical defect: `disarm()` calls `recognitionRequest?.endAudio()` while holding the lock. `endAudio()` is an XPC call to the speech daemon. This blocks the Core Audio I/O thread for the duration of the IPC round-trip.

**MicTranscriberFeed**  
The audio feed callback for the microphone capture channel in `RecordingService.swift`. It is called by Core Audio's I/O thread approximately 46 times per second. It currently allocates a new `AVAudioPCMBuffer` on every call while holding `NSLock`. Heap allocation on the real-time thread is a Core Audio safety violation.

**ParticipantSTFeed**  
The audio feed callback for the system audio (participant) capture channel in `SystemAudioCaptureService.swift`. It has the same real-time heap allocation defect as `MicTranscriberFeed`.

**GenerationCounter pattern**  
The mechanism used in `RecordingService` and `SystemAudioCaptureService` to prevent stale recognition callbacks from acting on a session that has already been torn down. Each recognition session is assigned an integer `recognitionGeneration`. Callbacks check `self.recognitionGeneration == gen` before executing. The current implementation has a TOCTOU (time-of-check, time-of-use) window where the watchdog `Task` and an error callback `Task` can both pass the generation check before either increments the counter, spawning two simultaneous `SFSpeechRecognitionTask` instances.

---

### Persistence Terms

**TranscriptChunk**  
A SwiftData `@Model` in `Sources/Orin/Models/OrinModels.swift` representing a unit of persisted speech recognition output at the time of capture. `TranscriptChunk` is written incrementally during recording and used as the source-of-truth for crash recovery. It stores the raw transcript text, speaker label, start/end timestamps, and a reference to the parent `MeetingItem`. Multiple `TranscriptChunk` instances are consolidated into `TranscriptSegment` records during finalization.

**TranscriptSegment**  
A SwiftData `@Model` in `Sources/Orin/Models/OrinModels.swift` representing a processed, finalized segment of a meeting transcript. `TranscriptSegment` is the output of the finalization pass that runs after recording ends. It is distinct from `TranscriptChunk`: chunks are raw, incremental, and written during recording; segments are processed, stable, and read during display and analysis. The `allSegments` `@Query` in `MeetingsView` currently has no predicate, loading all segments from all meetings simultaneously.

---

### Service Terms

**RecognitionSessionManager** *(proposed)*  
A Swift actor that encapsulates the recognition session lifecycle: generation counter management, error-triggered restart with delay (1110 error), 10-second cold-start watchdog, utterance-boundary heuristic, and `generationHadSpeech` tracking. This actor exists to eliminate the current situation where ~400 lines of this logic are copy-pasted verbatim between `RecordingService` and `SystemAudioCaptureService`, causing the two channels to diverge in behavior (they currently have different hardcoded locale strings as a direct consequence of this duplication).

**RecordingSessionCoordinator** *(proposed)*  
A service-layer component (likely an `@Observable` class) extracted from `MainContainerView` that owns recording orchestration, auto-stop logic, meeting detection integration, and post-recording analysis trigger. Currently, `MainContainerView` contains 483 lines that intermingle view rendering with service coordination. The coordinator extracts the service coordination, leaving `MainContainerView` as a pure view.

**MeetingAnalysisCoordinator** *(proposed)*  
A service-layer component (likely an `@Observable` class) extracted from `MeetingDetailView` that owns the post-recording analysis orchestration: writing 12 model properties, encoding `structuredActionItemsJSON`, calling `safeSave`, and triggering `InferenceWorker`. Currently embedded directly in view code.

**OrinCore** *(proposed)*  
A Swift package that encapsulates the platform-agnostic business logic of Orin: transcript processing, AI prompt construction, action item extraction, meeting intelligence orchestration, and vocabulary management. `OrinCore` must have zero macOS-specific imports (`AVFoundation`, `Speech`, `ScreenCaptureKit`, `SwiftUI`, `AppKit`). It is the prerequisite for the Windows proof-of-concept and iOS/Android ports. Extracting `OrinCore` is a Phase 3 activity.

**ServiceContainer**  
The service locator in `Sources/Orin/App/ServiceContainer.swift`. It maintains a `[String: Any]` dictionary of registered services, populated in `OrinApp.init()` on the main thread and read from `Task.detached` closures in `MeetingDetectorService`. The dictionary has no lock and no actor isolation. This is a data race that the Swift concurrency sanitizer (`TSan`) would flag. Fix: add `NSLock` around reads and writes, or refactor to constructor injection for the services that call it from background contexts.

---

### Vocabulary Terms

**VocabularyContext** *(proposed)*  
A value type that aggregates vocabulary terms from four prioritized namespaces for injection into the speech recognizer and AI prompt. Namespace priority: Session (calendar attendee names for the current meeting) > User (manually added terms) > Org (organization-level terms, not yet implemented) > BuiltIn (language-specific default terms). `VocabularyContext` replaces the current flat array of 103 hardcoded terms in `VocabularyProvider`.

**CorrectionStore** *(proposed)*  
A service that observes user edits to meeting transcripts and promotes frequently corrected terms into the `User` vocabulary namespace. Promotion threshold: a term must be manually corrected at least 3 times before it is auto-promoted. All data is stored on-device in SwiftData. No correction data is transmitted to any server.

**VocabularyNamespace** *(proposed)*  
One of the four tiers within `VocabularyContext`: `session`, `user`, `org`, `builtIn`. Each namespace is a `[String]` of recognition hint terms. At runtime, the four namespaces are merged with the session namespace taking highest priority, and the combined list is passed to the speech recognizer and AI prompt builder.

---

### Operating Principles

**Local-first**  
Orin's inference preference ordering: local provider (Ollama, LM Studio, Apple Foundation Models) before cloud (OpenAI, Anthropic). Local inference runs on the user's hardware, incurs no API cost, and remains available offline. Cloud is the fallback when local providers are unavailable or when the user explicitly prefers a cloud model.

**Offline-first**  
Orin's recording, transcription, and analysis pipeline must function without a network connection. All capabilities that require a network connection (cloud inference, calendar sync) are optional enhancements. Core meeting capture and local AI analysis are network-independent.

**Privacy-first**  
No meeting transcript leaves the user's device without an explicit user action. Audio buffers are processed in memory and not persisted beyond `TranscriptChunk` records in the local SwiftData store. The privacy violation currently in `MeetingIntelligenceService.swift` — writing raw AI output to `/tmp/orin_phi3_raw.txt`, a world-readable path — is tracked as TD-014 and marked for immediate removal.

---

## 5. Architecture Principles

These five principles are non-negotiable constraints for all future engineering work on Orin. Any proposed change that violates one of these principles requires an explicit architectural exception, documented and reviewed before implementation.

---

### Principle 1: Local-First Inference

Local LLM providers (Ollama, LM Studio, Apple Foundation Models) are preferred for all inference operations. Cloud providers are the fallback, not the default. This principle applies to all pipeline stages: chunk analysis, synthesis, summarization, action item extraction, and title generation.

Consequence: The `InferenceWorker` and `ModelRouter` components must implement `LocalFirstRouter` as the default routing strategy. Cloud routing must require explicit user opt-in via a settings preference.

---

### Principle 2: Privacy-First Data

Meeting audio, transcripts, and AI-generated analysis are private to the user's device. No transcript content, audio buffer, or AI output is transmitted to any external service without an explicit, per-action user consent gesture. This principle supersedes product convenience.

Consequence: Cloud inference providers may be used only after the user has explicitly enabled them in settings. When a transcript is sent to a cloud provider for inference, the user must be notified. The `/tmp/orin_phi3_raw.txt` write (TD-014) violates this principle on the file system level and must be removed immediately.

---

### Principle 3: Real-Time Audio is Sacred

The Core Audio I/O thread is a hard-real-time thread with strict scheduling constraints. Code executing on this thread — specifically `MicTranscriberFeed.feed()`, `ParticipantSTFeed.feed()`, and `TapState` lock acquisition — must not perform heap allocation, XPC calls, or any operation with unbounded latency.

Consequence: Audio buffers must be pre-allocated in `arm()` and reused in `feed()`. `TapState.disarm()` must call `recognitionRequest?.endAudio()` only after releasing `NSLock`. `ServiceContainer.resolve()` must never be called from inside an audio tap callback.

---

### Principle 4: Sequential Local Inference

Local LLM runtimes (Ollama, LM Studio, llama.cpp, Apple Foundation Models) are single-process, single-GPU operations. Sending multiple concurrent inference requests to a local provider does not increase throughput — it increases memory pressure, risks GPU out-of-memory events, and causes synchronized timeout cascades. Local inference must always be processed sequentially, one job at a time, through `InferenceWorker`.

Consequence: The `withTaskGroup` pattern in `analyzeChunked()` must be replaced with sequential chunk processing (a `for` loop) or a semaphore with `limit: 1` for local providers. This is a fix, not a regression. Sequential local inference produces identical throughput to the current unbounded concurrent dispatch because Ollama serializes inference internally. The only difference is in the failure mode, which becomes graceful instead of catastrophic.

---

### Principle 5: Fix Before Feature

The recording pipeline and analysis pipeline have known defects (TD-001 through TD-005) that are causing production crashes and freezes. No new capabilities — additional languages, new AI providers, UI features, or cross-platform work — should be implemented until these defects are resolved. Adding surface area to an unstable foundation increases the cost of every subsequent fix.

Consequence: Phase 1 (quick wins, 2-3 weeks) is a prerequisite for Phase 2 (medium-term redesigns). Phase 2 is a prerequisite for Phase 3 (OrinCore, cross-platform). Any engineer proposing a feature addition before Phase 1 is complete should be directed to this document.

---

## 6. Quick Reference: Critical Issues

The following five items are **CRITICAL** severity. They are currently causing production failures. A new engineer joining this project should read the relevant source files before touching any of the surrounding code.

| ID | One-Line Description | Primary File | Effort |
|----|---------------------|--------------|--------|
| **TD-001** | `analyzeChunked()` submits all N chunk tasks simultaneously with no concurrency limit, causing ~41 simultaneous Ollama requests and synchronized timeout cascades | `Sources/Orin/Services/MeetingIntelligenceService.swift` | Days |
| **TD-002** | `MicTranscriberFeed.feed()` and `ParticipantSTFeed.feed()` allocate `AVAudioPCMBuffer` on every Core Audio I/O callback (~46/sec) while holding `NSLock`, risking priority inversion and audio dropout | `Sources/Orin/Services/RecordingService.swift`, `Sources/Orin/Services/SystemAudioCaptureService.swift` | Days |
| **TD-003** | `TapState.disarm()` calls `recognitionRequest?.endAudio()` (an XPC call to the speech daemon) while holding `NSLock`, blocking the Core Audio I/O thread for the duration of the IPC round-trip | `Sources/Orin/Services/TapState.swift` | Days |
| **TD-004** | `AVAudioEngineConfigurationChange` observer fires on an arbitrary thread and wraps in `Task { @MainActor }`; two concurrent notifications within 500ms both pass the debounce guard before either `Task` executes, calling `removeTap + installTap` twice on a running engine | `Sources/Orin/Services/RecordingService.swift` | Days |
| **TD-005** | `ServiceContainer`'s `[String: Any]` dictionary has no thread safety; it is written on the main thread during app startup and read concurrently from `Task.detached` closures in `MeetingDetectorService` — a real data race | `Sources/Orin/App/ServiceContainer.swift` | Days |

For full analysis of each defect, including reproduction paths and recommended fixes, see `05-critical-defects.md`.

For the single highest-priority fix — the one change that unblocks the majority of reported post-recording freezes — see QW-001 in `10-quick-wins.md`.

---

## 7. Review Metadata

| Field | Value |
|-------|-------|
| **Review Date** | June 2026 |
| **Codebase Snapshot** | Commit `4f603ea` (analysis perf logger, en-IN locale, MeetingDetectorService `@MainActor`) |
| **Method** | Nine parallel analytical agents, each assigned one subsystem. Each agent performed independent static analysis of all Swift source files in the subsystem's scope. Findings were cross-checked across agents for consistency. |
| **Source Scope** | All `.swift` files under `Sources/Orin/`: services (22 files), models (3 files), views (14 files), app entry point (3 files). Test suite reviewed for coverage gaps (24 test files). |
| **Subsystems Reviewed** | Recording pipeline, speech pipeline, AI pipeline, data persistence, concurrency model, vocabulary system, app architecture, cross-platform feasibility, long-term roadmap |
| **Confidence Level** | High for defect identification (all findings are grounded in specific code paths with line references). Medium for performance estimates (throughput numbers are derived from first-principles analysis, not from profiling runs on real hardware). Low for timeline estimates (Phase 2-4 timelines assume a single senior iOS/macOS engineer; actual delivery depends on team size and velocity). |
| **What This Review Does Not Cover** | Runtime profiling with Instruments (gated on crash stability; see `project_instruments_plan.md`), UI/UX assessment, App Store review compliance, notarization and code signing, TestFlight distribution pipeline. |

---

*This document is the entry point for the Orin Architecture Review package. It does not contain the full analysis. Follow the reading order in Section 2 to build the complete picture.*
