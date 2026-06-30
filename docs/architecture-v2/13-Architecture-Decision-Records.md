# Document 13: Architecture Decision Records (ADRs)

**Series**: Orin Long-Term Architecture Design  
**Document**: 13 of 13  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Overview

Architecture Decision Records (ADRs) document the WHY behind each significant design decision in the Orin V2 architecture. They capture the context in which a decision was made, the alternatives that were evaluated, and the trade-offs that were accepted. Without ADRs, future engineers are forced to reverse-engineer intent from code, and frequently undo correct decisions because they do not understand why those decisions were made.

**ADR Format:**
- **Status**: Proposed | Accepted | Deprecated | Superseded by ADR-XXX
- **Context**: What situation required a decision?
- **Decision**: What was decided?
- **Alternatives**: What else was evaluated?
- **Rationale**: Why was this option chosen?
- **Consequences**: What becomes easier? What becomes harder?
- **Trade-offs Accepted**: What are we explicitly giving up?
- **Review Trigger**: What would cause this decision to be revisited?

---

## ADR-001: Hexagonal Architecture as the Primary Architectural Pattern

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: Orin must eventually run on macOS, Windows, iOS, and Android without rewriting the core business logic. The current monolithic ServiceContainer design tightly couples business logic (meeting intelligence, transcript management) to Apple-specific APIs (SwiftData, AVFoundation, ScreenCaptureKit). This makes cross-platform portability impossible without a full rewrite.

**Decision**: Adopt Hexagonal Architecture (Ports and Adapters) as the primary architectural style. `OrinCore` contains all domain logic. Ports are protocol interfaces. Adapters are concrete platform implementations. `OrinCore` has zero knowledge of any specific adapter.

**Alternatives Considered**:
- **Layered Architecture**: presentation → domain → data layers. Simple, but layers still import platform-specific types through the layers, preventing true portability.
- **VIPER**: UI-centric, iOS-focused. Does not address cross-platform portability at the package level.
- **Clean Architecture (Uncle Bob)**: Similar to hexagonal but with different terminology. Hexagonal's "ports and adapters" framing is more intuitive for the adapter-per-platform use case.

**Rationale**: Hexagonal Architecture is the only pattern that provides a hard, compiler-enforced boundary between core logic and platform adapters. The `OrinCore` Swift Package will fail to build if anyone accidentally imports a platform-specific framework — the compiler enforces the boundary, not code review.

**Consequences**:
- (+) `OrinCore` can be tested in isolation with no Apple hardware required
- (+) Windows and Android adapters can be built without touching core logic
- (+) New platform adapters compose cleanly (just implement the protocol)
- (−) Initial boilerplate: every external dependency requires a protocol + adapter
- (−) Requires discipline to keep `OrinCore` clean; CI checks are mandatory

**Trade-offs Accepted**: More upfront protocol boilerplate in exchange for guaranteed long-term portability.

**Review Trigger**: If Orin never expands beyond macOS, the portability overhead has no payoff. Reassess if the five-year product roadmap changes to macOS-only.

---

## ADR-002: Bounded Contexts over Microservices

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: The system needs clear ownership boundaries between subsystems (Session, Transcription, Intelligence, Knowledge, etc.) to prevent the entanglement that currently exists in `MeetingIntelligenceService` (which knows about audio, transcripts, persistence, and AI simultaneously).

**Decision**: Logical bounded contexts within a monorepo, not separate deployable microservices. Bounded contexts communicate via domain events (Document 02). Each context owns its data and exposes a defined API.

**Alternatives Considered**:
- **Microservices**: separate HTTP services per context. Provides isolation and independent deployment.
- **Modular Monolith without DDD**: just separate files or Swift packages, but without event-based communication.

**Rationale**: Orin is a local application. Network-based microservices add 1-100ms of latency per IPC round-trip for operations that currently take microseconds. For real-time audio processing and live transcript display, this is unacceptable. Bounded contexts provide the same conceptual isolation and ownership clarity as microservices, without the network overhead.

**Consequences**:
- (+) Sub-millisecond communication between contexts (in-process actor calls)
- (+) Simpler deployment (single application bundle)
- (+) Full stack traces across context boundaries in crash reports
- (−) Context boundaries are not enforced by network topology; requires discipline and code review
- (−) A bug in one context can theoretically affect another (though event-based comms reduce this)

**Trade-offs Accepted**: Context boundary violations are possible but not automatic. Mitigated by: separate Swift modules per context (build system enforces import rules), and the event bus (contexts do not call each other's methods directly).

**Review Trigger**: If Orin adds a multi-user server component (e.g., an OrinSync server), some contexts may genuinely need network-based separation.

---

## ADR-003: Swift Actors as the Primary Concurrency Primitive

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: The current codebase mixes GCD `DispatchQueue`, `@MainActor`, `NSLock`, and unstructured `Task` launches. This has produced: data races that require `@unchecked Sendable` suppressions, an EXC_BREAKPOINT crash related to `@Observable` + GCD mixing on macOS 26, and a TapState lock held across an XPC boundary.

**Decision**: Replace all GCD-based concurrency with Swift actors and Swift Concurrency. All shared mutable state is owned by an actor. `@MainActor` for all UI state. Custom actors for all background service state.

**Alternatives Considered**:
- **Continue with GCD**: lower migration cost. Does not fix data race bugs; they remain latent.
- **GCD + `os_unfair_lock` everywhere**: safe but verbose; does not benefit from Swift compiler's actor isolation checking.

**Rationale**: Swift actors are checked by the compiler. A data race on actor-isolated state is a compile error, not a runtime crash. The `swift_task_isCurrentExecutorWithFlagsImpl` crash on macOS 26 is a direct consequence of mixing GCD with `@Observable`, which requires Swift Concurrency's executor model. Migrating to actors eliminates the root cause.

**Consequences**:
- (+) Data races become compile errors (actor isolation checking)
- (+) `async/await` is more readable than GCD callback chains
- (+) Interoperates with Apple's APIs that are adopting Swift Concurrency
- (−) Core Audio callback remains on a real-time thread outside the actor model; requires an NSLock bridge (this is correct and unavoidable — the RT thread predates actors)
- (−) Some legacy Apple APIs still use completion handlers; bridging via `withCheckedContinuation`

**Trade-offs Accepted**: The Core Audio thread requires explicit NSLock bridging. This is a documented, well-understood pattern (`TapState`) and is not a regression from the current design.

**Review Trigger**: Apple deprecates Swift actors or introduces a better concurrency model.

---

## ADR-004: Sequential Local Inference via InferenceWorker Actor

**Status**: Accepted — Supersedes implicit V1 decision to use `withTaskGroup` without concurrency limit  
**Date**: 2026-06-30

**Context**: `MeetingIntelligenceService.analyzeChunked()` submits all N chunk analysis tasks simultaneously via `withTaskGroup`. For an 8-chunk meeting, this creates 8 concurrent Ollama requests. Ollama is a single-process, single-GPU application that serializes requests internally. The effect: 8 requests queued internally → all approaching the 60s timeout simultaneously → all timing out → all retrying → 41 simultaneous retry requests → GPU OOM → system-wide freeze lasting 2-5 minutes post-call.

**Decision**: Introduce `InferenceWorker`, a Swift actor that owns a serial job queue. Exactly one `InferenceJob` executes at a time per local `InferenceProvider`. Cloud providers with genuine parallelism use a bounded semaphore (limit = 3), not unlimited parallelism.

**Alternatives Considered**:
- **Fix `withTaskGroup` with a `TaskGroup` concurrency limit**: Swift's `TaskGroup` has no built-in concurrency limit in Swift 5.9. Would require a semaphore, defeating the purpose of using `TaskGroup`.
- **Rate-limit Ollama requests with exponential backoff**: Does not prevent the thundering herd at analysis start; just delays it.
- **Process one meeting at a time, but parallelize chunks within a meeting**: This is the current failing design. Local LLMs cannot parallelize over chunks.

**Rationale**: The correct mental model for a local LLM is "single-threaded worker with a job queue", not "scalable REST API". Sending parallel requests to Ollama does not increase throughput — it creates a thundering herd. The `InferenceWorker` actor enforces the correct model at the type level: callers cannot submit two concurrent jobs to a local provider even if they try.

**Consequences**:
- (+) Eliminates post-meeting system freeze (root cause resolved)
- (+) Predictable, monotonic analysis progress (no thundering herd retries)
- (+) Progressive result delivery via `AsyncStream<InferenceToken>` (UI shows live progress)
- (−) Longer wall-clock time for multi-chunk analysis compared to (theoretical) parallel processing
- (−) Sequential processing is the actual behaviour; parallel processing was never working correctly

**Trade-offs Accepted**: Analysis wall-clock time is longer on paper but identical in practice (Ollama was always serializing; we are now explicit about it and avoid the timeout cascade).

**Review Trigger**: A local inference runtime that supports genuine parallelism across GPU cores emerges. At that point, `InferenceWorker` would allow bounded parallelism (e.g., limit = GPU core count).

---

## ADR-005: Event-Driven Communication Between Bounded Contexts

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: Currently, `MeetingIntelligenceService` calls `TranscriptStore` directly, `RecordingService` calls `MeetingIntelligenceService` directly, and so on. A crash in one service can cascade. Adding the knowledge graph requires modifying `MeetingIntelligenceService`. Adding plugins requires modifying every service they want to observe.

**Decision**: Bounded contexts communicate exclusively via domain events through the `EventBus`. No direct method calls across context boundaries. Each context publishes events; interested contexts subscribe.

**Alternatives Considered**:
- **Delegate protocols**: tight coupling between publisher and subscriber (publisher knows the subscriber type).
- **NotificationCenter**: untyped, global, no compile-time safety, no structured payload.
- **Combine publishers**: possible, but Combine is being de-emphasized by Apple in favour of Swift Concurrency async streams.

**Rationale**: Events decouple publishers from subscribers. Adding the Knowledge Context does not require touching the Intelligence Context — Knowledge subscribes to `AnalysisCompleted` events. Adding a plugin does not require modifying any service — plugins subscribe to their declared events. A crash in the Plugin Context cannot cascade to the Intelligence Context (events are delivered asynchronously; a subscriber crash does not affect the publisher).

**Consequences**:
- (+) Loose coupling: new features subscribe to events, do not modify existing services
- (+) Crash isolation: subscriber crash does not affect publisher
- (+) Auditable: all cross-context communication is explicit in the event catalogue
- (−) Harder to trace execution flow (must follow event subscriptions, not call stacks)
- (−) Eventual consistency: subscribers may lag behind publishers
- (−) Debug complexity: "why didn't X happen?" requires checking if the event was emitted and if the subscription is active

**Trade-offs Accepted**: Reduced debuggability of cross-context flows in exchange for loose coupling and crash isolation.

**Review Trigger**: Event debugging becomes a persistent productivity problem. At that point, introduce distributed tracing (causationID/correlationID already in the event envelope) into the debug UI.

---

## ADR-006: XPC-Based Plugin Sandboxing

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: Orin handles sensitive data: raw meeting transcripts, analysis of professional communications, knowledge graphs of professional relationships. If a third-party plugin runs in-process, it has full access to all of this data in memory. A buggy plugin can also crash the host process, interrupting a live meeting recording.

**Decision**: All plugins run as XPC services in separate processes. Communication is via serialized message passing. Plugins receive only the data their declared capabilities grant access to.

**Alternatives Considered**:
- **In-process plugins with capability checks**: simpler, lower overhead. Capability checks are enforced at the API layer, but a compromised or buggy plugin can still access all memory.
- **Web views as plugin UI (like VS Code extensions)**: limits plugins to JavaScript; too restrictive for the types of integrations Orin needs.

**Rationale**: XPC provides a genuine security boundary enforced by the operating system (separate address space, separate entitlements, sandboxed filesystem access). A buggy plugin XPC service crashes without affecting the Orin main process. A malicious plugin cannot read Orin's memory. The 1-5ms XPC latency is acceptable because plugins are never on the real-time audio path. macOS App Store review will require this isolation for any plugin that accesses user data.

**Consequences**:
- (+) Complete crash isolation (plugin crash ≠ recording lost)
- (+) OS-enforced memory isolation
- (+) Network access restricted to declared domains (App Sandbox entitlements on XPC service)
- (−) 1-5ms latency per plugin API call
- (−) Complex lifecycle management (XPC service process management)
- (−) Higher plugin developer complexity vs. in-process SDK

**Trade-offs Accepted**: Higher plugin developer friction in exchange for robust security isolation.

**Review Trigger**: XPC overhead becomes measurable to the user (i.e., > 100ms for a plugin API call). At that point, investigate batched API calls to amortize the IPC cost.

---

## ADR-007: SQLite Adjacency List for Knowledge Graph (Phase 1)

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: The Knowledge Context (Document 08) needs to store entities (People, Projects, Organizations), relationships between entities, and facts about entities. A graph structure fits this data naturally. Options include: a dedicated graph database, a relational database with adjacency list tables, or an embedded graph store.

**Decision**: Use SQLite with an adjacency list schema for Phase 1. GRDB (or SwiftData with raw SQL fallback) as the query interface. Recursive CTEs for graph traversal queries.

**Alternatives Considered**:
- **Neo4j**: industry-standard graph database. Excellent query language (Cypher), rich graph algorithms. Requires a separate server process, is not embeddable, adds ~4GB to installation size.
- **ArangoDB**: multi-model (document + graph). Same problem as Neo4j — requires a server.
- **DGraph**: cloud-native graph database. Completely unsuitable for local-first.
- **GunDB**: peer-to-peer graph database. Interesting but experimental; insufficient tooling.

**Rationale**: At the expected scale (10,000 meetings × 50 entities = 500,000 nodes; 2,000,000 edges), SQLite with proper indexes handles all required query patterns in < 100ms. SQLite is already present (SwiftData uses it). No additional server process required. The schema is designed to be Cypher-migration-friendly if we ever need to move to Neo4j. Recursive CTEs handle depth-limited graph traversal (e.g., "find all colleagues within 2 hops").

**Consequences**:
- (+) Zero additional infrastructure (SQLite is embedded)
- (+) App bundle size unchanged
- (+) Same persistence layer as the rest of the application
- (−) Graph algorithms (shortest path, centrality) are more complex in SQL than Cypher
- (−) Deep graph traversal (> 5 hops) requires complex recursive CTEs

**Trade-offs Accepted**: Graph algorithm complexity is acceptable for Phase 1 use cases (all queries are bounded-depth). Full graph analytics (shortest path, centrality scoring) deferred to Phase 3 when the need is proven.

**Review Trigger**: Any knowledge graph query exceeds 500ms at 10,000 meetings. At that point, evaluate GRDB with custom FTS5 indexes or migration to an embedded graph engine.

---

## ADR-008: Immutable TranscriptSegments with Correction Overlay

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: Users will correct ASR errors in transcript text. The question is: should corrections mutate the original segment, or be stored as an overlay on top of the immutable original?

**Decision**: `TranscriptSegments` are immutable once finalized. User corrections create `VocabularyCorrection` records and a display overlay. The original ASR output is always preserved.

**Alternatives Considered**:
- **Mutable segments**: corrections directly update the text field. Simple UI, simple queries. But the original ASR output is lost.

**Rationale**: The original ASR output has multiple forms of value:
1. Learning: `CorrectionStore` compares original vs. corrected text to identify systematic errors
2. Provenance: knowledge graph facts reference specific segment text; if the text mutates, the fact's source becomes ambiguous
3. Future re-transcription: a better ASR model may produce a different (and more accurate) transcript; the original output is the ground truth to compare against
4. Audit: in regulated industries, the original machine-produced transcript may be required alongside any human corrections

**Consequences**:
- (+) Original ASR output preserved for learning and re-analysis
- (+) Full correction history with timestamps
- (+) Knowledge graph facts have stable, immutable sources
- (−) More complex display logic (merge segment + correction overlay)
- (−) More storage (both original and correction stored)

**Trade-offs Accepted**: Display complexity and additional storage in exchange for data completeness and learning capability.

**Review Trigger**: Correction overlay display performance becomes a problem at scale (thousands of corrections per long meeting). At that point, evaluate pre-merged display text with original stored separately.

---

## ADR-009: Language-Neutral Section Markers in AI Prompts

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: The AI parser (`parseComprehensiveResponse()`) uses English section headers to locate summary, action items, decisions, and key points in LLM output. When the LLM responds in Spanish, French, or Hindi, it may use Spanish/French/Hindi section headers instead of English ones, causing the parser to return empty results.

**Decision**: Use language-neutral ASCII markers (`[SUMMARY]`, `[ACTION_ITEMS]`, `[DECISIONS]`, `[KEY_POINTS]`, `[/SECTION]`) as parser anchors. The system prompt instructs the LLM to use these exact markers regardless of the response language.

**Alternatives Considered**:
- **Language-specific parsers**: maintain a parser per supported language. N languages = N parsers to maintain.
- **LLM-structured output (JSON)**: instruct the LLM to return structured JSON directly. More reliable parsing, but degrades streaming (cannot progressively display as tokens arrive).
- **Post-processing translation**: translate the LLM's response to English, then parse. Adds a second inference call; doubles cost and time.

**Rationale**: Language-neutral markers are a zero-cost solution that works for all languages, including languages we have not yet added. The LLM is instructed to use the markers ("use these ASCII section markers regardless of your response language") and modern LLMs reliably follow this instruction. A single parser works for all 99 Whisper-supported languages.

**Consequences**:
- (+) Single parser implementation for all languages
- (+) Zero marginal cost per new language
- (+) Works for languages not yet officially supported (parser is already ready)
- (−) If a model does not follow the marker instruction, the parser falls back to heuristic extraction (the current fallback logic)

**Trade-offs Accepted**: Parser fallback required for non-compliant model outputs. The fallback already exists in the current codebase (`keywordFallback()`); it needs to be made language-aware.

**Review Trigger**: A production model consistently fails to use the markers. At that point, switch to structured JSON output (disabling streaming) for that model.

---

## ADR-010: No Server-Side User Data

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: Orin captures meeting transcripts, which are among the most sensitive data a professional generates. The product positions itself as privacy-first. The question is whether any user data (transcripts, analysis, vocabulary, knowledge graph) should ever be stored on Orin, Inc. servers.

**Decision**: Orin, Inc. operates no server that stores, processes, or has access to user data. Transcripts, analyses, vocabulary, and knowledge graphs remain on the user's device. Sync is via user-owned cloud storage (iCloud, OneDrive, Google Drive) with encryption before transmission.

**Alternatives Considered**:
- **Server-side storage with encryption**: data stored encrypted on Orin servers. Orin has the keys. Enables server-side search, analytics, backup. But creates a liability (breach risk), a regulatory burden (GDPR data controller responsibilities), and a trust problem (users must trust Orin's encryption claims).
- **Client-side encryption with server storage**: data encrypted on device, server stores ciphertext. Orin cannot read it. Harder to implement; still creates regulatory obligations (GDPR data processor).

**Rationale**: The only server that can be definitively trusted not to misuse data is a server that never receives data. By designing the system so that user data never leaves the device without going through user-owned cloud storage, Orin, Inc. eliminates: breach risk (no user data to breach), regulatory burden (not a data controller or processor for content), trust requirements (no "trust us" required), and compliance costs (HIPAA, GDPR, FCA automatically met for the data that matters).

**Consequences**:
- (+) Complete elimination of breach risk for user content
- (+) Regulatory compliance is an architectural property, not a process
- (+) No infrastructure cost proportional to user count
- (+) Strongest possible marketing claim: "your data never touches our servers"
- (−) No server-side search or analytics
- (−) No server-side backup if user loses device and has no cloud sync configured
- (−) Cannot train on user data (even with consent) without adding server infrastructure

**Trade-offs Accepted**: Server-side analytics, user behaviour data, and content-based features are permanently off the table for the core product. Accepted: these features are not compatible with the privacy-first positioning.

**Review Trigger**: A regulatory change requires server-side processing for a specific use case (e.g., mandatory retention for regulated industries). At that point, a separate, opt-in enterprise mode with compliant server-side processing may be introduced.

---

## ADR-011: iCloud Private Zone for Sync (Not Orin Servers)

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: Users with multiple Apple devices want their meetings to appear on all devices. A sync mechanism is required.

**Decision**: Use iCloud `CKContainer` private database (user-owned, Apple-managed, end-to-end encrypted for CloudKit) for multi-device sync on Apple platforms. This extends the "no user data on Orin servers" principle to sync.

**Alternatives Considered**:
- **Orin-operated sync server**: gives Orin, Inc. control over sync conflict resolution. Violates ADR-010.
- **Firebase/Firestore**: excellent real-time sync, but Orin would be entrusting user data to a third party.
- **Custom encrypted sync via S3**: possible, but requires Orin to operate key management infrastructure.

**Rationale**: iCloud private database is encrypted at rest, encrypted in transit, and managed by Apple. Data in the private database is accessible only to the user who owns the iCloud account. Orin, Inc. cannot access it even if subpoenaed (Apple holds keys for iCloud, but users can enable Advanced Data Protection for end-to-end encryption). This is the strongest available privacy model for sync without operating our own key management infrastructure.

**Consequences**:
- (+) Apple-managed encryption and key distribution
- (+) Users who already trust iCloud do not need to trust an additional party (Orin)
- (+) No Orin infrastructure required for sync
- (−) Apple platforms only (macOS + iOS) for iCloud sync; Windows needs OneDrive, Android needs Google Drive
- (−) Cannot access or debug user sync conflicts (by design)

**Trade-offs Accepted**: iCloud sync is Apple-platform-only. Windows sync requires OneDrive integration, and Android sync requires Google Drive integration.

**Review Trigger**: CloudKit's sync reliability or latency becomes a persistent user complaint. At that point, evaluate a self-hostable sync server as an option.

---

## ADR-012: PersistenceStore Protocol over SwiftData Dependency

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: `OrinCore` must be platform-agnostic (ADR-001). SwiftData is an Apple-platform-only framework. If `OrinCore` imports SwiftData, it cannot build on Windows or Android.

**Decision**: All persistence operations in `OrinCore` go through the `PersistenceStore` protocol. `SwiftDataPersistenceAdapter` is the macOS/iOS concrete implementation. Windows uses `GRDBPersistenceAdapter`. Android uses `RoomPersistenceAdapter` (Kotlin).

**Alternatives Considered**:
- **Keep SwiftData dependency in OrinCore**: simpler in the short term. Blocks cross-platform portability permanently.
- **Use GRDB for all platforms**: GRDB is cross-platform (Swift). Gives up SwiftData's `@Observable` integration and `@Query` macros, which are the primary UI benefits of SwiftData.

**Rationale**: SwiftData provides the best macOS/iOS UI integration (live `@Query` results, `@Observable` models). But it is Apple-only. The protocol approach lets macOS use SwiftData for its UI integration advantages while Windows and Android use GRDB or Room. `OrinCore` never sees the persistence implementation.

**Consequences**:
- (+) `OrinCore` is truly platform-agnostic
- (+) Each platform uses the best persistence technology for that platform
- (−) `@Query` SwiftUI macro is not available in `OrinCore` (only in platform-specific UI layer)
- (−) More indirection (all persistence goes through the protocol)

**Trade-offs Accepted**: `@Query` macros only available in platform-specific UI code, not in shared business logic. This is correct anyway — persistence queries are UI concerns.

**Review Trigger**: SwiftData adds cross-platform support (unlikely but possible if Apple adopts it for server-side Swift). At that point, the protocol approach can be simplified to a thin wrapper.

---

## ADR-013: Two-Tier Event Bus (In-Process + XPC for Plugins)

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: Internal bounded contexts need low-latency event delivery (< 1ms). Plugin contexts need crash-isolated event delivery (plugin crash must not affect internal contexts).

**Decision**: Two-tier event bus. Tier 1: in-process Swift actor for all core contexts (Session, Transcription, Intelligence, Knowledge, Learning, Vocabulary, Identity, Observability). Tier 2: XPC bridge for delivering events to Plugin and Integration contexts.

**Alternatives Considered**:
- **XPC for all events**: uniform, but adds 1-5ms latency to all event dispatch including internal core events. Unacceptable for high-frequency events (SegmentAdded during recording).
- **In-process for all events**: no crash isolation for plugins. A plugin crash can affect the event bus.

**Rationale**: Internal events need sub-millisecond dispatch — `SegmentAdded` fires 4-6 times per second during recording; XPC overhead would add up to 30ms/minute of unnecessary latency. Plugin events need crash isolation — a Linear integration plugin crashing must not interrupt live transcription. Two tiers provide both: fast + safe internally, isolated externally.

**Consequences**:
- (+) < 1ms internal event dispatch
- (+) Plugin crashes cannot corrupt the internal event bus
- (+) Plugins receive only events their capabilities allow (enforced at the XPC bridge)
- (−) Two code paths for event delivery (complexity)
- (−) Plugin event delivery has higher latency (1-5ms per event)

**Trade-offs Accepted**: Plugin event delivery latency is higher than internal event delivery. Acceptable because plugins are never on the real-time audio path.

---

## ADR-014: Whisper for ASR in Locales Not Supported by Apple

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: The target market includes significant Hinglish (Hindi-English code-switching) speakers in India. Apple's SpeechTranscriber and SFSpeechRecognizer support no Hindi (hi-IN) locale — this is an Apple platform constraint with no workaround. A significant user segment is unreachable without a non-Apple ASR option.

**Decision**: Integrate `WhisperASRBackend` (whisper.cpp HTTP server, same operational model as Ollama) as the ASR backend for locales not supported by Apple. User installs and runs a local whisper.cpp HTTP server; Orin connects to it.

**Alternatives Considered**:
- **Cloud-based Hindi ASR (Google Speech-to-Text, Azure Cognitive Services)**: high accuracy, but sends audio to external servers, violating the privacy-first principle. Requires consent, adds latency, requires network connectivity.
- **On-device Whisper via Core ML**: highest quality approach. Requires converting Whisper to Core ML format (Apple provides tools). Apple silicon ANE accelerates it. Not yet implemented — deferred to Phase 3.
- **Skip hi-IN support**: loses a significant market segment.

**Rationale**: Whisper supports 99 languages with good accuracy, is open source, runs locally, and follows the same operational pattern (local HTTP server) as Ollama — a pattern the target user is already familiar with. The "user must run a separate server" friction is a known trade-off but is lower than the alternative of sending audio to the cloud.

**Consequences**:
- (+) hi-IN and 96 other non-Apple languages become possible
- (+) All transcription remains local (no cloud)
- (+) User already familiar with running local AI servers (Ollama pattern)
- (−) User must install and run a separate whisper.cpp server
- (−) Setup friction compared to built-in SpeechTranscriber
- (−) Whisper model size (39MB–1.5GB) is an additional download

**Trade-offs Accepted**: Installation friction for non-Apple locales in exchange for privacy-preserving language coverage.

**Review Trigger**: Apple adds hi-IN or other high-priority missing locales to SpeechTranscriber. At that point, `ASRBackendRouter` automatically prefers SpeechTranscriber (higher quality, lower friction) without any code changes.

---

## ADR-015: Zero Telemetry by Default, Opt-In Anonymous Analytics

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: Understanding how users use the product is valuable for product decisions. But collecting telemetry without explicit consent violates the privacy-first principle and, in some jurisdictions, applicable law.

**Decision**: Zero telemetry is collected without user opt-in. An optional, anonymous analytics mode (crash counts, feature usage frequency — no content, no transcripts, no analysis, no knowledge graph data) can be enabled in Settings.

**Alternatives Considered**:
- **Opt-out telemetry**: collect by default, allow users to disable. Common industry practice. Violates privacy-first positioning.
- **Zero telemetry always**: no data to inform product decisions.
- **Differential privacy for usage analytics**: technically sophisticated approach to sharing statistics without exposing individuals. Complex to implement correctly.

**Rationale**: Collecting any data without consent is a trust violation for a privacy-first product. The product's primary users (privacy-conscious professionals, regulated industries) will notice and object to opt-out telemetry. The business value of usage data does not outweigh the positioning damage. If users opt in, basic aggregate analytics (feature popularity, crash rates) are sufficient for product decisions.

**Consequences**:
- (+) Complete privacy by default
- (+) No GDPR/CCPA consent banner required for core functionality
- (+) Trust-building: users know Orin genuinely respects privacy
- (−) No automatic visibility into production issues
- (−) Reliance on user-reported bug reports
- (−) Cannot measure feature adoption without surveys

**Trade-offs Accepted**: Blind to production behaviour without user reports. Mitigated by: local `Observability` context provides detailed on-device logs accessible to users for self-diagnosis and support.

---

## ADR-016: VocabularyContext 100-Term Budget with Explicit Allocation

**Status**: Accepted  
**Date**: 2026-06-30

**Context**: `SFSpeechRecognizer.contextualStrings` has an undocumented limit (~100 terms). The current code silently calls `.prefix(100)` on a 103-term array, dropping the last 6 built-in terms without any log or indicator. Silent truncation is a defect.

**Decision**: `VocabularyContext.build()` explicitly allocates the 100-term budget across tiers. If any tier is truncated, a `VocabularyBudgetExceeded` event is emitted and logged. No silent truncation.

**Alternatives Considered**:
- **Increase the limit**: not possible — the limit is in Apple's private API.
- **Remove the limit**: not possible.
- **Keep silent `.prefix(100)`**: simple but incorrect. Users cannot know why specific vocabulary terms aren't recognized.

**Rationale**: Silent truncation is always a bug, never a feature. The correct behaviour is explicit allocation with logging when the budget is exceeded. The four-tier system (Session 20% + User 40% + Org 30% + Built-in 10%) ensures the most relevant terms are included when the budget is tight.

**Consequences**:
- (+) Users can see exactly which terms are active in the session (debug view)
- (+) `VocabularyBudgetExceeded` events enable monitoring of vocabulary health
- (−) More complex `VocabularyContext.build()` logic

**Trade-offs Accepted**: None significant. The previous behavior was a bug.

---

## ADR-017: Kotlin Multiplatform for Android (Not Swift on Android)

**Status**: Proposed  
**Date**: 2026-06-30

**Context**: For Android support (Phase 4+), the question is whether to use Swift on Android (experimental) or reimplement `OrinCore` in Kotlin using Kotlin Multiplatform (KMP).

**Decision**: `OrinCore` is reimplemented in Kotlin for Android using Kotlin Multiplatform. The Swift `OrinCore` package and the Kotlin `OrinCore` module share the same specification (this architecture document series) and the same contract tests.

**Alternatives Considered**:
- **Swift on Android**: technically possible (swiftlang.org supports Android as an experimental target). But the Swift toolchain for Android is experimental, has limited library support, and is not ready for production use.
- **GraalVM Native Image**: compile Swift to native Android binary. Complex, limited Swift standard library support.
- **React Native or Flutter**: cross-platform UI frameworks. Do not solve the audio/ASR/inference layer problem, which is the hard part.

**Rationale**: Kotlin Multiplatform is mature and production-ready (JetBrains, Google). KMP shared modules build cleanly for Android (JVM/ART) and iOS (Kotlin/Native). The bounded context design means reimplementing `OrinCore` in Kotlin is a well-specified task (the domains, aggregates, events, and protocols are all defined). Contract tests that run against both implementations ensure semantic equivalence.

**Consequences**:
- (+) Production-quality Android runtime
- (+) Access to all Android JVM libraries (Room, ML Kit, AudioRecord)
- (+) KMP can also share code with iOS (targeting Kotlin/Native)
- (−) Two implementations of `OrinCore` (Swift + Kotlin) must be kept in sync
- (−) Feature parity requires explicit effort per feature added to Swift `OrinCore`

**Trade-offs Accepted**: Two implementations maintained in parallel. Mitigated by: shared specification (this document series) and cross-platform contract tests that fail if the implementations diverge semantically.

**Review Trigger**: Swift on Android reaches production-ready status (stable toolchain, full Foundation support). At that point, the Kotlin implementation could potentially be replaced by a single Swift implementation.

---

## ADR-018: MCP Integration via InferenceProvider Variant

**Status**: Proposed  
**Date**: 2026-06-30

**Context**: Model Context Protocol (MCP) is an emerging standard that allows AI models to call external tools. Orin's knowledge graph, transcript search, and action item tracking are natural MCP tools. Integrating MCP would allow AI agents (inside and outside Orin) to query Orin's data during analysis.

**Decision**: MCP integration is implemented as a specialised `InferenceProvider` variant (for consuming MCP servers as AI backends) and as an MCP tool server (exposing Orin's data to MCP clients). The existing `InferenceProvider` protocol and `KnowledgeQueryService` protocol are used — MCP is an adapter, not a new subsystem.

**Alternatives Considered**:
- **Separate MCP subsystem**: adds architectural complexity. The protocols already provide the right boundaries.
- **MCP only for external agents, not for internal Orin analysis**: missed opportunity to use Orin's own knowledge to enrich its own analysis.

**Rationale**: MCP tool-calling enriches Orin's analysis. During chunk processing, an MCP-capable model can call `search_knowledge_graph("John")` and retrieve all prior commitments, decisions, and meeting history for the entity "John" — producing analysis that is contextually aware of the user's professional history. The `InferenceProvider` protocol already handles the AI interaction layer; MCP adds tool-calling callbacks without requiring architectural changes.

**Consequences**:
- (+) Contextually-aware analysis (model knows prior history)
- (+) Orin becomes queryable by external AI agents
- (+) No new subsystem — adapters only
- (−) MCP servers must be trusted (they receive query access to knowledge graph and potentially transcript)
- (−) Tool-calling adds latency to inference (additional round-trips)

**Trade-offs Accepted**: Latency for tool-calling is acceptable because MCP-enhanced analysis is opt-in per model. Users who want faster analysis use non-MCP providers.

**Review Trigger**: MCP becomes a widely-adopted standard and external agents commonly query Orin. At that point, the MCP tool server becomes a higher-priority feature than document 09 Plugin SDK extensions.

---

## ADR Summary Table

| ADR | Decision | Status | Key Trade-off |
|-----|----------|--------|--------------|
| 001 | Hexagonal Architecture | Accepted | Protocol boilerplate ↔ cross-platform portability |
| 002 | Bounded contexts, not microservices | Accepted | Discipline required ↔ sub-millisecond IPC |
| 003 | Swift actors over GCD | Accepted | Migration cost ↔ compiler-enforced safety |
| 004 | Sequential local inference | Accepted | Longer analysis ↔ system stability |
| 005 | Event-driven cross-context communication | Accepted | Debug complexity ↔ loose coupling |
| 006 | XPC plugin sandboxing | Accepted | Plugin friction ↔ crash isolation |
| 007 | SQLite adjacency list for knowledge graph | Accepted | Graph algorithm complexity ↔ zero infra |
| 008 | Immutable segments + correction overlay | Accepted | Display complexity ↔ data completeness |
| 009 | Language-neutral section markers | Accepted | Fallback needed ↔ single parser for all languages |
| 010 | No server-side user data | Accepted | No analytics ↔ complete privacy |
| 011 | iCloud for sync, not Orin servers | Accepted | Apple-only ↔ no Orin server infrastructure |
| 012 | PersistenceStore protocol over SwiftData | Accepted | More indirection ↔ OrinCore portability |
| 013 | Two-tier event bus | Accepted | Two code paths ↔ fast + isolated |
| 014 | Whisper for non-Apple locales | Accepted | Install friction ↔ 99-language coverage |
| 015 | Zero telemetry by default | Accepted | Product blindness ↔ privacy-first trust |
| 016 | Explicit vocabulary budget allocation | Accepted | Build complexity ↔ no silent truncation |
| 017 | Kotlin Multiplatform for Android | Proposed | Two implementations ↔ production Android |
| 018 | MCP via InferenceProvider adapter | Proposed | Tool-call latency ↔ contextual analysis |

---

*This document represents the complete Architecture Decision Record set for Orin V2. New significant architectural decisions should be documented here before implementation begins.*
