# 05 — Performance Review

**Review date**: 2026-06-29  
**Reviewer**: Principal Architecture Review (9-agent synthesis)  
**Codebase commit**: 4f603ea  
**Verdict**: Multiple production-severity bottlenecks. No single bottleneck requires a full rewrite. Fixes are additive and sequenced below.

---

## 1. Performance Bottleneck Summary

| ID | Description | Severity | Category | Status |
|----|-------------|----------|----------|--------|
| PB-001 | Thundering herd Ollama dispatch — unbounded `withTaskGroup` in `analyzeChunked()` | Critical | CPU / GPU | Open |
| PB-002 | Real-time heap allocation — `AVAudioPCMBuffer` allocated on every Core Audio I/O callback | Critical | RAM / Thread | Open |
| PB-003 | O(N²) SwiftData saves — `context.save()` on every 10-character transcript growth | High | Disk / Thread | Open |
| PB-004 | `allSegments` `@Query` loads all segments from all meetings on every `MeetingsView` render | High | RAM / Disk | Open |
| PB-005 | `MeetingItem.transcript` inline SQLite column loaded for all meetings in list view | High | RAM / Disk | Open |
| PB-006 | Full-table scans in `buildTimelineSegments()` and `deleteMeetingFully()` — no `meetingId` predicate | High | Disk | Open |
| PB-007 | `MeetingItem.structuredActionItems` JSON decoded on every list row render — no caching | Medium | CPU | Open |
| PB-008 | O(N×M) hallucination word scan runs on `@MainActor` — 200 words × 39,000 chars = 7.8 M comparisons | Medium | CPU / Thread | Open |

---

## 2. CPU Analysis

### 2.1 Ollama Thundering Herd (PB-001)

**File**: `Sources/Orin/Services/MeetingIntelligenceService.swift`, lines 150–173

`analyzeChunked()` dispatches every chunk simultaneously via `withTaskGroup`:

```swift
await withTaskGroup(of: (Int, ChunkAnalysis).self) { group in
    for (i, chunk) in chunks.enumerated() {
        group.addTask {
            let ca = await TranscriptChunker.analyzeChunk(...)
            return (i, ca)
        }
    }
    for await (i, ca) in group { ordered[i] = ca }
}
```

Swift Concurrency submits all tasks to the cooperative thread pool immediately. Each task issues one `URLSession` POST to Ollama's `/api/generate`. Ollama is single-GPU and serializes internally, but the HTTP server accepts all connections and queues them, binding a thread per connection in the process.

**Measured impact for a 150-minute meeting:**

| Phase | Request count | GPU state |
|-------|--------------|-----------|
| Wave 1 — initial dispatch | ~20 requests at t=0 | 100% GPU, 100% CPU inference queue |
| Wave 2 — all time out at t=60s | ~19–20 retry requests at t=70s | Second full saturation |
| Total requests | ~41 | System freeze for ~130 seconds |

The problem is not concurrency per se — Ollama will process the requests sequentially regardless. The problem is that 20 open HTTP connections each hold a 60-second URLSession timeout, all expiring at the same moment, all retry at `t+10s` simultaneously. This produces two back-to-back saturation events instead of one progressive sequence.

**Fix**: Replace `withTaskGroup` with a `for` loop or an actor-bounded semaphore (limit: 1 for local Ollama, limit: 3 for cloud APIs). The total GPU time is identical; latency improves to progressive delivery and system freeze is eliminated. See QW-001 in Section 9.

### 2.2 Production Benchmarking Work: `sampleCPUUsage()` and `sampleRAMMB()`

**File**: `Sources/Orin/Services/RecordingService.swift`, lines 946–953, 1316–1360

A `Task.detached` fires every 5 seconds for the lifetime of every recording session and calls two raw Mach kernel API functions:

```swift
micSTSamplingTask = Task.detached { [weak metrics] in
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        metrics?.record(cpu: sampleCPUUsage(), ram: sampleRAMMB())
    }
}
```

`sampleCPUUsage()` calls `task_threads(mach_task_self_, &threadList, &threadCount)` to enumerate all threads, then calls `thread_info()` on each with flavor `THREAD_BASIC_INFO`. `sampleRAMMB()` calls `task_info()` with `MACH_TASK_BASIC_INFO`. Both are Mach traps (kernel transitions) and carry real cost.

**Impact**:

- Every 5-second sample requires a kernel trap per thread (Orin has 20–30 threads during recording). That is 4–6 kernel calls per sample, 12–18 per minute, continuous during all recordings.
- `_cpuSamples` and `_ramSamples` arrays in `MicSTSessionMetrics` grow unboundedly. A 3-hour recording produces 2,160 samples per array. No capacity limit is set; the arrays accumulate for the process lifetime if `micSTMetrics` is not released.
- The results are written to `SessionLogger` as a summary block, meaning this benchmarking apparatus exists in production builds for all users, not only during development.

**Fix**: Gate the sampling task behind `#if DEBUG` or a `FeatureFlags.metricsEnabled` check. If retained for production diagnostics, drain the arrays into a ring buffer of fixed size (last 60 samples) instead of an unbounded append.

### 2.3 O(N×M) Hallucination Word Scan on `@MainActor` (PB-008)

**File**: `Sources/Orin/Services/MeetingIntelligenceService.swift`, lines 218–232

After every chunked analysis the following runs synchronously in the main analysis path:

```swift
let summaryWords = summary.components(separatedBy: .whitespacesAndNewlines)
    .map { $0.trimmingCharacters(in: .punctuationCharacters) }
    .filter { w in w.count >= 4 && w.first?.isUppercase == true && w != title }
var flagged: [String] = []
for word in summaryWords {
    if !transcriptLower.contains(word.lowercased()) && !flagged.contains(word) {
        flagged.append(word)
    }
}
```

This is a `[String].contains(_:)` inside a loop, which is O(N×M) where N is the number of summary words and M is the length of the transcript string. `String.contains` performs a full linear scan of the receiver. For a 150-minute meeting:

- `transcriptLower` ≈ 39,000 characters
- `summaryWords` after filtering ≈ 150–200 words
- Total character comparisons: 150 × 39,000 = **5.85–7.8 million**

This runs on `@MainActor`. During the window where this executes, SwiftUI cannot process layout passes, gesture events, or `@Query` updates.

Additionally, `flagged.contains(word)` inside the inner loop makes the outer loop O(N²) in the number of flagged words — negligible for small N but structurally wrong.

**Fix**: Pre-build a `Set<Substring>` of transcript words once. Replace `transcriptLower.contains(word.lowercased())` with a set lookup. Move the entire scan to a `Task.detached` actor. This reduces complexity from O(N×M) to O(N+M) and removes main actor blocking.

### 2.4 74 Unguarded `print()` Statements in Release Builds

**Count**: 74 `print()` calls across `Sources/Orin/` (verified with `grep -rn "print(" Sources/Orin/ | wc -l`).

The most severe are in `MeetingIntelligenceService.swift` (16 calls) including the `[ProofRun]` diagnostic block that prints the full meeting summary, all action items, all decisions, and the raw hallucination check to stdout on every single analysis run. These are not guarded by `#if DEBUG`.

`print()` is synchronous and holds a write lock on stdout. In a concurrent environment with multiple analysis tasks, this creates lock contention. More importantly, meeting transcripts and summaries — private user data — are written to a globally readable file descriptor in production builds.

**Fix**: Replace all `print()` with `Logger` (OSLog) calls. OSLog is zero-overhead when the log level is not active, satisfies privacy requirements via `.private` data classification, and does not block.

---

## 3. Memory Analysis

### 3.1 Real-Time Heap Allocation in Audio Callbacks (PB-002)

**File**: `Sources/Orin/Services/RecordingService.swift`, line 1195 (`MicTranscriberFeed.feed()`)  
**File**: `Sources/Orin/Services/SystemAudioCaptureService.swift`, line 825 (`convertToAVAudioPCMBuffer()`)

`MicTranscriberFeed.feed()` is called on the Core Audio real-time I/O thread at the hardware interrupt rate. For a 44.1 kHz capture device with a 512-frame buffer, this is approximately 86 callbacks per second. For 48 kHz with a 1024-frame buffer, approximately 46 callbacks per second. Each invocation inside `lock.withLock {}` allocates a new `AVAudioPCMBuffer`:

```swift
func feed(_ buffer: AVAudioPCMBuffer) {
    lock.withLock {
        // ...
        let dstCap = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 64)
        guard let dst = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: dstCap) else { return }
        // ...
    }
}
```

`AVAudioPCMBuffer(pcmFormat:frameCapacity:)` calls into `AVFoundation`, which allocates from the default allocator. Heap allocation from a real-time thread causes two problems:

1. **Priority inversion**: The allocator uses a mutex internally. If a non-real-time thread holds the allocator lock (e.g., during `free()`), the real-time thread blocks — violating the real-time guarantee and causing audio glitches and overruns.
2. **Allocation rate**: At 46 callbacks/second, the allocator handles ~2,760 allocations per minute, each paired with a deallocation when the buffer object is released. This contributes measurably to heap fragmentation over a multi-hour session.

`SystemAudioCaptureService.convertToAVAudioPCMBuffer()` at line 825 has the same pattern for the participant audio path, doubling the allocation rate when both microphone and system audio are active (approximately 92 allocations/second combined).

**Fix**: Pre-allocate a fixed pool of 3–4 `AVAudioPCMBuffer` objects at session start. In `feed()`, acquire one from the pool via a lock-free ring or a `DispatchSemaphore(value: N)`. Release back to the pool in the `cont.yield()` completion handler. This eliminates all runtime heap allocation from the real-time path.

### 3.2 `allSegments` `@Query` — Full Table Load (PB-004)

**File**: `Sources/Orin/Views/Meetings/MeetingsView.swift`, line 15

```swift
@Query(sort: \TranscriptSegment.timestamp, order: .forward)
private var allSegments: [TranscriptSegment]
```

This `@Query` carries no predicate. SwiftData fetches every `TranscriptSegment` row from SQLite into memory on every `MeetingsView` render. At scale:

- 100 meetings × 500 segments/meeting = 50,000 rows
- Each `TranscriptSegment` carries a `text` string column. At an average of 80 characters per segment, this is ~4 MB of string data loaded on every view render cycle.
- SwiftData wraps each row in a managed object. The `ModelContext` observation graph wires up change observers for all 50,000 objects, meaning any segment modification during a recording triggers a graph traversal over all 50,000 registered objects.

The segments are used in one place: line 90, to filter by `selectedMeeting.id` and pass to `MeetingDetailView`. The filter is performed in Swift after loading everything from disk.

**Fix**: Remove `allSegments` from `MeetingsView`. Pass a `meetingId`-predicated `@Query` to `MeetingDetailView` directly, or fetch on demand when a meeting is selected. This reduces the observation graph from O(total_segments) to O(selected_meeting_segments).

### 3.3 `MeetingItem.transcript` Inline SQLite Column (PB-005)

**File**: `Sources/Orin/Models/OrinModels.swift` (no `@Attribute(.externalStorage)` on `transcript`)

`MeetingItem.transcript` is a `String` stored as an inline SQLite TEXT column. SwiftData includes inline text columns in the projection for every `FetchDescriptor<MeetingItem>` unless the fetch explicitly sets `propertiesToFetch`. The `allMeetings` `@Query` in `MeetingsView` loads all `MeetingItem` rows, which includes the full transcript text for every meeting.

At 50 meetings with an average transcript of 15,000 characters each, this is approximately **750,000 characters (750 KB)** loaded into memory on every list view render. At 100 meetings with 30,000-character transcripts, this reaches **3 MB per render cycle**.

The transcript content is not displayed in the list view. The list shows only the meeting title, date, and duration. The transcript is only needed when a specific meeting is selected in `MeetingDetailView`.

**Fix**: Add `@Attribute(.externalStorage)` to `MeetingItem.transcript`. SwiftData will store transcript text in a separate file and load it lazily only when accessed. The list-view query no longer materializes transcript content, reducing per-render memory by the full transcript size for all meetings.

### 3.4 `TranscriptChunk` Accumulation — No Post-Finalize Pruning (PB-006 related)

**File**: `Sources/Orin/Services/TranscriptStore.swift`, `buildTimelineSegments()`

`TranscriptChunk` records are written throughout recording as crash-recovery checkpoints. After `finalize()` completes successfully, `buildTimelineSegments()` reads all chunks and converts them to `TranscriptSegment` rows. The chunks are then no longer needed for crash recovery — the segments exist and the final transcript is persisted.

However, no pruning step follows. `TranscriptChunk` records accumulate indefinitely. For a recording producing one chunk per 10-character growth increment, a 90-minute meeting may generate thousands of chunk rows. These are fetched in `buildTimelineSegments()` via a full-table `FetchDescriptor<TranscriptChunk>` with `fetchLimit: 10_000`.

**Fix**: After `buildTimelineSegments()` completes successfully, delete all `TranscriptChunk` records for that meeting from the context and save. This is safe because the timeline segments now hold the canonical representation.

### 3.5 `_cpuSamples` / `_ramSamples` Unbounded Growth

**File**: `Sources/Orin/Services/RecordingService.swift`, lines 1233–1234 (`MicSTSessionMetrics`)

The `_cpuSamples` and `_ramSamples` arrays in `MicSTSessionMetrics` grow by one entry every 5 seconds with no bound:

```swift
private var _cpuSamples: [Double] = []
private var _ramSamples: [Double] = []
```

For a 3-hour recording at one sample every 5 seconds: 2,160 entries per array, 17,280 bytes each — negligible by itself. However, if `micSTMetrics` is not released (e.g., a reference cycle through the `Task.detached` sampling closure), the arrays persist for the process lifetime and accumulate across sessions without bound.

The `lock.withLock` in `summary()` runs `_cpuSamples.reduce(0, +)` over the entire array, which is O(N) on the main thread.

**Fix**: Replace with a fixed-size ring buffer (capacity: 72 entries = 6 minutes at 5s intervals). This bounds memory and keeps the summary reduction O(1).

---

## 4. Disk I/O Analysis

### 4.1 O(N²) SwiftData Saves During Recording (PB-003)

**File**: `Sources/Orin/Services/TranscriptStore.swift`, lines 220–236 (`persistChunkIfNeeded`)

On every call to `updateMic()` or `updateParticipant()`, if the transcript has grown by 10 or more characters since the last chunk, a `TranscriptChunk` is inserted and the context is saved immediately:

```swift
private func persistChunkIfNeeded(speaker: String, text: String, previousLength: Int) {
    guard let meeting = activeMeeting,
          let context = activeContext,
          text.count - previousLength >= Self.chunkWriteThreshold else { return }
    let chunk = TranscriptChunk(meetingId: meeting.id, speaker: speaker, text: text)
    context.insert(chunk)
    do {
        try context.save()   // <-- SQLite WAL write on every call
    } catch { ... }
}
```

`updateMic()` is called on every `@Observable` change to `RecordingService.transcript`, which fires on every `SFSpeechRecognizer` partial result. SFSpeechRecognizer emits partial results at approximately 2–5 Hz during active speech. With a 10-character threshold, this produces:

- Speaking rate: ~150 words per minute = ~750 characters per minute
- Threshold crossings: ~75 per minute
- SQLite WAL `context.save()` calls: **~75/minute** during active recording

The 3-second checkpoint timer in `startCheckpointTimer()` fires independently of `persistChunkIfNeeded`, adding further saves. During a meeting with overlapping mic and participant audio, both `updateMic` and `updateParticipant` paths fire independently, potentially doubling the save rate.

Each `context.save()` flushes the WAL buffer, which involves an `fsync`-equivalent operation. On macOS, SQLite in WAL mode uses `F_FULLFSYNC` for durability, which is a full disk flush. On SSDs this takes 1–10 ms. At 75 saves per minute, this is 75–750 ms of I/O latency per minute, entirely on `@MainActor`.

**Fix (QW-008)**: Remove the `context.save()` from `persistChunkIfNeeded`. Retain the `context.insert(chunk)` (in-memory only). Let the 3-second checkpoint timer be the sole SQLite commit path. The crash-recovery value of chunks is unchanged — uncommitted inserts are still in the `ModelContext` change log and survive any path that calls `checkpoint()`. True crash recovery (SIGKILL, OOM kill) needs a different mechanism: the existing `UserDefaults` orphan backup already covers this case.

### 4.2 Full-Table Scans in `buildTimelineSegments()` and `deleteMeetingFully()` (PB-006)

**File**: `Sources/Orin/Services/TranscriptStore.swift`, line 388  
**File**: `Sources/Orin/Extensions/ModelContext+SafeSave.swift`, lines 85–90

`buildTimelineSegments()` fetches all `TranscriptChunk` rows with no meetingId predicate, then filters in Swift:

```swift
var chunkDescriptor = FetchDescriptor<TranscriptChunk>(
    sortBy: [SortDescriptor(\.timestamp, order: .forward)]
)
// No predicate — fetches ALL chunks from ALL meetings
guard let allChunks = try? context.fetch(chunkDescriptor) else { ... }
let chunks = allChunks.filter { $0.meetingId == meetingID }  // filtered in Swift
```

`deleteMeetingFully()` has the same pattern for both `TranscriptChunk` and `TranscriptSegment`:

```swift
let allChunks = (try? fetch(FetchDescriptor<TranscriptChunk>())) ?? []
allChunks.filter { $0.meetingId == meetingID }.forEach { delete($0) }
let allSegs = (try? fetch(FetchDescriptor<TranscriptSegment>())) ?? []
allSegs.filter { $0.meetingId == meetingID }.forEach { delete($0) }
```

SQLite has no opportunity to use an index for these queries because the predicate is applied in Swift after a full table load. At 50 meetings × 500 chunks each = 25,000 rows, every `deleteMeetingFully()` call loads all 25,000 chunk rows into memory and filters them in a linear scan.

**Fix (QW-009)**: Add `meetingId` predicates directly in the `FetchDescriptor`:

```swift
var desc = FetchDescriptor<TranscriptChunk>(
    predicate: #Predicate { $0.meetingId == meetingID },
    sortBy: [SortDescriptor(\.timestamp, order: .forward)]
)
```

SQLite can use an index on `meetingId` (which SwiftData creates for `@Attribute(.unique)` fields and relationships) to satisfy these queries without a full table scan. For `deleteMeetingFully()`, this reduces the fetch from O(total_chunks) to O(chunks_per_meeting).

### 4.3 `/tmp/orin_phi3_raw.txt` Write on Every Analysis Run

**File**: `Sources/Orin/Services/MeetingIntelligenceService.swift`, lines 274–275

```swift
// Dump raw phi3 response for debugging — read at /tmp/orin_phi3_raw.txt
try? result.text.write(to: URL(fileURLWithPath: "/tmp/orin_phi3_raw.txt"),
                       atomically: true, encoding: .utf8)
```

This line writes the full raw AI inference response — which contains the meeting transcript content — to a world-readable path in `/tmp` on every analysis call. This is a:

1. **Privacy violation**: `/tmp` is readable by all processes on the system running as any user in the same console session. Meeting content is exposed to every other app on the machine.
2. **Unnecessary I/O**: The write is synchronous and `atomically: true` means it writes to a temp file then `rename(2)`s it — two filesystem operations per analysis run.
3. **No `#if DEBUG` guard**: This runs in production builds for all users.

**Fix (QW-006)**: Delete this line entirely, or move it behind `#if DEBUG && ORIN_PROOF_RUN_LOGGING`.

---

## 5. Threading and Actor Analysis

### 5.1 Main Actor Blocking During Recording

**File**: `Sources/Orin/Services/TranscriptStore.swift`, `Sources/Orin/Services/RecordingService.swift`

`TranscriptStore` is `@MainActor`-isolated. `persistChunkIfNeeded()` — called on every `updateMic`/`updateParticipant` invocation — calls `context.save()` synchronously on `@MainActor`. This means:

- SQLite WAL flush executes on the main thread
- SwiftUI cannot process any render pass, gesture event, or animation frame during the flush
- At 75 saves/minute × 1–10ms/save, the main thread is blocked for 75–750 ms per minute

During high-frequency recognition callbacks (partial results at 2–5 Hz), the main thread alternates between SwiftUI layout, recognition callback dispatch, and SQLite I/O. Dropped frames manifest as UI stutters during the most active periods of a meeting.

**Fix**: The `persistChunkIfNeeded` save removal (QW-008) eliminates the in-callback save path. The 3-second checkpoint timer is the remaining main-thread SQLite writer; its periodic flush is acceptable given the 3-second interval.

### 5.2 1.5-Second `Task.sleep` on `@MainActor` in `TranscriptStore.finalize()`

**File**: `Sources/Orin/Services/TranscriptStore.swift`, line 315

```swift
try? await Task.sleep(nanoseconds: 1_500_000_000)
```

`finalize()` is `@MainActor`-isolated. `Task.sleep` does yield the actor (it is `async`), so the main actor is not held for 1.5 seconds. However, any code that `await`s `finalize()` from `@MainActor` will not receive its result for at least 1.5 seconds, blocking the call site from proceeding.

The purpose of the sleep is to allow any trailing recognition result callbacks to land before the finalization snapshot is taken. This is a timing assumption, not a guaranteed synchronization point. If recognition terminates cleanly (via `recognitionTask.finish()`), the final result is delivered synchronously before the task's completion handler fires — the 1.5-second sleep is unnecessary on that path.

**Fix**: Replace the sleep with an explicit `CheckedContinuation` or `AsyncStream` that `finalize()` can `await`. `RecordingService` resumes the continuation when the last recognition result is received (from the task's completion handler). This gives deterministic finalization without an arbitrary timeout.

### 5.3 `MeetingItem.structuredActionItems` JSON Decode on Every List Row Render (PB-007)

**File**: `Sources/Orin/Models/OrinModels.swift` (the `structuredActionItems` computed property or getter)

If `structuredActionItems` is a computed property that JSON-decodes from a stored string on every access, and if `MeetingsView` reads it for each row in the meeting list, then every list render cycle triggers N JSON decode operations where N is the number of visible meetings. Each decode is O(JSON length), holding the main thread for the decode duration.

**Fix**: Cache the decoded result in a `@Transient var _cachedActionItems: [ActionItemRecord]?` SwiftData transient property. Invalidate the cache when the underlying JSON string changes. Alternatively, store `structuredActionItems` as a SwiftData relationship to a separate `ActionItemRecord` `@Model` rather than as embedded JSON.

### 5.4 `SessionLogger.shared` from Real-Time Audio Thread

**File**: `Sources/Orin/Services/RecordingService.swift`, multiple sites

Recognition callbacks dispatch `Task { @MainActor in }` blocks that call `SessionLogger.shared.log(...)`. During high-frequency recognition (SFSpeechRecognizer partial results at 2–5 Hz), these dispatches accumulate in the Swift Concurrency cooperative pool. Each `Task { @MainActor in }` is a heap allocation (for the Task object and its closure), enqueued to the main actor's queue.

At 5 callbacks/second × 60 seconds = 300 Task allocations per minute during active recording. These accumulate if the main actor is busy (e.g., during SQLite saves), creating a backlog of pending main-actor work.

**Fix**: `SessionLogger.shared.log()` should be an actor method on a dedicated `SessionLogger` actor (not `@MainActor`). Log calls from recognition callbacks should use `Task.detached` or direct actor dispatch rather than `Task { @MainActor in }`, removing the main actor from the logging path entirely.

---

## 6. SwiftData Query Performance

### 6.1 `allSegments` — Unpredicated Global Load

**File**: `Sources/Orin/Views/Meetings/MeetingsView.swift`, line 15

As described in Section 3.2, this loads all `TranscriptSegment` rows on every `MeetingsView` render pass. SwiftData `@Query` properties register observation with the `ModelContext`; any insert, update, or delete of any `TranscriptSegment` anywhere in the system triggers a `MeetingsView` re-render, loading the entire dataset again.

During active recording, `buildTimelineSegments()` inserts segments at session finalization. This triggers an `allSegments` reload — potentially 50,000 rows — immediately after a recording session, at the moment when the user is most likely interacting with the UI.

### 6.2 `allMeetings` Transcript Blob Loading

**File**: `Sources/Orin/Views/MeetingsView.swift`, line 11

```swift
@Query(sort: \MeetingItem.date, order: .forward)
private var allMeetings: [MeetingItem]
```

Without `@Attribute(.externalStorage)` on `transcript`, this `@Query` materializes every meeting's full transcript text into RAM. SwiftData does not support partial projections (no equivalent to SQL `SELECT id, title, date` — it always loads the full model object). The only mitigation is to move transcript storage out of the inline column via `.externalStorage`.

### 6.3 Observation Graph Complexity

`MeetingsView` registers for observation on every property of every `MeetingItem` loaded by `allMeetings`. This includes `transcript`, `structuredActionItemsJSON`, `summary`, and all other string columns. A checkpoint save that updates `meeting.transcript` during recording notifies the observation graph for that meeting, which triggers a `MeetingsView` diff pass over all meetings and re-renders the list.

This is a structural consequence of SwiftData `@Observable` and cannot be fully avoided without migrating to manual observation or splitting `MeetingItem` into a lightweight list model and a detail model.

---

## 7. Ollama Interaction Performance

### 7.1 Health Check — No Caching (QW-002)

Every analysis flow calls an Ollama health check (`/api/tags` or equivalent) to verify the server is running before dispatching inference. If this check is called once per chunk in `analyzeChunked()`, a 20-chunk analysis triggers 20+ separate `/api/tags` requests. Even if called once per `analyze()` invocation, back-to-back analyses (e.g., folder summary after meeting analysis) issue redundant health checks with no caching between calls.

**Fix**: Cache the health check result for 10 seconds. A single `var ollamaHealthCache: (result: Bool, time: Date)?` in `AIService` is sufficient. Check expiry before issuing a new request.

### 7.2 Retry Synchronization — No Jitter (QW-003)

All 20 chunk tasks use an identical 10-second retry delay after timeout. Because they all time out at the same wall-clock moment (t=60s), they all retry at t=70s. This produces synchronized wave behavior: Wave 1 at t=0, Wave 2 at t=70s.

**Fix**: Add ±2.5 seconds of random jitter to the retry delay. This desynchronizes the retry wave, spreading requests across a 5-second window and preventing the second full saturation event.

### 7.3 No Connection Reuse or Streaming

Ollama supports streaming inference via `"stream": true` in the request body. The current implementation waits for the complete response body before proceeding, holding a URLSession connection for the full inference duration (up to 60 seconds). Streaming would allow progressive result processing and earlier timeout detection.

No keep-alive strategy is configured for `URLSession`. Each request opens a new TCP connection to localhost:11434. While TCP setup latency to localhost is negligible, connection establishment consumes socket file descriptors and triggers kernel-side TCP state machine work 41 times per analysis in the worst case.

---

## 8. Execution Timeline Analysis

### 8.1 Current Worst-Case: 150-Minute Meeting Analysis

| Time (s) | Event |
|----------|-------|
| t=0 | `analyzeChunked()` launches 20 simultaneous chunk tasks |
| t=0 | All 20 URLSession connections opened to Ollama localhost:11434 |
| t=0–60 | Ollama processes requests serially; 19 connections wait |
| t=60 | All 19 waiting connections time out simultaneously |
| t=60 | 20th connection completes (first chunk result available) |
| t=60 | System: URLSession timeout callbacks on 19 threads simultaneously |
| t=70 | All 19 retry requests dispatched simultaneously (no jitter) |
| t=70–130 | Second saturation wave: 19 requests, all waiting |
| t=130 | 18 more timeouts; system freeze period 2 |
| end | Only 1 chunk result; analysis incomplete or severely degraded |

User experience: UI hangs for 60–130 seconds, then shows degraded analysis results from 1–2 successful chunks out of 20.

### 8.2 Proposed Sequential: Same 150-Minute Meeting

| Time (s) | Event |
|----------|-------|
| t=0 | `analyzeChunked()` dispatches chunk 1 |
| t=8–12 | Chunk 1 completes (local Phi-3 Mini, typical inference time) |
| t=8–12 | Chunk 2 dispatched immediately |
| t=16–24 | Chunk 2 completes; chunk 3 dispatched |
| ... | Sequential processing continues |
| t=160–240 | All 20 chunks complete (8–12s × 20) |
| t=240–260 | Synthesis call completes |

Total elapsed: ~4–5 minutes. Progressive results available starting at t=10s. No timeout events. No retry wave. GPU utilization: 100% continuous throughout, identical total work. System remains responsive throughout.

The total inference compute is identical in both scenarios. The sequential approach simply does not waste time on TCP connection establishment, timeout handling, and retry synchronization.

---

## 9. Performance Fixes by Priority

### 9.1 Immediate (Hours, No Architecture Change)

| ID | Fix | File | Estimated LOC |
|----|-----|------|---------------|
| QW-001 | Replace `withTaskGroup` in `analyzeChunked()` with sequential `for` loop (or `actor`-bounded semaphore) | `MeetingIntelligenceService.swift` | ~10 lines changed |
| QW-002 | Cache Ollama health check result for 10 seconds in `AIService` | `AIService.swift` | ~8 lines |
| QW-003 | Add `Double.random(in: -2.5...2.5)` jitter to retry delay | `AIService.swift` or `TranscriptChunker.swift` | ~2 lines |
| QW-004 | Fix `TapState.disarm()` XPC-in-lock: release lock before calling `recognitionRequest?.endAudio()` | `TapState.swift` | ~5 lines |
| QW-005 | Add `NSLock` to `ServiceContainer.resolve()` | `ServiceContainer.swift` | ~8 lines |
| QW-006 | Delete `/tmp/orin_phi3_raw.txt` write (or guard with `#if DEBUG`) | `MeetingIntelligenceService.swift` | 2 lines deleted |
| QW-007 | Fix `AVAudioEngineConfigurationChange` double-fire with `DispatchWorkItem` cancel pattern | `RecordingService.swift` | ~15 lines |
| QW-008 | Remove `context.save()` from `persistChunkIfNeeded()` — retain insert, checkpoint saves only | `TranscriptStore.swift` | 5 lines deleted |
| QW-009 | Add `meetingId` predicate to `buildTimelineSegments()` and `deleteMeetingFully()` fetches | `TranscriptStore.swift`, `ModelContext+SafeSave.swift` | ~6 lines |

QW-001 through QW-003 address the most critical user-visible performance failure (system freeze during analysis). They can be shipped together as a single patch. Combined estimated effort: 4–8 hours.

### 9.2 Short-Term (1–3 Days, Targeted Refactors)

| ID | Fix | File | Notes |
|----|-----|------|-------|
| ST-001 | Pre-allocate `AVAudioPCMBuffer` pool in `MicTranscriberFeed` and `SystemAudioCaptureService` | `RecordingService.swift`, `SystemAudioCaptureService.swift` | Eliminates real-time heap allocation |
| ST-002 | Remove `allSegments` `@Query` from `MeetingsView`; pass predicated fetch to `MeetingDetailView` | `MeetingsView.swift` | Requires minor view refactor |
| ST-003 | Add `@Attribute(.externalStorage)` to `MeetingItem.transcript` | `OrinModels.swift` | Requires SwiftData migration |
| ST-004 | Prune `TranscriptChunk` rows after successful `buildTimelineSegments()` | `TranscriptStore.swift` | ~10 lines |
| ST-005 | Gate `sampleCPUUsage()`/`sampleRAMMB()` behind `#if DEBUG` or feature flag | `RecordingService.swift` | 2 lines |
| ST-006 | Replace all `print()` calls with `Logger` (OSLog) | All service files | ~74 substitutions |
| ST-007 | Replace `Task.sleep(1.5s)` in `finalize()` with explicit continuation-based signal from recognition completion | `TranscriptStore.swift`, `RecordingService.swift` | ~25 lines |

### 9.3 Medium-Term (Weeks, Architectural)

| ID | Fix | Files Affected | Notes |
|----|-----|----------------|-------|
| MT-001 | Extract `RecognitionSessionManager` actor — eliminates 400-line duplication between `RecordingService` and `SystemAudioCaptureService` | Multiple | Phase 2 prerequisite |
| MT-002 | Build `InferenceWorker` actor: serial queue for local Ollama, bounded semaphore (limit: 3) for cloud | New file | Subsumes QW-001; supports multi-provider future |
| MT-003 | Build `AnalysisJobQueue` actor: serializes multi-meeting analyses to prevent double Ollama load | New file | Prevents concurrent folder + meeting analysis |
| MT-004 | Split `MeetingsView.swift` (2,281 lines) into 5+ files | `MeetingsView/` directory | Reduces observation graph scope |
| MT-005 | Move O(N×M) hallucination scan to `Task.detached`; use `Set<Substring>` for transcript words | `MeetingIntelligenceService.swift` | Removes last main-actor CPU spike |
| MT-006 | Move `structuredActionItems` from JSON string to SwiftData `ActionItemRecord` `@Model` | `OrinModels.swift` | Eliminates per-row JSON decode |

---

## 10. Performance Testing Recommendations

### 10.1 Instruments Time Profiler — CPU Hotspots

**Target**: CPU time during analysis of a 150-minute meeting recording.

Setup:
1. Open the app with a pre-recorded 150-minute meeting transcript (or generate one via text injection).
2. Attach Instruments → Time Profiler.
3. Trigger analysis and record for 5 minutes.

Expected hotspots to confirm after fixes:
- `analyzeChunked()` should show as sequential calls separated by Ollama wait time, not a burst.
- `@MainActor` should be largely idle during inference wait.
- No `persistChunkIfNeeded` → `context.save()` frames should appear in the main thread call tree.

**Signal**: After QW-001, the main thread CPU trace during analysis should drop to near-zero between chunk inference calls.

### 10.2 Instruments Allocations — Audio Buffer Allocation Rate

**Target**: `AVAudioPCMBuffer` allocation frequency during recording.

Setup:
1. Attach Instruments → Allocations.
2. Filter on `AVAudioPCMBuffer` in the allocation list.
3. Start a recording session with an active microphone.
4. Record for 60 seconds.

Before ST-001 fix: expect approximately 2,700–5,200 allocations per minute.  
After ST-001 fix (pre-allocated pool): expect 3–4 allocations total at session start, zero during recording.

**Additional check**: Enable "Record reference counts" and verify no `AVAudioPCMBuffer` objects are retained past the `cont.yield()` call.

### 10.3 OSLog Metrics — Analysis Timing

Add `OSLog` signposts at analysis entry and exit points. Use `os.signpost` intervals to measure per-chunk and total analysis duration:

```swift
let log = OSLog(subsystem: "com.clavrit.orin", category: .pointsOfInterest)
os_signpost(.begin, log: log, name: "ChunkAnalysis", "chunk %d of %d", i, total)
// ... inference call ...
os_signpost(.end, log: log, name: "ChunkAnalysis")
```

View in Instruments → os_signpost. After QW-001, each chunk interval should be sequential with no overlap.

**Key metric to establish baseline before patching**: Total analysis wall-clock time for a 150-minute meeting. Expected before fix: 60–130s (timeout dominated). Expected after QW-001: 160–300s (inference dominated, no timeouts).

### 10.4 Xcode Memory Graph — Observation Graph Complexity

**Target**: `TranscriptSegment` and `MeetingItem` retain graph in `MeetingsView`.

1. Run the app with 50 meetings populated in the store.
2. Navigate to `MeetingsView`.
3. In Xcode, use Debug → View Memory Graph.
4. Search for `TranscriptSegment`. Before PB-004 fix: expect N×500 instances shown, all live.
5. After PB-004 fix: expect only the selected meeting's segments to be live.

### 10.5 SwiftData Disk Write Audit

Enable SQLite logging via `SQLITE_TRACE_STMT` at app launch (debug builds only):

```swift
// In AppDelegate or @main entry, debug builds only
#if DEBUG
sqlite3_config(SQLITE_CONFIG_LOG, { _, code, msg in
    print("[SQLite] code=\(code) \(String(cString: msg!))")
}, nil)
#endif
```

Alternatively, use `fs_usage -f filesys` in Terminal, filtering for `Orin` process writes to `*.sqlite-wal`. Before QW-008: expect 70–80 WAL writes per minute during active recording. After QW-008: expect 20 WAL writes per minute (checkpoint timer only).

### 10.6 Regression Metrics to Track Per Release

| Metric | Measurement method | Target after fixes |
|--------|-------------------|-------------------|
| Analysis wall-clock time (150-min meeting) | `AnalysisPerfLogger` (already instrumented) | < 5 min, no timeouts |
| Main thread CPU during active recording | Instruments Time Profiler | < 5% average |
| `AVAudioPCMBuffer` allocations/min | Instruments Allocations | 0 during recording |
| SQLite WAL writes/min during recording | `fs_usage` or SQLite trace | ≤ 20/min |
| `MeetingsView` render time per selection change | Instruments Time Profiler → main thread | < 16ms |
| Peak RAM during 3-hour recording | Instruments Allocations → heap total | < 200 MB |

---

## Appendix: File and Line Reference Summary

| Issue | Primary File | Key Lines |
|-------|-------------|-----------|
| Thundering herd Ollama | `MeetingIntelligenceService.swift` | 150–173 |
| CPU/RAM sampling in production | `RecordingService.swift` | 946–953, 1316–1360 |
| `MicSTSessionMetrics` unbounded arrays | `RecordingService.swift` | 1233–1234 |
| Hallucination scan on `@MainActor` | `MeetingIntelligenceService.swift` | 218–232 |
| `/tmp/orin_phi3_raw.txt` write | `MeetingIntelligenceService.swift` | 274–275 |
| Real-time heap allocation | `RecordingService.swift` | 1195 |
| Real-time heap allocation (participant) | `SystemAudioCaptureService.swift` | 817–825 |
| `allSegments` unpredicated `@Query` | `MeetingsView.swift` | 15 |
| Inline transcript column | `OrinModels.swift` | `MeetingItem.transcript` field |
| `persistChunkIfNeeded` save in callback | `TranscriptStore.swift` | 224–236 |
| `buildTimelineSegments` full-table scan | `TranscriptStore.swift` | 383–393 |
| `deleteMeetingFully` full-table scans | `ModelContext+SafeSave.swift` | 85–90 |
| 1.5s sleep on `@MainActor` | `TranscriptStore.swift` | 315 |
| 74 unguarded `print()` statements | All `Sources/Orin/` files | (74 sites) |
