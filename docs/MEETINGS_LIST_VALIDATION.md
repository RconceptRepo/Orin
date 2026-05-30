# Meetings List Validation

**Date:** 2026-05-30  
**Phase:** 2 — Calendar sync and Meeting list (Upcoming / Past)

---

## Changes Made

### 1. `MeetingItem.endDate` (new computed property)

**File:** `Sources/Orin/Models/OrinModels.swift`

```swift
var endDate: Date {
    date.addingTimeInterval(durationSeconds > 0 ? durationSeconds : 3600)
}
var isInProgress: Bool {
    let now = Date()
    return date <= now && endDate > now
}
```

Uses 1-hour default when `durationSeconds == 0`, matching the existing `UpcomingMeetingItemRow.isMeetingNow` calculation.

---

### 2. Fixed `upcomingUnfiled` and `pastUnfiled` Filters

**File:** `Sources/Orin/Views/Meetings/MeetingsView.swift`

| | Before (broken) | After (correct) |
|---|---|---|
| **Upcoming** | `meeting.date >= startOfDay(today)` | `meeting.endDate > now` |
| **Past** | `meeting.date < startOfDay(today)` | `meeting.endDate <= now` |
| **Sort (Past)** | Ascending → `.reversed()` (cancelled by `groupByDay`) | Descending, most recent first |

**Result:** Today's completed meetings now appear in Past immediately when they end. In-progress meetings remain in Coming Up until they end.

---

### 3. Fixed Past Meeting Sort Order

**File:** `Sources/Orin/Views/Meetings/MeetingsView.swift`

`groupByDay` now accepts a `descending: Bool` parameter. Past section calls `groupByDay(pastMeetings, descending: true)`, showing the most recent past meetings at the top. The broken `.reversed()` call before `groupByDay` (which was then re-sorted ascending, discarding the reversal) is removed.

---

### 4. Removed Manual Recording Gate (BUG-02)

**Files:**
- `Sources/Orin/Views/Meetings/MeetingsView.swift` — `startManualRecording(for:)`
- `Sources/Orin/Views/Meetings/MeetingsView.swift` — `MeetingDetailView.startRecording()`

The `guard meetingDetector.detectedMeetingApp != nil` check was removed from both manual recording paths. Recording now starts for any meeting regardless of detection state. Auto-detection is preserved as a prompt/notification feature only.

---

### 5. Fixed TranscriptStore Session Ordering (BUG-07)

**File:** `Sources/Orin/Views/Meetings/MeetingsView.swift`

`transcriptStore.beginSession()` is now called **after** `recordingService.startRecording()` confirms `isRecording == true`. If recording fails (permission denied, no mic), no orphan session is leaked.

---

### 6. Calendar Events in "Coming Up" Section (BUG-03)

**File:** `Sources/Orin/Views/Meetings/MeetingsView.swift`

Added `calendarOnlyUpcomingEvents` computed property:
```swift
private var calendarOnlyUpcomingEvents: [EKEvent] {
    let now = Date()
    let knownIdentifiers = Set(allMeetings.compactMap { $0.externalEventIdentifier })
    return calendarService.events
        .filter { event in
            event.startDate > now &&
            !knownIdentifiers.contains(event.eventIdentifier ?? "")
        }
        .sorted { $0.startDate < $1.startDate }
}
```

Calendar events that have no corresponding `MeetingItem` appear in "Coming Up" as `CalendarOnlyEventRow` entries. Tapping "Open" creates a linked `MeetingItem`. This satisfies "Support: calendar meetings" for users who have EventKit events but haven't yet started Orin recording.

---

### 7. Calendar Background Sync Fires on Launch (BUG-04)

**File:** `Sources/Orin/Services/CalendarService.swift`

```swift
func startBackgroundSync() {
    guard backgroundSyncTimer == nil else { return }
    Task { @MainActor [weak self] in await self?.syncEvents() }  // ← immediate
    backgroundSyncTimer = Timer.scheduledTimer(...)
}
```

First sync now fires at app launch instead of 15 minutes later.

---

## Validation Test Results

### Test Suite: `MeetingListClassificationTests`

| Test | Result |
|---|---|
| `testEndDateWithDurationIsStartPlusDuration` | ✅ PASS |
| `testEndDateWithZeroDurationDefaultsToOneHour` | ✅ PASS |
| `testFutureMeetingIsUpcoming` | ✅ PASS |
| `testInProgressMeetingIsStillUpcoming` | ✅ PASS |
| `testMeetingThatJustEndedIsPast` | ✅ PASS |
| `testMeetingWithZeroDurationThatStartedMoreThanOneHourAgoIsPast` | ✅ PASS |
| `testSameDayPastMeetingIsNotUpcoming` (**BUG-01 regression**) | ✅ PASS |
| `testIsInProgressTrueForCurrentMeeting` | ✅ PASS |
| `testIsInProgressFalseForFutureMeeting` | ✅ PASS |
| `testIsInProgressFalseForPastMeeting` | ✅ PASS |

### Test Suite: `MeetingItemEndDateTests`

| Test | Result |
|---|---|
| `testEndDateEqualsDurationZeroDefaultsOneHour` | ✅ PASS |
| `testEndDateWithLongDuration` | ✅ PASS |
| `testMeetingWithExactlyOneHourDurationEndDateMatchesStartPlusHour` | ✅ PASS |

---

## Classification Logic Summary

```
now = Date()

Upcoming (Coming Up section):
  → MeetingItem: meeting.endDate > now
  → EKEvent:     event.startDate > now AND no matching externalEventIdentifier

Past:
  → MeetingItem: meeting.endDate ≤ now
  → Sorted: most recent first (groups descending, meetings within group descending)

In-progress:
  → meeting.date ≤ now AND meeting.endDate > now
  → Appears in Coming Up with "Now" indicator
  → Classified as upcoming until the meeting fully ends
```

---

## Calendar Refresh Behavior

| Scenario | Before | After |
|---|---|---|
| App launch, first 15 min | No events in `calendarService.events` | Immediate sync on `startBackgroundSync()` |
| Meeting detection | Live EventKit query (always fresh) | Unchanged |
| CalendarView | Syncs on appearance | Unchanged |
| Background timer | Every 15 min | Every 15 min (unchanged) |
| Manual refresh button | `syncNow()` | Unchanged |

---

## Supported Meeting Types in Lists

| Type | Coming Up | Past |
|---|---|---|
| Manually created `MeetingItem` | ✅ (if endDate > now) | ✅ (if endDate ≤ now) |
| Auto-detected `MeetingItem` | ✅ | ✅ |
| `MeetingItem` with transcript/recording | ✅ | ✅ |
| `EKEvent` (no Orin record yet) | ✅ (as calendar row) | — |
| Folder meetings | In folder blocks (unchanged) | In folder blocks (unchanged) |
