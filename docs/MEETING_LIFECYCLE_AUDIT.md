# Meeting Lifecycle Audit

**Date:** 2026-05-31

---

## Complete Lifecycle Diagram

```
macOS System
    │
    ├─ MeetingDetectorService (polls every 30s / 3s fast)
    │    │  NSWorkspace process check: Zoom/Teams/Slack/Webex
    │    │  CalendarService: EKEvent ± 2-5 min window
    │    │  AppleScript: Chrome/Edge/Arc browser tabs
    │    │  macOSAccessibilityProvider: window title keywords
    │    │  AVAudioActivityProvider: mic in use by another app
    │    │  Confidence scoring (threshold 40/100)
    │    │
    │    ├─ onMeetingDetected(appName)
    │    │    │
    │    │    ├─ MeetingNotificationService.notifyMeetingDetected()
    │    │    │    └─ UNNotification with "Start Recording" / "Dismiss" actions
    │    │    │
    │    │    └─ MeetingRecordingPromptView overlay (bottom-right of main window)
    │    │
    │    └─ shouldShowRecordingPrompt = true (confidence-gated)
    │
    ▼
User taps "Start Recording" (overlay OR notification action)
    │
    ├─ [Overlay path] MainContainerView.startRecordingFromDetectedMeeting()
    │    Creates MeetingItem → navigates to Meetings module
    │
    └─ [Notification path] MeetingNotificationService.didReceive()
         Sets UserDefaults "orin.pending.startRecording"
         MainContainerView.processPendingNotificationAction() on next activation
    │
    ▼
RecordingService.startRecording(for: meetingID)
    │  AVAudioEngine → AVAudioFile (.caf)
    │  SFSpeechRecognizer (on-device, transparent ~60s restart)
    │
    ├─ SystemAudioCaptureService.startCapturing(for: meetingID)
    │    SCStream → CMSampleBuffer → AVAudioPCMBuffer
    │    Parallel SFSpeechRecognizer ("Participant:")
    │
    ├─ TranscriptStore.beginSession()
    │    Checkpoint timer: every 3s → MeetingItem.transcript
    │    UserDefaults backup: every 3s (crash safety)
    │    TranscriptChunk: every ≥10-char growth
    │
    └─ FloatingRecordingWidgetWindowManager.show()
         NSPanel (.floating, canJoinAllSpaces, fullScreenAuxiliary)
         Multi-monitor: placed on cursor's screen
         hidesOnDeactivate = false
    │
    ▼
User taps "Stop" (widget OR recording card OR notification) / auto-stop fires
    │
    ├─ Auto-stop conditions:
    │    1. MeetingDetectorService.onMeetingEnded fires (meeting gone)
    │    2. 1.5s grace period
    │    3. Audio inactivity check: TranscriptStore.secondsSinceLastUpdate > 30s
    │
    ├─ RecordingService.stopRecording()
    ├─ SystemAudioCaptureService.stopCapturing()
    ├─ FloatingRecordingWidgetWindowManager.hide()
    ├─ MeetingNotificationService.notifyRecordingStopped() [clears stale banner]
    │
    └─ TranscriptStore.finalize(elapsed:audioURL:)
         1.5s wait for trailing recognition chunks
         Best-of-N transcript selection
         ConversationTimelineBuilder → TranscriptSegments persisted
         meeting.transcript = finalText
         meeting.durationSeconds = elapsed
         meeting.audioFilePath = audioURL.path
    │
    ▼
Auto-Analysis (if orin.meetings.autoAnalyze enabled AND elapsed >= minDuration)
    │
    └─ MeetingIntelligenceService.analyze(title:segments:fallback:)
         ConversationTimelineBuilder.formatted() → conversation-style prompt
         AIService (Ollama → OpenAI → Claude → Gemini)
         meeting.summary / .decisions / .actionItems / .suggestedTaskTitles / .commitments
    │
    ▼
Meeting Detail View ready
    │  Quick Stats Bar: duration, participants, recording, transcript, analyzed, actions
    │  Transcript Card: Timeline (default) / Full Transcript toggle
    │  Summary Card: AI-generated or empty
    │  Decisions / Action Items / Commitments
    │
    ▼
Optional: Folder Suggestion
    │
    └─ RecurringMeetingService.detectPatterns()
         Title similarity (35%) + Participants (25%) + Day (20%) + Time (15%) + Topics (5%)
         If confidence ≥ 60%: RecurringSuggestionBanner shown in meeting list
         Accept → creates MeetingFolderItem, moves all matched meetings
         Dismiss → dismissedKey set in UserDefaults
```

---

## Friction Points Found and Addressed

| Stage | Issue | Fix Applied |
|---|---|---|
| Meeting start from notification | App backgrounded: `onReceive` not active | `UserDefaults` pending flag + `scenePhase` observer |
| Recording start | Detection gate blocked all manual recording | Gate removed — any meeting can be manually recorded |
| Auto-stop | Stopped on brief network blip (Zoom process restart) | Audio-inactivity guard: waits for 30s silence |
| Meeting detail | Transcript buried 3 cards down | Transcript card moved above summary |
| Meeting detail | No at-a-glance meeting health | `meetingQuickStats` bar added |
| Meeting card | No summary/actions status visible | `MeetingMetaBadgeRow` added |
| Empty list | Blank screen on fresh install | `EmptyMeetingsState` with "New Meeting" CTA |
| Deletion | TranscriptChunks/Segments orphaned | `ModelContext.deleteMeetingFully` added |

---

## Lifecycle Timing

| Phase | Duration | Notes |
|---|---|---|
| Detection → prompt | 3–30s | Fast poll (3s) when recording; normal (30s) otherwise |
| Permission request → recording start | <2s | Mic/speech already granted → instant |
| Recording active → final save | 1.5s | `finalize()` sleep for trailing recognition chunks |
| TranscriptChunk written | Every ~1s | 10-char growth threshold |
| TranscriptSegment built | At finalize | From chunks via ConversationTimelineBuilder |
| Auto-analysis | 5–30s | Depends on AI provider; Ollama varies by model |
| Folder suggestion | Synchronous | `detectPatterns()` runs on `onAppear` and meeting count change |
