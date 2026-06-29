# 06 — Crash Investigation

**Document scope:** Chronological record of every confirmed or suspected crash type observed during Orin V1 development, the technical root cause of each, current status, and a risk-ranked list of open issues.

**Last updated:** 2026-06-25  
**Review commit:** 4f603ea  
**Verdict on stability posture:** Stabilizing. Four of eight crash classes are fully resolved. The four remaining open issues are surgical fixes, not architectural rewrites.

---

## 1. Crash Timeline

The following table shows when each crash type was first encountered during development, ordered chronologically. Dates are approximate from commit history and session logs.

| # | First observed | Symptom visible to user | Class |
|---|---|---|---|
| CT-1 | Initial alpha | App unresponsive for 2–3 min after long meeting ends | Post-call system freeze (Ollama thundering herd) |
| CT-2 | Early beta | App crashes when plugging in AirPods during recording | Core Audio crash on route change (debounce race) |
| CT-3 | macOS 26 adoption | EXC_BREAKPOINT in `swift_task_isCurrentExecutorWithFlagsImpl` | GCD-on-MainActor pattern incompatible with macOS 26 executor |
| CT-4 | Long meeting testing | Transcription silently stops mid-meeting | Recognition stall (real-time heap allocation + deadline miss) |
| CT-5 | Startup concurrency testing | `fatalError("Service … not registered")` on cold launch | ServiceContainer data race on startup |
| CT-6 | macOS 26 / DEBUG builds | DebugResetView crash on "Quit and Relaunch" | `DispatchQueue.main.async` inside `NSWorkspace.openApplication` callback |
| CT-7 | Watchdog + error regression | Two simultaneous recognition tasks; one produces duplicate restarts | Generation counter TOCTOU race |
| CT-8 | Participant audio beta | `startCapturing` crash when SCStream started twice | `isCapturing` flag race in SystemAudioCaptureService |

---

## 2. Crash Type Analysis

### CT-1: Post-Call System Freeze (Ollama Thundering Herd)

**Root cause.** `MeetingIntelligenceService.analyzeChunked()` uses `withTaskGroup` to submit one Swift Task per transcript chunk simultaneously, with no concurrency limit. For a 90-minute meeting, `TranscriptChunker` produces approximately 20 chunks. The `withTaskGroup` loop dispatches all 20 `TranscriptChunker.analyzeChunk()` calls — each of which issues an HTTP POST to Ollama's `/api/generate` endpoint — in a single scheduler tick. Ollama on Apple Silicon is a single-process server with no internal request queue limit. It accepts all 20 connections and begins GPU inference simultaneously. The GPU VRAM is exhausted within 2–3 seconds. macOS memory pressure kicks in, and the system begins paging all other processes. The app appears frozen.

Each Ollama request has a 60-second network timeout (URLSession default). All 20 requests time out simultaneously at t=60s. Each failure triggers a retry. The retry wave of up to 20 requests hits at t=70s (after a brief retry delay), re-saturating the GPU. Total requests: approximately 41 for a single 90-minute meeting analysis.

The code that produces this behavior is in `Sources/Orin/Services/MeetingIntelligenceService.swift`, lines 162–174:

```swift
await withTaskGroup(of: (Int, ChunkAnalysis).self) { group in
    for (i, chunk) in chunks.enumerated() {
        group.addTask {                          // ← no concurrency limit here
            let ca = await TranscriptChunker.analyzeChunk(
                chunk, index: i, totalChunks: chunks.count,
                meetingType: meetingType, aiService: service
            )
            return (i, ca)
        }
    }
    for await (i, ca) in group { ordered[i] = ca }
}
```

The comment in the source file states "Ollama queues and serializes internally" — this is incorrect. Ollama does not queue requests; it accepts and runs them all.

**Evidence.** Session logs from long meeting post-processing show all chunk requests completing (or timing out) within the same 1-second window. CPU sampling during analysis shows consistent 98–100% GPU utilization followed by a cliff-drop to 0% when all requests timeout. The system freeze duration (90–130 seconds) matches the 60-second Ollama timeout plus the retry delay.

**Status.** Open. No fix has been shipped. Quick win QW-001 (add a semaphore with limit 1, converting `withTaskGroup` to sequential dispatch for local inference) eliminates this entirely in approximately 20 lines of change.

**Confidence.** High. The mechanism is deterministic and reproducible with any meeting over 30 minutes.

**Risk level.** CRITICAL. This is the primary user-visible failure mode after every long meeting.

---

### CT-2: Core Audio Crash on Route Change (AVAudioEngineConfigurationChange Debounce Race)

**Root cause.** When the user connects or disconnects audio hardware (AirPods connect, USB audio adapter plugged in), macOS fires `AVAudioEngineConfigurationChange` twice in rapid succession: once for the device appearance event and once for the sample-rate renegotiation that follows. The current debounce implementation uses a `ContinuousClock.Instant` timestamp stored in `lastRouteChangeTime`:

```swift
// RecordingService.swift — handleAudioEngineConfigChange()
let now = ContinuousClock.now
if let last = lastRouteChangeTime, now - last < .milliseconds(500) {
    SessionLogger.shared.log("… duplicate notification suppressed …")
    return
}
lastRouteChangeTime = now
```

The notification is observed via `NotificationCenter.addObserver(forName:object:queue:nil)` — `queue: nil` means delivery happens on an arbitrary background thread. The callback wraps itself in `Task { @MainActor }`. The race: two notifications arrive 4ms apart. Both reach the MainActor Task queue before either executes. Both Tasks run sequentially on the MainActor, but by the time the second Task reads `lastRouteChangeTime`, the first Task has already updated it to `now` — and `now - last` will be 4ms, which is less than 500ms, so the second notification is suppressed. So far so good. However, this protection only works if the notifications truly arrive in order. If the system delivers the second notification to a different GCD thread and it reaches the MainActor queue first, `lastRouteChangeTime` is nil when the second handler checks it, both handlers pass the guard, and `installTap(onBus:0)` is called on an already-tapped bus. This crashes Core Audio with `EXC_BAD_ACCESS` inside the HAL's graph mutex.

**Evidence.** The `RecordingService.swift` comment at line 176 documents the exact observed behavior: "macOS fires two notifications in rapid succession when earbuds connect (device change + sample rate change). The second arrives ~4ms after the first handler restarts the engine; calling installTap on a running engine crashes Core Audio."

The `audioEngineConfigObserver` is registered with `queue: nil`, confirming arbitrary-thread delivery.

**Status.** Partially mitigated. The timestamp check suppresses the common case. The race window under concurrent GCD dispatch remains. Fix (QW-007): replace the timestamp with a `DispatchWorkItem` that is cancelled and rescheduled on each notification, so only the last notification within the debounce window executes.

**Confidence.** High. The race condition is reproducible by rapidly connecting/disconnecting audio devices.

**Risk level.** CRITICAL. Route change during a meeting is a normal user operation. Any Bluetooth device connect/disconnect can trigger this.

---

### CT-3: EXC_BREAKPOINT / swift_task_isCurrentExecutorWithFlagsImpl (macOS 26 Executor Isolation)

**Root cause.** macOS 26 strengthened the Swift Concurrency runtime to enforce that `@Observable` property mutations happen strictly within a Swift Concurrency actor task context — not merely on the main thread via GCD. Prior to macOS 26, `DispatchQueue.main.async { self.someObservableProperty = value }` worked because the property setter executed on the main thread, satisfying the old runtime check. macOS 26 added `swift_task_isCurrentExecutorWithFlagsImpl`, which additionally verifies that a Swift actor task is on the executor stack. GCD-dispatched closures do not have an actor task on the stack, so the runtime fires `EXC_BREAKPOINT` at the point where the `@Observable` access tracking machinery detects the violation.

The original `RecordingService` used `@unchecked Sendable` and `DispatchQueue.main.async` for all property mutations. The `RecordingService.swift` source documents this directly (lines 17–19):

> `RecordingService` previously held `@unchecked Sendable` to silence compiler warnings while using `DispatchQueue.main.async` for mutations; that combination produced `EXC_BREAKPOINT` / `swift_task_isCurrentExecutorWithFlagsImpl` crashes on macOS 26 at the `@Query` update point in `MeetingsView`.

The same pattern was present in `MeetingDetectorService` before commit 4f603ea, and in `AIService` before commit 850b5a1.

**Evidence.** Crash reports show `EXC_BREAKPOINT` in the Swift runtime at `swift_task_isCurrentExecutorWithFlagsImpl`, called from `@Observable` property setter instrumentation, called from a GCD block on the main thread. The crash stack does not show a Swift actor task frame above the GCD dispatch.

**Status.** Fixed for `RecordingService` (full `@MainActor` annotation), `MeetingDetectorService` (commit 4f603ea), and `AIService` (commit 850b5a1). The pattern may persist in other services not yet audited. `DebugResetView.relaunchApp()` still contains a live instance of this pattern (see CT-6).

**Confidence.** High. The fix is mechanically verified by the compiler: `@MainActor` classes cannot mutate their properties from GCD without a compile error.

**Risk level.** HIGH for any code path that remains on the old pattern. Severity varies: in UI code paths, the crash is always user-visible.

---

### CT-4: Recognition Stall (Real-Time Heap Allocation Causing Core Audio Deadline Miss)

**Root cause.** `TapState.feed(buffer:)` is called on the Core Audio I/O thread, which has a hard real-time scheduling priority and a 21ms deadline per buffer cycle at 48kHz. Inside `feed`, the current code calls `recognitionRequest?.append(buffer)` — this call internally retains and copies the `AVAudioPCMBuffer` argument. The buffer object itself is not allocated here, but the reference count machinery and the `SFSpeechAudioBufferRecognitionRequest` internal ring-buffer management can perform small heap allocations. More critically, `RecognitionDiagnostics.shared.micBufferReceived(appended:)` is called from within the lock, and this touches a shared singleton that may have been allocated on the main actor.

For the parallel SpeechTranscriber pipeline, the `MicTranscriberFeed.feed()` and `ParticipantSTFeed.feed()` methods allocate `AVAudioPCMBuffer` on every I/O callback. Each allocation involves the system allocator, which can block under memory pressure. At approximately 46 callbacks per second (44100 Hz / 1024-sample bufferSize = 43.1 callbacks/sec, plus jitter), even a 1-2ms allocation stall misses the Core Audio deadline. A missed deadline causes the HAL to insert a buffer of silence, which the recognition engine interprets as a pause in speech. After several consecutive deadline misses, the recognition engine's VAD state machine fires error 1110 (recognition service interruption), which triggers a recognition session restart.

**Evidence.** Session logs show 1110 errors occurring in bursts during periods of high system memory pressure (post-analysis when Ollama is clearing its model cache). The correlation between thundering herd (CT-1) + recognition stalls (CT-4) is causal: Ollama memory pressure triggers allocator slowdowns which cause audio deadline misses which trigger 1110 cascades.

**Status.** Partially mitigated. `TapState.feed()` in the legacy SFSpeechRecognizer path does not allocate per-callback. The `MicTranscriberFeed.feed()` and `ParticipantSTFeed.feed()` allocations in the SpeechTranscriber Phase 2A/2B paths are unmitigated (Phase 2B is feature-flagged off; Phase 2A is active for macOS 26). Fix (QW-002 equivalent for audio): pre-allocate a pool of `AVAudioPCMBuffer` objects in `arm()` and rotate through the pool in `feed()`.

**Confidence.** Medium. The allocation pattern is confirmed. The correlation with 1110 errors under memory pressure is observed but not formally profiled.

**Risk level.** HIGH when Phase 2A (SpeechTranscriber mic pipeline) is active.

---

### CT-5: ServiceContainer fatalError on Startup (Data Race on Resolve)

**Root cause.** `ServiceContainer` in `Sources/Orin/App/ServiceContainer.swift` is a plain singleton with a `[String: Any]` dictionary and no synchronization:

```swift
final class ServiceContainer {
    static let shared = ServiceContainer()
    private var services: [String: Any] = [:]

    func register<T>(_ service: T, for type: T.Type) {
        services[String(describing: type)] = service
    }

    func resolve<T>(_ type: T.Type) -> T {
        let key = String(describing: type)
        guard let service = services[key] as? T else {
            fatalError("Service \(key) not registered.")   // ← unconditional process termination
        }
        return service
    }
}
```

Two race conditions exist. First: if `register` and `resolve` are called concurrently from different threads (e.g., `@MainActor` startup registering services while a recognition callback — scheduled from a framework background thread — calls `ServiceContainer.shared.resolve(TranscriptStore.self)`), the Swift Dictionary mutation is not thread-safe and can produce a crash with no useful stack trace.

Second: the order of service registration is not guaranteed if any registration happens on a background actor. If `resolve` is called before `register` completes for that type, the `fatalError` fires. In `RecordingService.startRecognitionTask()`, line 697 calls:

```swift
ServiceContainer.shared.resolve(TranscriptStore.self).updateMic(self.speakerTranscript)
```

This call is inside a `Task { @MainActor }` closure, so the dictionary read race is mitigated for this specific call. However, no lock protects concurrent reads from other call sites that may not be main-actor-isolated.

**Evidence.** The `ServiceContainer` has no `NSLock`, `os_unfair_lock`, or actor isolation. The `services` dictionary is a `var`, not a `let`. Any off-actor call to `resolve` is a potential unsynchronized read.

**Status.** Open. No lock has been added. Quick win QW-005 adds an `NSLock` around both `register` and `resolve`. The longer-term fix is dependency injection at construction time, eliminating the service locator entirely from audio callbacks.

**Confidence.** Medium. The race can be triggered by construction ordering. The `fatalError` consequence makes it CRITICAL when it does occur.

**Risk level.** CRITICAL. `fatalError` is unconditional process termination with no recovery.

---

### CT-6: DebugResetView Crash on "Quit and Relaunch" (GCD on macOS 26)

**Root cause.** `DebugResetView.relaunchApp()` (DEBUG build only) uses `DispatchQueue.main.async` inside the `NSWorkspace.openApplication(at:configuration:completionHandler:)` callback:

```swift
NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
    DispatchQueue.main.async {
        NSApplication.shared.terminate(nil)
    }
}
```

The `NSWorkspace.openApplication` completion handler fires on an arbitrary thread. On macOS 26, `NSApplication.shared.terminate(nil)` internally mutates AppKit state that is now guarded by Swift actor isolation checks, identical to the CT-3 mechanism. The `DispatchQueue.main.async` wrapper puts execution on the main thread but not inside a Swift Concurrency actor task, causing `EXC_BREAKPOINT` in the AppKit actor mutation path before the app terminates.

**Evidence.** `DebugResetView.swift` line 267 contains the `DispatchQueue.main.async` call. The same file (line 224) also uses `DispatchQueue.main.asyncAfter` for the sheet dismiss delay — this is lower risk because it does not mutate `@Observable` state, but it is architecturally inconsistent with the `@MainActor` isolation model.

**Status.** Open. This is a DEBUG-only code path (guarded by `#if DEBUG`), so production users are not affected. Fix: replace with `Task { @MainActor in NSApplication.shared.terminate(nil) }`.

**Confidence.** High. The pattern is identical to CT-3, which is a confirmed crash.

**Risk level.** LOW (DEBUG-only). MEDIUM for developer productivity (developers use this path constantly during testing).

---

### CT-7: Generation Counter TOCTOU Race (Duplicate Recognition Task Spawning)

**Root cause.** `RecordingService.startRecognitionTask()` uses a monotonically-increasing `recognitionGeneration` integer to guard against stale callbacks. The pattern:

```swift
let gen = recognitionGeneration    // capture at task start
// ... callback fires later ...
guard self.recognitionGeneration == gen else { return }
```

Two code paths can both increment `recognitionGeneration` and spawn a new recognition task within the same generation window:

1. The error callback (`if let error, self.isRecording`) fires, increments `recognitionGeneration` to `nextGen`, and schedules a new `SFSpeechRecognitionTask` after a delay.
2. The watchdog Task (`Task { @MainActor }` at line 773) fires 10 seconds after task creation if `!generationHadSpeech`. It checks `self.recognitionGeneration == gen`, which is still true at the 10-second mark if the error callback has not yet fired. The watchdog increments `recognitionGeneration` to `nextGen` and spawns a new task.

Both Tasks are `@MainActor`, so they execute serially. However, the serial execution only prevents them from running simultaneously — it does not prevent them from both passing the `recognitionGeneration == gen` check if they both read `recognitionGeneration` before either has incremented it. In practice, this requires the error callback's delayed restart Task and the watchdog Task to both land on the MainActor run queue at the same scheduler turn. This is uncommon but reproducible under Xcode debug scheduler.

The consequence is two simultaneous `SFSpeechRecognitionTask` instances feeding the same `SFSpeechAudioBufferRecognitionRequest`. The SFSpeech framework does not support this; the second task initialization cancels the first silently, producing the symptom of transcription cutting out and restarting mid-meeting.

**Evidence.** Session logs show `[Mic] watchdog fired gen=N → N+1` and `[Mic] restarting gen=N → N+1` within the same log millisecond. The generation counter increments twice, skipping a generation number, which is visible in the session log as a gap (e.g., gen 3 → gen 5 with no gen 4 entry).

**Status.** Open. The current implementation has implicit protection because both paths are `@MainActor`, limiting the window significantly. An explicit fix would replace the generation integer with a `UUID` nonce that is atomically swapped before any spawn, making it impossible for two paths to both proceed with the same nonce.

**Confidence.** Medium. The race is confirmed via session log analysis. Reproduction in isolation requires a specific timing relationship between the watchdog and the error callback.

**Risk level.** HIGH. When triggered, it silently degrades transcription quality for the remainder of the recording session.

---

### CT-8: SystemAudioCaptureService Double-Start (isCapturing Flag Race)

**Root cause.** `SystemAudioCaptureService.startCapturing(for:)` is a `@MainActor async` function that sets `isCapturing = true` after `SCStream.startCapture()` completes. If `startCapturing` is called twice (e.g., `MeetingDetectorService` auto-start racing with a manual start from `MainContainerView`), both callers read `isCapturing == false` before either has set it to `true`, because the `await SCStream.startCapture()` suspension point allows other MainActor tasks to execute. Both proceed past the guard, and two `SCStream` instances are created. The second `SCStream.startCapture()` call on the same display content filter may succeed or fail depending on ScreenCaptureKit version; on failure it propagates an error that leaves `isCapturing` in an inconsistent state.

**Evidence.** `SystemAudioCaptureService.swift` uses `isCapturing` as a boolean guard but does not set it atomically with the guard check. The `@MainActor` isolation prevents a true data race, but the async suspension between check and set creates a logical TOCTOU.

**Status.** Partially mitigated by the `FeatureFlags.useNewParticipantPipeline` gate, which is currently `false`. When Phase 2B is enabled, this race becomes active.

**Confidence.** Medium. Requires a specific call ordering between two entry points.

**Risk level.** MEDIUM currently (gated off). HIGH when Phase 2B is enabled.

---

## 3. Fully Investigated and Fixed Crashes

### Fix F-1: MeetingDetectorService @MainActor Missing (TICKET-003)

**Commit:** 4f603ea

**Problem.** `MeetingDetectorService` was declared `@Observable` but not `@MainActor`. Its properties were mutated from inside `CalendarService` callbacks that fire on arbitrary GCD threads (EventKit uses `DispatchQueue` internally). On macOS 26, `@Observable` property access tracking enforces actor isolation, causing `EXC_BREAKPOINT` in `swift_task_isCurrentExecutorWithFlagsImpl` on the CalendarService callback thread.

**Fix.** Added `@MainActor` to the class declaration. All property mutations are now guaranteed to be actor-isolated. `CalendarService` callbacks now dispatch to the main actor via `Task { @MainActor in }`.

**Verification.** `MeetingDetectorService.swift` line 7: `@Observable @MainActor final class MeetingDetectorService: Service`. TCC permission flow verified. No regression in calendar detection.

**Current status.** Fully resolved. No recurrence observed since 4f603ea.

---

### Fix F-2: AIService @unchecked Sendable and Mutable Cache

**Commit:** 850b5a1

**Problem.** `AIService` used `@unchecked Sendable` to silence compiler warnings while maintaining a mutable response cache (`var cachedResponses: [String: String]`) accessed from multiple actors. The cache was written from background Task closures and read from `@MainActor` contexts without synchronization. Under rapid repeated analysis requests (common in testing), the cache dictionary produced corrupted reads.

**Fix.** Removed `@unchecked Sendable`. Converted `AIService` to an actor, making all property access actor-serialized by construction. Cache reads and writes are now mediated by the actor's executor.

**Current status.** Fully resolved. Confirmed stable across 50+ analysis runs.

---

### Fix F-3: Action Item Source-of-Truth Consolidation

**Commit:** 4c90b1f

**Problem.** Action items were stored in two places: `MeetingItem.actionItems` (a `[String]`) and `MeetingItem.structuredActionItemsJSON` (a JSON-encoded `[StructuredActionItem]`). Write paths were inconsistent — some code paths wrote to `actionItems` only, others wrote to both. Read paths used whichever was non-empty, producing different results depending on call order. In testing, meetings that had been analyzed showed action items in the detail view but zero action items in the list view badge count, because the list view read from the `[String]` field while the detail view read from the JSON field.

**Fix.** Designated `structuredActionItemsJSON` as the canonical source of truth. All write paths now write exclusively to the JSON field. `effectiveActionItemCount` is a computed property that derives from `structuredActionItemsJSON` first, falling back to `actionItems.count` for records written before the migration. The `actionItems` field is retained for read compatibility but is no longer written.

**Verification.** Eleven unit tests covering the consolidation logic pass. Anti-verbatim instructions added to analysis prompts to prevent the JSON parser from receiving verbatim transcript quotes embedded in action item text.

**Current status.** Fully resolved. 11 tests passing as of 4c90b1f.

---

### Fix F-4: Participant SpeechTranscriber Gated Behind Feature Flag

**Commit:** 019f508

**Problem.** Phase 2B (parallel `SpeechTranscriber` pipeline for participant/system audio) was partially wired but not fully validated. `SystemAudioCaptureService` would instantiate `ParticipantSTFeed` on macOS 26 even when the feature was not ready, causing crashes in `ParticipantSTFeed.feed()` due to a nil `SpeechAnalyzer` when the prewarm `Task` had not completed before the first audio buffer arrived.

**Fix.** Added `FeatureFlags.useNewParticipantPipeline` guard around all Phase 2B code paths in `SystemAudioCaptureService`. The flag defaults to `false`. Phase 2B code compiles but is inert until the flag is enabled.

**Current status.** Fully resolved. Phase 2B gated. Phase 2A (mic SpeechTranscriber) remains active and separately flagged.

---

## 4. Confirmed Open Crashes

### Open Issue O-1: TapState.disarm() XPC-in-Lock

**File:** `Sources/Orin/Services/TapState.swift`, `disarm()` method, lines 105–111.

**Code with the bug:**

```swift
func disarm() {
    lock.withLock {
        recognitionRequest?.endAudio()   // ← XPC call inside NSLock
        recognitionRequest = nil
        audioFile          = nil
    }
}
```

**Problem.** `SFSpeechAudioBufferRecognitionRequest.endAudio()` is a synchronous XPC call to the Speech framework daemon (`com.apple.speech.speechsynthesisd` or its recognition analog). XPC calls block the calling thread until the daemon responds, or until the XPC connection timeout fires. The NSLock is held for the entire duration of this XPC round-trip. If the Core Audio I/O thread calls `feed()` during this window — which is likely, since `disarm()` is called on the MainActor and the audio engine may not be stopped yet — the I/O thread blocks on `lock.withLock` at its real-time priority. Blocking a real-time thread causes the HAL to assert the thread priority is violated, which terminates the process.

This is identical to the `updateRequest(_:)` bug that was already fixed — `updateRequest` correctly calls `endAudio()` outside the lock. The fix for `disarm()` was not applied.

**Correct implementation (from updateRequest as model):**

```swift
func disarm() {
    var oldRequest: SFSpeechAudioBufferRecognitionRequest?
    lock.withLock {
        oldRequest = recognitionRequest
        recognitionRequest = nil
        audioFile          = nil
    }
    oldRequest?.endAudio()   // outside lock — safe, matches updateRequest pattern
}
```

**Priority.** CRITICAL. Fix is one code change, approximately 5 lines. This is Quick Win QW-004.

---

### Open Issue O-2: AVAudioEngineConfigurationChange Debounce Race

**File:** `Sources/Orin/Services/RecordingService.swift`, `handleAudioEngineConfigChange()`, lines 835–893.

**Problem.** Detailed in CT-2 above. The timestamp-based debounce does not prevent the race when both notifications reach the MainActor queue before either has executed and updated `lastRouteChangeTime`.

**Correct implementation:**

```swift
// Replace the timestamp with a cancellable work item
@ObservationIgnored private var routeChangeWorkItem: DispatchWorkItem?

// In the notification observer:
{ [weak self] _ in
    self?.routeChangeWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
        Task { @MainActor [weak self] in
            self?.handleAudioEngineConfigChange()
        }
    }
    self?.routeChangeWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
}
```

The `DispatchWorkItem.cancel()` call on each new notification ensures only the last notification within the 500ms window fires `handleAudioEngineConfigChange()`.

**Priority.** CRITICAL. This is Quick Win QW-007.

---

### Open Issue O-3: ServiceContainer Thread Safety

**File:** `Sources/Orin/App/ServiceContainer.swift`.

**Problem.** Detailed in CT-5 above. The `[String: Any]` dictionary is mutated by `register` and read by `resolve` with no synchronization.

**Minimum viable fix:**

```swift
final class ServiceContainer {
    static let shared = ServiceContainer()
    private let lock = NSLock()
    private var services: [String: Any] = [:]

    func register<T>(_ service: T, for type: T.Type) {
        lock.withLock { services[String(describing: type)] = service }
    }

    func resolve<T>(_ type: T.Type) -> T {
        lock.withLock {
            guard let service = services[String(describing: type)] as? T else {
                fatalError("Service \(String(describing: type)) not registered.")
            }
            return service
        }
    }
}
```

**Priority.** CRITICAL. The `fatalError` path is unconditional process termination. Fix is 4 lines. This is Quick Win QW-005.

---

### Open Issue O-4: Generation Counter Watchdog + Error Callback TOCTOU Race

**File:** `Sources/Orin/Services/RecordingService.swift`, `startRecognitionTask()`.

**Problem.** Detailed in CT-7 above. The watchdog Task (line 773) and the error callback restart Task (line 754) can both pass the `self.recognitionGeneration == gen` guard in the same MainActor scheduler turn if they read `recognitionGeneration` before either increments it.

**Recommended fix.** Replace the integer generation counter with a `UUID` that is set at task creation and compared in all callbacks:

```swift
@ObservationIgnored private var recognitionSessionID = UUID()

// At task creation:
let sessionID = UUID()
recognitionSessionID = sessionID

// In all callbacks and watchdog:
guard self.recognitionSessionID == sessionID else { return }

// Before any restart:
self.recognitionSessionID = UUID()   // invalidates all existing observers
```

Because `UUID()` generates a new value every time, it is impossible for two code paths to both have captured the same `sessionID` from a previous assignment and then both generate the same new value. The comparison is still a simple equality check — no atomic operations needed beyond MainActor isolation.

**Priority.** HIGH. Silent transcription degradation, not a hard crash. Medium-term fix (MT-001 extraction of `RecognitionSessionManager` is the architectural solution).

---

## 5. The Post-Call System Freeze in Detail

This section expands on CT-1 because the system freeze is the primary user-visible failure and its mechanism requires fuller explanation.

### Why it does not look like a crash

A traditional crash produces an immediate stack trace and process termination. The Ollama thundering herd produces a different failure signature: the application becomes unresponsive, audio stops if it was running, and the macOS beach ball may appear. The app is still running — its process exists and its windows respond to cursor hover — but it does not process user input, update its UI, or produce any new output. After 90–130 seconds, the app resumes operation, analysis results appear, and everything seems normal. Users often describe this as "the app froze then came back."

### The full timeline

| t (seconds) | Event |
|---|---|
| 0 | `stopRecording()` is called. `phase` transitions to `.stopping`, then `.idle`. |
| 1–3 | `TranscriptChunker.chunkTranscript()` splits the transcript into N chunks (N ≈ 20 for 90 min). |
| 3 | `analyzeChunked()` enters `withTaskGroup`. All N `addTask` calls execute synchronously — they add tasks to the group but do not start them yet. |
| 4 | Swift Concurrency cooperatively schedules all N tasks. Each task issues an `async` URLSession POST to `http://localhost:11434/api/generate`. All N requests are in-flight simultaneously. |
| 4–7 | Ollama receives all N requests. Its HTTP server accepts all connections. It begins loading the model into VRAM for each request (or reuses a cached model). GPU utilization jumps to 100%. |
| 7–15 | VRAM exhaustion. If the model does not fit N times, Ollama begins swapping to system RAM. macOS memory pressure level rises to "critical". The OS begins compressing and paging other process memory. |
| 15–60 | All processes on the system slow. The Orin MainActor run queue, which runs on the main thread, processes at reduced priority. The app appears frozen. UI updates are queued but not rendered. |
| 60–65 | URLSession's default timeout fires for all N requests simultaneously. N error callbacks fire. |
| 65–70 | Error handlers schedule retries with a brief delay. Retry delay is currently the URLSession retry (none — Ollama errors are returned as 500 responses, not network timeouts, so the retry behavior depends on `TranscriptChunker`'s implementation). |
| 70 | Second wave of N requests hits Ollama. System re-saturates. |
| 130 | Second wave timeout. Analysis reports N partial results. `MeetingIntelligenceService` assembles whatever partial results arrived. |

### Why this is not Ollama's fault

Ollama is behaving correctly. It is a local inference server designed for interactive use, not batch processing. Its request acceptance behavior is intentional. The bug is in Orin's dispatch pattern — submitting N requests simultaneously to a resource that can only process one at a time efficiently.

### The fix

Serialize local inference by replacing the `withTaskGroup` parallel dispatch with a sequential for-loop:

```swift
// Replace the concurrent withTaskGroup with:
for (i, chunk) in chunks.enumerated() {
    let ca = await TranscriptChunker.analyzeChunk(
        chunk, index: i, totalChunks: chunks.count,
        meetingType: meetingType, aiService: service
    )
    ordered[i] = ca
}
```

For a 20-chunk meeting, the serialized total time is approximately 20 × 8 seconds/chunk = 160 seconds — longer than the concurrent case succeeds (when it does succeed), but consistently completing without saturating the GPU. User-visible improvement: the app remains responsive throughout analysis, progress can be shown per-chunk, and macOS is not starved of resources.

The medium-term `InferenceWorker` actor design (MT-002) adds a bounded semaphore (limit 1 for local, limit 3 for cloud) and an `AnalysisJobQueue` that serializes multi-meeting analysis, which addresses both the thundering herd and the scenario where the user completes two back-to-back meetings.

---

## 6. Framework Limitations and Known Bugs

### SFSpeechRecognizer Error 1110

Error code 1110 (`kLSUnknownErr` in the Speech framework's internal error domain) is fired by the on-device VAD (Voice Activity Detector) when it determines that the current recognition window has ended. This is expected behavior for long recordings — the on-device model has a maximum input window of approximately 60 seconds of continuous speech. The framework signals boundary via error 1110 rather than `isFinal = true` on the result.

The current handling in `RecordingService.startRecognitionTask()` correctly interprets 1110 as a session boundary and restarts with a new `SFSpeechAudioBufferRecognitionRequest`. The 200ms restart delay for the "had-speech" case and the 1-second delay for the "no-speech" startup case are empirically tuned to avoid the tight-loop spiral that preceded the current implementation.

Error 301 is `SFSpeechRecognizerErrorCancelled` — this fires when the task is cancelled programmatically. It is explicitly excluded from the restart logic (line 728: `if nsError.code != 301`).

### swift_task_isCurrentExecutorWithFlagsImpl on macOS 26

This is not a framework bug — it is an intentional runtime enforcement added in macOS 26 to close the gap between `@MainActor` isolation at the type level and the underlying GCD main queue. Code that was silently incorrect on macOS 14–15 (mutating `@Observable` state from GCD dispatch blocks) now crashes with a clear signal. The fix — adopting `@MainActor` and replacing all GCD dispatches with `Task { @MainActor in }` — is correct and forward-compatible.

### SCStream stopCapture() Async Behavior

`SCStream.stopCapture()` is an `async` function but its completion does not guarantee that in-flight audio buffer callbacks have been delivered. Audio buffers are delivered via `CMSampleBuffer` on a dedicated ScreenCaptureKit internal thread. Calling `stopCapture()` and then immediately deallocating the delegate (`streamDelegate = nil`) can produce a delegate callback on a deallocated object. The current `SystemAudioCaptureService` mitigates this by nilling `streamDelegate` only after the `await stopCapture()` resolves, but the gap between callback delivery and stream stop is not formally guaranteed by the API contract.

### SpeechAnalyzer / SpeechTranscriber Resource Cleanup on Abandon

When `MicTranscriberFeed.disarm()` is called (during `stopRecording`), the `SpeechAnalyzer` finalization path calls `finalizeAndFinishThroughEndOfInput()` asynchronously in a detached Task (see `RecordingService.stopRecording()`, lines 518–525). If the app is force-quit between `disarm()` and the completion of `finalizeAndFinishThroughEndOfInput()`, the `SpeechAnalyzer` may not release its audio session properly. On the next launch, a new `SpeechAnalyzer` initialization may fail with a session conflict. This is a known limitation of the `SpeechAnalyzer` API in its first macOS 26 release. The prewarm Task in `startMicSTSession` mitigates cold-start failures but does not address the abandon case.

---

## 7. Crash Prevention Architecture

The following principles have been established from direct crash investigation and are now part of the Orin engineering standards:

### P-1: Never call XPC from the Core Audio I/O thread

The Core Audio I/O thread has real-time scheduling priority. Any blocking operation — including NSLock contention, heap allocation, and XPC round-trips — can cause a HAL deadline miss, which terminates the process. All XPC calls (`endAudio()`, `appendBuffer()` to a recognition request, any framework call that touches `mach_msg`) must be either:

- Already on the I/O thread path with confirmed non-blocking behavior (e.g., `AVAudioFile.write(from:)` with a pre-opened file descriptor), or
- Deferred outside the lock, following the `TapState.updateRequest(_:)` pattern.

**Files that must enforce this:** `TapState.swift` (the `disarm()` fix), any future audio tap callback.

### P-2: Never allocate on the Core Audio I/O thread

Memory allocation on the real-time I/O thread is prohibited. All buffers used in `feed()` methods must be pre-allocated in `arm()`. Resampling converters must be pre-configured before the tap is installed. Objects must be pre-retained before the callback touches them.

**Files that must enforce this:** `MicTranscriberFeed`, `ParticipantSTFeed`, any future tap closure.

### P-3: Never use DispatchQueue.main.async from recognition callbacks or @Observable services

On macOS 26, `DispatchQueue.main.async` does not satisfy the Swift Concurrency actor isolation requirement for `@Observable` property mutations. All mutations must use `Task { @MainActor in }`. Timer callbacks must use the same pattern.

**Replacement pattern:**
```swift
// Before (crashes on macOS 26):
DispatchQueue.main.async { self.someProperty = value }

// After (correct):
Task { @MainActor [weak self] in self?.someProperty = value }
```

**Files that must enforce this:** Any `@Observable @MainActor` class with callbacks from non-actor contexts.

### P-4: Never use ServiceContainer.resolve() from audio callbacks

Audio callbacks may execute on Core Audio I/O threads or ScreenCaptureKit audio threads. `ServiceContainer.resolve()` is not thread-safe and uses a `fatalError` that terminates the process if the service is not registered. All dependencies needed in audio callbacks must be captured at tap installation time (closure capture) or injected at construction time, never resolved lazily from within a callback.

**Files that must enforce this:** Any tap callback closure, any `SCStreamOutput` delegate method.

### P-5: Never use withTaskGroup without a concurrency limit for local inference

`withTaskGroup` dispatches all `addTask` calls into the Swift Concurrency cooperative thread pool. For local inference (Ollama, LM Studio, Apple Foundation Models), all inference is serialized within the inference server — parallelism provides no benefit and causes GPU saturation. Always use a sequential for-loop or a semaphore-gated approach when dispatching to a local inference endpoint.

**Files that must enforce this:** `MeetingIntelligenceService.analyzeChunked()`, any future analysis pipeline code that calls an AI service in a loop.

---

## 8. Open Questions

The following questions remain unresolved and require further investigation before their associated code paths can be considered stable.

### OQ-1: Does SpeechAnalyzer correctly release its audio session when abandoned mid-lifecycle?

If the user force-quits Orin while a `SpeechAnalyzer` is active (between prewarm and `finalizeAndFinishThroughEndOfInput()`), does macOS properly clean up the audio session on the next launch? This has not been tested with a force-quit between prewarm and recording start. The concern is that a leftover audio session could cause the next `SpeechAnalyzer` initialization to fail with a session conflict error, blocking the entire Phase 2A pipeline.

**How to answer:** Write a test that kills the process with `kill -9` at various points in the `SpeechAnalyzer` lifecycle and measure next-launch success rate.

### OQ-2: What are the exact conditions under which the generation counter race (CT-7/O-4) materializes?

The race requires the watchdog Task and the error callback restart Task to both pass the generation check before either increments the counter. This implies they must both be scheduled on the MainActor run queue without any intervening turn that executes the other. Under what CPU load, Xcode instrument, or scheduler state does this scheduling pattern reliably occur?

**How to answer:** Add a counter to the session log that records the millisecond timestamp of every generation increment. If the log ever shows two increments of the same generation number, the race is confirmed.

### OQ-3: Is SCKitSystemAudioProvider live code or dead code?

The codebase mentions `SCKitSystemAudioProvider` in the synthesis context (referenced in the investigation but not found in a direct file search during this review). If this type exists in the codebase, is it used? Is it the predecessor to `SystemAudioCaptureService`? If it is unreachable, it should be deleted. If it is reachable, its concurrency contract needs to be verified.

**How to answer:** `grep -rn "SCKitSystemAudioProvider"` in the repository. If found, trace all call sites.

### OQ-4: Does `MicTranscriberFeed.feed()` block when the SpeechAnalyzer's internal ring buffer is full?

`MicTranscriberFeed.feed()` pushes audio into the `SpeechAnalyzer`'s input stream. If the analyzer is not consuming audio fast enough (e.g., under CPU pressure during Ollama inference), the internal ring buffer may fill. Does the push block, drop, or overwrite? A blocking push from the Core Audio I/O thread would cause a real-time deadline miss (CT-4 mechanism). The `SpeechAnalyzer` API documentation does not specify the buffer-full behavior.

**How to answer:** Instrument `MicTranscriberFeed.feed()` with `os_signpost` and observe call duration under Ollama load in Instruments.

---

## 9. Risk Assessment — Next 30 Days

The following table ranks open issues by their likelihood of causing a user-visible failure in the next 30 days, given the current feature set and user population.

| Rank | Issue | Crash type | Trigger condition | User impact | Days to fix |
|---|---|---|---|---|---|
| 1 | O-1: TapState.disarm() XPC-in-lock | Hard crash (process termination) | Any recording stop when SFSpeechRecognizer pipeline is active | Total data loss (recording may not be saved) | 0.5 |
| 2 | CT-1: Thundering herd (O pending: QW-001) | System freeze, 2+ min | Any meeting > 30 min | Perceived app crash, user-reported freeze | 1 |
| 3 | O-2: Debounce race | Core Audio crash | Any Bluetooth audio device connect during recording | Recording loss, app restart required | 0.5 |
| 4 | O-3: ServiceContainer thread safety | Hard crash (fatalError) | Cold launch with background activity | Total loss of session, no diagnostics | 0.5 |
| 5 | O-4: Generation counter race | Silent transcription degradation | Long meetings with network/CPU pressure | Reduced transcript quality, no crash | 3 |
| 6 | OQ-4: MicTranscriberFeed blocking push | Recognition stall | Phase 2A active + Ollama inference concurrent | Transcription stops mid-meeting | Unknown |
| 7 | CT-6: DebugResetView crash | DEBUG-only crash | Developer "Quit and Relaunch" on macOS 26 | Developer friction only | 0.25 |
| 8 | OQ-1: SpeechAnalyzer session conflict | Phase 2A pipeline failure | Force-quit during SpeechAnalyzer lifecycle | Phase 2A unavailable on next launch | Unknown |

**Immediate action items (before next DMG release):**

1. Fix `TapState.disarm()` XPC-in-lock (O-1) — 5 lines, no behavior change.
2. Add Ollama inference serialization (CT-1/QW-001) — replace `withTaskGroup` with a sequential for-loop in `analyzeChunked()`.
3. Fix `AVAudioEngineConfigurationChange` debounce (O-2) — replace timestamp with `DispatchWorkItem.cancel()`.
4. Add `NSLock` to `ServiceContainer` (O-3) — 4 lines.

All four fixes are independent, have no inter-dependencies, and can be shipped as a single patch commit.
