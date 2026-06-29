# Thread Model Diagrams

## 1. Complete Thread / Actor Map

```mermaid
flowchart TB
    subgraph RT["Core Audio Real-Time I/O Thread (HAL, ~46 callbacks/sec)"]
        direction TB
        RT1["TapState.feed(buffer, time)"]
        RT2["MicTranscriberFeed.feed(buffer, time)"]
        RT3["ParticipantSTFeed.feed(buffer, time)"]
        RT1 --> LOCK1["NSLock.lock()"]
        RT2 --> LOCK2["NSLock.lock()"]
        RT3 --> LOCK3["NSLock.lock()"]
    end

    subgraph MA["@MainActor (Main Thread)"]
        direction TB
        RS["RecordingService"]
        SACS["SystemAudioCaptureService"]
        TS["TranscriptStore"]
        MDS["MeetingDetectorService"]
        VIEWS["All SwiftUI Views\n(MeetingsView, MainContainerView, etc.)"]
    end

    subgraph TP["Swift Cooperative Thread Pool"]
        direction TB
        AI["AIService.generate()"]
        IW["InferenceWorker jobs"]
        MIS["MeetingIntelligenceService\nanalyzeChunked() — withTaskGroup"]
        ASYNC["Other async operations\n(network, disk I/O)"]
    end

    subgraph RCQ["SFSpeechRecognizer Result Queue (private serial queue)"]
        direction TB
        RCB["recognitionTask result callback"]
        RCB --> PARSE["Parse SFTranscriptionSegment"]
        PARSE --> EMIT["Emit to TranscriptStore"]
    end

    subgraph OLLAMA["External: Ollama Process (localhost:11434)"]
        OL["/api/generate HTTP endpoint"]
    end

    RT1 -- "audioBuffer append" --> RCQ
    RT2 -- "audioBuffer append" --> RCQ
    EMIT -- "Task { @MainActor }" --> TS
    RS -- "installTap()" --> RT
    SACS -- "installTap()" --> RT
    AI -- "URLSession HTTP" --> OLLAMA
    MIS -- "withTaskGroup (unbounded)" --> AI
    TS -- "@Query / context.save()" --> MA
    MDS -- "CalendarKit async calls" --> TP
```

## 2. Actor Isolation Map

```mermaid
flowchart LR
    subgraph MainActor["@MainActor (Global Actor)"]
        RS2["RecordingService\n@MainActor class"]
        SACS2["SystemAudioCaptureService\n@MainActor class"]
        TS2["TranscriptStore\n@MainActor class"]
        MDS2["MeetingDetectorService\n@MainActor class"]
        SC["ServiceContainer\n.shared (singleton, NO actor)"]
        VIEWS2["SwiftUI Views\n(@MainActor by default)"]
    end

    subgraph CustomActors["Custom Actors (proposed — not yet implemented)"]
        IW2["InferenceWorker\nactor (proposed MT-002)"]
        AJQ["AnalysisJobQueue\nactor (proposed MT-002)"]
        RSM["RecognitionSessionManager\nactor (proposed MT-001)"]
    end

    subgraph Unprotected["Unprotected / Unsafe (current pain points)"]
        SC2["ServiceContainer.shared\n[String:Any] — no NSLock\n(TD-005)"]
        RD["RecognitionDiagnostics\nnonisolated(unsafe) static var\nexperimentMode"]
        TS3["TapState\nNSLock-protected struct\n(not actor)"]
        VF["MicTranscriberFeed /\nParticipantSTFeed\nNSLock-protected structs\n(not actors)"]
    end

    RS2 -- "owns" --> TS3
    SACS2 -- "owns" --> VF
    RS2 -- "resolve()" --> SC2
    SACS2 -- "resolve()" --> SC2
    RCQ2["Recognition callback\n(private serial queue)"] -- "Task { @MainActor }" --> TS2
    RD -- "read/write from\nany thread" --> DANGER["RACE CONDITION"]
```

## 3. XPC-in-Lock Problem: TapState.disarm()

```mermaid
sequenceDiagram
    participant CAT as Core Audio<br/>Real-Time Thread
    participant TSF as TapState.feed()
    participant DIS as TapState.disarm()
    participant NL as NSLock
    participant RR as recognitionRequest<br/>(SFSpeechAudioBufferRecognitionRequest)
    participant XPC as XPC Channel<br/>(com.apple.speechrecognition.SpeechRecognitionCore)
    participant SD as Speech Daemon<br/>(SpeechRecognitionCore)

    Note over CAT,SD: ~46 times/second — feed() path (safe)
    CAT->>TSF: feed(buffer, time)
    TSF->>NL: lock()
    TSF->>RR: append(buffer)
    TSF->>NL: unlock()

    Note over CAT,SD: disarm() called from @MainActor on RecordingService stop
    DIS->>NL: lock()
    Note over NL: NSLock held — Core Audio thread will spin-wait if feed() fires now

    DIS->>RR: endAudio()  ← XPC CALL WHILE LOCKED
    RR->>XPC: IPC message to speech daemon
    XPC->>SD: signal end-of-stream
    SD-->>XPC: acknowledge (may take 10–200 ms)
    XPC-->>RR: return

    Note over CAT,NL: If Core Audio fires during XPC round-trip,<br/>it spin-waits on NSLock → real-time deadline miss → glitch / crash

    DIS->>NL: unlock()
```

## 4. Proposed Fix: endAudio() Outside NSLock

```mermaid
sequenceDiagram
    participant DIS as TapState.disarm()
    participant NL as NSLock
    participant RR as recognitionRequest
    participant XPC as XPC Channel
    participant SD as Speech Daemon
    participant CAT as Core Audio<br/>Real-Time Thread

    Note over DIS,SD: BEFORE (buggy — XPC inside lock)
    DIS->>NL: lock()
    DIS->>RR: endAudio()        ← blocks here up to 200 ms
    DIS->>NL: unlock()

    Note over DIS,SD: AFTER (fixed — capture ref, unlock, then XPC)
    DIS->>NL: lock()
    DIS->>DIS: let req = recognitionRequest<br/>recognitionRequest = nil<br/>isArmed = false
    DIS->>NL: unlock()          ← Core Audio can now acquire lock immediately
    DIS->>req: endAudio()       ← XPC call happens with no lock held
    req->>XPC: IPC message
    XPC->>SD: signal end-of-stream
    SD-->>XPC: acknowledge
    XPC-->>req: return

    Note over CAT,NL: Core Audio thread never blocks — real-time safety restored
    CAT->>NL: lock() [next callback]
    NL-->>CAT: acquired immediately (req already nil, isArmed false → early return)
```

---

### Thread Safety Reference Table

| Component | Isolation | Thread-safe? | Notes |
|---|---|---|---|
| `RecordingService` | `@MainActor` | Yes | All mutations on main thread |
| `SystemAudioCaptureService` | `@MainActor` | Yes | All mutations on main thread |
| `TranscriptStore` | `@MainActor` | Yes | SwiftData context is main-thread |
| `MeetingDetectorService` | `@MainActor` | Yes | Fixed in commit 4f603ea |
| `TapState` | `NSLock` | Mostly | XPC-in-lock bug (TD-003) |
| `MicTranscriberFeed` | `NSLock` | Mostly | Heap alloc in callback (TD-002) |
| `ParticipantSTFeed` | `NSLock` | Mostly | Heap alloc in callback (TD-002) |
| `ServiceContainer` | None | **No** | No lock, fatalError on missing key (TD-005) |
| `RecognitionDiagnostics.experimentMode` | `nonisolated(unsafe)` | **No** | Static var, any-thread read/write |
| `AIService` | Unstructured `async` | Partial | No actor, no concurrency limit |
| `MeetingIntelligenceService` | Unstructured `async` | **No** | Unbounded `withTaskGroup` (TD-001) |
| Recognition result callback | Private serial queue | Yes | Dispatches to `@MainActor` via `Task {}` |
