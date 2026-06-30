# Document M-05: Event Catalog

**Series**: Orin V2 Migration Planning  
**Document**: 5 of 8  
**Status**: Accepted  
**Date**: 2026-06-30  
**Author**: Chief Software Architect

---

## Overview

This is the definitive reference for all domain events in the Orin V2 event-driven architecture. Every event emitted on the `EventBus` is catalogued here with its producer, consumers, payload schema, ordering guarantee, retry policy, and failure handling.

**V2 Reference**: Document 02 (Event-Driven Architecture), ADR-005

### Conventions

| Symbol | Meaning |
|--------|---------|
| `→` | flows to |
| `P` | Producer |
| `C` | Consumer |
| `required` | field must be present; nil or missing is a publish-time error |
| `optional` | field may be omitted |

### Ordering Guarantees

- **Session**: All events with the same `sessionID` are emitted in causal order within a single actor. Across actors, ordering is best-effort; consumers must not assume strict total ordering across sessions.
- **Analysis**: `AnalysisQueued` → `AnalysisStarted` → (`ChunkAnalyzed` × N) → `AnalysisCompleted | AnalysisFailed` is the guaranteed happy-path sequence for a given `meetingID`.
- **Vocabulary**: Correction and promotion events are causal but not atomic. A `VocabularyPromotionAccepted` event always follows a `VocabularyCorrectionRecorded` event on the same term, but the gap is user-driven and may span sessions.
- **Knowledge**: Graph events are emitted after persistence. A subscriber that acts on `EntityLinked` can assume the graph has already been written.

### Retry Policy Defaults (unless overridden per event)

| Tier | Max retries | Backoff | Dead-letter? |
|------|------------|---------|-------------|
| Critical | 3 | 500ms × 2ⁿ | Yes |
| Standard | 2 | 200ms × 2ⁿ | No |
| Advisory | 0 | N/A | No |

---

## Session Context Events

---

### `SessionStarted`

**Tier**: Critical  
**V2 Reference**: Document 02 §3.1, Document 04 §2

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessionID` | `UUID` | yes | Unique identifier for this recording session |
| `startedAt` | `Date` | yes | Monotonic timestamp of session start |
| `audioLocale` | `Locale` | yes | Configured speech recognition locale |
| `participantMode` | `ParticipantMode` | yes | `.micOnly`, `.systemAudio`, `.mixed` |
| `meetingContext` | `MeetingContext?` | no | Calendar-derived context if available |

**Producer**: `SessionStateMachine` (transition `Idle → Starting`)  
**Consumers**:
- `AnalysisCoordinator` — initializes analysis job record
- `SessionLogger` — opens log file for this session
- `AnalysisPerfLogger` — records session start timestamp
- `KnowledgeQueryService` — pre-warms entity cache for detected participants

**Ordering**: First event in any session's causal chain. Must precede all other session events with same `sessionID`.  
**Retry**: Critical (3 retries, dead-lettered on exhaustion)  
**Failure handling**: If no consumer ACKs within 5s, `SessionStateMachine` transitions to `Failed`. Session is NOT started until event is confirmed delivered to `SessionLogger` (at minimum).

---

### `SessionStopped`

**Tier**: Critical  
**V2 Reference**: Document 02 §3.1, Document 04 §2

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessionID` | `UUID` | yes | Session being stopped |
| `stoppedAt` | `Date` | yes | Timestamp of stop request |
| `stoppedBy` | `StopReason` | yes | `.user`, `.meetingEnd`, `.error`, `.timeout` |
| `totalDurationSeconds` | `Double` | yes | Wall-clock recording duration |

**Producer**: `SessionStateMachine` (transition `Active → Stopping`)  
**Consumers**:
- `RecordingSessionCoordinator` — flushes pending audio buffers
- `ASRSessionStateMachine` — transitions to `Finalizing`
- `SessionLogger` — marks session as stopped; starts finalization log

**Ordering**: Follows `SessionStarted` for same `sessionID`. Precedes `SessionFinalized`.  
**Retry**: Critical  
**Failure handling**: `ASRSessionStateMachine` must begin finalization regardless. If coordinator fails to flush, session marked `incomplete`.

---

### `SessionFinalized`

**Tier**: Critical  
**V2 Reference**: Document 02 §3.1, Document 04 §2

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessionID` | `UUID` | yes | Session being finalized |
| `meetingID` | `UUID` | yes | Persisted `MeetingItem` identifier |
| `finalizedAt` | `Date` | yes | Timestamp of full finalization |
| `transcriptSegmentCount` | `Int` | yes | Total segments in final transcript |
| `detectedLocale` | `Locale` | yes | Locale detected by `NLLanguageRecognizer` |
| `durationSeconds` | `Double` | yes | Total recording duration |

**Producer**: `RecordingSessionCoordinator` (after `PersistenceStore.save()` succeeds)  
**Consumers**:
- `AnalysisCoordinator` — triggers `AnalysisQueued` for this meeting
- `KnowledgeGraph` (Phase 4) — queues entity extraction job
- `MeetingPatternLearner` (Phase 4) — updates meeting pattern statistics
- `AnalysisPerfLogger` — records finalization timestamp
- `SessionLogger` — closes log file

**Ordering**: Last event in session causal chain. Always follows `SessionStopped`.  
**Retry**: Critical  
**Failure handling**: If persistence failed, `SessionFinalized` is NOT emitted. The session is recorded in the dead-letter log as `PersistenceFailed`.

---

### `SessionFailed`

**Tier**: Critical  
**V2 Reference**: Document 02 §3.1, Document 04 §2

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessionID` | `UUID` | yes | Session that failed |
| `failedAt` | `Date` | yes | Timestamp of failure detection |
| `error` | `SessionError` | yes | Typed error with associated value |
| `recoverable` | `Bool` | yes | Whether restart is safe |

**Producer**: `SessionStateMachine` (transition to `Failed` from any active state)  
**Consumers**:
- `RecordingSessionCoordinator` — tears down audio pipeline
- `SessionLogger` — logs failure with full context
- `UIEventHandler` — shows error notification to user

**Ordering**: Terminal session event. Nothing follows for same `sessionID`.  
**Retry**: Advisory (0 retries; failure already happened)  
**Failure handling**: If `recoverable == true`, `SessionStateMachine` may be restarted by user action.

---

## Transcription Events

---

### `SegmentAdded`

**Tier**: Standard  
**V2 Reference**: Document 02 §3.2

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessionID` | `UUID` | yes | Session this segment belongs to |
| `segment` | `TranscriptSegment` | yes | Segment with text, timestamps, confidence, speaker |
| `segmentIndex` | `Int` | yes | Monotonically increasing index within session |
| `isFinal` | `Bool` | yes | False = interim hypothesis; true = committed |

**Producer**: `SpeechTranscriberASRAdapter`, `SFSpeechASRAdapter`, `WhisperASRBackend`  
**Consumers**:
- `TranscriptStore` — persists segment (only when `isFinal == true`)
- `LiveTranscriptView` — updates UI in real time (interim + final)
- `VocabularyProvider` — scans for new correction candidates

**Ordering**: `segmentIndex` provides ordering guarantee within a session. Interim segments (same index, `isFinal == false`) may arrive multiple times; only the final segment at each index is authoritative.  
**Retry**: Standard  
**Failure handling**: `TranscriptStore` failure on `isFinal == true` → segment placed in in-memory retry queue; 3 retries before `TranscriptError.segmentLost` logged.

---

### `TranscriptFinalized`

**Tier**: Critical  
**V2 Reference**: Document 02 §3.2

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessionID` | `UUID` | yes | Session |
| `meetingID` | `UUID` | yes | Persisted meeting |
| `totalSegments` | `Int` | yes | Count of committed final segments |
| `fullText` | `String` | yes | Concatenated transcript text for analysis |
| `detectedLocale` | `Locale` | yes | Detected primary language |

**Producer**: `ASRSessionStateMachine` (transition `Finalizing → Completed`)  
**Consumers**:
- `RecordingSessionCoordinator` — triggers `SessionFinalized`
- `TranscriptStore` — final consistency check; writes completeness flag

**Ordering**: Follows all `SegmentAdded` events for same `sessionID`.  
**Retry**: Critical  
**Failure handling**: If `TranscriptStore` consistency check fails, `TranscriptFinalizationFailed` emitted (see below).

---

### `TranscriptFinalizationFailed`

**Tier**: Critical  
**V2 Reference**: Document 02 §3.2

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessionID` | `UUID` | yes | Session |
| `missedSegments` | `[Int]` | yes | Indexes of segments not committed to store |
| `recoveryAction` | `RecoveryAction` | yes | `.retryFromMemory`, `.markIncomplete`, `.discard` |

**Producer**: `TranscriptStore`  
**Consumers**:
- `SessionLogger` — records missed segments and recovery decision
- `UIEventHandler` — displays partial transcript warning

**Ordering**: Replaces `TranscriptFinalized` if finalization fails.  
**Retry**: Advisory  
**Failure handling**: System attempts `.retryFromMemory` first; if in-memory cache evicted, falls back to `.markIncomplete`.

---

## Analysis Events

---

### `AnalysisQueued`

**Tier**: Standard  
**V2 Reference**: Document 02 §3.3, Document 05 §3

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `meetingID` | `UUID` | yes | Meeting to analyze |
| `queuedAt` | `Date` | yes | Timestamp |
| `priority` | `AnalysisPriority` | yes | `.immediate`, `.background`, `.deferred` |
| `estimatedChunks` | `Int` | yes | Based on transcript length |

**Producer**: `AnalysisCoordinator` (on receipt of `SessionFinalized`)  
**Consumers**:
- `InferenceWorker` — adds job to serial queue
- `AnalysisPerfLogger` — records queue entry time
- `MeetingListView` — updates meeting status badge to `.queued`

**Ordering**: Follows `SessionFinalized` for same `meetingID`.  
**Retry**: Standard  
**Failure handling**: If `InferenceWorker` rejects job (circuit open), `priority` downgraded to `.deferred`; `AnalysisQueued` re-emitted with updated priority after 60s backoff.

---

### `AnalysisStarted`

**Tier**: Standard  
**V2 Reference**: Document 02 §3.3, Document 05 §3

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `meetingID` | `UUID` | yes | |
| `startedAt` | `Date` | yes | Dequeue timestamp |
| `chunkCount` | `Int` | yes | Total chunks to process |
| `modelID` | `String` | yes | Ollama model ID in use (e.g. `phi3`) |
| `inferenceProviderID` | `String` | yes | From `InferenceProvider.providerID` |

**Producer**: `InferenceWorker` (when job begins execution)  
**Consumers**:
- `AnalysisPerfLogger` — records start; begins per-chunk timing
- `MeetingListView` — updates status badge to `.running`

**Ordering**: Follows `AnalysisQueued` for same `meetingID`.  
**Retry**: Standard  
**Failure handling**: If provider goes offline after `AnalysisStarted`, `AnalysisFailed` emitted with `.providerUnavailable` reason.

---

### `ChunkAnalyzed`

**Tier**: Standard  
**V2 Reference**: Document 02 §3.3, Document 05 §5

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `meetingID` | `UUID` | yes | |
| `chunkIndex` | `Int` | yes | Zero-based chunk number |
| `totalChunks` | `Int` | yes | Total expected chunks |
| `chunkDurationSeconds` | `Double` | yes | Duration of audio represented by this chunk |
| `inferenceLatencyMs` | `Double` | yes | Time from job enqueue to completion for this chunk |
| `outputTokens` | `Int` | yes | Tokens in model response |
| `partial` | `ChunkAnalysisResult` | yes | Summaries, action items, decisions from this chunk alone |

**Producer**: `InferenceWorker` (after each chunk completes)  
**Consumers**:
- `AnalysisPerfLogger` — records per-chunk latency; accumulates token totals
- `TranscriptDetailView` — streaming progress update

**Ordering**: `chunkIndex` is authoritative ordering within a `meetingID`. Chunks are processed serially (by `InferenceWorker`), but events may arrive slightly out of order due to bus scheduling.  
**Retry**: Advisory (chunk already completed; re-emitting is informational only)  
**Failure handling**: Consumer should tolerate duplicate `ChunkAnalyzed` events for same `(meetingID, chunkIndex)`.

---

### `AnalysisCompleted`

**Tier**: Critical  
**V2 Reference**: Document 02 §3.3, Document 05 §6

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `meetingID` | `UUID` | yes | |
| `completedAt` | `Date` | yes | |
| `totalInferenceMs` | `Double` | yes | Wall-clock time for all chunks |
| `totalTokens` | `Int` | yes | Sum of all output tokens |
| `summaryWordCount` | `Int` | yes | |
| `actionItemCount` | `Int` | yes | |
| `decisionCount` | `Int` | yes | |
| `effectiveActionItemCount` | `Int` | yes | After dedup; matches `MeetingItem.effectiveActionItemCount` |
| `responseLanguage` | `String` | yes | BCP-47 language tag (e.g. `en`, `hi`) |

**Producer**: `AnalysisCoordinator` (after all chunks synthesized and persisted)  
**Consumers**:
- `AnalysisPerfLogger` — records final metrics; logs to `os_signpost`
- `MeetingListView` — updates status badge to `.completed`
- `KnowledgeGraph` (Phase 4) — triggers entity extraction using analysis output
- `LearningEngine` (Phase 4) — records analysis quality for model feedback

**Ordering**: Follows all `ChunkAnalyzed` events for same `meetingID`.  
**Retry**: Critical  
**Failure handling**: Duplicate delivery tolerated; consumers check `MeetingItem.analysisStatus` before re-acting.

---

### `AnalysisFailed`

**Tier**: Critical  
**V2 Reference**: Document 02 §3.3, Document 05 §6

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `meetingID` | `UUID` | yes | |
| `failedAt` | `Date` | yes | |
| `reason` | `AnalysisFailureReason` | yes | `.providerUnavailable`, `.modelError`, `.contextTooLarge`, `.timeout`, `.cancelled` |
| `completedChunks` | `Int` | yes | How many chunks finished before failure |
| `retryable` | `Bool` | yes | Whether the failure warrants an automatic retry |

**Producer**: `InferenceWorker` (circuit breaker trips) or `AnalysisCoordinator` (synthesis failure)  
**Consumers**:
- `MeetingListView` — shows error badge; retry affordance if `retryable == true`
- `SessionLogger` — logs failure with reason
- `AnalysisCoordinator` — resets `InferenceWorker` circuit if appropriate

**Ordering**: Terminal analysis event for a `meetingID`. A subsequent `AnalysisQueued` can restart the flow.  
**Retry**: Standard (if `retryable == true`, `AnalysisCoordinator` re-queues after 30s)  
**Failure handling**: After 3 automatic retries, status set to `.deferred`; user must manually trigger retry.

---

## Vocabulary and Learning Events

---

### `VocabularyCorrectionRecorded`

**Tier**: Standard  
**V2 Reference**: Document 06 §3, Document 02 §3.5

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `correctionID` | `UUID` | yes | Unique ID for this correction record |
| `originalText` | `String` | yes | What ASR transcribed |
| `correctedText` | `String` | yes | What the user typed |
| `context` | `String` | yes | ±50 chars of surrounding transcript text |
| `sessionID` | `UUID` | yes | Session where the error occurred |
| `meetingID` | `UUID` | yes | |
| `languageCode` | `String` | yes | BCP-47 of the segment being corrected |
| `correctedAt` | `Date` | yes | |

**Producer**: `TranscriptDetailView` (user submits inline correction)  
**Consumers**:
- `CorrectionStore` (Phase 4) — persists correction record
- `PromotionEngine` (Phase 4) — evaluates whether correction threshold met
- `VocabularyProvider` — increments correction count for existing vocabulary term if present

**Ordering**: Causal (must precede `VocabularyPromotionSuggested` for same `originalText`)  
**Retry**: Standard  
**Failure handling**: If `CorrectionStore` write fails, event placed in 3-retry dead-letter. User shown: "Correction will be applied when storage is available."

---

### `VocabularyPromotionSuggested`

**Tier**: Advisory  
**V2 Reference**: Document 06 §4, Document 02 §3.5

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `term` | `String` | yes | Vocabulary term being proposed |
| `languageCode` | `String` | yes | BCP-47 |
| `correctionCount` | `Int` | yes | Number of corrections that triggered this |
| `sourceSessionIDs` | `[UUID]` | yes | Sessions where correction was observed |
| `suggestedTier` | `VocabularyTier` | yes | `.core`, `.domain`, `.custom` |
| `proposedAt` | `Date` | yes | |

**Producer**: `PromotionEngine` (Phase 4)  
**Consumers**:
- `SettingsView` — adds badge to Vocabulary settings section
- `NotificationService` — sends system notification (if user opted in)

**Ordering**: Follows at least one `VocabularyCorrectionRecorded` for same `term`.  
**Retry**: Advisory (0 retries; re-evaluated on next correction)  
**Failure handling**: Failure to deliver to UI is non-critical. Promotion suggestion persisted in `PromotionEngine` and re-evaluated on next app launch.

---

### `VocabularyPromotionAccepted`

**Tier**: Standard  
**V2 Reference**: Document 06 §4

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `term` | `String` | yes | Term accepted into vocabulary |
| `languageCode` | `String` | yes | BCP-47 |
| `tier` | `VocabularyTier` | yes | Final assigned tier |
| `acceptedAt` | `Date` | yes | |
| `acceptedBy` | `AcceptedBy` | yes | `.user`, `.autoPromotion` |

**Producer**: `SettingsView` (user taps Accept) or `PromotionEngine` (auto-promotion threshold)  
**Consumers**:
- `VocabularyProvider` — creates `VocabularyItem` record at specified tier
- `ASRBackendRouter` — rebuilds vocabulary context for current locale
- `CorrectionStore` (Phase 4) — archives related corrections

**Ordering**: Follows `VocabularyPromotionSuggested` for same `term`.  
**Retry**: Standard  
**Failure handling**: If `VocabularyItem` creation fails, event dead-lettered and user notified.

---

### `VocabularyPromotionRejected`

**Tier**: Advisory  
**V2 Reference**: Document 06 §4

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `term` | `String` | yes | Term rejected |
| `languageCode` | `String` | yes | |
| `rejectedAt` | `Date` | yes | |

**Producer**: `SettingsView` (user taps Reject)  
**Consumers**:
- `PromotionEngine` (Phase 4) — adds term to rejection list (not re-suggested for 30 days)

**Ordering**: Follows `VocabularyPromotionSuggested`.  
**Retry**: Advisory  
**Failure handling**: None required.

---

### `VocabularyBudgetExceeded`

**Tier**: Advisory  
**V2 Reference**: Document 07 §8, M-04 EPIC-21

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessionID` | `UUID` | yes | Session where this occurred |
| `totalTermsRequested` | `Int` | yes | Terms requested before truncation |
| `budgetLimit` | `Int` | yes | Always 100 per ADR-016 |
| `droppedTerms` | `[String]` | yes | Exact terms dropped by tier allocation |
| `droppedTiers` | `[VocabularyTier]` | yes | Tier each dropped term belonged to |

**Producer**: `VocabularyContext.build()` (Phase 3)  
**Consumers**:
- `SessionLogger` — logs dropped terms for diagnostic review
- `SettingsView` — shows vocabulary overflow warning banner (debounced; once per session)

**Ordering**: Emitted during session initialization; precedes `SessionStarted`.  
**Retry**: Advisory  
**Failure handling**: None. Session proceeds; logging is the only action required.

---

## Knowledge Graph Events (Phase 4)

---

### `EntityExtracted`

**Tier**: Standard  
**V2 Reference**: Document 08 §4, Document 02 §3.6

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `meetingID` | `UUID` | yes | Source meeting |
| `entities` | `[ExtractedEntity]` | yes | Typed entities (Person, Org, Project, etc.) |
| `extractedAt` | `Date` | yes | |

**Producer**: `NLTaggerEntityExtractor` (Phase 4)  
**Consumers**:
- `EntityResolver` (Phase 4) — resolves extracted entities against graph
- `KnowledgeQueryService` — invalidates relevant cached queries

**Ordering**: Follows `AnalysisCompleted` for same `meetingID`.  
**Retry**: Standard  
**Failure handling**: Failed extraction logged; `KnowledgeGraph` continues without this meeting's entities. No user notification.

---

### `EntityLinked`

**Tier**: Standard  
**V2 Reference**: Document 08 §5

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sourceEntityID` | `UUID` | yes | Graph node ID |
| `targetEntityID` | `UUID` | yes | Graph node ID |
| `relationship` | `String` | yes | Edge type (e.g. `mentioned_with`, `reports_to`, `works_on`) |
| `meetingID` | `UUID` | yes | Source meeting that established this link |
| `confidence` | `Float` | yes | 0.0–1.0 |

**Producer**: `EntityResolver` (Phase 4)  
**Consumers**:
- `KnowledgeQueryService` — invalidates cached subgraph queries
- `SessionLogger` — diagnostic logging at debug level only

**Ordering**: Follows `EntityExtracted` for same `meetingID`.  
**Retry**: Standard  
**Failure handling**: Duplicate link events for same `(sourceEntityID, targetEntityID, relationship)` are idempotent; `KnowledgeGraph` treats them as no-ops.

---

## Meeting Detection Events

---

### `MeetingDetected`

**Tier**: Standard  
**V2 Reference**: Document 02 §3.1 (implicit in meeting detection flow)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `detectedAt` | `Date` | yes | |
| `source` | `DetectionSource` | yes | `.calendar`, `.audioActivity`, `.manual` |
| `confidence` | `Float` | yes | 0.0–1.0 |
| `meetingContext` | `MeetingContext?` | no | Calendar event details if `.calendar` source |

**Producer**: `MeetingDetectorService`  
**Consumers**:
- `RecordingSessionCoordinator` — triggers auto-record if setting enabled
- `OverlayView` — shows "Meeting detected" notification
- `SessionLogger` — records detection event

**Ordering**: Not constrained relative to other events; independent detection signal.  
**Retry**: Advisory  
**Failure handling**: If coordinator fails to respond, overlay still shown. Auto-record failure surfaced as `SessionFailed`.

---

### `MeetingEnded`

**Tier**: Standard  
**V2 Reference**: Document 02 §3.1

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `endedAt` | `Date` | yes | |
| `source` | `DetectionSource` | yes | `.calendar`, `.audioSilence`, `.manual` |
| `detectedSilenceDurationSeconds` | `Double?` | no | For `.audioSilence` source |

**Producer**: `MeetingDetectorService`  
**Consumers**:
- `RecordingSessionCoordinator` — triggers auto-stop if auto-record active

**Ordering**: Follows `MeetingDetected` (logically).  
**Retry**: Advisory  
**Failure handling**: Auto-stop failure → user notified; session continues until manual stop.

---

## Observability Events

---

### `PerformanceSampleRecorded`

**Tier**: Advisory  
**V2 Reference**: Document 11 §9, Document 02 §3.8

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `subsystem` | `OrinSubsystem` | yes | Enum of subsystem being measured |
| `metric` | `String` | yes | Metric name (e.g. `inferenceLatencyMs`) |
| `value` | `Double` | yes | Measured value |
| `unit` | `String` | yes | Unit string (e.g. `ms`, `percent`, `bytes`) |
| `budget` | `Double?` | no | Budget limit if applicable |
| `exceeded` | `Bool` | yes | Whether budget was exceeded |
| `sampledAt` | `Date` | yes | |

**Producer**: `AnalysisPerfLogger`, performance monitoring hooks throughout the codebase  
**Consumers**:
- `MetricsAggregator` — accumulates samples per session; surfaces in debug UI
- `SessionLogger` — records to log file at debug level

**Ordering**: Unordered; consumers must handle out-of-order delivery.  
**Retry**: Advisory (0 retries; metric data is best-effort)  
**Failure handling**: Dropped metrics are acceptable; these are diagnostic instruments, not application state.

---

### `ResourceBudgetExceeded`

**Tier**: Standard  
**V2 Reference**: Document 11 §5

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `subsystem` | `OrinSubsystem` | yes | Which subsystem breached |
| `metric` | `String` | yes | Which budget metric |
| `actual` | `Double` | yes | Measured value |
| `budget` | `Double` | yes | Allowed budget |
| `exceededBy` | `Double` | yes | `actual - budget` |
| `detectedAt` | `Date` | yes | |

**Producer**: Performance monitoring actors  
**Consumers**:
- `SessionLogger` — always logs; treated as a warning if < 2× budget, error if ≥ 2×
- `DebugOverlay` — shows real-time budget gauge in developer builds

**Ordering**: Unordered.  
**Retry**: Standard  
**Failure handling**: None; this is a diagnostic event, not application-critical.

---

## Event Summary Table

| Event | Tier | Producer | Phase Introduced |
|-------|------|----------|-----------------|
| `SessionStarted` | Critical | `SessionStateMachine` | Phase 2 |
| `SessionStopped` | Critical | `SessionStateMachine` | Phase 2 |
| `SessionFinalized` | Critical | `RecordingSessionCoordinator` | Phase 2 |
| `SessionFailed` | Critical | `SessionStateMachine` | Phase 2 |
| `SegmentAdded` | Standard | `ASRBackend adapters` | Phase 2 |
| `TranscriptFinalized` | Critical | `ASRSessionStateMachine` | Phase 2 |
| `TranscriptFinalizationFailed` | Critical | `TranscriptStore` | Phase 2 |
| `AnalysisQueued` | Standard | `AnalysisCoordinator` | Phase 2 |
| `AnalysisStarted` | Standard | `InferenceWorker` | Phase 2 |
| `ChunkAnalyzed` | Standard | `InferenceWorker` | Phase 2 |
| `AnalysisCompleted` | Critical | `AnalysisCoordinator` | Phase 2 |
| `AnalysisFailed` | Critical | `InferenceWorker / AnalysisCoordinator` | Phase 2 |
| `VocabularyCorrectionRecorded` | Standard | `TranscriptDetailView` | Phase 3 |
| `VocabularyPromotionSuggested` | Advisory | `PromotionEngine` | Phase 4 |
| `VocabularyPromotionAccepted` | Standard | `SettingsView / PromotionEngine` | Phase 4 |
| `VocabularyPromotionRejected` | Advisory | `SettingsView` | Phase 4 |
| `VocabularyBudgetExceeded` | Advisory | `VocabularyContext` | Phase 3 |
| `EntityExtracted` | Standard | `NLTaggerEntityExtractor` | Phase 4 |
| `EntityLinked` | Standard | `EntityResolver` | Phase 4 |
| `MeetingDetected` | Standard | `MeetingDetectorService` | Phase 2 |
| `MeetingEnded` | Standard | `MeetingDetectorService` | Phase 2 |
| `PerformanceSampleRecorded` | Advisory | Various | Phase 2 |
| `ResourceBudgetExceeded` | Standard | Monitoring actors | Phase 2 |

**Total events catalogued**: 23  
**Critical**: 7  
**Standard**: 11  
**Advisory**: 5
