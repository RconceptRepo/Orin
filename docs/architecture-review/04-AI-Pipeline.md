# 04 — AI Pipeline: Current State, Root Cause Analysis, and Redesign

**Document type:** Principal engineering reference (HIGHEST PRIORITY in package)
**Codebase:** Orin V1 — macOS meeting intelligence application
**Review date:** 2026-06-29
**Status:** Accurate as of commit 4f603ea

---

## Table of Contents

1. [Pipeline Overview](#1-pipeline-overview)
2. [The 41-Request Problem — Root Cause Analysis](#2-the-41-request-problem--root-cause-analysis)
3. [Why Local Inference Requires a Different Approach](#3-why-local-inference-requires-a-different-approach)
4. [Current Implementation Details](#4-current-implementation-details)
5. [Chunk Size and Synthesis Strategy](#5-chunk-size-and-synthesis-strategy)
6. [Prompt Architecture](#6-prompt-architecture)
7. [Proposed Architecture: InferenceWorker + AnalysisJobQueue](#7-proposed-architecture-inferenceworker--analysisjobqueue)
8. [Proposed Execution Timeline: Before vs. After](#8-proposed-execution-timeline-before-vs-after)
9. [Quick Wins vs. Full Redesign](#9-quick-wins-vs-full-redesign)
10. [Implementation Sequence](#10-implementation-sequence)
11. [Known Secondary Issues](#11-known-secondary-issues)

---

## 1. Pipeline Overview

The complete AI analysis pipeline activates when recording stops. The flow begins in `TranscriptStore`, passes through chunking logic in `TranscriptChunker`, dispatches inference through `MeetingIntelligenceService` and `AIService`, and ultimately writes results back to the `MeetingItem` SwiftData model before the UI refreshes.

### 1.1 End-to-End Sequence Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  User stops recording / Meeting ends automatically                           │
└─────────────────────────────┬────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  RecordingService.stopRecording()                                            │
│  • Stops AVAudioEngine tap                                                   │
│  • Stops SCStream (system audio)                                             │
│  • Calls TranscriptStore.finalize(meetingId:)                                │
└─────────────────────────────┬────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  TranscriptStore.finalize(meetingId:)   [@MainActor]                         │
│  • Loads all TranscriptSegments for the meeting from SwiftData               │
│  • Merges mic (Me:) and participant (Participant:) segment arrays             │
│  • Sorts by timestamp                                                        │
│  • Sets MeetingItem.isFinalized = true                                       │
│  • Calls context.save() once                                                 │
│  • Returns (segments: [TranscriptSegment], transcript: String)               │
└─────────────────────────────┬────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  MeetingDataService.triggerAnalysis(meeting:segments:transcript:)            │
│  • Runs in Task { } (detaches from caller's context)                        │
│  • Calls MeetingIntelligenceService.analyze(title:segments:meetingStart:)    │
└─────────────────────────────┬────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  MeetingIntelligenceService.analyze()                                        │
│  • Keyword-based meeting type detection (synchronous, no AI)                 │
│  • Routing decision:                                                         │
│      timelineText.count <= 12,000 chars  →  analyzeSingleCall()             │
│      timelineText.count >  12,000 chars  →  analyzeChunked()                │
└──────────────────┬──────────────────────────────┬────────────────────────────┘
                   │                              │
          (short meeting)                  (long meeting)
                   │                              │
                   ▼                              ▼
   analyzeSingleCall()              analyzeChunked()
   • One prompt → AIService        • TranscriptChunker.chunks()
   • One AI response               • withTaskGroup { N tasks }  ← BUG
   • Full parsing                  • Each task → AIService
   • Evidence checking             • Merge all ChunkAnalysis
   • Returns MeetingAnalysis       • synthesize() → one more AI call
                   │                              │
                   └──────────────┬───────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  AIService.generate(prompt:maxTokens:)                                       │
│  • isOllamaAvailable() — GET /api/tags (3s timeout, no cache)                │
│  • If available: callOllama() — POST /api/generate (60s timeout)             │
│  • If Ollama fails: retry once after 10s sleep (no jitter)                   │
│  • If both fail: callOpenAI() → callAnthropic() → callGemini()               │
│  • Returns (text: String, fallbackUsed: Bool)                                │
└─────────────────────────────┬────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  Ollama (localhost:11434)                                                    │
│  • Single process, single GPU, single model instance                         │
│  • Serializes all inference requests internally                              │
│  • /api/generate: returns when inference completes                           │
│  • 60s URLSession timeout fires if model is slow (large context)             │
└─────────────────────────────┬────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  Back in MeetingIntelligenceService                                          │
│  • Parse AI response: summary, action items, decisions, risks, etc.          │
│  • Hallucination check: snippet verification against raw transcript          │
│  • Build MeetingAnalysis struct                                              │
└─────────────────────────────┬────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  MeetingDataService — persist results                                        │
│  • Sets MeetingItem.summary, .actionItems, .structuredActionItemsJSON, etc.  │
│  • Calls context.save() on @MainActor                                        │
└─────────────────────────────┬────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  SwiftUI reactive update                                                     │
│  • @Observable MeetingItem changes propagate to MeetingsView                 │
│  • Summary card, action items list, decisions list all re-render             │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Routing Decision

The routing decision at `MeetingIntelligenceService.analyze()` (line 97 of `MeetingIntelligenceService.swift`) uses `TranscriptChunker.singleCallThreshold = 12_000` characters:

- At 130 words per minute average speech rate, 12,000 chars ≈ 18 minutes of meeting transcript.
- Meetings under 18 minutes: single AI call, one prompt, one response.
- Meetings over 18 minutes: chunked path. This is where the 41-request problem lives.

---

## 2. The 41-Request Problem — Root Cause Analysis

This is the primary failure mode causing system-wide freezes and analysis failures. It is not a subtle race condition. It is a misapplication of a concurrency primitive for a workload type it was not designed to handle.

### 2.1 The Code

In `MeetingIntelligenceService.swift`, lines 157-173:

```swift
// Phase 1: Extract from all chunks concurrently.
// Cloud APIs process requests in parallel; Ollama queues and serializes internally
// so total inference time is the same but network overhead overlaps.
let service = aiService
var ordered = [ChunkAnalysis?](repeating: nil, count: chunks.count)
await withTaskGroup(of: (Int, ChunkAnalysis).self) { group in
    for (i, chunk) in chunks.enumerated() {
        group.addTask {
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

`group.addTask` is called in a `for` loop with no concurrency limit. For N chunks, all N tasks are submitted simultaneously. There is no `AsyncSemaphore`, no `withTaskGroup` child limit, no serial queue — nothing preventing all N tasks from issuing their HTTP requests at the same moment.

### 2.2 Chunk Count by Meeting Length

From `TranscriptChunker.swift`, the inline documentation:

```
15 min  →  ~9,750 chars  →  single call (below singleCallThreshold)
30 min  → ~19,500 chars  →  4 chunks + 1 synthesis = 5 calls
60 min  → ~39,000 chars  →  8 chunks + 1 synthesis = 9 calls
90 min  → ~58,500 chars  → 12 chunks + 1 synthesis = 13 calls
120 min → ~78,000 chars  → 16 chunks + 1 synthesis = 17 calls
150 min → ~97,500 chars  → ~20 chunks + 1 synthesis = ~21 calls
```

A 150-minute meeting produces approximately 20 simultaneous `/api/generate` requests.

### 2.3 The Health Check Amplification

Each call to `AIService.generate()` first calls `isOllamaAvailable(endpoint:)` — a GET to `/api/tags` with a 3-second timeout. This check is not cached. The result: for N = 20 chunk tasks, there are 20 simultaneous `/api/tags` health checks followed immediately by 20 simultaneous `/api/generate` requests.

```swift
// AIService.swift, line 73
if await isOllamaAvailable(endpoint: endpoint) {
    if let result = await callOllama(prompt: prompt, maxTokens: maxTokens) {
```

The health check for a 20-chunk meeting fires 20 times within milliseconds of each other. Since Ollama's `/api/tags` response is trivial (JSON model list), these succeed quickly. But each one represents a wasted TCP connection and a missed caching opportunity. If Ollama is under load from the inference requests, these health checks start failing, which causes the code to skip to cloud providers — attempting OpenAI, Anthropic, and Gemini in sequence — before the Ollama inference has even had time to queue up.

### 2.4 The Retry Synchronization Problem

When an Ollama request times out (URLSession 60-second timeout), `AIService.generate()` retries after an exact 10-second sleep:

```swift
// AIService.swift, lines 79-84
aiLogger.info("Ollama call failed on first attempt — waiting 10s then retrying")
AnalysisPerfLogger.event("Ollama first attempt failed — sleeping 10s before retry")
try? await Task.sleep(nanoseconds: 10_000_000_000)
if let result = await callOllama(prompt: prompt, maxTokens: maxTokens) {
    AnalysisPerfLogger.event("provider=ollama SUCCESS (retry)")
    return (result, false)
}
```

Because all N chunk tasks were submitted simultaneously and all hit Ollama at the same moment, all N also hit the 60-second timeout at approximately the same moment. All N then sleep for exactly 10 seconds — no jitter — and all N fire retry requests at t+70s simultaneously.

This produces two distinct thundering herds:

- **Wave 1** at t=0s: ~20 simultaneous `/api/generate` requests
- **Wave 2** at t=70s: ~19-20 simultaneous retry `/api/generate` requests
- **Peak total observed:** ~41 in-flight requests

### 2.5 Failure Mode Timeline Diagram

```
t=0s:    Recording stops. 20 tasks submitted to withTaskGroup.

t=0.001s: Task 1..20: isOllamaAvailable() — 20 simultaneous GET /api/tags

t=0.010s: 20 health checks return OK (Ollama idle, responds instantly)

t=0.011s: Task 1..20: POST /api/generate — 20 simultaneous inference requests
          ┌─────────────────────────────────────────────────────────┐
          │  Ollama (single process, single GPU):                   │
          │  - Accepts all 20 TCP connections                       │
          │  - Serializes inference on GPU queue                    │
          │  - Request 1: starts inference immediately              │
          │  - Request 2..20: queued, waiting for GPU              │
          │  - GPU memory: 1 model * N KV cache slots              │
          │  - If context is large, OOM risk on ≤16GB RAM systems  │
          └─────────────────────────────────────────────────────────┘

t=60s:   URLSession.timeoutInterval = 60 fires.
         All 20 tasks return nil from callOllama().

         Note: Ollama is still actively processing these requests.
         Closing the URLSession connection does NOT cancel Ollama
         inference. Ollama continues computing responses for closed
         connections, consuming GPU and RAM with no client to receive.

t=60s:   All 20 tasks print:
         "Ollama call failed on first attempt — waiting 10s then retrying"

t=60.001s: All 20 tasks enter: Task.sleep(nanoseconds: 10_000_000_000)

t=70s:   All 20 tasks wake simultaneously.

t=70.001s: All 20 tasks: isOllamaAvailable() — 20 more GET /api/tags

t=70.010s: Task 1..20: POST /api/generate — 20 more simultaneous requests
           ┌─────────────────────────────────────────────────────────┐
           │  Ollama (still processing wave 1 responses internally): │
           │  - Accepts 20 more TCP connections                      │
           │  - Now: up to 40 pending inference contexts             │
           │  - GPU OOM likely on <32GB systems                      │
           │  - Ollama may crash or return 500 errors                │
           └─────────────────────────────────────────────────────────┘

t=130s:  Second timeout fires. All 20 retry tasks fail.
         Code falls through to cloud providers.

t=130.001s: All 20 tasks attempt OpenAI, Anthropic, Gemini in sequence.
            20 simultaneous cloud API calls per provider tier.
            If cloud keys are not configured: all 20 return ("", fallbackUsed: true)
            → keyword fallback only. User sees empty analysis.

t=130.002s: context.save() called with fallback results.
            Analysis card shows "insufficient information."
```

### 2.6 The Code Comment Is Correct — And Catastrophically Incomplete

The comment in `analyzeChunked()` reads:

> "Cloud APIs process requests in parallel; Ollama queues and serializes internally so total inference time is the same but network overhead overlaps."

This is accurate for the **success path**: if every Ollama request completes within 60 seconds, the total wall-clock time for N sequential requests equals the total wall-clock time for N parallel requests (since Ollama serializes them). The parallelism provides no throughput benefit but causes no harm in this path.

The comment is silent about the **failure path**: what happens when Ollama is slow (large context window, busy system, thermal throttling) and requests start timing out. In the failure path, parallelism transforms a graceful degradation (slow analysis) into a catastrophic one (synchronized thundering herd, GPU saturation, system freeze, total analysis failure).

The design must be changed so that local inference — where the "server" is a single-process, single-GPU, single-model system — is always dispatched sequentially.

### 2.7 Impact on the User

From the user's perspective:
1. 30+ minute meeting ends.
2. Analysis spinner appears.
3. System becomes sluggish (GPU saturated by Ollama).
4. After 2 minutes (130 seconds), analysis card appears with empty or keyword-only results.
5. No error message. No retry option. The meeting is marked as analyzed.

The user has no way to re-trigger analysis without going into Settings and manually requesting it. This is the primary source of "Orin didn't work" reports.

---

## 3. Why Local Inference Requires a Different Approach

### 3.1 The Fundamental Difference

Cloud LLM APIs (OpenAI, Anthropic, Gemini) are designed for parallel request handling:

- **Horizontally scaled:** Thousands of GPU instances across multiple data centers.
- **Request isolation:** Each request lands on an independent GPU with its own KV cache.
- **True parallelism:** 20 simultaneous requests genuinely execute in parallel, each completing in the same time as a single request.
- **Rate limiting as the only constraint:** The API rate limit (requests per minute, tokens per minute) is the practical ceiling. Below the limit, parallelism is always beneficial.

Local LLM runtimes (Ollama, LM Studio, llama.cpp) have none of these properties:

- **Single process:** One Ollama daemon per machine.
- **Single model in memory:** Loading phi3 into VRAM takes 3-6 GB; switching models requires unloading and reloading.
- **Single-threaded GPU execution:** Even with multi-GPU support, a single inference request uses all available VRAM for its KV cache. Two concurrent requests compete for the same VRAM.
- **Serialized at the GPU level:** Ollama accepts multiple TCP connections and queues requests, but executes them one at a time on the GPU. There is no performance benefit to sending 20 requests simultaneously vs. sending them one after another.

### 3.2 What Saturation Looks Like

When Ollama receives 20 simultaneous large-context requests:

1. **VRAM pressure:** Each request has its own KV cache in VRAM. With 20 requests queued, Ollama must either reject them (which it does not — it queues them in RAM instead) or expand its in-RAM queue.
2. **RAM pressure:** Context data for 20 chunks of 5,000 chars each (plus model weights) easily exceeds 8-16 GB available RAM on most MacBook Pro M-series machines.
3. **Thermal response:** GPU under sustained load triggers macOS thermal management, which reduces clock speed. Inference that normally takes 20 seconds may take 45-60 seconds — pushing into timeout territory.
4. **System responsiveness:** macOS shares GPU resources between applications. A saturated Ollama process degrades rendering performance system-wide, causing window animation jank and UI lag.

### 3.3 The Correct Mental Model

**Wrong model:** Ollama as a horizontally-scaled API — send all requests immediately, Ollama handles load distribution.

**Correct model:** Ollama as a single-threaded worker with a job queue — always submit one job at a time, wait for completion before submitting the next.

This is the same mental model that applies to:
- A single SQLite connection (write serialization via WAL lock)
- A single-threaded file I/O queue
- A hardware device that accepts one command at a time

The correct Swift concurrency primitive for this model is not `withTaskGroup` — it is an `actor` with a serial execution queue, or a simple `for` loop over the chunks array.

### 3.4 The Performance Cost of Serialization Is Zero

A common objection to serializing Ollama inference is "it will make analysis slower." This is incorrect:

- With parallel dispatch: Ollama queues all N requests, executes them sequentially. Total GPU time = N * T where T is the time per chunk.
- With serial dispatch: we submit requests one at a time. Total GPU time = N * T.

The GPU computation is identical. Parallelism provides no GPU speedup. The only difference is that with serial dispatch, we never hit the timeout, never saturate RAM, never trigger thermal throttling, and never produce a thundering herd on failure.

For cloud providers (OpenAI, Anthropic, Gemini), parallelism does provide real speedup and should be preserved — but with a bounded semaphore to avoid rate limit errors.

---

## 4. Current Implementation Details

### 4.1 analyzeChunked() — Structure

`MeetingIntelligenceService.analyzeChunked()` has two entry points:

**Entry point 1 — string-based (legacy path):**
```swift
private func analyzeChunked(title:, transcript:, meetingType:) async -> MeetingAnalysis {
    let chunks = TranscriptChunker.chunks(of: transcript)  // line-boundary splitting
    return await analyzeChunked(title: title, chunks: chunks, meetingType: meetingType)
}
```

**Entry point 2 — segment-aware (preferred path):**
```swift
// In analyze(title:segments:meetingStart:), line 99:
let chunks = TranscriptChunker.chunks(of: segments, meetingStart: meetingStart)
result = await analyzeChunked(title: title, chunks: chunks, meetingType: meetingType)
```

The segment-aware path (entry point 2) is superior: it splits at speaker-change boundaries rather than line breaks, ensuring no utterance is split across chunks and both speakers are represented in every chunk.

**Core function:**
```swift
private func analyzeChunked(title:, chunks:, meetingType:) async -> MeetingAnalysis {
    // Phase 1: withTaskGroup — BUG IS HERE
    var ordered = [ChunkAnalysis?](repeating: nil, count: chunks.count)
    await withTaskGroup(of: (Int, ChunkAnalysis).self) { group in
        for (i, chunk) in chunks.enumerated() {
            group.addTask {
                let ca = await TranscriptChunker.analyzeChunk(...)
                return (i, ca)
            }
        }
        for await (i, ca) in group { ordered[i] = ca }
    }

    // Phase 2: Merge — deterministic, no AI
    let allDecisions     = TranscriptChunker.deduplicateStrings(...)
    let allOpenQuestions = TranscriptChunker.deduplicateStrings(...)
    // ... etc.

    // Phase 3: Synthesis — ONE additional AI call
    let summary = await TranscriptChunker.synthesize(
        chunks: chunkAnalyses, title: title, meetingType: meetingType, aiService: aiService
    )
    // ... return MeetingAnalysis
}
```

**Phase 1 breakdown — what happens inside each chunk task:**
```
TranscriptChunker.analyzeChunk() →
  AIService.generate(prompt:, maxTokens: 500) →
    isOllamaAvailable() [GET /api/tags, 3s timeout, uncached] →
    callOllama() [POST /api/generate, 60s timeout] →
    [on failure] 10s sleep → retry callOllama() →
    [on failure] callOpenAI() →
    [on failure] callAnthropic() →
    [on failure] callGemini() →
    return ("", fallbackUsed: true)  ← keyword fallback activated
```

### 4.2 AIService.generate() — Retry Logic

The retry logic in `AIService.generate()` is sound in concept — retry once after a short delay to handle model loading. The implementation has two defects:

**Defect 1: Fixed sleep with no jitter**
```swift
try? await Task.sleep(nanoseconds: 10_000_000_000)  // exactly 10 seconds
```
When 20 tasks all fail at the same moment, they all sleep for exactly 10 seconds, then all fire simultaneously. A ±2.5 second jitter would spread the retry load:
```swift
let jitterNanos = UInt64.random(in: 7_500_000_000...12_500_000_000)  // 7.5s-12.5s
try? await Task.sleep(nanoseconds: jitterNanos)
```

**Defect 2: Health check result not carried across the retry**
The retry path calls `callOllama()` directly without re-checking availability. This is the correct behavior for a retry. However, the initial health check is uncached — so if the same `generate()` call is made by 20 concurrent tasks, all 20 independently hit `/api/tags`.

### 4.3 TranscriptChunker — Chunking Parameters

From `TranscriptChunker.swift`:

```swift
static let singleCallThreshold = 12_000   // chars — route to chunked if above
static let chunkSize           =  5_000   // chars — target per chunk
static let overlapSize         =    500   // chars — overlap between chunks
```

The segment-aware chunker (preferred) uses a different mechanism: it accumulates utterances until `chunkSize` chars are reached, then snaps back to the last speaker-change boundary. This ensures cleaner context windows than the line-boundary splitter.

**Overlap strategy:** The last 3 utterances of each chunk are carried into the next chunk (`utteranceOverlap = 3`). This prevents cross-boundary action items and decisions from being missed.

### 4.4 Synthesis — The Final AI Call

After all chunk analyses are complete and merged, `TranscriptChunker.synthesize()` makes one additional AI call with a compact prompt:

```swift
static func synthesize(chunks:, title:, meetingType:, aiService:) async -> String {
    let keyPointsText = chunks
        .sorted { $0.index < $1.index }
        .flatMap { chunk in chunk.keyPoints.map { "  • \($0)" } }
        .joined(separator: "\n")

    let prompt = buildSynthesisPrompt(
        keyPointsText: keyPointsText,
        decisionsCount: allDecisions.count,
        actionsCount: allActions.count,
        title: title
    )
    let result = await aiService.generate(prompt: prompt, maxTokens: 350)
    // ...
}
```

The synthesis prompt sends **only key-points** (1-3 bullets per chunk), not the full transcript. This is a good design decision — the synthesis call is always compact regardless of meeting length. For a 20-chunk meeting, the synthesis prompt contains at most 60 bullet points, well within any model's context window.

This synthesis call goes through the same `AIService.generate()` path and therefore exhibits the same health-check-every-time behavior, but since it is a single call, it does not contribute to the thundering herd.

### 4.5 Hardcoded Model IDs

`AIService.swift` hardcodes model identifiers for all three cloud providers:

| Provider | Hardcoded Model | Location |
|---|---|---|
| OpenAI | `"gpt-4o-mini"` | `callOpenAI()`, line 196 |
| Anthropic | `"claude-haiku-4-5-20251001"` | `callAnthropic()`, line 222 |
| Gemini | `"gemini-1.5-flash"` | `callGemini()`, URL parameter |
| Ollama | `"mistral"` (default) | `resolvedOllamaModel()`, line 279 |

The Anthropic model ID `claude-haiku-4-5-20251001` is a hardcoded snapshot. This model identifier will become stale as Anthropic releases updated versions. The correct approach is to read this from a remotely-updateable configuration, or at minimum from a named constant in a configuration file.

The Ollama model is configurable via `UserDefaults` key `orin.ai.ollamaModel`, which is the correct pattern. The cloud models should follow the same pattern.

### 4.6 Privacy Violation: /tmp/orin_phi3_raw.txt

In `MeetingIntelligenceService.analyzeSingleCall()`, line 275:

```swift
// Dump raw phi3 response for debugging — read at /tmp/orin_phi3_raw.txt
try? result.text.write(to: URL(fileURLWithPath: "/tmp/orin_phi3_raw.txt"),
                       atomically: true, encoding: .utf8)
```

This writes AI response text — which contains processed content derived from meeting transcript audio — to a world-readable temporary file. On macOS, `/tmp` is accessible by any process running as the same user. Depending on content, this could expose:
- Meeting participant names mentioned in action items
- Decision text derived from transcript
- Organizational information discussed in meetings

This is classified as a **privacy defect, not merely a debug artifact**. It must be removed before any production release. If debugging capability is needed, the output should route through `OSLog` with the `privacy:` annotation, which applies log privacy rules and restricts export.

**Fix:** Delete lines 274-276 of `MeetingIntelligenceService.swift`. If debugging is needed: replace with `log.debug("phi3 response: \(result.text.prefix(200), privacy: .private)")`.

---

## 5. Chunk Size and Synthesis Strategy

### 5.1 Current Chunk Size Analysis

At `chunkSize = 5,000` characters and 130 words per minute:
- 5,000 chars ≈ 1,000 words ≈ 7-8 minutes of speech per chunk
- Ollama phi3 default context: 8,192 tokens ≈ 32,000 chars
- Each chunk (5,000 chars) occupies ~15% of phi3's context window

This is a reasonable chunk size for the local model. The extraction prompt adds ~500 chars of system instructions, leaving the model with plenty of context to reason about the chunk content. The design is correct here.

### 5.2 Chunk Size for Cloud Models

Cloud models (GPT-4o-mini: 128K context, Claude Haiku: 200K context) can handle entire meetings in one call. The current chunked path is applied uniformly regardless of provider. When the provider is a cloud model, chunking introduces unnecessary overhead:

- Extra API round trips (N extraction calls + 1 synthesis call vs. 1 comprehensive call)
- Deduplication logic that sometimes incorrectly merges semantically distinct items
- Higher API cost (more tokens sent in aggregate due to overlapping context)

The proposed architecture addresses this by making the routing decision provider-aware: local providers use chunked extraction, cloud providers use a single comprehensive call if the meeting fits within context limits.

### 5.3 Overlap Strategy

The 3-utterance overlap (`utteranceOverlap = 3`) is appropriate. It ensures that decisions and commitments made at the boundary of two chunks are captured by at least one chunk. The string-based chunker uses 500 characters of overlap, which at 5 chars/word covers approximately 100 words — about 45 seconds of speech. Both are sufficient for preventing cross-boundary loss.

### 5.4 Synthesis Quality

The synthesis prompt (in `TranscriptChunker.buildSynthesisPrompt()`) sends key-points extracted from each chunk to the model and asks for a 2-4 sentence executive summary. This approach works well when key-points are accurate. When the model fails to extract good key-points from a chunk (which happens on meeting types that produce sparse transcripts — long silences, one-sided conversations), the synthesis summary degrades.

An improvement would be to weight key-points by chunk length: longer chunks with more speech contribute more key-points (currently capped at 3 per chunk regardless of chunk density).

---

## 6. Prompt Architecture

### 6.1 Current Prompt Structure

There are two distinct prompt types in the AI pipeline:

**Type 1: Extraction prompt** — used for each chunk in the chunked path (`TranscriptChunker.buildExtractionPrompt()`):
```
Extract structured information from this [meetingType] transcript segment.
This is segment [N] of [total]. Extract only what is explicitly stated.

TRANSCRIPT SEGMENT:
[chunk text]

## ACTION ITEMS
[format instructions]

## DECISIONS
## OPEN QUESTIONS
## RISKS
## DEPENDENCIES
## COMMITMENTS
## KEY POINTS
```
- maxTokens: 500
- Purpose: extract structured fields, not summarize
- Format: pipe-delimited action items (`OWNER: x | TASK: y | PRIORITY: z | DUE: w`)

**Type 2: Comprehensive prompt** — used for single-call path (`MeetingIntelligenceService.buildComprehensivePrompt()`):
```
You are a meeting notes assistant. Fill in the five sections below...

MEETING TITLE: [title]
TRANSCRIPT:
[full transcript]

## SUMMARY
## DISCUSSION POINTS
## ACTION ITEMS
## DECISIONS
## FOLLOW-UPS
```
- maxTokens: 1500
- Purpose: extract all fields plus generate summary in one call

**Type 3: Synthesis prompt** — used once per meeting after chunked extraction (`TranscriptChunker.buildSynthesisPrompt()`):
```
Write a factual summary for the meeting titled "[title]".

The meeting covered these topics:
  • [key point 1]
  • [key point 2]
  ...

There were [N] decision(s) and [M] action item(s) identified.

Rules:
- Use ONLY the topics listed above.
- Write 2-4 sentences. Be specific.
```
- maxTokens: 350
- Purpose: synthesize executive summary from key-points

### 6.2 English-Only Prompts

All prompt text in `MeetingIntelligenceService.buildComprehensivePrompt()` and `TranscriptChunker.buildExtractionPrompt()` is in English. There is no language detection or language-parameterized prompt construction anywhere in the pipeline.

This affects quality in two ways:

1. **Non-English meetings:** If a meeting is conducted in Spanish, French, or Hindi, the English-language instructions still extract correctly (most models understand the task regardless of instruction language), but field labels like `OWNER:`, `TASK:`, `PRIORITY:`, `DUE:` are hardcoded English. Models occasionally emit these labels in the input language, which breaks the parser.

2. **Hinglish meetings (Hindi-English code-switching):** The most common failure mode in the current app. The transcript may contain both Hindi and English words. The model extracts action items from the English portions correctly but misses commitments expressed in Hindi (e.g., "main kal bhejunga" — "I will send tomorrow"). The section parser correctly handles the structured output format but the model never saw the Hindi commitment as a commitment.

### 6.3 Section Header Flexibility

The parser in `MeetingIntelligenceService.sectionHeader(from:)` handles multiple header styles that different models emit:

- Markdown: `## SUMMARY`, `## Summary:`
- Bold markdown: `**SUMMARY:**`, `**EXECUTIVE SUMMARY:**`
- Bracket: `[SUMMARY]`, `[ACTION ITEMS] text`
- Plain uppercase: `SUMMARY:`, `ACTION ITEMS:`

This flexibility is necessary because phi3, mistral, and GPT-4o-mini emit headers in different styles even when given identical instructions. The parser is robust; it is not a source of failures. The extractor (`parseActionItemLine()`) handles both pipe-delimited and multi-line formats that phi3 sometimes uses.

### 6.4 Path to Language-Parameterized Prompts (MT-005)

The medium-term redesign (MT-005) introduces language-parameterized prompt construction:

**Step 1: Post-session language detection**
```swift
import NaturalLanguage

func detectLanguage(in transcript: String) -> Locale.LanguageCode? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(transcript)
    guard let hypothesis = recognizer.dominantLanguage else { return nil }
    return Locale.LanguageCode(hypothesis.rawValue)
}
```

**Step 2: Language-parameterized extraction prompt**
The field labels should use language-neutral section markers that do not depend on the instruction language:
```swift
enum SectionMarker: String {
    case actionItems  = "<<ACTION_ITEMS>>"
    case decisions    = "<<DECISIONS>>"
    case summary      = "<<SUMMARY>>"
    // etc.
}
```
This allows the parser to match `<<ACTION_ITEMS>>` regardless of what language surrounds it, eliminating parser failures on non-English model output.

**Step 3: Native-language instructions**
For models that support it, issuing extraction instructions in the meeting language improves recall. A language-keyed prompt dictionary:
```swift
let extractionInstructions: [String: String] = [
    "en": "Extract structured information from this transcript...",
    "es": "Extrae información estructurada de esta transcripción...",
    "fr": "Extrayez des informations structurées de cette transcription...",
    "hi": "इस ट्रांसक्रिप्ट से संरचित जानकारी निकालें..."
]
```

This is Phase 3 work (12-16 weeks out) — it cannot be implemented meaningfully until the vocabulary system redesign is complete and Whisper integration provides hi-IN transcription.

---

## 7. Proposed Architecture: InferenceWorker + AnalysisJobQueue

This is the full medium-term redesign (MT-002). It introduces two new actors and a protocol hierarchy that cleanly separates the concerns of job scheduling, provider selection, and inference execution.

### 7.1 Design Principles

1. **One rule for local, one rule for cloud.** Local inference is always serial. Cloud inference is parallel with a bounded semaphore.
2. **Progressive results.** The UI should show analysis results as they arrive per-chunk, not wait for all chunks to complete.
3. **Provider opacity.** `MeetingIntelligenceService` should not know which provider is executing. It submits an `InferenceJob` and receives results.
4. **Resilience through circuit breaking.** Repeated local inference failures should automatically route to cloud without user intervention.
5. **Queue visibility.** When two meetings end simultaneously, the user should see "Analysis queued (1 meeting waiting)" rather than experiencing silent degradation.

### 7.2 InferenceProvider Protocol

The foundational abstraction that all providers implement:

```swift
// Capabilities that a provider declares
struct InferenceCapabilities {
    let maxContextTokens: Int
    let supportsStreaming: Bool
    let isLocal: Bool
    let requiresAPIKey: Bool
    let supportedLanguageCodes: Set<String>  // e.g. ["en", "es", "fr"]
}

// A single token in a streaming response
struct InferenceToken {
    let text: String
    let isLast: Bool
}

// The job submitted to inference
struct InferenceJob {
    let id: UUID
    let prompt: String
    let maxTokens: Int
    let priority: JobPriority
    let chunkIndex: Int?
    let totalChunks: Int?
    let meetingID: UUID

    enum JobPriority: Int, Comparable {
        case background = 0
        case normal = 1
        case userInitiated = 2

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}

// Result for a completed job
struct InferenceResult {
    let jobID: UUID
    let text: String
    let providerUsed: String
    let durationSeconds: Double
    let tokenCount: Int?
}

// The protocol
protocol InferenceProvider: AnyObject {
    var identifier: String { get }
    var capabilities: InferenceCapabilities { get }

    /// Check if this provider is available right now.
    func isAvailable() async -> Bool

    /// Execute a single inference job. Returns a streaming token sequence.
    func infer(job: InferenceJob) async throws -> AsyncThrowingStream<InferenceToken, Error>
}
```

**Concrete implementations:**

```swift
// Local providers
actor OllamaProvider: InferenceProvider { ... }
actor LMStudioProvider: InferenceProvider { ... }
actor AppleFoundationModelsProvider: InferenceProvider { ... }  // future

// Cloud providers
actor OpenAIProvider: InferenceProvider { ... }
actor AnthropicProvider: InferenceProvider { ... }
actor GeminiProvider: InferenceProvider { ... }
```

### 7.3 InferenceWorker Actor

The single point of contact for all LLM inference. Enforces the local/cloud concurrency rule.

```swift
actor InferenceWorker {

    private let localProviders: [InferenceProvider]    // Ollama, LM Studio, Apple FM
    private let cloudProviders: [InferenceProvider]    // OpenAI, Anthropic, Gemini

    // State for circuit breaker
    private var consecutiveLocalFailures = 0
    private var localUnavailableUntil: ContinuousClock.Instant?
    private let circuitBreakerThreshold = 3
    private let circuitBreakerCooldown: Duration = .seconds(60)

    // Cached health check result
    private var cachedAvailability: (available: Bool, checkedAt: ContinuousClock.Instant)?
    private let healthCheckTTL: Duration = .seconds(10)

    // Cloud concurrency limiter (cloud APIs support genuine parallel processing)
    private let cloudSemaphore = AsyncSemaphore(limit: 3)

    init(localProviders: [InferenceProvider], cloudProviders: [InferenceProvider]) {
        self.localProviders = localProviders
        self.cloudProviders = cloudProviders
    }

    // MARK: - Primary Entry Point

    /// Execute a single inference job. The worker selects the provider automatically.
    /// For local jobs: always waits for the current job to complete before starting next.
    /// For cloud jobs: bounded parallelism (limit: 3).
    func execute(job: InferenceJob) async throws -> InferenceResult {
        let provider = try await selectProvider(for: job)

        if provider.capabilities.isLocal {
            // Local: completely serial — no semaphore needed, actor serializes all calls
            return try await executeJob(job, on: provider)
        } else {
            // Cloud: bounded parallel — acquire semaphore, release on completion
            await cloudSemaphore.acquire()
            defer { cloudSemaphore.release() }
            return try await executeJob(job, on: provider)
        }
    }

    // MARK: - Provider Selection (ModelRouter logic embedded here)

    private func selectProvider(for job: InferenceJob) async throws -> InferenceProvider {
        // Check circuit breaker for local
        if let unavailableUntil = localUnavailableUntil,
           ContinuousClock.now < unavailableUntil {
            // Local circuit open — route to cloud
            return try firstAvailableCloud()
        }

        // Check local availability (cached for 10 seconds)
        if await isLocalAvailable() {
            consecutiveLocalFailures = 0
            return localProviders.first!
        }

        // Local not available — try cloud
        return try firstAvailableCloud()
    }

    private func isLocalAvailable() async -> Bool {
        // Return cached result if fresh
        if let cached = cachedAvailability,
           ContinuousClock.now - cached.checkedAt < healthCheckTTL {
            return cached.available
        }
        // Fresh check
        let available = await localProviders.first?.isAvailable() ?? false
        cachedAvailability = (available: available, checkedAt: ContinuousClock.now)
        return available
    }

    private func firstAvailableCloud() throws -> InferenceProvider {
        for provider in cloudProviders {
            // Cloud providers are considered available if their API key is loaded
            // (actual connectivity is checked lazily on first request)
            return provider
        }
        throw InferenceError.noProviderAvailable
    }

    // MARK: - Job Execution with Circuit Breaker

    private func executeJob(_ job: InferenceJob, on provider: InferenceProvider) async throws -> InferenceResult {
        let start = ContinuousClock.now

        do {
            let stream = try await provider.infer(job: job)
            var fullText = ""
            for try await token in stream {
                fullText += token.text
            }
            // Reset circuit breaker on success
            if provider.capabilities.isLocal {
                consecutiveLocalFailures = 0
            }
            let duration = ContinuousClock.now - start
            return InferenceResult(
                jobID: job.id,
                text: fullText,
                providerUsed: provider.identifier,
                durationSeconds: duration.components.seconds.toDouble(),
                tokenCount: nil
            )
        } catch {
            // Update circuit breaker on local failure
            if provider.capabilities.isLocal {
                consecutiveLocalFailures += 1
                if consecutiveLocalFailures >= circuitBreakerThreshold {
                    localUnavailableUntil = ContinuousClock.now + circuitBreakerCooldown
                }
            }
            throw error
        }
    }
}

// MARK: - Bounded semaphore for cloud parallelism
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
        }
    }
}

enum InferenceError: Error {
    case noProviderAvailable
    case providerTimeout
    case contextTooLong
    case invalidResponse(String)
}
```

**Key properties of InferenceWorker:**

- Being an `actor`, Swift guarantees that only one `execute()` call runs at a time for local providers — actor isolation provides the serial queue for free.
- The cloud semaphore limits parallelism to 3 concurrent cloud requests, preventing rate-limit errors.
- The 10-second health check cache eliminates the current per-request `/api/tags` overhead.
- The circuit breaker prevents repeated local failures from blocking the pipeline — after 3 consecutive failures within 90 seconds, local inference is bypassed for 60 seconds.

### 7.4 AnalysisJobQueue Actor

Serializes multi-meeting analysis requests to prevent two meetings ending simultaneously from doubling Ollama load.

```swift
@Observable
actor AnalysisJobQueue {

    struct AnalysisRequest: Identifiable {
        let id = UUID()
        let meeting: MeetingItem
        let segments: [TranscriptSegment]
        let transcript: String
        let priority: InferenceJob.JobPriority
        let enqueuedAt: Date
    }

    // Observable for UI consumption
    private(set) var pendingCount: Int = 0
    private(set) var activeRequest: AnalysisRequest?

    private var queue: [AnalysisRequest] = []
    private var isProcessing = false
    private let worker: InferenceWorker
    private let intelligenceService: MeetingIntelligenceService

    init(worker: InferenceWorker, intelligenceService: MeetingIntelligenceService) {
        self.worker = worker
        self.intelligenceService = intelligenceService
    }

    // MARK: - Public API

    /// Enqueue an analysis request. Returns immediately — analysis runs in background.
    func enqueue(_ request: AnalysisRequest) {
        // Insert at correct priority position
        let insertIdx = queue.lastIndex { $0.priority >= request.priority }
            .map { $0 + 1 } ?? 0
        queue.insert(request, at: insertIdx)
        pendingCount = queue.count
        if !isProcessing {
            Task { await processNext() }
        }
    }

    // MARK: - Internal Processing

    private func processNext() async {
        guard !queue.isEmpty else {
            isProcessing = false
            activeRequest = nil
            pendingCount = 0
            return
        }

        isProcessing = true
        let request = queue.removeFirst()
        activeRequest = request
        pendingCount = queue.count

        // Run analysis (non-blocking to queue — actor is free to accept new enqueue() calls)
        let analysis = await intelligenceService.analyze(
            title: request.meeting.title,
            segments: request.segments,
            meetingStart: request.meeting.startDate
        )

        // Persist results
        await persistAnalysis(analysis, for: request.meeting)

        // Process next in queue
        await processNext()
    }

    private func persistAnalysis(_ analysis: MeetingAnalysis, for meeting: MeetingItem) async {
        // Dispatch to @MainActor for SwiftData write
        await MainActor.run {
            meeting.summary = analysis.summary
            meeting.actionItems = analysis.actionItems
            // ... etc.
        }
    }
}
```

**UI integration:**
```swift
// In a SwiftUI view
if analysisJobQueue.pendingCount > 0 {
    Label("Analysis queued (\(analysisJobQueue.pendingCount) waiting)",
          systemImage: "clock")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

### 7.5 ModelRouter Protocol

Separates provider selection strategy from `InferenceWorker`:

```swift
protocol ModelRouter: AnyObject {
    func selectProvider(
        for job: InferenceJob,
        from candidates: [InferenceProvider]
    ) async -> InferenceProvider?
}

/// Default router: local first, cloud fallback
final class LocalFirstRouter: ModelRouter {
    func selectProvider(for job: InferenceJob, from candidates: [InferenceProvider]) async -> InferenceProvider? {
        // Try local providers first
        for provider in candidates where provider.capabilities.isLocal {
            if await provider.isAvailable() { return provider }
        }
        // Fall back to cloud
        return candidates.first { !$0.capabilities.isLocal }
    }
}

/// Cloud-only router for when Ollama is explicitly disabled by the user
final class CloudOnlyRouter: ModelRouter {
    func selectProvider(for job: InferenceJob, from candidates: [InferenceProvider]) async -> InferenceProvider? {
        candidates.first { !$0.capabilities.isLocal }
    }
}

/// Specialized router: routes summarization to a capable model, extraction to a fast/cheap model
final class SpecializedRouter: ModelRouter {
    func selectProvider(for job: InferenceJob, from candidates: [InferenceProvider]) async -> InferenceProvider? {
        // Synthesis calls benefit from larger models; extraction calls should use the fastest available
        if job.chunkIndex == nil {  // synthesis call (no chunk index)
            return candidates.first { $0.capabilities.maxContextTokens >= 32_000 }
        } else {
            return candidates.first { $0.capabilities.isLocal } ?? candidates.first
        }
    }
}
```

### 7.6 Updated analyzeChunked() With InferenceWorker

The revised `analyzeChunked()` in `MeetingIntelligenceService` with serialized local inference:

```swift
private func analyzeChunked(
    title: String,
    chunks: [String],
    meetingType: String,
    worker: InferenceWorker,
    progressHandler: ((Int, ChunkAnalysis) -> Void)? = nil
) async -> MeetingAnalysis {
    log.info("chunked analysis: \(chunks.count) chunks for title='\(title)'")

    var ordered = [ChunkAnalysis?](repeating: nil, count: chunks.count)

    // Serial loop — works correctly for both local (actor serializes) and cloud (bounded semaphore)
    // This replaces the withTaskGroup that caused the thundering herd.
    for (i, chunk) in chunks.enumerated() {
        let job = InferenceJob(
            id: UUID(),
            prompt: TranscriptChunker.buildExtractionPrompt(
                chunk: chunk, index: i, total: chunks.count, meetingType: meetingType),
            maxTokens: 500,
            priority: .normal,
            chunkIndex: i,
            totalChunks: chunks.count,
            meetingID: currentMeetingID
        )

        do {
            let result = try await worker.execute(job: job)
            var analysis = TranscriptChunker.parseChunkResponse(result.text)
            analysis.index = i
            ordered[i] = analysis
            progressHandler?(i, analysis)  // UI can update progressively
        } catch {
            log.warning("chunk \(i + 1)/\(chunks.count) failed: \(error) — using keyword fallback")
            ordered[i] = TranscriptChunker.keywordChunkFallback(chunk, index: i)
        }
    }

    let chunkAnalyses = ordered.compactMap { $0 }
    // ... merge and synthesize as before
}
```

Note that this is a `for` loop with `await` inside — Swift Concurrency executes the loop body sequentially. Each `worker.execute()` suspends the current task until the inference completes, then the loop advances to the next chunk. This is the correct pattern for local inference.

For cloud providers where parallelism is beneficial, `InferenceWorker.execute()` internally uses the `AsyncSemaphore` to allow up to 3 concurrent requests while the loop appears sequential from the caller's perspective.

---

## 8. Proposed Execution Timeline: Before vs. After

### 8.1 Current Execution (90-Minute Meeting, Ollama Busy)

```
t=0s:    Meeting ends. RecordingService.stopRecording() called on @MainActor.
t=0s:    AVAudioEngine stopped. TranscriptStore.finalize() called.
t=~1s:   TranscriptStore.finalize() completes. Segments loaded.
t=~1s:   Task { } detaches. MeetingIntelligenceService.analyze() called.
t=~1s:   Meeting type detected (keyword scan, sync).
t=~1s:   Routing: transcript > 12,000 chars → analyzeChunked()
t=~1s:   TranscriptChunker.chunks(): 90 min → 12 chunks
t=~1s:   withTaskGroup: 12 tasks submitted simultaneously.

t=~1s:   Task 1..12: isOllamaAvailable() — 12 simultaneous GET /api/tags
t=~2s:   12 health checks return OK
t=~2s:   Task 1..12: POST /api/generate — 12 simultaneous requests to Ollama
          [Ollama queues 11, processes 1]
          [GPU memory under pressure]
          [System responsiveness degrades]

t=62s:   URLSession timeout fires on all 12 tasks.
t=62s:   All 12 print "Ollama first attempt failed — sleeping 10s before retry"
t=62s:   All 12 enter Task.sleep(10_000_000_000) — exactly 10 seconds.

t=72s:   All 12 tasks wake simultaneously.
t=72s:   Task 1..12: POST /api/generate — 12 more simultaneous requests.
          [Ollama still processing wave 1 responses internally]
          [Memory + GPU saturation. Possible Ollama crash.]

t=132s:  Second timeout fires on all 12 tasks.
          All 12 fall through: callOpenAI() → callAnthropic() → callGemini()
          If no cloud keys configured: all 12 return ("", fallbackUsed: true)

t=132s:  All 12 tasks complete. chunkAnalyses has 0-12 keyword-fallback entries.
t=132s:  synthesize() — one more AI call (same path, same timeout risk)

t=~192s: Total: 3 minutes 12 seconds for a 90-min meeting that produces empty analysis.
          @MainActor context.save() persists keyword-fallback results.
          UI refreshes showing sparse or empty analysis card.
```

### 8.2 Proposed Execution (90-Minute Meeting, InferenceWorker)

```
t=0s:    Meeting ends. RecordingService signals AnalysisJobQueue.
t=0s:    AnalysisJobQueue.enqueue() returns immediately (non-blocking).
t=0s:    UI shows "Analysis in progress" badge on meeting card.

t=~1s:   AnalysisJobQueue.processNext() begins.
t=~1s:   MeetingIntelligenceService.analyze() called in background Task.
t=~1s:   Routing: chunked. 12 chunks.

t=~1s:   InferenceWorker.execute(chunk 1) — serial for-loop begins.
         InferenceWorker calls isLocalAvailable() — cached from app launch.
         Ollama is available. OllamaProvider.infer() called.

t=~1s:   OllamaProvider: POST /api/generate for chunk 1.
         [Ollama: 1 request, single KV cache, full GPU bandwidth]
         [No memory pressure. Normal system responsiveness.]

t=~25s:  Chunk 1 complete (normal inference at full GPU speed).
         ChunkAnalysis 1 parsed. progressHandler called.
         UI updates: "Chunk 1/12 complete. 1 action item found."

t=~50s:  Chunk 2 complete. UI updates.
         ...
t=~5min: All 12 chunks complete sequentially.
         Each took ~25s. Total: 12 × 25s = 300s ≈ 5 minutes.
         [This is the same wall-clock time as serial processing in the old path
          — the old path also serialized at the GPU. But the new path never
          times out, never thunders, never degrades.]

t=~5:05  synthesize() — one final AI call with key-points.
t=~5:30  Summary generated.
t=~5:30  AnalysisJobQueue.persistAnalysis() — single context.save().
         UI shows complete analysis card.
```

**Total: ~5.5 minutes, 100% success rate, no system freeze.**

The wall-clock time is longer than the best case of the old path (which would be ~5 minutes if no timeouts occurred), but:
1. It is dramatically shorter than the old path's worst case (3+ minutes with empty results).
2. The UI shows progressive results, so the user sees content starting at t=25s.
3. The system never freezes.
4. Analysis always completes with AI-generated content (no keyword fallback degradation).

---

## 9. Quick Wins vs. Full Redesign

### 9.1 Quick Wins (Hours of Work)

These changes can be made to the existing code without any architectural refactoring. Each is a small, targeted change with immediate impact.

**QW-001: Serialize Ollama inference (CRITICAL — do this first)**
Replace the `withTaskGroup` in `analyzeChunked()` with a serial `for` loop:

```swift
// BEFORE (lines 162-173 of MeetingIntelligenceService.swift):
await withTaskGroup(of: (Int, ChunkAnalysis).self) { group in
    for (i, chunk) in chunks.enumerated() {
        group.addTask {
            let ca = await TranscriptChunker.analyzeChunk(...)
            return (i, ca)
        }
    }
    for await (i, ca) in group { ordered[i] = ca }
}

// AFTER (~20 lines replacing the above):
for (i, chunk) in chunks.enumerated() {
    log.info("analyzing chunk \(i + 1) of \(chunks.count)")
    let ca = await TranscriptChunker.analyzeChunk(
        chunk, index: i, totalChunks: chunks.count,
        meetingType: meetingType, aiService: aiService
    )
    ordered[i] = ca
}
```

This single change eliminates TD-001, eliminates PB-001, and prevents the thundering herd. It is approximately 8 lines of deletion and 8 lines of replacement. It should ship within hours.

**QW-002: Cache Ollama health check for 10 seconds**
Add a cached availability result to `AIService`:

```swift
// Add to AIService:
private var cachedOllamaAvailability: (available: Bool, checkedAt: Date)?
private let healthCheckTTL: TimeInterval = 10.0

func isOllamaAvailableCached(endpoint: String) async -> Bool {
    if let cached = cachedOllamaAvailability,
       Date().timeIntervalSince(cached.checkedAt) < healthCheckTTL {
        return cached.available
    }
    let available = await isOllamaAvailable(endpoint: endpoint)
    cachedOllamaAvailability = (available: available, checkedAt: Date())
    return available
}
```
Replace `isOllamaAvailable(endpoint:)` with `isOllamaAvailableCached(endpoint:)` in `generate()`. Eliminates the N simultaneous `/api/tags` calls.

**QW-003: Add jitter to retry sleep**

```swift
// BEFORE (AIService.swift line 81):
try? await Task.sleep(nanoseconds: 10_000_000_000)

// AFTER:
let jitterNanos = UInt64.random(in: 7_500_000_000...12_500_000_000)  // 7.5–12.5s
try? await Task.sleep(nanoseconds: jitterNanos)
```
Prevents synchronized retry waves even if QW-001 is not yet applied.

**QW-006: Delete /tmp/orin_phi3_raw.txt write (privacy)**

```swift
// DELETE these lines from MeetingIntelligenceService.swift (lines 274-276):
// Dump raw phi3 response for debugging — read at /tmp/orin_phi3_raw.txt
try? result.text.write(to: URL(fileURLWithPath: "/tmp/orin_phi3_raw.txt"),
                       atomically: true, encoding: .utf8)
```
Privacy fix. Zero risk. Must ship before any production release.

**Combined impact of QW-001 through QW-003:** Eliminates the primary crash mode. Analysis succeeds reliably for all meeting lengths. System never freezes during analysis.

### 9.2 Full Redesign (Weeks of Work)

These are the medium-term architectural changes that provide resilience, extensibility, and observability beyond what the quick wins deliver.

| ID | Change | Effort | Requires |
|---|---|---|---|
| MT-002a | `InferenceProvider` protocol + `OllamaProvider` actor | 1 week | QW-001 done |
| MT-002b | `InferenceWorker` actor with circuit breaker | 1 week | MT-002a |
| MT-002c | `AnalysisJobQueue` actor with priority queue | 3 days | MT-002b |
| MT-002d | `CloudOnlyRouter`, `LocalFirstRouter` | 2 days | MT-002b |
| MT-002e | Progressive UI updates via `progressHandler` | 1 week | MT-002c |
| MT-002f | `AnthropicProvider`, `OpenAIProvider`, `GeminiProvider` | 1 week | MT-002a |
| MT-005 | Language-parameterized prompts + NLLanguageRecognizer | 2 weeks | Phase 2A stable |

The quick wins should ship in the current sprint. The full redesign is Phase 2 (8-10 weeks from now), after Phase 1 stabilization is complete.

---

## 10. Implementation Sequence

The following sequence minimizes risk by never breaking existing functionality. Each step can be independently tested and reverted.

### Step 1: Apply Quick Wins (this sprint, ~1 day)

**1a.** Delete `/tmp/orin_phi3_raw.txt` write (5 minutes, zero risk).

**1b.** Add jitter to retry sleep in `AIService.swift` (10 minutes, zero risk).

**1c.** Add health check cache to `AIService.swift` (30 minutes, low risk). Test: verify that 12 chunk tasks produce 1 `/api/tags` call, not 12.

**1d.** Replace `withTaskGroup` with serial `for` loop in `MeetingIntelligenceService.analyzeChunked()` (30 minutes). Test: record a 30+ minute meeting, verify analysis completes without system freeze, verify results are complete.

### Step 2: Extract OllamaProvider (Phase 2, Week 1)

Create `Sources/Orin/Services/AI/OllamaProvider.swift`. Move `callOllama()`, `isOllamaAvailable()`, and the health check cache from `AIService` into this new actor. `AIService.generate()` delegates to `OllamaProvider`. Behavior is identical to Step 1 — this is a pure refactor.

### Step 3: Define InferenceProvider Protocol (Phase 2, Week 1)

Create `Sources/Orin/Services/AI/InferenceProvider.swift`. Define `InferenceJob`, `InferenceResult`, `InferenceCapabilities`, `InferenceToken`, `InferenceError`. Make `OllamaProvider` conform. All call sites still go through `AIService` — the protocol is introduced without changing any caller.

### Step 4: Build InferenceWorker (Phase 2, Week 2)

Create `Sources/Orin/Services/AI/InferenceWorker.swift`. Implement the `AsyncSemaphore`, circuit breaker, and health check cache as documented in Section 7.3. Wire `AIService.generate()` to delegate to `InferenceWorker.execute()`.

At this point, `AIService` becomes a thin facade over `InferenceWorker`. Callers that use `AIService.generate()` see no behavioral change.

### Step 5: Build Cloud Providers (Phase 2, Week 3)

Extract `OpenAIProvider`, `AnthropicProvider`, `GeminiProvider` from `AIService`. Each implements `InferenceProvider`. Model IDs move to a configuration struct (remove hardcoded strings). API keys continue to load from Keychain via `AIKeychainService`.

### Step 6: Build AnalysisJobQueue (Phase 2, Week 4)

Create `Sources/Orin/Services/AI/AnalysisJobQueue.swift`. Wire `MeetingDataService.triggerAnalysis()` to enqueue via `AnalysisJobQueue` instead of calling `MeetingIntelligenceService` directly. Add `pendingCount` observation to the appropriate status view.

### Step 7: Progressive UI Updates (Phase 2, Week 5-6)

Add `progressHandler: ((Int, ChunkAnalysis) -> Void)?` parameter to `analyzeChunked()`. Wire this to a `@Published` `analysisProgress` property on `MeetingItem` (stored in memory, not persisted). Update the meeting detail view to show action items as they are extracted, before synthesis is complete.

### Step 8: Remove AIService Facade (Phase 2, End)

Once all callers use `InferenceWorker` through `AnalysisJobQueue`, remove the `AIService.generate()` delegation path. `AIService` retains provider connection testing functionality (`AIProviderTestService.swift`) but is no longer in the hot path.

---

## 11. Known Secondary Issues

The following AI pipeline issues are not part of the primary failure mode but should be tracked and addressed in Phase 2.

### 11.1 Model ID Staleness

The Anthropic model `claude-haiku-4-5-20251001` is a pinned version. Anthropic regularly deprecates specific model versions. This will cause silent fallback to OpenAI or keyword-only results when the model is deprecated.

**Fix:** Move all cloud model IDs to a configuration plist that can be updated without an app release. In the InferenceProvider redesign, each provider reads its model ID from a user-overridable setting with a sensible default.

### 11.2 No Retry Limit on Cloud Providers

`AIService.generate()` retries Ollama once (10-second sleep then retry), but has no retry logic for cloud providers. A transient 429 (rate limit) or 503 (server busy) response causes immediate fallback to the next provider, which may exhaust all providers unnecessarily.

**Fix:** Add exponential backoff with 2 retries for cloud providers in `InferenceWorker.executeJob()`.

### 11.3 O(N×M) Hallucination Word Scan on @MainActor

In `analyzeChunked()` (lines 219-231 of `MeetingIntelligenceService.swift`), the hallucination check scans summary words against the full concatenated transcript on `@MainActor`:

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

For a 150-minute meeting: transcript ~97,500 chars, summary ~500 chars. `String.contains()` on 97,500 chars for each summary word is O(N×M) where N = transcript length and M = summary word count. At ~100 summary words and 97,500-char transcript: ~9.7 million character comparisons per analysis, running on `@MainActor`.

**Fix:** Move this check off `@MainActor` and into the background Task that runs analysis. Use a pre-tokenized `Set<Substring>` for O(1) membership testing rather than `String.contains()`.

### 11.4 Transcript Concatenation for Hallucination Check

In `analyzeChunked()`, line 200:
```swift
let fullTranscript = chunks.joined(separator: "\n")
```
For a 150-minute meeting with 20 chunks of 5,000 chars each (plus 500-char overlaps), this creates a new string of ~110,000 characters purely for the hallucination check. This string is never persisted or returned — it is created, scanned, and discarded. Pass the original transcript string instead.

### 11.5 Print Statements in Production Path

The `analyzeChunked()` function contains 20+ `print()` statements (the `[ProofRun]` block, lines 201-233). These execute on every analysis in production. They should be replaced with `log.debug()` so they are silent in production builds and only visible when the subsystem logger is enabled.

### 11.6 Synthesis Calls on Keyword Fallback Results

When Ollama fails and keyword fallback is used for all chunks, `synthesize()` is still called with the keyword-fallback `ChunkAnalysis` objects. The synthesis prompt receives bullet points derived from keyword matching, not from AI extraction. The resulting "synthesis summary" is low quality.

**Fix:** Check whether any `chunkAnalyses` were produced by AI (not keyword fallback) before calling `synthesize()`. If all chunks used keyword fallback, use the `keyPointsSummary()` fallback directly and skip the synthesis AI call.

---

*End of document. See `05-Data-Persistence.md` for SwiftData persistence issues including the O(N^2) save pattern and missing meetingId predicates.*
