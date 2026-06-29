# AI Pipeline Diagrams

## 1. Current AI Pipeline (Thundering Herd — TD-001)

```mermaid
flowchart TD
    subgraph Trigger["Analysis Trigger (@MainActor)"]
        MIS["MeetingIntelligenceService\n.analyzeChunked(meeting:)"]
        TC["TranscriptChunker\nproduces N chunks\n(~20 for 150-min meeting\n@ 5000 chars/chunk)"]
    end

    subgraph TG["withTaskGroup — NO CONCURRENCY LIMIT"]
        direction LR
        T1["Task 1\nchunk[0]"]
        T2["Task 2\nchunk[1]"]
        T3["Task 3\nchunk[2]"]
        TN["Task N\nchunk[N-1]"]
        DOTS["...all submitted\nbefore any completes"]
    end

    subgraph Ollama["Ollama (local, single-GPU, serialized)"]
        HC["isOllamaAvailable()\n/api/tags — 3s timeout\n⚠ N simultaneous HTTP calls"]
        GEN["/api/generate\n60s URLSession timeout\nOllama serializes internally:\nonly 1 runs, 19 wait"]
    end

    subgraph Fail["Failure Mode"]
        TO["t=60s: all 19 waiting\nrequests timeout simultaneously"]
        SLEEP["all tasks sleep\n10_000_000_000 ns (10s)\nNO JITTER — synchronized"]
        RETRY["t=70s: wave 2\n19-20 retry requests"]
        TOTAL["TOTAL: ~41 concurrent\nOllama connections\nGPU exhaustion → system freeze"]
    end

    subgraph Synth["Synthesis (only runs after ALL chunks complete)"]
        WAIT["group.waitForAll()"]
        DEDUP["deduplicateActionItems()"]
        BUILD["buildSummary()"]
        WRITE["write MeetingItem properties\n(12 fields, 2x context.save())"]
    end

    MIS --> TC
    TC -->|"group.addTask for each chunk"| TG
    T1 & T2 & T3 & TN --> HC
    HC --> GEN
    GEN -->|"timeout"| TO
    TO --> SLEEP
    SLEEP --> RETRY
    RETRY --> TOTAL
    GEN -->|"success path"| WAIT
    WAIT --> DEDUP --> BUILD --> WRITE

    style TG fill:#fee2e2,stroke:#dc2626
    style Fail fill:#fee2e2,stroke:#dc2626
    style Ollama fill:#fef3c7,stroke:#d97706
```

---

## 2. 41-Request Failure Mode Timeline

```mermaid
gantt
    title Thundering Herd: 41 Concurrent Ollama Requests (150-min meeting, 20 chunks)
    dateFormat  s
    axisFormat  t=%Ss

    section Wave 1 (20 requests)
    /api/tags ×20 simultaneous          :crit, hc1, 0, 3s
    chunk[0] inference (runs on GPU)    :active, c0, 3, 60s
    chunk[1-19] waiting in Ollama queue :crit, wait1, 3, 60s
    All 19 waiting → URLSession timeout :milestone, crit, to1, 63, 0s

    section Synchronized Sleep (no jitter)
    All 19 tasks sleep 10s (exact)      :sleep, 63, 10s

    section Wave 2 (19-20 retry requests)
    /api/tags ×19 simultaneous          :crit, hc2, 73, 3s
    chunk[1-19] retry inference         :crit, retry, 76, 60s
    Wave 2 timeout                      :milestone, crit, to2, 136, 0s

    section System Impact
    GPU saturated / OOM possible        :crit, gpu, 3, 133s
    System-wide frame drops             :crit, frames, 3, 133s
```

---

## 3. Proposed InferenceWorker Sequential Pipeline

```mermaid
flowchart TD
    subgraph AJQ["AnalysisJobQueue (Swift actor)"]
        QUEUE["queue: [PendingAnalysis]\nrunning: Bool\npriority: .userInitiated > .automatic\n\nSerializes multi-meeting analysis:\nprevents 2N concurrent requests\nwhen two meetings finish simultaneously"]
    end

    subgraph IW["InferenceWorker (Swift actor)"]
        JOBS["jobQueue: AsyncStream<InferenceJob>\nprocesses ONE job at a time (local)\nor N≤3 concurrent (cloud)\n\ncurrentLoad: InferenceLoad\n  .idle\n  .working(chunkIndex:, total:)\n  .overloaded (queue > 10 or failures > 3)"]
        CB["Circuit Breaker:\n3 failures in 90s window\n→ mark Ollama unavailable 60s\n→ route to cloud provider"]
        HC_CACHE["Health Check Cache:\nURLSession /api/tags result\ncached 10 seconds\nshared across all callers\n(eliminates N simultaneous /api/tags)"]
    end

    subgraph Providers["InferenceProvider Protocol"]
        OP["OllamaProvider\n(local, serial)"]
        LM["LMStudioProvider\n(local, serial)"]
        AFM["AppleFoundationModelsProvider\n(macOS 26+, serial)"]
        OAI["OpenAIProvider\n(cloud, semaphore limit:3)"]
        ANT["AnthropicProvider\n(cloud, semaphore limit:3)"]
    end

    subgraph MR["ModelRouter Protocol"]
        LFR["LocalFirstRouter:\nOllama → LMStudio → cloud fallback"]
        COR["CloudOnlyRouter:\nno local model installed"]
        SPR["SpecializedRouter:\nlarge model for analysis\nsmall model for summarization"]
    end

    subgraph Results["Streaming Results"]
        STREAM["AsyncStream<(chunkIndex, ChunkAnalysis)>\nSynthesis begins after FIRST chunk\n(not waiting for all N)"]
        SYNTH["Incremental synthesis\nUI updates as chunks arrive"]
    end

    MIS2["MeetingIntelligenceService\n.analyzeChunked() — revised"]
    MIS2 -->|"enqueue(analysis:)"| AJQ
    AJQ -->|"one analysis at a time"| IW
    IW --> HC_CACHE
    IW --> CB
    IW -->|"route(job:)"| MR
    MR --> OP & LM & AFM & OAI & ANT
    OP & LM & AFM -->|"sequential inference"| STREAM
    OAI & ANT -->|"bounded parallel inference"| STREAM
    STREAM --> SYNTH

    note1["JITTER: retry delay = 10s ± 2.5s (random)\nbreaks synchronized retry waves"]

    style IW fill:#d1fae5,stroke:#059669
    style AJQ fill:#dbeafe,stroke:#2563eb
    style MR fill:#ede9fe,stroke:#7c3aed
    style Results fill:#f0fdf4,stroke:#16a34a
```

---

## 4. InferenceProvider Protocol Hierarchy

```mermaid
classDiagram
    class InferenceJob {
        +prompt: String
        +systemPrompt: String
        +maxTokens: Int
        +priority: JobPriority
        +chunkIndex: Int
        +meetingID: UUID
    }

    class InferenceResult {
        +text: String
        +modelID: String
        +providerName: String
        +latencyMs: Int
        +tokenCount: Int
    }

    class InferenceProvider {
        <<protocol>>
        +providerName: String
        +isAvailable() async Bool
        +infer(job: InferenceJob) async throws InferenceResult
    }

    class ModelRouter {
        <<protocol>>
        +route(job: InferenceJob) InferenceProvider
    }

    class OllamaProvider {
        -baseURL: URL
        -modelID: String (UserDefaults)
        -healthCacheTTL: 10s
        +isAvailable() async Bool
        +infer(job:) async throws InferenceResult
        note: serial execution only
    }

    class LMStudioProvider {
        -baseURL: URL
        -modelID: String (UserDefaults)
        +isAvailable() async Bool
        +infer(job:) async throws InferenceResult
        note: serial execution only
    }

    class AppleFoundationModelsProvider {
        +isAvailable() async Bool
        note: macOS 26+ only
        note: on-device, no network
        +infer(job:) async throws InferenceResult
    }

    class OpenAIProvider {
        -apiKey: String (Keychain)
        -modelID: String (UserDefaults)
        -semaphore: AsyncSemaphore(limit: 3)
        +isAvailable() async Bool
        +infer(job:) async throws InferenceResult
    }

    class AnthropicProvider {
        -apiKey: String (Keychain)
        -modelID: String (UserDefaults)
        -semaphore: AsyncSemaphore(limit: 3)
        +isAvailable() async Bool
        +infer(job:) async throws InferenceResult
    }

    class LocalFirstRouter {
        +route(job:) InferenceProvider
        note: Ollama → LMStudio → AFM → cloud
    }

    class CloudOnlyRouter {
        +route(job:) InferenceProvider
        note: OpenAI → Anthropic
    }

    class SpecializedRouter {
        +route(job:) InferenceProvider
        note: large model for analysis
        note: small model for summary
    }

    InferenceProvider <|.. OllamaProvider
    InferenceProvider <|.. LMStudioProvider
    InferenceProvider <|.. AppleFoundationModelsProvider
    InferenceProvider <|.. OpenAIProvider
    InferenceProvider <|.. AnthropicProvider

    ModelRouter <|.. LocalFirstRouter
    ModelRouter <|.. CloudOnlyRouter
    ModelRouter <|.. SpecializedRouter

    LocalFirstRouter --> OllamaProvider
    LocalFirstRouter --> LMStudioProvider
    LocalFirstRouter --> AppleFoundationModelsProvider
    LocalFirstRouter --> OpenAIProvider
    CloudOnlyRouter --> OpenAIProvider
    CloudOnlyRouter --> AnthropicProvider
```

---

## 5. AnalysisJobQueue State Machine

```mermaid
stateDiagram-v2
    [*] --> Idle : actor initialized

    Idle --> Processing : enqueue(analysis:)\nrunning = true\npop highest priority job

    Processing --> Processing : job completes\nqueue not empty\npop next job

    Processing --> Idle : job completes\nqueue is empty\nrunning = false

    Idle --> Processing : enqueue(analysis:) while idle\nstart immediately

    Processing --> Queued : enqueue(analysis:) while running\nappend to [PendingAnalysis]\n(user-initiated jumps ahead of automatic)

    Queued --> Processing : current job completes\nnext job popped from queue

    Processing --> Overloaded : consecutive failures > 3\nOR queue depth > 10\nnew enqueue() returns .queuedForLater\nmeeting.pendingAnalysis = true

    Overloaded --> Processing : Ollama health check succeeds\ncircuit breaker resets\nretry pending analyses

    note right of Processing
        Observable state exposed to UI:
        .idle
        .working(meeting: MeetingItem,
                 chunk: Int, of: Int)
        .queued(count: Int)
        .overloaded
    end note

    note right of Queued
        Priority ordering:
        1. .userInitiated (Analyze button)
        2. .automatic (post-recording)
        Within same priority: FIFO
    end note
```
