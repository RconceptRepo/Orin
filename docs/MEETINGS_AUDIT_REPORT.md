# Meetings Subsystem — Forensic Audit Report

**Date:** 2026-05-30  
**Auditor:** Principal macOS Architect  
**Scope:** CalendarService, MeetingDetectorService, RecordingService, SystemAudioCaptureService, TranscriptStore, MeetingItem model, MeetingNotificationService, MainContainerView, MeetingsView, MeetingDetailView, MeetingIntelligenceService

---

## Dependency Map

```
CalendarService (EventKit)
    │
    ├─► MeetingDetectorService.detectFromCalendar()
    │       │
    │       ▼
    │   MeetingDetectorService (polls every 30 s / 3 s fast)
    │       │   onMeetingDetected → MeetingNotificationService
    │       │   onMeetingEnded   → MainContainerView auto-stop
    │       │   shouldShowRecordingPrompt → MeetingRecordingPromptView
    │       ▼
    │   MainContainerView.startRecordingFromDetectedMeeting()
    │       │
    │       ▼
    │   RecordingService (AVAudioEngine + SFSpeechRecognizer, "Me:")
    │   SystemAudioCaptureService (ScreenCaptureKit, "Participant:")
    │       │
    │       ▼
    │   TranscriptStore
    │       │  beginSession() / updateMic() / updateParticipant()
    │       │  checkpoint() every 3 s → MeetingItem.transcript (SwiftData)
    │       │  UserDefaults backup (orphan recovery)
    │       │  finalize() → final save + endSession()
    │       ▼
    │   MeetingItem (SwiftData)
    │       │
    │       ▼
    │   MeetingIntelligenceService (AI analysis → summary / decisions / actions)
    │
    └─► CalendarView (EventKit display, independent of MeetingItem)
```

---

## Bug Inventory

### BUG-01 — Meeting List Upcoming/Past Uses Wrong Cutoff
**Severity:** CRITICAL  
**File:** `Sources/Orin/Views/Meetings/MeetingsView.swift:373-385`

**Root Cause:**  
`upcomingUnfiled` and `pastUnfiled` filter on `Calendar.current.startOfDay(for: Date())`, not on `Date()`. Any meeting that started today (e.g., 9am) will remain in "Coming Up" all day even after it has ended, because `meeting.date >= startOfDay` is true throughout the day.

```swift
// BROKEN
let today = Calendar.current.startOfDay(for: Date())
return unfiledMeetings.filter { $0.date >= today }  // ← startOfDay, not now

// REQUIRED BY SPEC
// Upcoming = meeting.endDate > now (not yet fully over)
// Past     = meeting.endDate <= now (fully ended)
```

**Impact:** Today's completed meetings always show in "Coming Up". Meetings that ended yesterday appear in "Past" correctly, but same-day past meetings are misclassified.

**Fix:** Filter on `meeting.endDate` vs. `Date()`. Add computed `endDate` to `MeetingItem`.

---

### BUG-02 — Manual Recording Gated on Auto-Detection (Blocks All Manual Recording)
**Severity:** CRITICAL  
**Files:**  
- `Sources/Orin/Views/Meetings/MeetingsView.swift:422-427`  
- `Sources/Orin/Views/Meetings/MeetingsView.swift:1211-1216`

**Root Cause:**  
Both `MeetingsView.startManualRecording(for:)` and `MeetingDetailView.startRecording()` contain:
```swift
guard meetingDetector.detectedMeetingApp != nil else {
    // Show error, return early
    return
}
```
This means the user can ONLY start recording if `MeetingDetectorService` has an active meeting app in its detection window. If the user wants to record a manually created meeting, a phone call on AirPods, an in-person meeting, or any app not in the detector's list, recording is impossible.

**Impact:** All manual recording is broken for meetings not auto-detected. The record button shows an error "No active meeting detected" instead of starting.

**Fix:** Remove the guard entirely from manual recording paths. Auto-detection is a notification convenience; it must not gate manual use.

---

### BUG-03 — Calendar Events Not Shown in Upcoming Meetings Section
**Severity:** HIGH  
**Files:** `Sources/Orin/Views/Meetings/MeetingsView.swift` (no CalendarService observation)

**Root Cause:**  
`MeetingsView` only fetches `MeetingItem` records via `@Query`. It does not observe `CalendarService.events`. The "Coming Up" section is therefore empty until the user has manually created `MeetingItem` records or had meetings auto-detected. A user with a full calendar but no prior Orin meetings sees nothing.

**Impact:** "Upcoming meetings visible" requirement unmet for new users or users with calendar-only workflows.

**Fix:** Inject `CalendarService` into `MeetingsView`. Merge future `EKEvent` entries that don't have a corresponding `MeetingItem` (`externalEventIdentifier`) into the "Coming Up" section as calendar-only rows.

---

### BUG-04 — Calendar Background Sync Does Not Fire on Launch
**Severity:** HIGH  
**File:** `Sources/Orin/Services/CalendarService.swift:102-110`

**Root Cause:**  
`startBackgroundSync()` creates a repeating 15-minute timer but does not fire an immediate sync:
```swift
backgroundSyncTimer = Timer.scheduledTimer(
    withTimeInterval: Self.backgroundSyncInterval,  // 900 seconds
    repeats: true
) { ... }
// ← no immediate call to syncEvents()
```
The first sync happens 15 minutes after launch. `CalendarView` works around this via its own `initialSetup()` which calls `syncNow()` when `lastSyncTimestamp == nil`. But `MeetingDetectorService.detectFromCalendar()` calls `calendarService.events(from:to:)` which is a live EventKit query (correct — not stale). However, `CalendarView.selectedEvents` and any Meetings-based calendar display depend on `calendarService.events`, which remains empty until 15 minutes post-launch.

**Fix:** Call `Task { await syncEvents() }` immediately in `startBackgroundSync()` before arming the timer.

---

### BUG-05 — MeetingItem Has No `endDate` Property
**Severity:** HIGH  
**File:** `Sources/Orin/Models/OrinModels.swift:112-152`

**Root Cause:**  
`MeetingItem` has `date` (start) and `durationSeconds` but no computed `endDate`. The spec requires filtering on `endDate`. Every classification site (`upcomingUnfiled`, `pastUnfiled`, `isMeetingNow`) reimplements the same duration fallback inline with inconsistent values.

**Fix:** Add `var endDate: Date` computed property using `max(durationSeconds, 3600)` as fallback (matches existing `isMeetingNow` logic in `UpcomingMeetingItemRow`).

---

### BUG-06 — Auto-Stop Does Not Check Audio Inactivity
**Severity:** HIGH  
**File:** `Sources/Orin/App/MainContainerView.swift:100-113`

**Root Cause:**  
The auto-stop logic fires 1.5 s after `onMeetingEnded` regardless of whether the microphone or system audio was recently active:
```swift
meetingDetector.onMeetingEnded = {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        recordingService.stopRecording()   // ← no audio inactivity check
    }
}
```

Requirement: "Meeting must stop only when meeting no longer detected AND audio inactive for configurable period." A brief network blip that causes Zoom to disappear from the process list for 2 seconds would stop an active recording.

**Fix:** After grace period, check `transcriptStore.secondsSinceLastUpdate` before stopping. If audio was updated within the past N seconds (default 30), defer stop.

---

### BUG-07 — TranscriptStore beginSession Called Before Recording Is Confirmed
**Severity:** MEDIUM  
**Files:**  
- `Sources/Orin/Views/Meetings/MeetingsView.swift:430`  
- `Sources/Orin/Views/Meetings/MeetingsView.swift:1217-1218`

**Root Cause:**  
In both `startManualRecording` and `MeetingDetailView.startRecording`, `transcriptStore.beginSession` is called synchronously before `recordingService.startRecording()` (async). If recording fails (no microphone, HAL error, permissions denied), the TranscriptStore session remains open — the checkpoint timer fires every 3 seconds saving empty text, and the orphan recovery key is written but never cleared.

```swift
transcriptStore.beginSession(...)   // ← open BEFORE confirming recording
Task {
    await recordingService.startRecording(...)  // may fail
    // if failed: TranscriptStore session leaks
}
```

**Fix:** Move `beginSession` into the Task, after confirming `recordingService.isRecording == true`.

---

### BUG-08 — Duplicate Transcript Finalization
**Severity:** MEDIUM  
**Files:**  
- `Sources/Orin/App/MainContainerView.swift:147-164`  
- `Sources/Orin/Views/Meetings/MeetingsView.swift:960-968`

**Root Cause:**  
When recording stops while `MeetingDetailView` is visible, BOTH `MainContainerView` and `MeetingDetailView` call `transcriptStore.finalize()` in their `onChange(of: recordingService.isRecording)` handlers. This spawns two concurrent async tasks, each waiting 1.5 seconds. `TranscriptStore.finalize()` is idempotent (second call is a no-op), but the two sleeps run concurrently, wasting 1.5 s of CPU and producing confusing log output.

**Impact:** Benign due to idempotency, but wasteful.

**Fix:** The primary finalization path is `MainContainerView`. `MeetingDetailView` should only call `finalize()` when `MainContainerView` is not in scope (i.e., when the recording was started from the detail view only). Since `TranscriptStore` owns the session, `finalize()` is safe to call from either side — no code change strictly required. Documented as known pattern.

---

### BUG-09 — Transcript Persistence Relies Solely on 3-Second Timer and UserDefaults
**Severity:** MEDIUM  
**File:** `Sources/Orin/Services/TranscriptStore.swift`

**Root Cause:**  
Transcript data is persisted:
1. Every 3 seconds via `checkpointTimer` to `MeetingItem.transcript`
2. On every checkpoint, also to `UserDefaults` as orphan backup

On crash between checkpoints, up to 3 seconds of transcript can be lost. The UserDefaults backup is a single string (no history), so only the most recent checkpoint survives. There is no per-update granular persistence.

**Fix:** Add `TranscriptChunk` model. Write one chunk per `updateMic`/`updateParticipant` call when content grows ≥ 10 characters. Reconstruct from chunks on orphan recovery as an additional fallback beyond UserDefaults.

---

### BUG-10 — Meeting Detection Has No Confidence Scoring
**Severity:** MEDIUM  
**File:** `Sources/Orin/Services/MeetingDetectorService.swift`

**Root Cause:**  
Detection is binary: any positive signal from any source (native app, calendar, browser) immediately triggers the recording prompt and notification. There is no weighting or confidence threshold. A Zoom process running in the background (not in a meeting) or a calendar event with a Meet URL (meeting is tomorrow) could trigger false positives.

**Fix:** Add a `MeetingDetectionConfidence` scoring system. Sources: CalendarEvent (+40), MeetingURL (+30), RunningProcess (+25), MicrophoneActivity (+20), SystemAudioActivity (+20). Require threshold ≥ 40 to show prompt.

---

### BUG-11 — Past Meeting Sort Order Is Inconsistent
**Severity:** LOW  
**File:** `Sources/Orin/Views/Meetings/MeetingsView.swift:269-270`

**Root Cause:**  
`pastUnfiled` sorts ascending (`$0.date < $1.date` = oldest first), then the view calls `.reversed()`. But `groupByDay()` re-sorts the group keys ascending, discarding the reversal:
```swift
let groups = groupByDay(pastMeetings.reversed())  // reversal is lost
```
Result: past meetings show oldest-first (least useful order). Most recent past meetings should be at the top.

**Fix:** Sort `pastUnfiled` descending and fix `groupByDay()` to sort descending for past context, or sort the groups descending in `pastSection`.

---

### BUG-12 — `notifyRecordingActive` Banner Never Cleared on Stop
**Severity:** LOW  
**File:** `Sources/Orin/Services/MeetingNotificationService.swift:103-117`

**Root Cause:**  
`notifyRecordingActive()` posts a persistent notification (`identifier: "orin.recording.active"`). When recording stops, this notification is never removed. The user sees a stale "Recording in Progress" notification after every session. `clearMeetingDedupe()` removes it, but it is never called on recording stop.

**Fix:** Call `center.removeDeliveredNotifications(withIdentifiers: ["orin.recording.active"])` in a `notifyRecordingStopped()` helper, triggered from `MainContainerView.onChange(of: recordingService.isRecording)` when `isNow == false`.

---

## Affected Files Summary

| File | Bugs |
|---|---|
| `Sources/Orin/Views/Meetings/MeetingsView.swift` | BUG-01, BUG-02, BUG-03, BUG-07, BUG-11 |
| `Sources/Orin/Models/OrinModels.swift` | BUG-05 |
| `Sources/Orin/Services/CalendarService.swift` | BUG-04 |
| `Sources/Orin/App/MainContainerView.swift` | BUG-06, BUG-08 |
| `Sources/Orin/Services/TranscriptStore.swift` | BUG-07 (secondary), BUG-09 |
| `Sources/Orin/Services/MeetingDetectorService.swift` | BUG-10 |
| `Sources/Orin/Services/MeetingNotificationService.swift` | BUG-12 |
| `Sources/Orin/App/OrinApp.swift` | BUG-09 (schema) |

---

## Recommended Fix Priority

| Priority | Bug | Phase |
|---|---|---|
| 1 | BUG-02: Manual recording gate | Phase 2 |
| 2 | BUG-01, BUG-05: Meeting list filter + endDate | Phase 2 |
| 3 | BUG-03: Calendar events in Upcoming | Phase 2 |
| 4 | BUG-04: Calendar initial sync | Phase 2 |
| 5 | BUG-11: Past meeting sort | Phase 2 |
| 6 | BUG-09: TranscriptChunk persistence | Phase 3 |
| 7 | BUG-07: beginSession ordering | Phase 3 |
| 8 | BUG-10: Detection confidence | Phase 4 |
| 9 | BUG-06: Auto-stop audio inactivity | Phase 5 |
| 10 | BUG-12: Stale notification | Phase 5 |
| 11 | BUG-08: Duplicate finalization | Deferred (benign) |
