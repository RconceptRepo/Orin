# 10 — Technical Debt Register

**Document status**: Authoritative  
**Review date**: 2026-06-29  
**Based on**: 9-agent architectural review of commit 4f603ea  
**Overall verdict**: NEEDS_PATCHING (targeted fixes, not a rewrite)

This register is the single source of truth for all known engineering problems in the Orin codebase. Items are ordered within each severity tier by production risk. Every item references the specific source file and line range where the defect lives.

---

## Critical Severity

These five items are causing production crashes and system-wide freezes today. No other work should proceed until all five are resolved.

---

### TD-001: Unbounded concurrent Ollama dispatch

**Severity**: CRITICAL  
**Category**: Architecture / Performance  
**Effort**: HOURS  
**Impact**: The direct root cause of post-call system freezes and the "41-request thundering herd." `analyzeChunked()` submits all N chunk tasks simultaneously to `withTaskGroup` with no concurrency limit. For a 150-minute meeting, `TranscriptChunker` produces approximately 20 chunks. All 20 tasks call `isOllamaAvailable()` (a live HTTP `/api/tags` round-trip) and then `/api/generate` simultaneously. Ollama is a single-GPU, single-threaded inference process: it accepts all 20 TCP connections but serializes GPU inference behind one execution slot. The remaining 19 requests wait. At t=60s, all 19 hit the `URLSession` `timeoutInterval = 60` simultaneously. All 19 then `Task.sleep(nanoseconds: 10_000_000_000)` — with no jitter — and fire a second synchronized wave at t=70s. Wave 1: 20 requests. Wave 2: 19–20 retry requests. Observed total: 41 concurrent connections to a process that can service one at a time. The GPU is saturated, system memory is under pressure from 20 concurrent response buffers, and the Ollama process itself can crash with an OOM condition, causing subsequent analysis attempts to all fail.  
**Files**: `Sources/Orin/Services/MeetingIntelligenceService.swift` lines 160–173 (the `withTaskGroup` loop in `analyzeChunked()`); `Sources/Orin/Services/AIService.swift` line 81 (the fixed 10s retry sleep)  
**Fix**: For Ollama and all local providers, replace the `withTaskGroup` fan-out with a sequential `for` loop: `for (i, chunk) in chunks.enumerated() { let ca = await TranscriptChunker.analyzeChunk(chunk, ...) }`. Alternatively, add an `AsyncSemaphore(value: 1)` inside the `addTask` body and `await sem.wait()` before each call. Sequential processing has identical total throughput (Ollama serializes anyway) but eliminates the catastrophic timeout cascade entirely. Simultaneously, replace the fixed `10_000_000_000` nanosecond sleep in `AIService.generate()` with a randomized value in the range `8_000_000_000...15_000_000_000` to prevent synchronized retry waves if parallelism is ever re-enabled for cloud providers.  
**Dependencies**: None. This is the first fix to ship.

---

### TD-002: Real-time heap allocation in audio callbacks

**Severity**: CRITICAL  
**Category**: Concurrency / Performance  
**Effort**: DAYS  
**Impact**: `MicTranscriberFeed.feed()` and `ParticipantSTFeed.feed()` allocate a new `AVAudioPCMBuffer` on every Core Audio I/O callback. The I/O callback fires approximately 46 times per second. Heap allocation on the real-time audio thread violates Core Audio's real-time safety contract. The memory allocator can block on a `pthread_mutex` held by a non-real-time thread (e.g., the GC or another malloc call), causing unbounded priority inversion. Under memory pressure — which is common when Ollama is also running on the same machine — these allocations can stall the I/O thread for milliseconds, causing audio dropout, recognition engine stalls, and eventual audio callback termination by the OS. The `NSLock.withLock` block in both `feed()` methods compounds the problem: lock acquisition on the real-time thread can itself block if any other code path holds the lock.  
**Files**: `Sources/Orin/Services/RecordingService.swift` (`MicTranscriberFeed.feed()`); `Sources/Orin/Services/SystemAudioCaptureService.swift` (`ParticipantSTFeed.feed()`)  
**Fix**: Pre-allocate the `AVAudioPCMBuffer` in `arm()`, after the `AVAudioConverter` is created and the output format and frame capacity are known. Store it as a property (`private var preallocatedBuffer: AVAudioPCMBuffer?`). In `feed()`, use the pre-allocated buffer instead of allocating a new one. The converter API allows in-place conversion to a pre-allocated output buffer. This eliminates all heap allocation from the real-time path. Apply the same pattern to both `MicTranscriberFeed` and `ParticipantSTFeed`.  
**Dependencies**: None. Can be implemented in parallel with TD-001.

---

### TD-003: TapState.disarm() XPC call inside NSLock

**Severity**: CRITICAL  
**Category**: Concurrency  
**Effort**: HOURS  
**Impact**: `TapState.disarm()` (line 107) calls `recognitionRequest?.endAudio()` inside `lock.withLock {}`. `endAudio()` is a synchronous XPC call to the `com.apple.speech.speechdatainstallerd` daemon. The Core Audio I/O thread calls `TapState.feed()` (line 118) under the same `NSLock`. If `disarm()` is called from the MainActor while the I/O thread is blocked waiting to acquire the lock, or if the I/O thread acquires the lock just after `disarm()` starts the XPC round-trip, the I/O thread blocks for the full IPC latency (typically 1–5ms, but variable). This is a textbook priority inversion on a real-time thread. Under worst-case IPC conditions (daemon swap, kernel scheduling latency), the block can exceed 10ms, causing the Core Audio hardware interrupt deadline to be missed and the audio subsystem to tear down the I/O session. The fix pattern is already documented and implemented correctly in `TapState.updateRequest()` (lines 93–98): capture the reference under lock, release lock, then call `endAudio()` outside.  
**Files**: `Sources/Orin/Services/TapState.swift` lines 105–111  
**Fix**: Refactor `disarm()` to use the same two-phase pattern as `updateRequest()`:
```swift
func disarm() {
    var req: SFSpeechAudioBufferRecognitionRequest?
    lock.withLock {
        req = recognitionRequest
        recognitionRequest = nil
        audioFile = nil
    }
    req?.endAudio()  // outside lock — same pattern as updateRequest()
}
```
**Dependencies**: None. TD-003 and TD-004 are independent.

---

### TD-004: AVAudioEngineConfigurationChange debounce race

**Severity**: CRITICAL  
**Category**: Concurrency  
**Effort**: HOURS  
**Impact**: The `AVAudioEngineConfigurationChange` notification observer in `RecordingService` fires on an arbitrary background thread (the notification center's delivery thread) and wraps its handler in `Task { @MainActor in }`. If two notifications arrive within 500ms — which is common when a Bluetooth headset connects and the OS fires both a hardware-attach and a configuration-update notification — both notifications are received on the background thread before either `Task` executes on the MainActor. Both tasks read `lastRouteChangeTime` as `nil` (or as the same stale timestamp), both pass the debounce guard, and both proceed to call `removeTap()` followed by `installTap()` on the running `AVAudioEngine`. The second `removeTap + installTap` pair arrives while the first is still executing, causing a Core Audio `EXC_BAD_ACCESS` in the engine's tap installation path. This crash has been observed in production.  
**Files**: `Sources/Orin/Services/RecordingService.swift` (AVAudioEngineConfigurationChange handler)  
**Fix**: Replace the `Task { @MainActor }` + `lastRouteChangeTime` guard with a `DispatchWorkItem` cancel-and-reschedule pattern, which correctly coalesces events regardless of how many notifications arrive before the handler executes:
```swift
private var pendingRouteChangeWork: DispatchWorkItem?

// In the notification observer:
pendingRouteChangeWork?.cancel()
let work = DispatchWorkItem { [weak self] in
    self?.handleRouteChange()
}
pendingRouteChangeWork = work
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
```
The `cancel()` on the previous item guarantees that only the most recent notification triggers a handler, regardless of threading. This is the correct debounce primitive for this pattern.  
**Dependencies**: None.

---

### TD-005: ServiceContainer — no thread safety, fatalError on resolve

**Severity**: CRITICAL  
**Category**: Concurrency / Architecture  
**Effort**: HOURS  
**Impact**: `ServiceContainer.swift` stores services in a plain `[String: Any]` dictionary with no synchronization whatsoever. Services are registered on the main thread in `OrinApp.init()`. They are resolved on cooperative-pool threads in `Task.detached` closures used by `MeetingDetectorService.poll()` and in recognition callbacks. This is a real unsynchronized read/write data race that the Swift concurrency runtime and Thread Sanitizer would both flag. The `fatalError` in `resolve()` — "Service \(key) not registered." — means any registration-ordering bug, or any thread that calls `resolve()` before `OrinApp.init()` completes, terminates the process immediately with no recovery path. In audio callbacks (the most latency-sensitive context in the app) there is no acceptable reason for a service lookup to ever `fatalError`.  
**Files**: `Sources/Orin/App/ServiceContainer.swift` (entire 23-line file)  
**Fix**: Add a single `NSLock` and wrap both `register()` and `resolve()` under it. This is a two-line change. For the `fatalError`: change it to return an `Optional<T>` and have call sites handle `nil` gracefully, or — better — eliminate `ServiceContainer.resolve()` calls from audio callbacks entirely by passing dependencies through constructor injection at the point where `RecordingService` and `SystemAudioCaptureService` are created.  
**Dependencies**: None. Apply the NSLock fix immediately; constructor injection can follow as part of TD-007 (RecognitionSessionManager extraction).

---

## High Severity

These items cause measurable degradation in performance, correctness, or privacy. Each must be resolved within the Phase 1 or Phase 2 window.

---

### TD-006: O(N²) SwiftData writes during active recording

**Severity**: HIGH  
**Category**: Performance  
**Effort**: HOURS  
**Impact**: `TranscriptStore.persistChunkIfNeeded()` calls `context.save()` synchronously on `@MainActor` every time the transcript grows by 10 or more characters (the `chunkWriteThreshold`). At a typical speech rate of 130 words per minute, the threshold is crossed multiple times per second. Each `context.save()` is a synchronous SQLite WAL write. The main actor is blocked on disk I/O continuously during active recording. The UI drops frames. The 3-second checkpoint timer also calls `safeSaveWithRetry()`, which means checkpoint saves and chunk saves can overlap on the same actor, producing back-to-back SQLite writes. The compound effect is that the main actor thread is effectively dedicated to SQLite I/O during recording, making all other UI updates and user interactions sluggish.  
**Files**: `Sources/Orin/Services/TranscriptStore.swift` lines 224–236 (`persistChunkIfNeeded()`)  
**Fix**: Remove the `try context.save()` call from `persistChunkIfNeeded()`. Replace it with `context.insert(chunk)` only. The existing `checkpoint()` method (called every 3 seconds by the checkpoint timer) already calls `safeSaveWithRetry()`, which flushes all pending inserts to disk. TranscriptChunks are inserted in-memory and persisted at the next 3-second checkpoint boundary. This reduces SQLite write frequency from multiple-per-second to once per 3 seconds (20 writes per hour during active recording vs. several hundred).  
**Dependencies**: None. Safe to apply independently.

---

### TD-007: 400+ lines of recognition session management duplicated verbatim

**Severity**: HIGH  
**Category**: Code Quality / Architecture  
**Effort**: WEEKS  
**Impact**: The entire recognition session lifecycle — generation counter (`recognitionGeneration: Int`), `generationHadSpeech: Bool` flag, error-1110 restart logic with 200ms / 1s delay, 10-second cold-start watchdog `Task`, utterance-boundary heuristic, and stale-result shrink detection — is copy-pasted verbatim between `RecordingService.swift` and `SystemAudioCaptureService.swift`. Any bug fixed in one service must be manually applied to the other. This duplication has already produced a real divergence: the mic channel hardcodes `en-IN` and the participant channel hardcodes `en-US` (see TD-012), because the two copies evolved independently after the initial paste. A second active bug — the generation counter TOCTOU race where the watchdog `Task` and the error callback `Task` can both pass the `recognitionGeneration == gen` check before either increments the counter — must be fixed in both files independently, doubling the chance of a missed fix.  
**Files**: `Sources/Orin/Services/RecordingService.swift` (approximately lines 400–820); `Sources/Orin/Services/SystemAudioCaptureService.swift` (approximately lines 300–700)  
**Fix**: Extract a `RecognitionSessionManager` actor that owns the generation counter, restart logic, cold-start watchdog, and utterance-boundary heuristic. Both `RecordingService` and `SystemAudioCaptureService` hold one `RecognitionSessionManager` instance and delegate all session lifecycle decisions to it via a `RecognitionSessionDelegate` protocol. The generation-counter approach is architecturally correct and must be preserved — it simply needs to live in one class. This extraction also resolves the TOCTOU race by making the counter increment atomic under actor isolation.  
**Dependencies**: TD-005 (ServiceContainer must be thread-safe before adding a new actor that is resolved from it).

---

### TD-008: CalendarService.status data race

**Severity**: HIGH  
**Category**: Concurrency  
**Effort**: DAYS  
**Impact**: `CalendarService.status` is an `@Observable`-tracked property. It is written on `@MainActor` (inside `syncEvents()` and `requestPermission()`). It is read on cooperative-pool threads inside `nonisolated` methods of `MeetingDetectorService` — specifically in `detectFromCalendar()`, which is called from a `Task.detached` in `MeetingDetectorService.poll()`. Swift's `@Observable` macro inserts observation hooks but does not make property access thread-safe. A concurrent write on the main actor and a read on a cooperative-pool thread is an unsynchronized data race. Under Swift 6 strict concurrency checking this is a compile-time error; under the current Swift 5 mode it is a runtime race that TSan would flag.  
**Files**: `Sources/Orin/Services/CalendarService.swift`; `Sources/Orin/Services/MeetingDetectorService.swift`  
**Fix**: Annotate `CalendarService` with `@MainActor`. Any call site in `MeetingDetectorService` that reads `CalendarService.status` must then `await MainActor.run { ... }` or be restructured to pass the status as a value parameter. Alternatively, use `@MainActor` on `MeetingDetectorService` entirely — the commit 4f603ea already added `@MainActor` to `MeetingDetectorService` for this reason; verify that `CalendarService.status` reads are now covered by the same actor boundary.  
**Dependencies**: None.

---

### TD-009: MeetingsView.swift — 2,281 lines, Single Responsibility violated

**Severity**: HIGH  
**Category**: Code Quality / Architecture  
**Effort**: WEEKS  
**Impact**: `MeetingsView.swift` is 2,281 lines and contains two top-level view structs, 36 private helper types, the full analysis orchestration state machine, recording lifecycle observers, export logic, folder management, deletion logic, and transcript display. This is the most severe Single Responsibility Principle violation in the codebase. No single developer can reason about the full file. Adding a feature to any one area requires reading through all 2,281 lines to understand side effects. The analysis orchestration (writing 12 `MeetingItem` properties and calling `safeSave` twice) is embedded in a `View` struct, which means it has no isolation from SwiftUI re-renders and is untestable without constructing the entire view hierarchy. The `allSegments @Query` (TD-010) is also in this file, loading all segments from all meetings on every render.  
**Files**: `Sources/Orin/Views/Meetings/MeetingsView.swift`  
**Fix**: Decompose into at minimum six files: `MeetingsView.swift` (list panel and folder panel, ~350 lines), `MeetingDetailView.swift` (detail panel, recording card, ~450 lines), `FolderDetailView.swift` (~200 lines), `MeetingRowViews.swift` (all row types: `PastMeetingRowView`, `UpcomingDayGroupCard`, `UpcomingMeetingItemRow`, ~300 lines), `MeetingInsightComponents.swift` (`InsightCard`, `ActionItemCard`, `DecisionCard`, `KnowledgeSnapshotView`, ~400 lines), `MeetingSharedTypes.swift` (local enums and draft models, ~100 lines). Extract the analysis orchestration into a new `MeetingAnalysisCoordinator` observable class, injected as a dependency. The view calls coordinator methods; the coordinator owns all `MeetingItem` property writes and `safeSave` calls.  
**Dependencies**: None for the file split (pure refactor). TD-024 must be resolved as part of this work.

---

### TD-010: allSegments @Query loads all segments from all meetings

**Severity**: HIGH  
**Category**: Performance  
**Effort**: DAYS  
**Impact**: `MeetingsView` declares `@Query var allSegments: [TranscriptSegment]` with no predicate. SwiftData fetches every `TranscriptSegment` row from the SQLite store and loads it into memory on every render of `MeetingsView`. At 100 meetings with 500 segments each, this is 50,000 in-memory `TranscriptSegment` objects loaded to display a meeting list that shows only titles, dates, and summaries. Each `@Observable` change on any `MeetingItem` triggers a re-evaluation of all `@Query` bindings. The segments are used only in `MeetingDetailView` to render the conversation timeline for the currently selected meeting. Loading all of them in the parent list view is architecturally incorrect.  
**Files**: `Sources/Orin/Views/Meetings/MeetingsView.swift` (the `@Query var allSegments` declaration)  
**Fix**: Remove `allSegments` from `MeetingsView`. Add a predicated `@Query` to `MeetingDetailView`:
```swift
@Query(
    filter: #Predicate<TranscriptSegment> { $0.meetingId == meetingID },
    sort: \.timestamp
) var segments: [TranscriptSegment]
```
where `meetingID` is the selected meeting's UUID passed via initializer. SwiftData pushes the filter to SQLite and returns only the current meeting's segments. This change is a prerequisite for TD-009 (the `MeetingsView` decomposition will naturally enforce this).  
**Dependencies**: None independently. Logically part of TD-009.

---

### TD-011: builtInTerms silently truncated — 6 built-in terms never delivered to ASR

**Severity**: HIGH  
**Category**: Code Quality  
**Effort**: DAYS  
**Impact**: `VocabularyProvider.builtInTerms` contains 103 terms. `VocabularyProvider.allTerms` applies `.prefix(100)` before any user custom terms are appended: `Array((builtInTerms + userTerms).prefix(100))`. Because built-in terms are first, the last 6 built-in terms ("sath mein", "suno", "seedha", "confirm karo" and 2 others in the Hinglish pack) are silently dropped before any user terms are ever considered. A user who has added even one custom term via `defaults write` receives 99 built-in terms and 1 user term — the last 4 built-in terms are dropped to make room. There is no warning, no log entry, no UI indicator that truncation is occurring. The 100-term cap is Apple's documented limit for `contextualStrings`; the correct behavior is to enforce it with explicit priority ordering, not silent truncation at the concatenation boundary.  
**Files**: `Sources/Orin/Services/VocabularyProvider.swift` lines 123–125  
**Fix**: Apply priority-ordered budget allocation. User terms are higher priority than built-in terms: `Array((userTerms + builtInTerms).prefix(100))`. Add a `Logger.warning()` call when the total count exceeds 100 so the condition is observable in logs. As part of MT-004 (layered vocabulary), formalize priority ordering: session attendee names > user terms > org terms > built-in by detected language > built-in English fallback, with each tier consuming budget sequentially until 100 is reached.  
**Dependencies**: None for the immediate fix. MT-004 for the full redesign.

---

### TD-012: Legacy SFSpeechRecognizer hardcodes locale, ignores VocabularyProvider.speechLocale

**Severity**: HIGH  
**Category**: Architecture  
**Effort**: DAYS  
**Impact**: The legacy `SFSpeechRecognizer` path in `RecordingService` declares: `private lazy var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-IN"))`. In `SystemAudioCaptureService`, the participant channel creates `SFSpeechRecognizer(locale: Locale(identifier: "en-US"))`. Both ignore `VocabularyProvider.speechLocale`, which exists specifically to allow locale configuration without a rebuild. The `SpeechTranscriber` path (Phase 2A) correctly reads `VocabularyProvider.speechLocale`; the legacy path never will unless this is fixed. Additionally, the `lazy var` bakes in the locale at first access — if the user changes `orin.speechLocale` in UserDefaults and the lazy var has already been evaluated, the change has no effect until the app is relaunched. The two channels using different hardcoded locales also means that en-IN acoustic model biases apply to the mic and en-US acoustic model biases apply to participants on the same call, producing inconsistent recognition accuracy between channels.  
**Files**: `Sources/Orin/Services/RecordingService.swift` (`speechRecognizer` lazy var); `Sources/Orin/Services/SystemAudioCaptureService.swift` (participant `SFSpeechRecognizer` initialization)  
**Fix**: Remove the `lazy var` pattern. Create `SFSpeechRecognizer` at session start (inside `startRecognition()`) using `VocabularyProvider.speechLocale` at that moment. Apply the same change to `SystemAudioCaptureService`. Both channels now use the same locale source, and the locale is re-read on every session start rather than being baked in at first access.  
**Dependencies**: TD-007 (RecognitionSessionManager extraction will create the natural place to consolidate locale initialization).

---

### TD-013: MeetingItem.transcript stored inline in SQLite — no external storage

**Severity**: HIGH  
**Category**: Performance  
**Effort**: DAYS  
**Impact**: `MeetingItem.transcript: String` is stored as an inline SQLite TEXT column with no `@Attribute(.externalStorage)` annotation. SwiftData loads this column for every `MeetingItem` row returned by any `@Query`, including the `MeetingsView` list query that fetches all meetings to display titles, dates, and summaries. A 2-hour meeting produces approximately 40,000–60,000 characters of transcript. With 100 meetings, the list view query loads 4–6 MB of transcript data into memory just to display meeting titles. This also means that any `@Observable` change on a `MeetingItem` that triggers a list re-render causes all transcript blobs to be re-evaluated by the SwiftUI diffing engine.  
**Files**: `Sources/Orin/Models/OrinModels.swift` (`MeetingItem.transcript` property)  
**Fix**: Add `@Attribute(.externalStorage)` to `transcript: String`. SwiftData will store the blob as an external binary file in the app's container and only load it when the property is explicitly accessed — not during list queries. This requires a SwiftData schema migration: add a `ModelVersion` and `MigrationPlan` with a `MigrationStage` that moves existing transcript data to external storage. This is the single highest-impact model-layer change for list view performance.  
**Dependencies**: Requires a SwiftData migration plan. No logic dependencies on other TD items.

---

### TD-014: /tmp/orin_phi3_raw.txt written unconditionally in production

**Severity**: HIGH  
**Category**: Privacy  
**Effort**: HOURS  
**Impact**: `MeetingIntelligenceService.analyzeSingleCall()` contains a line that writes the raw AI model output to `/tmp/orin_phi3_raw.txt` in every build, including App Store production releases. The `/tmp` directory on macOS is world-readable (mode 1777). Any process running as the same user — or, in some system configurations, other users — can read the raw meeting analysis output written to this file. The file is overwritten on every analysis call (single-call path), so the content is always the most recent analysis. This is a privacy violation: meeting content including names, action items, decisions, and business information is written to a world-readable location without the user's knowledge or consent. The file name still says "phi3" regardless of which model is actually in use, indicating this was debug scaffolding that was never removed.  
**Files**: `Sources/Orin/Services/MeetingIntelligenceService.swift` (the `try? result.text.write(to: URL(fileURLWithPath: "/tmp/orin_phi3_raw.txt"), ...)` line in `analyzeSingleCall()`)  
**Fix**: Delete the line. If raw AI output logging is needed for debugging, use `Logger.debug()` with the `com.clavrit.orin:MeetingIntelligence` subsystem. `Logger.debug()` is compiled out in release builds and writes to the unified log system, which is access-controlled and not world-readable.  
**Dependencies**: None. This is the first privacy fix to ship.

---

### TD-015: All AI prompts, section headers, and keyword matchers are hardcoded English

**Severity**: HIGH  
**Category**: Architecture  
**Effort**: WEEKS  
**Impact**: `MeetingIntelligenceService.buildComprehensivePrompt()` contains the instruction "Write a structured English summary" and expects response sections with English headers ("## SUMMARY", "## ACTION ITEMS", "## DECISIONS", "## OPEN QUESTIONS", "## RISKS", "## DEPENDENCIES", "## COMMITMENTS"). `parseComprehensiveResponse()` matches on these exact English strings. `detectMeetingType()` and `keywordFallback()` use English-only keyword lists. `VoiceCommandService` uses English-only matching. If a user records a meeting conducted in Spanish, Hindi, French, or any other language, the ASR will produce a non-English transcript and the AI will still receive the instruction to "write in English" — which means the LLM outputs English content derived from a non-English transcript. The user receives English analysis of a non-English meeting, with no indication that the analysis was produced in a different language than the source. For Hinglish (code-switched) meetings, the English-only prompts partially work but miss meaning in the Hindi portions. This is a structural blocker for any non-English market.  
**Files**: `Sources/Orin/Services/MeetingIntelligenceService.swift` (all prompt construction methods); `Sources/Orin/Services/VoiceCommandService.swift`  
**Fix**: (1) Add a `responseLanguage: String` parameter to `buildComprehensivePrompt()`. Post-session, run `NLLanguageRecognizer.dominantLanguage(for: transcript.prefix(2000))` and pass the result. (2) Replace hardcoded English section headers in the prompt and parser with language-neutral markers (`[SUMMARY]`, `[ACTION_ITEMS]`, `[DECISIONS]`, `[KEY_POINTS]`) that the LLM is instructed to use regardless of response language. (3) Add Spanish, French, and German keyword variants to `detectMeetingType()` and `keywordFallback()`. (4) Store the detected language on `MeetingItem.detectedLanguage: String?` for future re-analysis.  
**Dependencies**: MT-004 (layered vocabulary) provides the language context needed to select the right vocabulary pack. MT-005 is the medium-term implementation of this fix.

---

### TD-016: Full-table scans in buildTimelineSegments() and deleteMeetingFully()

**Severity**: HIGH  
**Category**: Performance  
**Effort**: HOURS  
**Impact**: `TranscriptStore.buildTimelineSegments()` fetches all `TranscriptChunk` rows from SwiftData using an unpredicated `FetchDescriptor<TranscriptChunk>()` and then filters in Swift by `meetingId`. At session finalization, this loads every `TranscriptChunk` from every historical meeting to process one meeting's segments. With one year of daily use (250 meetings × 30 chunks = 7,500 rows), this full-table scan loads all 7,500 rows into memory on every recording stop. The same pattern appears in `deleteMeetingFully()` for both `TranscriptChunk` and `TranscriptSegment` deletions. These are O(N) memory loads that could be O(1) with a WHERE clause.  
**Files**: `Sources/Orin/Services/TranscriptStore.swift` (`buildTimelineSegments()` and the delete path); `Sources/Orin/Extensions/ModelContext+SafeSave.swift` (`deleteMeetingFully()`)  
**Fix**: Add `meetingId` predicates to every `FetchDescriptor` that currently fetches without one:
```swift
FetchDescriptor<TranscriptChunk>(
    predicate: #Predicate { $0.meetingId == meetingID }
)
```
SwiftData pushes this predicate to SQLite as a WHERE clause. The fetch returns only the current meeting's rows regardless of total database size.  
**Dependencies**: None.

---

## Medium Severity

These items cause technical quality degradation, maintenance burden, or specific runtime hazards that are not currently producing crashes but will do so under specific conditions.

---

### TD-017: 74 bare print() statements in production builds

**Severity**: MEDIUM  
**Category**: Code Quality / Operational  
**Effort**: DAYS  
**Impact**: There are approximately 74 `print()` calls in production source files that are not gated by `#if DEBUG`. These include step-by-step startup traces (`STEP 1: OrinApp.init start`), recognition pipeline diagnostics, chunker progress logs (`[Chunker] chunk \(i+1)/\(chunks.count)`), and analysis proof-run dumps (`[ProofRun] ── FINAL SUMMARY ──`). In App Store builds, these print to `stdout` which appears in Console.app and user-submitted crash reports. They add noise that obscures real error signals and reveal internal implementation details. The `Logger` infrastructure (`OSLog`) is already in active use throughout the codebase — the `print()` calls are residual from before that infrastructure was established.  
**Files**: `Sources/Orin/Services/RecordingService.swift`, `Sources/Orin/Services/SystemAudioCaptureService.swift`, `Sources/Orin/Services/MeetingIntelligenceService.swift`, `Sources/Orin/Services/TranscriptChunker.swift`  
**Fix**: Audit all `print()` calls. Convert informational diagnostics to `Logger.info()` or `Logger.debug()`. `Logger.debug()` is zero-cost in release builds (compiled out). Delete the `[ProofRun]` and `STEP N:` startup traces entirely — they are debug scaffolding with no production value. The `[HALLUCINATION CHECK]` print block (TD-008 in performance: the O(N×M) word scan) should also be removed from production.  
**Dependencies**: TD-014 (the `/tmp` write is the most urgent production artifact to remove; the print cleanup follows).

---

### TD-018: Mach API CPU/RAM sampling running in every production recording

**Severity**: MEDIUM  
**Category**: Performance / Operational  
**Effort**: DAYS  
**Impact**: `MicSTSessionMetrics` calls `sampleCPUUsage()` and `sampleRAMMB()` — which use raw Mach system calls (`task_threads`, `thread_info`, `task_info`) — every 5 seconds throughout every recording session via a `Task.detached` loop. These samples are accumulated in `_cpuSamples: [Double]` and `_ramSamples: [Double]` arrays that grow unboundedly for the duration of the session (a 2-hour meeting accumulates 1,440 samples in each array). The Mach API calls themselves can block for several milliseconds under scheduler pressure. The data is used only for Phase 2A benchmarking comparisons between the legacy and SpeechTranscriber pipelines — it has no user-facing function and no production monitoring destination. The `NSLock` acquisition inside `MicSTSessionMetrics` on every recognition result compounds the overhead.  
**Files**: `Sources/Orin/Services/RecordingService.swift` (`MicSTSessionMetrics` class and its call sites)  
**Fix**: Gate all `MicSTSessionMetrics` code behind `#if DEBUG`. In production, replace the sampling infrastructure with a simple `(peakCPU: Double, avgCPU: Double, sampleCount: Int)` struct updated with three arithmetic operations per sample — no array allocation, no lock. If CPU/RAM telemetry is needed in production for observability, use `MetricKit` (the OS-provided performance monitoring API) rather than raw Mach calls.  
**Dependencies**: None.

---

### TD-019: RecognitionDiagnostics uses NSLock on Core Audio real-time thread

**Severity**: MEDIUM  
**Category**: Concurrency  
**Effort**: DAYS  
**Impact**: `RecognitionDiagnostics.shared.micBufferReceived(appended:)` is called from inside `TapState.feed()` (line 121), which executes on the Core Audio I/O thread. `RecognitionDiagnostics` uses `NSLock` for synchronization. `NSLock` is a `pthread_mutex`-backed lock that can block the calling thread if the lock is contended. On the real-time audio thread, any blocking operation violates the real-time contract. `os_unfair_lock` is the correct primitive for real-time contexts: it is non-blocking on the fast path (uses a compare-and-swap) and has a much lower worst-case latency than `pthread_mutex`. The risk is low when the lock is lightly contended, but under any memory pressure or thread scheduling variance, `NSLock` can stall the I/O thread.  
**Files**: `Sources/Orin/Services/RecognitionDiagnostics.swift`; called from `Sources/Orin/Services/TapState.swift` line 121  
**Fix**: Replace `NSLock` in `RecognitionDiagnostics` with `os_unfair_lock` (wrapped in a Swift-friendly struct). `os_unfair_lock` is documented as async-signal-safe and appropriate for real-time contexts. Alternatively, move the `micBufferReceived` call outside `TapState.feed()` to a non-real-time path and batch the diagnostic updates.  
**Dependencies**: None.

---

### TD-020: AIService hardcodes model IDs in source

**Severity**: MEDIUM  
**Category**: Architecture  
**Effort**: DAYS  
**Impact**: `AIService.swift` hardcodes model identifiers directly in the provider call methods: `"gpt-4o-mini"` for OpenAI (line 192), `"claude-haiku-4-5-20251001"` for Anthropic (line 221), and the Ollama model is read from UserDefaults but falls back to `"phi3"` hardcoded in `resolvedOllamaModel()`. The `"claude-haiku-4-5-20251001"` identifier is the internal model version string and will become invalid when Anthropic releases a newer version — at which point all Anthropic calls will silently fail until a source code update is shipped. The `"gpt-4o-mini"` identifier similarly changes with OpenAI model versioning. Users cannot switch from `phi3` to `mistral` or `llama3` for Ollama without learning about UserDefaults — there is no Settings UI.  
**Files**: `Sources/Orin/Services/AIService.swift` lines 192, 221 (hardcoded model strings); `resolvedOllamaModel()` (fallback)  
**Fix**: Move all model identifiers to a `ModelConfiguration` struct stored in `UserDefaults` and editable in `SettingsView`. Provide sensible defaults for each provider. Read the configured model at call time, not at compile time. For Anthropic and OpenAI, use the latest stable alias (`claude-haiku-latest`, `gpt-4o-mini` with a version-indifferent flag) where available, so the model tracks the provider's recommended version without requiring an app update.  
**Dependencies**: This is a prerequisite for the `InferenceProvider` protocol formalization in MT-002.

---

### TD-021: TranscriptStore.finalize() uses Task.sleep(1.5s) on @MainActor

**Severity**: MEDIUM  
**Category**: Architecture / Performance  
**Effort**: WEEKS  
**Impact**: `TranscriptStore.finalize()` calls `try? await Task.sleep(nanoseconds: 1_500_000_000)` on `@MainActor` (line 315). This blocks the main actor for 1.5 seconds on every recording stop. During this time, the entire UI is frozen — no button presses are processed, no animations run, and no view updates occur. The sleep exists as a heuristic: wait 1.5 seconds after stop before finalizing in case the speech recognition engine delivers trailing chunks. This is a time-based workaround for the absence of an explicit "recognition complete" signal from `RecordingService`. The heuristic is fragile: on slow hardware or under thermal throttling, 1.5 seconds may not be sufficient, and on fast hardware it is always too long.  
**Files**: `Sources/Orin/Services/TranscriptStore.swift` line 315  
**Fix**: Replace the heuristic sleep with an explicit `signalRecognitionComplete()` call from `RecordingService`. After `removeTap()` returns and the final recognition result has been processed, `RecordingService` calls `transcriptStore.signalRecognitionComplete()`. `TranscriptStore.finalize()` waits on an `AsyncStream` or `AsyncThrowingStream` for this signal rather than sleeping. This eliminates the 1.5-second UI freeze entirely and replaces a fragile time-based assumption with an explicit protocol. This is medium-effort because it requires coordinating across the RecordingService shutdown sequence.  
**Dependencies**: TD-007 (RecognitionSessionManager extraction is the natural place to add the completion signal); can be implemented independently as a simpler two-service coordination.

---

### TD-022: structuredActionItems JSON decoded on every property access

**Severity**: MEDIUM  
**Category**: Performance  
**Effort**: DAYS  
**Impact**: `MeetingItem.structuredActionItems` is a computed property that creates a new `JSONDecoder`, decodes `structuredActionItemsJSON: String`, and returns `[ActionItemRecord]` on every access. This property is called from `MeetingsView` list rows (once per meeting row on every scroll frame), from `MeetingDetailView` (multiple times per render), and from analysis result handlers. In a list of 50 meetings, a single scroll event triggers 50 `JSONDecoder` allocations and 50 JSON parse operations. SwiftData's `@Observable` tracking causes additional re-renders on any `MeetingItem` property change, amplifying the frequency.  
**Files**: `Sources/Orin/Models/OrinModels.swift` (`MeetingItem.structuredActionItems` computed property)  
**Fix**: Add a `@Transient private var _cachedActionItems: [ActionItemRecord]?` property to `MeetingItem`. Decode once and cache the result. Invalidate the cache in a `willSet` observer on `structuredActionItemsJSON`:
```swift
var structuredActionItemsJSON: String = "" {
    willSet { _cachedActionItems = nil }
}

var structuredActionItems: [ActionItemRecord] {
    if let cached = _cachedActionItems { return cached }
    let decoded = (try? JSONDecoder().decode([ActionItemRecord].self, from: ...)) ?? []
    _cachedActionItems = decoded
    return decoded
}
```
This reduces JSON decoding from O(n) per render to O(1) after first access per session.  
**Dependencies**: None.

---

### TD-023: DebugResetView uses DispatchQueue.main.async (macOS 26 crash pattern)

**Severity**: MEDIUM  
**Category**: Concurrency  
**Effort**: HOURS  
**Impact**: `DebugResetView` uses `DispatchQueue.main.async {}` to dispatch UI updates and reset operations. On macOS 26 (Tahoe) with Swift 6 strict concurrency enforcement, mixing GCD dispatch with Swift concurrency `@MainActor` isolation causes an executor mismatch that can produce a runtime crash: the GCD block runs on the main queue but is not considered `@MainActor`-isolated by Swift, leading to isolation violations detected at runtime. This crash has been seen in the macOS 26 beta.  
**Files**: `Sources/Orin/Views/DebugResetView.swift`  
**Fix**: Replace all `DispatchQueue.main.async {}` calls with `Task { @MainActor in }`. For any state mutations in `DebugResetView` that need to happen on the main actor, use `await MainActor.run {}` from a non-isolated context, or annotate the entire view's action handlers with `@MainActor`.  
**Dependencies**: None.

---

### TD-024: Analysis result mapping duplicated in MainContainerView and MeetingDetailView

**Severity**: MEDIUM  
**Category**: Code Quality  
**Effort**: DAYS  
**Impact**: The code that maps a `MeetingAnalysis` result to `MeetingItem` properties — writing `summary`, `meetingType`, `decisions`, `openQuestions`, `risks`, `dependencies`, `commitments`, `actionItems`, `structuredActionItemsJSON`, `suggestedTasks`, `evidenceJSON`, and `analysisCompleted`, then calling `safeSave` — is duplicated in both `MainContainerView` (post-recording auto-analysis path) and `MeetingDetailView` (manual analysis button path). When a new `MeetingAnalysis` field is added or a property name changes, both sites must be updated. The duplication has already caused the two paths to diverge: the `MainContainerView` auto-analysis path does not write `hallucinationReport` data while the `MeetingDetailView` manual path does.  
**Files**: `Sources/Orin/Views/Meetings/MeetingsView.swift` (inside `MeetingDetailView` analyze action); the auto-analysis handler in `MainContainerView.swift`  
**Fix**: Extract a `MeetingAnalysisCoordinator` class or a free function `applyAnalysis(_ analysis: MeetingAnalysis, to meeting: MeetingItem, context: ModelContext)` that is the single authoritative point for mapping all `MeetingAnalysis` fields to `MeetingItem`. Both call sites use this function. This ensures field additions and corrections propagate to both paths automatically. This extraction is a prerequisite step of MT-003 (MeetingsView split).  
**Dependencies**: TD-009 (MeetingsView split) includes this work.

---

## Architectural Debt Summary

### Dual Recognition Pipeline with No Sunset Date

The codebase maintains two parallel recognition pipelines: the legacy `SFSpeechRecognizer`-based path (the current default, gated behind `useNewParticipantPipeline == false`) and the new `SpeechTranscriber`-based Phase 2A path. Running both simultaneously is the correct migration strategy, but there is no concrete sunset date for the legacy path. The legacy path carries all five of the recognition session management bugs described in TD-007, cannot be updated with per-channel locale (TD-012), and cannot accept vocabulary hints through `contextualStrings` (the `SFSpeechRecognizer` API has no equivalent). Every bug fix in the legacy path must also be applied to `SystemAudioCaptureService` because both services embed the same copy of the logic (TD-007). The dual-pipeline state must be treated as a temporary condition with a concrete deadline: once SpeechTranscriber Phase 2A has 30 days of stable production data, schedule a sprint to delete the legacy path entirely. Do not let it become permanent.

### Flat Vocabulary System Structurally Unable to Support 10+ Languages

The current vocabulary system is a static enum with a 103-term flat array, a single `speechLocale: Locale` value, and no UI. It is architecturally incapable of supporting the product's stated multilingual ambition. The problems are structural, not cosmetic: (1) the single locale value applies to both the mic and participant channels, making per-channel locale independence impossible; (2) the vocabulary has no language namespace, so a Spanish meeting gets Hinglish terms consuming its 100-term budget; (3) there is no mechanism to inject per-meeting context (attendee names from EventKit, project names from calendar); (4) Apple does not support `hi-IN` in SpeechTranscriber or SFSpeechRecognizer, making Hindi ASR impossible without Whisper integration; (5) user vocabulary is managed via `defaults write` in Terminal, which is not a supported user-facing workflow. The redesign (MT-004) is a revenue-blocking priority, not a quality-of-life improvement.

### MeetingsView as a God View

At 2,281 lines, `MeetingsView.swift` is the God Object of the codebase. It owns the UI, the analysis state machine, the recording lifecycle observers, persistence coordination, folder management, export, and deletion. No automated test can exercise any of this code without constructing the entire SwiftUI view hierarchy with a full SwiftData model container. Adding any feature to meeting display, analysis, or recording requires understanding 2,281 lines of interleaved concerns. The `@Query var allSegments` in this file loads all segments from all meetings on every render. The analysis orchestration writes 12 model properties directly from a `View` struct. This file is the single largest impediment to engineering velocity in the codebase.

### ServiceContainer as an Untyped Service Locator

`ServiceContainer` is a type-erased `[String: Any]` dictionary with `fatalError` on missing keys, no thread safety, and global shared state. Service-locator patterns of this form are discouraged in modern Swift precisely because they defeat the type system, make dependencies invisible at compile time, and are incompatible with testing (there is no way to inject test doubles without modifying the singleton). The `fatalError` on `resolve()` means any programming error (wrong registration order, typo in type name, concurrent access before registration) terminates the process in production. The correct alternative is constructor injection: services declare their dependencies as initializer parameters. This makes every dependency visible, type-checked, and replaceable by a test double without modifying global state.

---

## Testing Debt

### What Is Currently Tested

The test suite contains 11 passing tests that cover the action item parsing and consolidation logic in `TranscriptStore` and the structured action item JSON round-trip. These tests verify: (1) `structuredActionItemsJSON` is written unconditionally on analysis completion; (2) `effectiveActionItemCount` returns the correct count from the structured JSON when available; (3) action item deduplication across chunk analyses produces correct results; (4) the JSON codec round-trip for `ActionItemRecord` is lossless.

### What Lacks Test Coverage

The following subsystems have zero automated test coverage:

- **Recording lifecycle**: `RecordingService.startRecording()`, `stopRecording()`, `installTap`, `removeTap`, generation counter behavior, watchdog Task, error-1110 restart. These are the highest-instability code paths in the codebase and are completely untested.
- **AI pipeline**: `MeetingIntelligenceService.analyzeChunked()`, `analyzeSingleCall()`, chunk synthesis, deduplication, hallucination detection, provider fallback waterfall.
- **Concurrency safety**: No tests for the debounce race (TD-004), the ServiceContainer data race (TD-005), the CalendarService status race (TD-008), or the generation counter TOCTOU race (TD-007).
- **SwiftData persistence**: `TranscriptStore.checkpoint()`, `finalize()`, orphan recovery, `buildTimelineSegments()`. These are tested implicitly by the action item tests but not in isolation.
- **Vocabulary system**: `VocabularyProvider.allTerms` truncation behavior, `speechLocale` UserDefaults integration.
- **Audio pipeline**: `TapState.arm()`, `disarm()`, `feed()` thread safety. The `testOnly_recordWriteFailure()` hook exists but no test exercises it.

### What Is Difficult to Test Because of Current Architecture

- **Anything in MeetingsView.swift**: The 2,281-line file has no dependency injection seams. All state is either `@Query` (requiring a real SwiftData container) or local `@State` (requiring view construction). The analysis orchestration is embedded in a View struct that cannot be instantiated in a test target without the full SwiftUI runtime.
- **Anything using ServiceContainer**: `ServiceContainer.resolve()` uses `fatalError` and accesses global shared state. There is no way to substitute test doubles for services resolved through `ServiceContainer` without either modifying the singleton (which affects all tests in the same process) or wrapping every resolution in a protocol (which requires the full constructor injection migration).
- **Audio callback paths**: `TapState.feed()` requires an `AVAudioPCMBuffer` which requires a running `AVAudioEngine` with a hardware device. Integration tests for the real-time path are possible with a virtual audio device but require significant setup infrastructure.
- **Ollama/AI inference**: `AIService.callOllama()` makes real HTTP requests. There is no `URLSession` injection point or mock protocol. Testing the thundering herd, retry logic, and provider fallback requires intercepting URLSession at the process level.

---

## Operational Debt

### Debug Artifacts in Production Builds

Three categories of debug artifacts survive into App Store release builds:

1. **Privacy violation**: `/tmp/orin_phi3_raw.txt` written with raw AI output on every single-call analysis (TD-014). World-readable. Must be deleted immediately.
2. **Unguarded output**: 74 `print()` statements writing recognition diagnostics, startup traces, and proof-run dumps to `stdout` in release builds (TD-017). Visible in Console.app and customer crash reports.
3. **Mach API sampling**: `sampleCPUUsage()` and `sampleRAMMB()` using raw Mach syscalls in every production recording session, accumulating unbounded arrays that are never surfaced to users (TD-018).

### No Crash Reporting Integration

The codebase has no crash reporting SDK integration (no Sentry, Crashlytics, or custom crash handler). When a user experiences a crash, the only diagnostic data available is whatever the user chooses to submit through Apple's opt-in crash reporter. There is no way to know which crash is occurring most frequently, whether a fix has eliminated a crash type, or how many users are affected by a specific defect. This makes prioritization of the TD items above dependent entirely on user-reported anecdotes rather than data.

### No Performance Monitoring in Production

There is no `MetricKit` integration, no `os_signpost` instrumentation of the recording pipeline, and no structured telemetry for analysis latency, recognition accuracy, or memory usage. The only performance data is the `AnalysisPerfLogger` output, which writes to `OSLog` in debug builds. A 10x slowdown in AI analysis latency (which has already occurred in practice due to TD-001) would not be visible in any dashboard — it would be discovered only when a user reports it.

### No Feature Flag Management System

Feature flags are managed through `FeatureFlags.swift` reading `UserDefaults`. The current flags — `useNewParticipantPipeline`, `enableHindiVocab`, and others — are toggled via `defaults write` in Terminal. There is no UI for flag management, no way to toggle flags for a specific user in production, no flag rollout percentage control, and no audit trail of flag changes. `UserDefaults` is appropriate for a developer-only feature flag system, but it is not suitable for: progressive rollouts to a subset of users, A/B testing analysis pipeline variants, emergency flag toggles without an app update, or org-level flag overrides. The `RecognitionDiagnostics.experimentMode: String` nonisolated(unsafe) static var (referenced in code to delete) is an example of the kind of ad-hoc experiment flag management that accumulates without a proper system — a string comparison inside a `@MainActor` `Task` with no cleanup path.

---

## Prioritized Fix Order

The table below shows the recommended implementation sequence. The dependency chain ensures that each fix is safe to apply given what has already been done.

| Order | Item | Effort | Why Now |
|-------|------|--------|---------|
| 1 | TD-001: Ollama unbounded dispatch | HOURS | The single root cause of the 41-request thundering herd and all post-call system freezes. Every other fix is lower priority until this is in production and validated with a 150-minute recording. |
| 2 | TD-014: Delete /tmp write | HOURS | Privacy violation in every production build. Zero risk, zero dependencies, five minutes of work. |
| 3 | QW-002: Cache Ollama health check 10s | HOURS | Eliminates 16+ simultaneous `/api/tags` requests at analysis start. Compound benefit with TD-001. |
| 4 | QW-003: Add jitter to retry delay | HOURS | Prevents synchronized retry wave if parallel dispatch is ever re-enabled. Applied to `AIService.generate()` alongside TD-001. |
| 5 | TD-004: Debounce race fix | HOURS | Active crash trigger on Bluetooth headset connection during recording. `DispatchWorkItem` pattern eliminates the race entirely. |
| 6 | TD-003: TapState XPC-in-lock | HOURS | Priority inversion on real-time audio thread. The fix is two lines; the pattern is already used in `updateRequest()`. |
| 7 | TD-005: ServiceContainer thread safety | HOURS | Data race between OrinApp.init() and Task.detached contexts. NSLock addition is two lines. |
| 8 | TD-006: Batch TranscriptChunk saves | HOURS | Eliminates multiple SQLite WAL writes per second on @MainActor. Changes `context.save()` to `context.insert()` in `persistChunkIfNeeded()`. |
| 9 | TD-016: meetingId predicates on fetch descriptors | HOURS | Eliminates full-table scans at session finalization. Applies to `buildTimelineSegments()` and `deleteMeetingFully()`. |
| 10 | TD-023: DebugResetView GCD migration | HOURS | macOS 26 crash pattern. Straightforward GCD-to-Task migration. |
| 11 | TD-008: CalendarService @MainActor | DAYS | Data race between MainActor writes and cooperative-pool reads. Annotation-level fix. |
| 12 | TD-002: Pre-allocate audio buffers | DAYS | Eliminates real-time heap allocation in MicTranscriberFeed and ParticipantSTFeed. Requires arm() refactor. |
| 13 | TD-017: Gate print() behind #if DEBUG | DAYS | Removes debug noise from production builds and crash reports. |
| 14 | TD-018: Gate Mach API sampling behind #if DEBUG | DAYS | Removes unbounded array growth and Mach syscall overhead from production recordings. |
| 15 | TD-012: Fix locale split in SFSpeechRecognizer | DAYS | Both channels now read `VocabularyProvider.speechLocale`. Removes hardcoded en-US/en-IN divergence. |
| 16 | TD-011: Fix builtInTerms truncation order | DAYS | User terms take priority over overflow built-in terms. Add warning log. |
| 17 | TD-022: Cache structuredActionItems decoding | DAYS | Eliminates O(n) JSONDecoder allocations per scroll frame in meeting list. |
| 18 | TD-019: Replace NSLock with os_unfair_lock in RecognitionDiagnostics | DAYS | Correct primitive for real-time thread context. |
| 19 | TD-020: Move model IDs to configuration | DAYS | Prevents silent failures when Anthropic/OpenAI change model version strings. Prerequisite for InferenceProvider protocol. |
| 20 | TD-013: Add @Attribute(.externalStorage) to transcript | DAYS | Single highest-impact model change for list view performance. Requires SwiftData migration plan. |
| 21 | TD-010: Move allSegments @Query to MeetingDetailView | DAYS | Eliminates loading all segments from all meetings on list render. Logically part of TD-009. |
| 22 | TD-007: Extract RecognitionSessionManager | WEEKS | Eliminates 400-line duplication. Resolves generation counter TOCTOU race permanently. Prerequisite for legacy pipeline deletion. |
| 23 | TD-021: Replace Task.sleep in finalize() with explicit signal | WEEKS | Eliminates 1.5-second @MainActor freeze on every recording stop. Requires RecordingService protocol coordination. |
| 24 | TD-024: Consolidate analysis result mapping | DAYS | Prerequisite for TD-009 (MeetingsView split). Single source of truth for MeetingAnalysis → MeetingItem. |
| 25 | TD-009: Split MeetingsView.swift | WEEKS | Removes the God View. Includes TD-024 and TD-010. Makes analysis orchestration testable. |
| 26 | MT-002: InferenceWorker + AnalysisJobQueue | WEEKS | Permanent architectural solution to AI serialization (supersedes TD-001 semaphore fix). Prerequisite for TD-020 InferenceProvider protocol. |
| 27 | TD-015: Language-parameterized AI prompts | WEEKS | Prerequisite for any non-English market. Blocks Spanish/French/German language support. |
| 28 | MT-004: Layered vocabulary system | WEEKS | Prerequisite for TD-015. Unblocks per-meeting attendee context injection and multi-language vocabulary packs. |
| 29 | MT-007: ASRBackend protocol | WEEKS | Cross-platform foundation. Enables per-channel locale independence, Whisper integration, and Windows/iOS port. |

---

*This register is maintained as a living document. Each item should be closed with the commit hash that resolves it and the date of closure. Items added after this review should be appended with a TD-025+ identifier and the date discovered.*
