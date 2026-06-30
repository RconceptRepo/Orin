# Document M-03: Technical Debt Register

**Series**: Orin V2 Migration Planning  
**Document**: 3 of 8  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Overview

This register catalogs every identified technical debt item in the Orin V1 codebase. Each item is ranked Critical / High / Medium / Low. Critical items are production defects or defects that block the V2 migration. High items degrade correctness, performance, or maintainability in measurable ways. Medium items are code quality issues. Low items are minor improvements.

**Total items**: 47  
**Critical**: 7  
**High**: 15  
**Medium**: 16  
**Low**: 9

---

## Critical Debt

### TD-C01: Heap Allocation in Core Audio I/O Callback

**File**: `Sources/Orin/Services/TapState.swift`  
**Type**: Real-time safety violation  
**Impact**: Potential audio dropout; GC pressure on RT thread; undefined behaviour under low memory  
**Description**: `AVAudioPCMBuffer` is allocated inside `TapState.feed()` which is called from the Core Audio I/O thread. The Core Audio I/O thread is a real-time thread; heap allocation is prohibited. Any allocation that triggers a GC pause or memory pressure event on this thread causes audio dropout.  
**V2 Ref**: ADR-003, Document 11 (Performance Budget §3)  
**Phase**: Phase 0  
**Fix**: Pre-allocate `AVAudioPCMBuffer` in `TapState.arm()` with fixed capacity matching the audio engine's buffer size. Reuse the pre-allocated buffer in `feed()` via `memcpy`. No allocation on RT thread.

---

### TD-C02: XPC Call While Holding NSLock (TapState)

**File**: `Sources/Orin/Services/TapState.swift`  
**Type**: Concurrency / priority inversion  
**Impact**: Potential deadlock if XPC call blocks while holding the lock; priority inversion: high-priority RT thread waits for low-priority main thread  
**Description**: `TapState.stop()` calls `recognitionRequest?.endAudio()` while holding `NSLock`. `endAudio()` is an XPC call to the `com.apple.speech.speechsynthesisd` process. XPC calls can block. Blocking while holding a lock that the audio callback thread may also try to acquire is a priority inversion and potential deadlock.  
**V2 Ref**: ADR-003, Document 11 §3  
**Phase**: Phase 0  
**Fix**: Capture `self.recognitionRequest` reference under lock, release lock, then call `endAudio()` outside the lock. Two-line fix.

---

### TD-C03: Ollama Thundering Herd (41 Concurrent Requests)

**File**: `Sources/Orin/Services/MeetingIntelligenceService.swift` lines 162-170  
**Type**: AI bottleneck / architectural violation  
**Impact**: System-wide freeze lasting 2-5 minutes after every long meeting; GPU OOM; timeout cascades  
**Description**: `MeetingIntelligenceService.analyzeChunked()` uses `withTaskGroup` to submit all N chunk analysis tasks simultaneously. For an 8-chunk meeting this creates 8 simultaneous Ollama HTTP requests. Ollama serializes them internally but all N approach the 60s timeout simultaneously, then all retry, producing 41 simultaneous requests. Result: GPU OOM → all fail → system freeze.  
**V2 Ref**: ADR-004, Document 05 (AI Orchestration §1-3)  
**Phase**: Phase 0  
**Fix**: Introduce `InferenceWorker` actor. Exactly one `InferenceJob` executes at a time.

---

### TD-C04: Generation Counter TOCTOU Race in ASR Restart

**File**: `Sources/Orin/Services/RecordingService.swift` lines ~595-640  
**Type**: Race condition  
**Impact**: Stale recognition callback fires after restart; transcript corruption; potential crash if stale reference is dereferenced  
**Description**: The generation counter pattern (incrementing a counter before ASR restart; checking it in callbacks) is a TOCTOU race. There is a window between incrementing the counter and the old recognition session completing where a stale callback can fire and pass the counter check. The counter is a mutable integer on `@MainActor`, not an actor-isolated state machine.  
**V2 Ref**: Document 04 (State Machine §5), ADR-003  
**Phase**: Phase 1 (temporary fix: atomic generation check); Phase 2 (full fix: `ASRSessionStateMachine` actor)  
**Fix**: `ASRSessionStateMachine` actor owns the restart lifecycle. Callbacks are validated against state machine state, not a mutable integer counter.

---

### TD-C05: `Task.sleep(1.5s)` on @MainActor in `finalize()`

**File**: `Sources/Orin/Services/RecordingService.swift` (finalize method)  
**Type**: Main thread blocking / architectural violation  
**Impact**: All UI updates frozen for 1.5 seconds after every recording stops; violates session-stop latency budget  
**Description**: A deliberate 1.5-second `Task.sleep` exists in the finalization path. This blocks `@MainActor` for 1.5 seconds — no UI updates, no touch responses, no SwiftUI animation. This was introduced as a workaround for a timing issue in ASR finalization and is not a permanent solution.  
**V2 Ref**: Document 11 §4, Document 04 §5  
**Phase**: Phase 0 (remove sleep; replace with appropriate await); Phase 2 (full fix via ASR state machine)  
**Fix**: Remove `Task.sleep`. Replace with `ASRSessionStateMachine` `Finalizing` state that waits for the `SpeechTranscriber` completion callback.

---

### TD-C06: Lazy `AVAudioConverter` Initialization on RT Thread

**File**: `Sources/Orin/Services/SystemAudioCaptureService.swift` (participant audio feed)  
**Type**: Real-time safety violation  
**Impact**: First audio buffer from participant channel may trigger `AVAudioConverter` init on RT thread; potential audio dropout  
**Description**: The `AVAudioConverter` for participant audio is lazily initialized on first use. If "first use" occurs within the Core Audio I/O callback, the initialization runs on the RT thread, which may allocate memory and call Objective-C APIs — both prohibited on the RT thread.  
**V2 Ref**: Document 11 §3  
**Phase**: Phase 0  
**Fix**: Initialize `AVAudioConverter` eagerly in `arm()` / `start()` before the audio engine starts.

---

### TD-C07: `ServiceContainer` Has No Thread Safety

**File**: `Sources/Orin/App/ServiceContainer.swift`  
**Type**: Concurrency violation  
**Impact**: Potential crash if `register()` and `resolve()` are called concurrently (e.g., during app startup race); `fatalError` on failed resolve masks misconfiguration  
**Description**: `ServiceContainer` stores services in a `[String: Any]` dictionary with no thread protection (`NSLock`, actor isolation, or `@MainActor`). `resolve()` calls `fatalError()` if the service is not registered — a crash, not a graceful error. It is a service locator, which is an anti-pattern that hides dependencies.  
**V2 Ref**: ADR-001, Document 03 §5  
**Phase**: Phase 1  
**Fix**: Replace with constructor injection at `OrinApp.init()` composition root. Delete `ServiceContainer.swift`.

---

## High Debt

### TD-H01: Hardcoded `en-IN` Locale in `RecordingService`

**File**: `Sources/Orin/Services/RecordingService.swift`  
**Type**: Architectural violation / multilingual gap  
**Impact**: Every non-English-India user gets incorrect ASR locale; completely blocks non-English market  
**V2 Ref**: Document 07 §2, Document 07 §5  
**Phase**: Phase 3  
**Fix**: Both channels read `VocabularyProvider.speechLocale` (user preference). `ASRBackendRouter` selects locale-appropriate backend.

---

### TD-H02: Hardcoded `en-US` Locale in `SystemAudioCaptureService`

**File**: `Sources/Orin/Services/SystemAudioCaptureService.swift`  
**Type**: Architectural violation / multilingual gap  
**Impact**: Participant audio always transcribed as English regardless of user configuration  
**V2 Ref**: Document 07 §2, Document 07 §5  
**Phase**: Phase 3  
**Fix**: Same as TD-H01 — read from user preference.

---

### TD-H03: Hardcoded English Keywords in AI Prompts

**Files**: `Sources/Orin/Services/MeetingIntelligenceService.swift` — `buildComprehensivePrompt()`, `detectMeetingType()`, `parseComprehensiveResponse()`, `keywordFallback()`  
**Type**: Architectural violation / multilingual gap  
**Impact**: Analysis completely fails to extract content for non-English sessions; section markers not found  
**V2 Ref**: Document 07 §7, ADR-009  
**Phase**: Phase 3  
**Fix**: Language-parameterized `PromptBuilder`; language-neutral ASCII section markers; `detectMeetingType()` keyword variants per language.

---

### TD-H04: `VocabularyProvider` Silent `.prefix(100)` Truncation

**File**: `Sources/Orin/Services/VocabularyProvider.swift`  
**Type**: Silent data loss  
**Impact**: 6 of 103 vocabulary terms silently dropped without log or warning; ASR never receives them  
**V2 Ref**: ADR-016, Document 07 §8  
**Phase**: Phase 3 (full Vocabulary V2); Phase 1 workaround (add logging)  
**Fix**: Replace with `VocabularyContext` builder with explicit tier budget allocation and `VocabularyBudgetExceeded` event.

---

### TD-H05: `persistChunkIfNeeded context.save()` on @MainActor

**File**: `Sources/Orin/Services/TranscriptStore.swift`  
**Type**: Performance / architectural violation  
**Impact**: Disk I/O blocks main thread during active recording; visible UI jank  
**V2 Ref**: Document 11 §8  
**Phase**: Phase 2  
**Fix**: Move `context.save()` to a background `ModelActor` or the `SwiftDataPersistenceAdapter`'s background context.

---

### TD-H06: `allSegments @Query` Loads All Meetings

**File**: `Sources/Orin/Views/Meetings/MeetingsView.swift` (or `MeetingsListViewModel`)  
**Type**: Memory / performance violation  
**Impact**: At 1,000+ meetings, this @Query loads all transcript segment data into memory; RSS violation  
**V2 Ref**: Document 11 §6, Document 12 §2  
**Phase**: Phase 2  
**Fix**: Add `#Predicate` scoped to current session; apply `@Attribute(.externalStorage)` to `MeetingItem.transcript`.

---

### TD-H07: `sampleCPUUsage()` Mach API in Production Every 5 Seconds

**File**: `Sources/Orin/Services/RecordingService.swift`  
**Type**: Performance overhead  
**Impact**: 720 unnecessary Mach API calls per hour during recording; runs on @MainActor; ~2ms per call  
**V2 Ref**: Document 11 §8  
**Phase**: Phase 1  
**Fix**: Gate behind `#if DEBUG` or move to Instruments trace hook.

---

### TD-H08: `WhisperTranscriptionService` Is a Stub

**File**: `Sources/Orin/Services/WhisperTranscriptionService.swift`  
**Type**: Missing implementation  
**Impact**: No hi-IN or other non-Apple-locale ASR capability; significant market gap  
**V2 Ref**: Document 07 §9, ADR-014  
**Phase**: Phase 3  
**Fix**: Implement `WhisperASRBackend` with whisper.cpp HTTP server integration.

---

### TD-H09: `MeetingItem.transcript` Not Tagged `@Attribute(.externalStorage)`

**File**: `Sources/Orin/Models/OrinModels.swift`  
**Type**: SwiftData scalability risk  
**Impact**: Transcript text loaded into SQLite main database row; @Query loads entire transcript for every meeting in list view  
**V2 Ref**: Document 11 §6, Document 12 §2  
**Phase**: Phase 1  
**Fix**: Add `@Attribute(.externalStorage)` to any transcript / large text field in `MeetingItem`.

---

### TD-H10: `NSLock` in `RecognitionDiagnostics` on Audio Callback Path

**File**: `Sources/Orin/Services/RecognitionDiagnostics.swift`  
**Type**: Real-time safety risk  
**Impact**: `NSLock.lock()` may block; if called from the RT audio thread, causes priority inversion  
**V2 Ref**: Document 11 §3  
**Phase**: Phase 0  
**Fix**: Replace `NSLock` in counter-increment path with `os_unfair_lock` or `OSAtomicIncrement`.

---

### TD-H11: `MeetingIntelligenceService` Is a `final class`, Not an Actor

**File**: `Sources/Orin/Services/MeetingIntelligenceService.swift`  
**Type**: Concurrency violation risk  
**Impact**: Mutable state in `MeetingIntelligenceService` is not actor-isolated; concurrent calls from multiple Task contexts could race on shared properties  
**V2 Ref**: ADR-003, Document 03 §6  
**Phase**: Phase 2  
**Fix**: Convert to actor or ensure all mutable state is protected. At minimum, the `InferenceWorker` refactor in Phase 0 makes the concurrency model explicit.

---

### TD-H12: `AIService` Has Hardcoded Ollama Model IDs

**File**: `Sources/Orin/Services/AIService.swift`  
**Type**: Architectural violation  
**Impact**: Cannot change AI model without modifying source code; blocks model router, A/B testing, model quality improvements  
**V2 Ref**: Document 05 §4, ADR-004  
**Phase**: Phase 1  
**Fix**: `InferenceProvider` protocol with `OllamaInferenceAdapter` exposes `modelID` as a configurable property read from `UserDefaults`/Settings.

---

### TD-H13: No `InferenceProvider` Protocol — AIService Called Directly

**File**: `Sources/Orin/Services/MeetingIntelligenceService.swift` calls `AIService` directly  
**Type**: Architectural violation / portability blocker  
**Impact**: Cannot swap AI backend; cannot add LM Studio, Apple Foundation Models, or cloud providers  
**V2 Ref**: Document 05 §4, ADR-001  
**Phase**: Phase 1  
**Fix**: `InferenceProvider` protocol + `OllamaInferenceAdapter`.

---

### TD-H14: No `ASRBackend` Protocol — ASR Called Directly

**File**: `Sources/Orin/Services/RecordingService.swift` calls `SpeechTranscriber` directly  
**Type**: Architectural violation / portability blocker  
**Impact**: Cannot swap ASR backend; blocks Whisper integration; blocks cross-platform  
**V2 Ref**: Document 07 §3, ADR-001  
**Phase**: Phase 1  
**Fix**: `ASRBackend` protocol + `SpeechTranscriberASRAdapter`.

---

### TD-H15: `TranscriptStore` O(N²) Save Pattern

**File**: `Sources/Orin/Services/TranscriptStore.swift`  
**Type**: Performance  
**Impact**: Each `persistChunkIfNeeded` call triggers a full `context.save()` which flushes all dirty objects; for N dirty chunks this is O(N) saves × O(objects) work = O(N²) total  
**V2 Ref**: Document 11 §8  
**Phase**: Phase 2  
**Fix**: Batch saves using a background `ModelActor`; save every 30 seconds or on session stop, not on every chunk.

---

## Medium Debt

### TD-M01: `RecordingService` Is 1,355 Lines

**File**: `Sources/Orin/Services/RecordingService.swift`  
**Type**: God object / maintainability  
**Description**: RecordingService contains audio capture, ASR management, session lifecycle, vocabulary provision, CPU sampling, and finalization logic. This violates single responsibility and makes testing and modification difficult.  
**V2 Ref**: Document 03 §4  
**Phase**: Phase 2

---

### TD-M02: `MeetingIntelligenceService` Is 1,010 Lines

**File**: `Sources/Orin/Services/MeetingIntelligenceService.swift`  
**Type**: God object / maintainability  
**Description**: Contains chunking, prompt building, HTTP calling, response parsing, hallucination detection, and post-processing. Should be split into `AnalysisCoordinator`, `PromptBuilder`, `ResponseParser`.  
**V2 Ref**: Document 03 §4, Document 05  
**Phase**: Phase 2

---

### TD-M03: `MeetingsView` Is 2,281 Lines (historical, needs verification)

**File**: `Sources/Orin/Views/Meetings/MeetingsView.swift`  
**Type**: God view / maintainability  
**Description**: All meeting list and detail logic in a single view file. Should be split into smaller view components.  
**Phase**: Phase 2 (alongside SwiftData @Query fixes)

---

### TD-M04: No `PersistenceStore` Protocol

**File**: All services using SwiftData `ModelContext` directly  
**Type**: Portability blocker  
**Description**: SwiftData is Apple-only. Direct use in service layer blocks Windows/Android portability and makes unit testing without a real model container impossible.  
**V2 Ref**: ADR-012, Document 03  
**Phase**: Phase 1

---

### TD-M05: `FeatureFlags` Enum with Static Computed Properties

**File**: `Sources/Orin/Services/FeatureFlags.swift`  
**Type**: Testability  
**Description**: `FeatureFlags.useNewMicPipeline` reads `UserDefaults.standard` directly. Cannot be injected in tests. A `FeatureFlagStore` protocol would allow test injection.  
**V2 Ref**: Document 03 §8  
**Phase**: Phase 1

---

### TD-M06: Missing `VocabularyItem` Language Namespace

**File**: `Sources/Orin/Services/VocabularyProvider.swift`  
**Type**: Data quality  
**Description**: 103 vocabulary terms have no `languageCode` field. Hindi/Hinglish terms are included in English-locale sessions. English terms are included in Hindi sessions.  
**V2 Ref**: Document 07 §8  
**Phase**: Phase 3

---

### TD-M07: `AIProviderTestService` Health Check Not Cached

**File**: `Sources/Orin/Services/AIProviderTestService.swift`  
**Type**: Performance  
**Description**: Ollama health check runs on every call with no caching. Should be cached for 10 seconds to avoid 200ms HTTP round-trip on every analysis start check.  
**V2 Ref**: Document 05 §6  
**Phase**: Phase 1

---

### TD-M08: `filterMeetings()` O(N) Linear Scan Without Debounce

**File**: `Sources/Orin/Services/MeetingDataService.swift` or `MeetingsView`  
**Type**: Performance  
**Description**: Meeting list filter runs on every keystroke with no debounce. On 1,000+ meetings this causes visible lag.  
**Phase**: Phase 2

---

### TD-M09: `DebugResetService` Has `@unchecked Sendable` (TICKET-002)

**File**: `Sources/Orin/Developer/DebugResetService.swift`  
**Type**: Concurrency risk  
**Description**: `@unchecked Sendable` suppresses the compiler's data-race detection. The service may have actual data races that are currently invisible.  
**V2 Ref**: Document 11, TICKET-002 in memory  
**Phase**: Phase 2

---

### TD-M10: `MeetingRetentionService` Has Actor Isolation Issue (TICKET-001)

**File**: `Sources/Orin/Services/MeetingRetentionService.swift`  
**Type**: Concurrency violation  
**Description**: TICKET-001 (open): actor isolation issue in MeetingRetentionService. Not yet resolved.  
**Phase**: Phase 1

---

### TD-M11: No Unit Tests for Domain Logic

**Files**: All service files  
**Type**: Testing gap  
**Description**: No unit tests exist for `TranscriptChunker`, `MeetingIntelligenceService` prompt construction, `VocabularyProvider`, or state machine transitions. The only tests are integration tests that require the full app. V2 migration creates testable units — tests must be written alongside.  
**Phase**: Ongoing — each phase adds unit tests for new components

---

### TD-M12: `ConversationTimelineBuilder` Purpose Unclear

**File**: `Sources/Orin/Services/ConversationTimelineBuilder.swift` (234 lines)  
**Type**: Dead code risk  
**Description**: Unclear whether this is used in the current UI or is legacy code. Needs audit.  
**Phase**: Phase 1 (audit)

---

### TD-M13: `ReflowEngine` and `RolloverEngine` Not Mapped to V2 Architecture

**Files**: `Sources/Orin/Services/ReflowEngine.swift`, `Sources/Orin/Services/RolloverEngine.swift`  
**Type**: Unclear ownership  
**Description**: These services do not have a clear home in the V2 bounded context model. Need to be mapped to a context or identified as deprecated.  
**Phase**: Phase 2 (context assignment audit)

---

### TD-M14: `VaultService` Security Model Not Reviewed

**File**: `Sources/Orin/Services/VaultService.swift` (436 lines)  
**Type**: Security  
**Description**: VaultService manages encrypted storage. Its security model has not been audited against the V2 privacy requirements (ConsentRecord, Restricted data class, data deletion guarantees).  
**Phase**: Phase 2 (security audit)

---

### TD-M15: `SystemAudioProvider` Protocol Name Does Not Match V2

**File**: `Sources/Orin/Providers/Protocols/SystemAudioProvider.swift`  
**Type**: Naming inconsistency  
**Description**: V2 calls this `SystemAudioCaptureProvider`. Current name is `SystemAudioProvider`. Minor but creates confusion when reading V2 docs alongside code.  
**Phase**: Phase 1 (rename)

---

### TD-M16: `MeetingDetectorProvider` Protocol Name Does Not Match V2

**File**: `Sources/Orin/Providers/Protocols/SystemAudioProvider.swift` (defined here)  
**Type**: Naming inconsistency  
**Description**: V2 calls this `MeetingDetector`. Current name is `MeetingDetectorProvider`.  
**Phase**: Phase 1 (rename)

---

## Low Debt

### TD-L01: `SessionLogger` and `AnalysisPerfLogger` Are Not `EventBus` Subscribers

**Files**: `Sources/Orin/Services/SessionLogger.swift`, `Sources/Orin/Services/AnalysisPerfLogger.swift`  
**Type**: Architecture (future)  
**Description**: These should subscribe to domain events instead of being called directly. Low priority until EventBus exists.  
**Phase**: Phase 2

---

### TD-L02: `OllamaInstallerService` UI Flow Not Mapped to V2 Onboarding

**File**: `Sources/Orin/Services/OllamaInstallerService.swift`  
**Type**: UX  
**Description**: Ollama install flow exists but Whisper install flow does not. V2 needs a unified AI provider setup flow.  
**Phase**: Phase 3

---

### TD-L03: `DailyBriefService` Not Mapped to Any V2 Bounded Context

**File**: `Sources/Orin/Services/DailyBriefService.swift`  
**Type**: Context ownership unclear  
**Description**: Daily brief is a cross-cutting feature. Should belong to either Intelligence Context (analyses) or Knowledge Context (trends). Needs explicit assignment.  
**Phase**: Phase 2 (assign to context)

---

### TD-L04: `FolderSummaryService` Duplicates MeetingIntelligenceService Logic

**File**: `Sources/Orin/Services/FolderSummaryService.swift` (210 lines)  
**Type**: Code duplication  
**Description**: Folder-level summarization likely duplicates the chunking and prompt logic in `MeetingIntelligenceService`. Should reuse `InferenceWorker` once it exists.  
**Phase**: Phase 2

---

### TD-L05: `VoiceCommandService` Not Mapped to Plugin / Intent System

**File**: `Sources/Orin/Services/VoiceCommandService.swift`  
**Type**: Future architecture  
**Description**: Voice commands are a form of `UserIntent`. Should integrate with the V2 `IntentRouter` when it exists.  
**Phase**: Phase 5

---

### TD-L06: `QuickCaptureParser` Not Mapped to V2 Bounded Context

**Files**: `Sources/Orin/QuickCapture/`  
**Type**: Context ownership unclear  
**Description**: Quick capture is a user input mechanism. V2 context: Session Context (captures user-initiated notes) or Intelligence Context (AI processes the note). Needs explicit assignment.  
**Phase**: Phase 2

---

### TD-L07: `RecurringMeetingService` Logic Could Be Absorbed by Learning Engine

**File**: `Sources/Orin/Services/RecurringMeetingService.swift` (319 lines)  
**Type**: Redundancy (future)  
**Description**: Recurring meeting detection is a form of meeting pattern learning. `MeetingPatternLearner` (Phase 4) may subsume this service.  
**Phase**: Phase 4

---

### TD-L08: `ErrorManager` Uses String-Based Error Codes

**File**: `Sources/Orin/Services/ErrorManager.swift` (470 lines)  
**Type**: Maintainability  
**Description**: Error codes and user-facing messages managed via string dictionaries. V2 domain errors should be typed Swift enums.  
**Phase**: Phase 2

---

### TD-L09: `NSPanelOverlayProvider` Hard-Couples to Specific NSPanel Type

**File**: `Sources/Orin/Providers/macOS/NSPanelOverlayProvider.swift`  
**Type**: Platform coupling  
**Description**: Directly uses NSPanel; not abstracted behind `OverlayProvider`. Acceptable for macOS-only; note for future cross-platform work.  
**Phase**: Phase 6 (cross-platform only concern)

---

## Debt Priority Matrix

```
CRITICAL (Fix in Phase 0/1 — blocks shipping)
├── TD-C01  Heap allocation in audio callback
├── TD-C02  XPC while holding NSLock
├── TD-C03  Ollama thundering herd
├── TD-C04  Generation counter TOCTOU race
├── TD-C05  Task.sleep on @MainActor
├── TD-C06  Lazy AVAudioConverter on RT thread
└── TD-C07  ServiceContainer no thread safety

HIGH (Fix in Phase 1/2 — degrades correctness)
├── TD-H01/H02  Hardcoded locales
├── TD-H03      Hardcoded English in AI prompts
├── TD-H04      Silent vocabulary truncation
├── TD-H05/H15  SwiftData save on main thread
├── TD-H06/H09  @Query loads all meetings / no externalStorage
├── TD-H07      Mach API in production
├── TD-H08      Whisper stub
├── TD-H10      NSLock in RecognitionDiagnostics
├── TD-H11      MeetingIntelligenceService not actor
├── TD-H12/H13  Hardcoded model IDs / no InferenceProvider
└── TD-H14      No ASRBackend protocol

MEDIUM (Fix during phase work)
├── TD-M01-M03  God objects (RecordingService, MIS, MeetingsView)
├── TD-M04      No PersistenceStore protocol
├── TD-M05      FeatureFlags not injectable
├── TD-M06      Vocabulary no language namespace
├── TD-M07      Health check not cached
├── TD-M08      filterMeetings no debounce
├── TD-M09/M10  Unchecked Sendable / actor isolation tickets
├── TD-M11      No unit tests
└── TD-M12-M16  Misc naming / unclear purpose

LOW (Address opportunistically)
└── TD-L01-L09  Logging, naming, future architecture hooks
```
