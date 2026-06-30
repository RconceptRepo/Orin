# Document 11: Performance & Resource Budget

**Series**: Orin Long-Term Architecture Design  
**Document**: 11 of 13  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Overview

This document defines the complete performance and resource budget for the Orin system. Every subsystem has an explicit allocation. Violations of these budgets are treated as defects, not acceptable trade-offs.

The key principle: **budgets are defined before implementation, not discovered after profiling**. A performance regression is a bug. An unspecified performance characteristic is a missing requirement.

---

## 1. Performance Budget Philosophy

### Why Explicit Budgets

Without explicit budgets, performance conversations become opinion-based. "It feels fast enough" is not a specification. Explicit budgets:

- Make regressions automatically detectable (automated tests)
- Create accountability: the owner of a component owns its budget
- Force architectural decisions early (a 0.1ms budget on the audio callback cannot be met with heap allocation — therefore we pre-allocate)
- Allow users to set expectations precisely ("Analysis of a 1-hour meeting takes under 6 minutes")

### Budget Enforcement

Budgets are not aspirational targets. They are enforced by:

1. **XCTest performance tests** that fail CI on regression > 20% from baseline
2. **Instruments profiling** in the release build before every major release
3. **Runtime monitoring** via the Observability Context (`PerformanceBudgetViolation` domain event)
4. **Architecture review** — any design that cannot satisfy its component's budget is rejected at design time, not post-profiling

### The Audio Thread Exception

The Core Audio I/O thread operates under constraints so strict that they are enforced architecturally, not just by tests:

- **No heap allocation** — pre-allocate all buffers before the audio engine starts
- **No I/O** — no file reads, no socket calls, no SwiftData operations
- **No IPC** — no XPC calls, no locks shared with other threads (only `os_unfair_lock` or atomics)
- **No unbounded work** — every operation on the audio thread must complete in bounded time

Any violation of these rules is a crash waiting to happen, not a performance problem to optimize later.

---

## 2. Hardware Reference Points

All budgets are specified against **minimum supported hardware**. If a budget is met on the minimum, it is more than met on target and high-end hardware.

| Tier | Hardware | RAM | OS |
|------|----------|-----|-----|
| **Minimum supported** | Apple M1 | 8 GB | macOS 13 |
| **Target** | Apple M2 | 16 GB | macOS 26 |
| **High-end** | Apple M4 Pro | 48 GB | macOS 26 |
| **Future Windows (target)** | AMD Ryzen 7 5800X | 32 GB | Windows 11 |
| **Future iOS (target)** | iPhone 16 | 8 GB | iOS 18 |

When a budget is given as "M2 budget", it applies to the Target tier. Minimum supported hardware gets a 1.5× multiplier.

---

## 3. Real-Time Audio Budget (NON-NEGOTIABLE)

### The Constraint

The Core Audio I/O callback is called every **1024 frames at 48kHz = 21.3ms**. The callback must complete in under 50% of this period = **< 10ms absolute maximum**. The budget below is far more conservative — the callback must complete in < 1ms to leave headroom for other real-time work.

```
┌─────────────────────────────────────────────────────────────────┐
│  Core Audio I/O Period: 21.3ms                                  │
│  ┌──────────────────────────────────┐                           │
│  │  Budget: < 1ms (< 5% of period) │  ← all Orin RT work here  │
│  └──────────────────────────────────┘                           │
│  ← 20.3ms remaining for other real-time processes               │
└─────────────────────────────────────────────────────────────────┘
```

### Current Status and Required Fixes

| Operation | Budget | Current Status | Violation Consequence | Fix |
|-----------|--------|---------------|----------------------|-----|
| `TapState.feed()` (NSLock acquire + buffer copy) | < 0.1ms | **VIOLATED** — heap allocation on every call | Audio dropout, GC pressure | Pre-allocate `AVAudioPCMBuffer` in `arm()`, reuse in `feed()` |
| `MicTranscriberFeed.feed()` | < 0.1ms | **VIOLATED** — allocates buffer in callback | Priority inversion risk | Pre-allocate buffer pool in `arm()` |
| `ParticipantSTFeed.feed()` (converter reuse) | < 0.05ms | **AT RISK** — lazy `AVAudioConverter` init | Initialization on RT thread | Move `AVAudioConverter` init to `arm()` |
| `RecognitionDiagnostics.increment()` | < 0.01ms | **AT RISK** — NSLock on RT thread | Priority inversion | Replace with `os_unfair_lock` or `OSAtomicIncrement` |
| `TapState.stop()` — `recognitionRequest?.endAudio()` | Never on RT thread | **VIOLATED** — XPC while holding NSLock | System hang | Capture ref under lock, call `endAudio()` outside lock |

### Audio Thread Invariants (enforced by architecture review)

```
// The following are NEVER permitted on the Core Audio I/O thread:
// ✗ Any Swift object allocation (new AnyObject(), Array creation, etc.)
// ✗ Any Objective-C message send that may allocate
// ✗ Any File I/O (read/write/seek)
// ✗ Any network I/O
// ✗ Any XPC call
// ✗ Any NSLock.lock() (may block)
// ✗ Any DispatchSemaphore.wait() (may block)
// ✗ Any Swift actor hop (crossing actor isolation)

// PERMITTED on the Core Audio I/O thread:
// ✓ os_unfair_lock_lock/unlock (fair, bounded wait)
// ✓ OSAtomicIncrement (atomic, no system call)
// ✓ memcpy into pre-allocated buffer
// ✓ Arithmetic, bit operations
// ✓ Reading from pre-allocated, pre-filled value types
```

---

## 4. Session Lifecycle Budget

| Operation | P50 Budget | P99 Budget | Notes |
|-----------|-----------|-----------|-------|
| `SessionDetected` to user notification in UI | < 200ms | < 1s | P99 includes calendar lookup |
| `Session.start()` to first audio buffer flowing | < 300ms | < 1s | `AVAudioEngine.start()` latency |
| First audio buffer to first transcript segment displayed | < 2s | < 5s | ASR warm-up time (SpeechTranscriber) |
| First segment to UI display update | < 200ms | < 500ms | @Observable propagation + SwiftUI render |
| `Session.stop()` to `SessionStopped` event | < 500ms | < 2s | Audio engine teardown |
| `SessionStopped` to `TranscriptFinalized` | < 2s | < 8s | Final segment flush |
| `TranscriptFinalized` to `AnalysisQueued` | < 100ms | < 200ms | Non-blocking queue enqueue |
| `Session.stop()` to UI showing "Analysing" state | < 500ms | < 1s | User feedback must be immediate |

### Current Violation: `Task.sleep` on `@MainActor`

`RecordingService.finalize()` contains `Task.sleep(nanoseconds: 1_500_000_000)` — a 1.5s deliberate sleep on the main actor. This:

- Blocks `@MainActor` for 1.5 seconds (all UI updates frozen)
- Violates the P99 budget for `SessionStopped` to `TranscriptFinalized`
- Was introduced as a workaround for a race condition that should be fixed at the source

**Fix**: Replace with proper state machine transition. The sleep is masking an underlying synchronization issue in ASR finalization. The correct fix is the ASR Session State Machine (Document 04) — `Finalizing` state waits for the `complete` callback from `SpeechTranscriber`, not an arbitrary sleep.

---

## 5. Analysis Pipeline Budget

| Operation | Budget | Notes |
|-----------|--------|-------|
| `TranscriptChunker.chunk()` | < 200ms | In-memory string operations, no I/O |
| `AnalysisJobQueue.enqueue()` | < 50ms | Must never block session stop flow |
| Provider health check (cached, 10s TTL) | < 1ms | Return from `ProviderHealthCache` actor |
| Provider health check (uncached, first call) | < 3s timeout | HTTP `/api/tags` to Ollama |
| Ollama single chunk inference (4k tokens, M1) | < 90s P99 | Typical 25-50s |
| Ollama single chunk inference (4k tokens, M2) | < 60s P99 | Typical 20-40s |
| Total analysis, 8 chunks, M2, sequential | < 8 min P99 | Typical 3-5 min |
| Synthesis call after all chunks | < 60s | M2; uses same InferenceWorker |
| First `ChunkAnalyzed` event delivered to UI | < 45s | From `AnalysisStarted` |
| `MeetingAnalysis` SwiftData write | < 500ms | JSON serialization + `context.save()` |
| UI update after `AnalysisCompleted` | < 200ms | @Observable propagation |

### Why Sequential Inference is Correct

The budget for sequential 8-chunk analysis (8 min max) is intentionally generous because **correctness takes priority over speed**. The alternative — parallel Ollama requests — produces:

- GPU out-of-memory errors on M1 with <8GB GPU memory shared
- Timeout cascades when all requests time out simultaneously
- System-wide freeze while Ollama serializes the requests internally anyway

Sequential processing with progressive UI feedback (`ChunkAnalyzed` events) gives the user real-time progress visibility while keeping the system stable.

---

## 6. Memory Budget

### Process Memory Allocations

| Component | Allocation | Notes |
|-----------|-----------|-------|
| Audio buffers (TapState, pre-allocated) | < 10MB | Fixed size, no GC pressure |
| Active SpeechTranscriber session | < 50MB | Apple framework overhead; measured |
| `TranscriptStore` in-memory cache | < 20MB | Current session only; not all meetings |
| `TranscriptChunks` in-memory during chunking | < 5MB | Pruned after finalization |
| `InferenceWorker` job queue | < 5MB | Job metadata, not full prompts |
| SwiftUI view hierarchy (MeetingsView) | < 100MB | Rendered text + layout |
| Knowledge graph hot node cache (LRU) | < 50MB | ~10,000 hot nodes |
| `VocabularyContext` for active session | < 1MB | 100 terms × ~50 chars avg |
| Observability log buffer (in-memory) | < 5MB | Ring buffer, oldest entries evicted |
| Plugin XPC services (per plugin) | < 50MB per | Separate processes, not in Orin RSS |
| **Orin process total** | **< 500MB RSS** | Excluding Ollama |

### Memory Monitoring

```swift
// Observability Context emits this event when threshold is crossed
struct PerformanceBudgetViolation: DomainEvent {
  let component: String       // "OrinProcess"
  let metric: String          // "RSS_MB"
  let budget: Double          // 500.0
  let actual: Double          // measured value
  let severity: Severity      // .warning (400MB), .critical (500MB)
}
```

The `MemoryMonitor` actor samples RSS every 30 seconds using `task_info()` and emits `PerformanceBudgetViolation` when thresholds are crossed. Unlike `sampleCPUUsage()` (which runs every 5s in production — a defect), memory sampling every 30s is low enough overhead to ship in production builds.

### Current Memory Defect: `allSegments @Query`

`MeetingsListViewModel.allSegments` is a `@Query` with no predicate that loads transcript segments from ALL meetings into memory. At 5,000 meetings × 50 segments × 200 bytes/segment = 50MB just for segment text. This violates the TranscriptStore budget.

**Fix**: Apply `@Attribute(.externalStorage)` to `MeetingItem.transcript` in SwiftData. This stores the transcript blob on disk and returns only a reference in @Query results — the blob is loaded on demand when displaying a specific meeting's detail view.

---

## 7. Disk Budget

### Storage Per Meeting (Text-Only Design)

Orin's fundamental storage advantage: **no audio is ever stored**. The audio stream is transcribed in real time and discarded. This makes Orin's disk footprint negligible compared to any audio-recording application.

| Data Type | Retention Policy | Size Per Meeting | Notes |
|-----------|-----------------|-----------------|-------|
| `TranscriptSegment` records | Forever | ~50KB | Text only; ~500 words/segment |
| `MeetingAnalysis` | Forever | ~20KB | Structured JSON |
| `TranscriptChunk` records | Until `TranscriptFinalized` | ~100KB | Ephemeral crash recovery; pruned |
| Knowledge graph entries | Forever (growing) | ~5KB | Nodes + edges sourced from session |
| Vocabulary corrections | 90 days then pruned | ~1KB per correction | Auto-purge on schedule |
| Observability logs | 7 days then pruned | ~10KB | OSLog + structured events |
| Audio | Never | 0 | Not stored by design |
| **Total per meeting** | | **~75KB** | |

### Annual Storage Projection

| User Type | Meetings/Year | Annual Storage |
|-----------|-------------|---------------|
| Light (1/day) | 250 | ~19MB |
| Regular (3/day) | 750 | ~56MB |
| Heavy (5/day) | 1,250 | ~94MB |
| Power (8/day) | 2,000 | ~150MB |

**5 years of daily heavy use: ~470MB.** This is smaller than a single podcast episode audio file. Communicate this explicitly to users — Orin will never fill their disk.

### SwiftData Store Configuration

```swift
// Correct SwiftData configuration for scale
let configuration = ModelConfiguration(
  isStoredInMemoryOnly: false,
  allowsSave: true,
  groupAppContainerIdentifier: "group.com.rconcept.orin"
)

// @Attribute(.externalStorage) on large blobs
@Model class MeetingItem {
  @Attribute(.externalStorage) var transcript: Data?  // blob stored on disk, not in SQLite
  var summary: String?       // small enough to keep inline
  var startDate: Date        // indexed for @Query
  // ...
}
```

---

## 8. CPU Budget During Recording

### Recording Mode (Audio Active)

| Subsystem | CPU Budget (% of 1 E-core) | Notes |
|-----------|--------------------------|-------|
| Core Audio I/O (real-time, P-core) | 5% | Fixed; Apple guarantees this slice |
| SpeechTranscriber inference | 15-25% | Neural Engine + CPU; profile to confirm |
| `TranscriptStore` writes (batched) | < 3% | After batching fix; currently on @MainActor (defect) |
| `MeetingDetectorService` polling | < 1% | 5-second timer; minimal |
| SwiftUI live transcript rendering | < 5% | @MainActor render budget |
| `EventBus` dispatch | < 1% | In-process actor, nanosecond overhead |
| `Observability` logging (OSLog) | < 0.5% | Kernel-buffered; essentially free |
| **Total Orin process during recording** | **< 40%** | Leaves 60% for user's other work |

### Analysis Mode (Post-Recording)

| Subsystem | CPU Budget | Notes |
|-----------|-----------|-------|
| Ollama inference | Up to 100% of 1 P-core + GPU | Serialized; expected behaviour |
| `InferenceWorker` (orchestration) | < 2% | Queue management only |
| `EntityExtractor` (NLTagger) | < 10% | Apple's NLP is efficient |
| Knowledge graph writes | < 5% | SQLite with indexed inserts |
| UI progressive updates | < 5% | `ChunkAnalyzed` events trigger @Observable |
| **Total during analysis** | **< 120% (1.2 cores)** | Ollama on GPU; CPU mostly free |

### Current CPU Defect: `sampleCPUUsage()` in Production

`RecordingService` calls a Mach API (`task_threads()` + `thread_info()`) every 5 seconds during recording to sample CPU usage. This:

- Runs on the @MainActor in production builds
- Takes ~2ms per call (Mach round-trip)
- Produces 12 samples per minute × 60-minute meeting = 720 unnecessary Mach calls
- The data is only useful for debugging, not user-facing

**Fix**: Gate behind `#if DEBUG` or move to an Instruments trace hook. Do not sample Mach thread info in production.

---

## 9. Battery Budget (iOS Future)

The following budgets apply to the future iOS platform (Document 10). They are defined now so that the iOS architecture is designed to meet them, not retrofitted.

| Mode | Target Drain | Measurement |
|------|-------------|-------------|
| Active recording (mic only, screen off) | < 8% per hour | iPhone 16 Pro, 100% battery start |
| Analysis in background (`BGProcessingTask`) | < 5% per analysis session | 1-hour meeting, Core ML inference |
| Idle (app backgrounded, no active tasks) | < 0.5% per hour | No background processing, no polling |
| Widget refresh (WidgetKit, every 15 min) | < 0.1% per refresh | Timeline entry generation |
| Knowledge graph background build | < 3% per hour | Low-priority background task |

### Battery Architecture Principles for iOS

- **No background audio without user explicit consent** (microphone background mode requires entitlement justification)
- **`BGProcessingTask` for analysis** — iOS scheduler runs it when device is idle + charging
- **`BGAppRefreshTask` for sync** — limited to 30 seconds of work
- **No polling** — all background work is event-driven (push notifications, `BGTaskScheduler`)
- **`CADisplayLink` only when UI is active** — no display link in background

---

## 10. Network Budget

Orin is designed to work with zero network connectivity. All network operations are optional and scoped to specific user-initiated actions.

| Operation | Max Bandwidth | Cache Duration | Notes |
|-----------|--------------|---------------|-------|
| Ollama health check | < 1KB request/response | 10s | Cached in `ProviderHealthCache` |
| Ollama inference request | < 50KB | None | Text prompt |
| Ollama inference response (streaming) | < 20KB | None | Streamed tokens |
| Cloud AI request (if consented) | < 100KB | None | Transcript text |
| iCloud metadata sync | < 200KB per meeting | N/A | Meeting metadata + analysis |
| iCloud knowledge delta | < 100KB per sync | N/A | Differential JSON-LD |
| Language pack download | < 1MB (compressed) | Permanent | One-time per pack |
| Plugin binary download | Varies | Permanent | One-time per install |

### Network Failure Handling

Every network operation in Orin has a defined failure mode that leaves the system in a fully functional local state:

- Ollama unavailable → `AnalysisDeferred`; user notified; analysis retries automatically when Ollama comes back
- iCloud unavailable → local operation unaffected; sync retries on next connectivity
- Language pack download fails → falls back to existing pack; user notified; retries in background
- Cloud AI unavailable → falls back to local provider; if no local provider, `AnalysisDeferred`

---

## 11. Performance Testing Strategy

### Test Categories

**Category 1: Real-Time Audio Safety Tests**

These tests verify that Core Audio callback operations meet the < 0.1ms budget:

```swift
class AudioCallbackPerformanceTests: XCTestCase {
  var tapState: TapState!
  var preallocatedBuffer: AVAudioPCMBuffer!
  
  override func setUp() async throws {
    tapState = try await TapState.armed(format: .standard48kHz)
    preallocatedBuffer = AVAudioPCMBuffer(
      pcmFormat: .standard48kHz,
      frameCapacity: 1024
    )!
  }
  
  func testFeedLatencyP99() {
    var samples = [TimeInterval]()
    for _ in 0..<10_000 {
      let start = mach_absolute_time()
      tapState.feed(preallocatedBuffer)
      let elapsed = machTimeToSeconds(mach_absolute_time() - start)
      samples.append(elapsed)
    }
    let p99 = samples.sorted()[Int(Double(samples.count) * 0.99)]
    XCTAssertLessThan(p99, 0.0001, "P99 feed() must be < 0.1ms; actual: \(p99 * 1000)ms")
  }
}
```

**Category 2: Session Lifecycle Tests**

```swift
func testSessionStopToFinalizedWithin10s() async throws {
  let session = await RecordingSessionCoordinator.startTestSession()
  let start = Date()
  await session.stop()
  let finalized = await session.awaitFinalized(timeout: 10)
  XCTAssertTrue(finalized, "Session must finalize within 10s P99")
  XCTAssertLessThan(Date().timeIntervalSince(start), 10.0)
}
```

**Category 3: Analysis Queue Tests**

```swift
func testEnqueueLatency() async throws {
  let queue = AnalysisJobQueue()
  let analysis = PendingAnalysis.testFixture()
  let start = Date()
  await queue.enqueue(analysis)
  let elapsed = Date().timeIntervalSince(start)
  XCTAssertLessThan(elapsed, 0.050, "Enqueue must be < 50ms")
}
```

**Category 4: SwiftData Scale Tests**

```swift
func testQueryPerformanceAt10000Meetings() async throws {
  // Seed 10,000 meetings
  let store = try SwiftDataPersistenceAdapter.testStore()
  await store.seedTestMeetings(count: 10_000)
  
  // Measure @Query performance
  let start = Date()
  let meetings = try await store.fetchRecentMeetings(limit: 50)
  let elapsed = Date().timeIntervalSince(start)
  
  XCTAssertEqual(meetings.count, 50)
  XCTAssertLessThan(elapsed, 0.1, "Query must be < 100ms with 10,000 meetings")
}
```

**Category 5: Memory Budget Tests**

```swift
func testProcessMemoryDuringRecording() async throws {
  let session = await RecordingSessionCoordinator.startTestSession()
  await Task.sleep(nanoseconds: 30_000_000_000)  // 30s recording
  
  let rssBytes = processResidentSetSize()
  let rssMB = Double(rssBytes) / 1_048_576
  
  XCTAssertLessThan(rssMB, 400, "RSS must be < 400MB during recording; actual: \(rssMB)MB")
  
  await session.stop()
}
```

### CI Enforcement

Performance tests run on every merge to `main` via a dedicated performance test Xcode scheme:

```yaml
# .github/workflows/performance.yml
- name: Run Performance Tests
  run: xcodebuild test
    -scheme OrinPerformance
    -destination "platform=macOS"
    -resultBundlePath performance.xcresult

- name: Check Regressions
  run: swift scripts/check_performance_regressions.swift
    --baseline performance_baseline.json
    --result performance.xcresult
    --threshold 0.20  # Fail on >20% regression
```

---

## 12. Runtime Performance Monitoring

The `Observability Context` emits `PerformanceBudgetViolation` events for runtime monitoring:

```swift
struct PerformanceBudgetViolation: DomainEvent {
  let eventID: UUID = UUID()
  let eventType = "observability.performance_budget_violation"
  let version = 1
  let occurredAt: Date
  let sessionID: UUID?
  let causationID: UUID? = nil
  let correlationID: UUID? = nil
  
  let component: String       // e.g., "InferenceWorker", "TranscriptStore"
  let operation: String       // e.g., "chunk_inference", "save"
  let budgetMs: Double        // the defined budget in milliseconds
  let actualMs: Double        // the measured actual time
  let severity: Severity      // .warning (1.5× budget), .critical (3× budget)
}
```

Violations are:
- Logged to OSLog with `os_log(.fault)` level (visible in Console.app)
- Written to the local audit log (7-day retention)
- Shown in the Debug menu (DEBUG builds only)
- Never transmitted to external services

---

## 13. Known Defects Mapped to Budgets

This table maps every known performance defect to the budget it violates, with severity and fix:

| Defect | Component | Budget Violated | Severity | Fix |
|--------|-----------|----------------|----------|-----|
| Heap allocation in `TapState.feed()` | Audio pipeline | RT thread < 0.1ms | **CRITICAL** | Pre-allocate in `arm()` |
| XPC while holding NSLock in `TapState.stop()` | Audio pipeline | RT thread invariant | **CRITICAL** | Capture ref, release lock first |
| Lazy `AVAudioConverter` init in `ParticipantSTFeed.feed()` | Audio pipeline | RT thread < 0.05ms | HIGH | Move to `arm()` |
| `Task.sleep(1.5s)` on `@MainActor` in `finalize()` | Session lifecycle | SessionStopped < 3s P99 | HIGH | Use ASR state machine await |
| `persistChunkIfNeeded` calls `context.save()` on `@MainActor` | Persistence | MainActor CPU < 5% | HIGH | Off-load to background actor |
| `allSegments @Query` loads all meeting transcripts | Memory | Process RSS < 500MB | HIGH | Add `@Attribute(.externalStorage)` |
| Ollama thundering herd (41 concurrent requests) | AI pipeline | Analysis within budget | **CRITICAL** | `InferenceWorker` serialization |
| `sampleCPUUsage()` Mach API every 5s in production | Session | Recording CPU < 40% | MEDIUM | Gate behind `#if DEBUG` |
| `filterMeetings` O(N) scan on every keypress | UI | UI CPU < 5% | MEDIUM | Debounce + SwiftData predicate |
| `NSLock` in `RecognitionDiagnostics` on RT thread | Audio pipeline | RT thread < 0.01ms | HIGH | Replace with `os_unfair_lock` |

---

## 14. Migration: Fixing the Critical Defects

### Priority Order

Fix in this order — the audio thread violations must be fixed before any new features ship:

**CRITICAL (block release):**
1. Pre-allocate `AVAudioPCMBuffer` in `TapState.arm()`, reuse in `TapState.feed()`
2. Fix `TapState.stop()` — capture `recognitionRequest` reference under lock, call `endAudio()` after releasing lock
3. Move lazy `AVAudioConverter` init from `ParticipantSTFeed.feed()` to `ParticipantSTFeed.arm()`
4. Replace `NSLock` in `RecognitionDiagnostics` with `os_unfair_lock`
5. Introduce `InferenceWorker` actor (fixes Ollama thundering herd)

**HIGH (ship within 2 sprints):**
6. Remove `Task.sleep(1.5s)` from `RecordingService.finalize()` — replace with proper state machine await
7. Move `persistChunkIfNeeded` `context.save()` off `@MainActor` — use a background persistence actor
8. Apply `@Attribute(.externalStorage)` to `MeetingItem.transcript`

**MEDIUM (backlog):**
9. Gate `sampleCPUUsage()` behind `#if DEBUG`
10. Add debounce to `filterMeetings` in `MeetingsListViewModel`

---

## Summary

The performance budget for Orin V2:

| Layer | Key Budget | Status |
|-------|-----------|--------|
| Audio callback | < 0.1ms per `feed()` call | VIOLATED (pre-allocate fix needed) |
| Session start | < 300ms to first audio | MEETING |
| Session stop | < 3s to `TranscriptFinalized` | VIOLATED (1.5s sleep) |
| Chunk inference (M2) | < 60s P99 per chunk | MEETING (when serialized) |
| Total analysis (M2, 8 chunks) | < 8 min P99 | VIOLATED (thundering herd) |
| Process memory | < 500MB RSS | AT RISK (allSegments @Query) |
| Disk per meeting | < 75KB | MEETING |
| Recording CPU | < 40% total | VIOLATED (Mach API sampling) |

All VIOLATED and AT RISK items have concrete fixes defined above. The fixes are non-breaking and can be applied incrementally without architectural changes to the rest of the system.
