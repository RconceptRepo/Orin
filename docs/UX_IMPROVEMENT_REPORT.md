# UX Improvement Report

**Date:** 2026-05-31  
**Objective:** Transform meetings experience toward Granola-class quality without visual redesign.

---

## Summary of Changes

| Task | Area | Change | Friction Reduced |
|---|---|---|---|
| 2 | Deletion | `deleteMeetingFully` cleans all associated data | Data integrity |
| 4 | Meeting Card | `MeetingMetaBadgeRow` — summary/duration/actions badges | 2 fewer clicks to understand a meeting |
| 4 | Meeting Card | Status icon: waveform for recorded, doc for unrecorded | Instant visual scan |
| 5 | Meeting Detail | `meetingQuickStats` bar — health summary on open | Eliminated scroll to assess meeting |
| 5 | Meeting Detail | Transcript card moved before summary | Primary content first |
| 5 | Meeting Detail | Participants card moved to bottom | Less critical info last |
| 6 | Folder UX | Rename folder now fully implemented | No more stub |
| 7 | Empty State | `EmptyMeetingsState` for fresh installs | Onboarding improvement |

---

## Task 4: Meeting Card UX

### Before
```
[checkbox] [doc] Weekly Standup                   09:00  ···
                 Alice, Bob, Carol
```

### After
```
[checkbox] [wave] Weekly Standup                  09:00  ···
                  Alice, Bob, Carol
                  [30m] [✅ Analyzed] [📋 3]
```

**Badges (only shown when non-trivial):**
- **Duration badge** — e.g. "30m", "1h 15m" — only shown when `durationSeconds > 60`
- **Analyzed badge** — green, only when `summary` is non-empty
- **Actions badge** — blue count, only when `actionItems.count > 0`
- **Transcript badge** — shown when transcript exists but no summary yet

**Status icon change:**
- Recorded meeting → `waveform` icon (accent colour)
- Unrecorded meeting → `doc.text` icon (secondary colour)

**Cognitive load reduction:** User can scan the meeting list and instantly know which meetings are analyzed, how long they were, and how many action items came out — without opening any of them.

---

## Task 5: Meeting Detail UX

### Card Order — Before
1. Recording Controls
2. Participants ← low-value when just opened
3. Transcript ← primary content, buried
4. Summary
5. Decisions
6. Action Items
7. Commitments
8. Suggested Tasks

### Card Order — After
1. Recording Controls
2. **Quick Stats Bar** ← NEW: at-a-glance health
3. Transcript ← primary content, surfaced
4. Summary
5. Decisions
6. Action Items
7. Commitments
8. Suggested Tasks
9. Participants ← moved down

### Quick Stats Bar

A horizontal scrollable row of compact chips showing:

```
[clock 30m]  [person.2 3]  [waveform Recording]  [text.bubble Transcript]  [sparkles Analyzed]  [checklist 5 actions]
```

- **Always visible** without scrolling
- **Active chips** are opaque; **inactive chips** are dimmed — user sees what's present/missing
- **Accent-colored** for analyzed + actions (most actionable facts)
- **Scrollable** on narrow panels

**What this eliminates:** Previously, to know if a meeting had been analyzed, the user had to scroll past Recording + Participants + Transcript cards. Now visible in 0 seconds.

### Transcript Card: Default to Timeline

When `TranscriptSegment` records exist, the transcript card shows the **Timeline** view by default (ordered conversation). The picker allows switching to Full Transcript. This surfaces the most readable format first.

---

## Task 6: Folder UX

### Rename Folder — Fixed

The "Rename Folder" menu item was a stub (`/* trigger rename */`) in `GranolaFolderBlockView`. Now it correctly triggers `RenameFolderSheet` via the `onRenameFolder` callback introduced in the previous session.

### Folder Selection — FolderDetailView

Clicking a folder **name** (not the expand chevron) opens `FolderDetailView` in the right panel:
- **Meetings tab:** All meetings in folder, sorted most-recent-first
- **Intelligence tab:** Cross-meeting summary, recurring topics, decisions, actions

### Folder Header — Icon Rendered

The `folder.icon` SF Symbol is now rendered in `GranolaFolderBlockView` header, replacing the hardcoded `"folder.fill"`. This makes color/icon preferences visible in the list.

---

## Task 7: Empty States

### Meetings List Empty State

When `meetings.isEmpty && folders.isEmpty`:

```
         [video.slash icon]
         
      No Meetings Yet
      
  Record and transcribe your meetings automatically.
  When a meeting is detected, Orin will prompt you to start recording.
  
         [+ New Meeting]
```

Previously: Three empty sections ("No upcoming meetings.", "No past meetings.") with no call-to-action or explanation.

### Folder Intelligence Tab — Empty State (existing)

Already implemented in `FolderDetailView.intelligenceTab`: shows "Generate Summary" call-to-action when no `FolderSummaryItem` exists.

### Meeting Detail — Empty States (existing)

- Empty transcript: `TextEditor` with empty state text
- Empty summary: "No summary." placeholder text
- Empty participants: "No participants added." placeholder text
- Empty commitments: "No commitments detected yet." placeholder text

---

## Task 3: Granola Flow Validation

### Validated Flow

```
Meeting detected (Zoom process + mic active)
    ↓ 3-30s detection delay
System notification: "Meeting Detected" + [Start Recording] [Dismiss]
    ↓ tap "Start Recording" (from notification, even with app backgrounded)
UserDefaults flag set → processPendingNotificationAction() on next app activation
    ↓
RecordingService starts → floating widget appears on user's active screen
    ↓ during meeting
Transcript chunks written every ~10 chars, checkpointed every 3s
    ↓
User taps Stop (widget) or meeting app closes (auto-stop after audio inactivity)
    ↓
TranscriptStore.finalize() — best-of-N, 1.5s trailing wait
ConversationTimelineBuilder → TranscriptSegments
    ↓
Auto-analysis (if enabled): MeetingIntelligenceService → summary + actions
    ↓
Meeting Detail: Quick Stats shows health at a glance
Transcript Card: Timeline view shows conversation
Folder Suggestion: RecurringSuggestionBanner if pattern detected
```

### Remaining Friction Points (not addressed — out of scope)

| Point | Reason not addressed |
|---|---|
| Detection latency (3-30s) | Inherent to 3/30s poll cycle; reducing would increase CPU |
| No per-utterance timestamps (Timeline shows 20s blocks) | Requires whisper.cpp + diarization — separate task |
| No calendar event → auto-create meeting | Would auto-create many false meetings; intentional |
| Folder description not shown in meeting list | Low priority; shown in FolderDetailView |

---

## Task 8: Regression Verification

All existing test suites remain passing. See test results for full detail.
