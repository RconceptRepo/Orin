# Meeting Detection Audit Report

**Date:** 2026-05-30  
**Scope:** MeetingDetectorService, MeetingNotificationService, RecordingService, SystemAudioCaptureService, MainContainerView, FloatingRecordingWidgetWindowManager

---

## Dependency Map (pre-refactor)

```
EventKit (EKEventStore)
    │  direct import inside MeetingDetectorService
    ▼
MeetingDetectorService
    │  detectNativeApp()    → NSWorkspace.runningApplications
    │  detectFromCalendar() → EKEventStore (direct)
    │  detectBrowserMeeting() → NSAppleScript (direct)
    │  Confidence scoring (Phase 4) → gated at threshold=40
    ▼
MainContainerView
    │  onMeetingDetected → MeetingNotificationService.notifyMeetingDetected()
    │  shouldShowRecordingPrompt → overlay banner in ZStack
    │  startRecordingFromDetectedMeeting() → RecordingService + TranscriptStore
    ▼
RecordingService (AVAudioEngine + SFSpeechRecognizer)
SystemAudioCaptureService (ScreenCaptureKit)
TranscriptStore (3-s checkpoint + orphan recovery)
    ▼
MeetingItem (SwiftData)

FloatingRecordingWidgetWindowManager (NSPanel, separate path)
    ← shown by MainContainerView.onChange(of: recordingService.isRecording)
    
MeetingNotificationService (UNUserNotificationCenter)
    ← called by MainContainerView / MeetingDetectorService callbacks
```

---

## Detection Methods

### 1. Native App Process Detection
- **Method:** `NSWorkspace.shared.runningApplications` → bundle ID match
- **Apps:** Zoom (us.zoom.xos), Teams (com.microsoft.teams / com.microsoft.teams2), Slack (com.tinyspeck.slackmacgap), Webex (com.cisco.webex.meetings)
- **Slack special case:** `slackHasActiveCall()` uses `CGWindowListCopyWindowInfo` to find "huddle"/"call"/"meeting" window titles
- **Confidence score:** `fromRunningProcess: 25`

### 2. Calendar Event Detection
- **Method:** `CalendarService.events(from:to:)` → EKEvent → URL/notes/location scan
- **Window:** [now − 2 min, now + 5 min]
- **URL patterns:** 10 patterns covering Google Meet, Zoom, Teams, Webex
- **Confidence score:** `fromCalendarEvent: 40`
- **Direct coupling:** EKEvent imported inside MeetingDetectorService (pre-refactor)

### 3. Browser Tab Detection
- **Method:** NSAppleScript queries Chrome, Edge, Arc, Safari for active tab URLs
- **URL patterns:** Same 10 patterns as calendar detection
- **Confidence score:** `fromMeetingURL: 30`
- **Direct coupling:** NSAppleScript string construction and execution inside service

### 4. Confidence Threshold (Phase 4 — implemented)
- **Threshold:** 40
- **Gate:** `detectMeeting()` returns confidence; `poll()` gates on `meetsThreshold`

---

## Pre-Refactor Limitations

### Direct Coupling (architecture requirement violations)

| Component | Coupled To | Impact |
|---|---|---|
| MeetingDetectorService | EventKit (EKEvent, EKEventStore) | Cannot substitute without importing EK |
| MeetingDetectorService | NSAppleScript (direct string exec) | Cannot mock without override hooks |
| MainContainerView | FloatingRecordingWidgetWindowManager.shared | Static singleton, not injectable |
| MainContainerView | NSPanel (via FloatingRecordingWidgetWindowManager) | Windows-incompatible |
| MeetingNotificationService | UNUserNotificationCenter (direct) | Cannot mock in tests |

### Detection Gaps

| Gap | Impact |
|---|---|
| No window title detection for Teams/Zoom (beyond Slack) | Teams direct call = process running but no call window check → 25 < 40 threshold → NOT detected |
| No microphone activity signal | Teams running + mic active = 25 + 0 = 25 → NOT detected |
| Browser URL alone (30) below threshold | Chrome on meet.google.com without any other signal → not detected |
| No FaceTime support | No bundle ID in native app list |

### Notification Limitations

| Issue | Impact |
|---|---|
| UNNotificationResponse only posts to NotificationCenter | If app is backgrounded when tapped, SwiftUI `.onReceive` may not fire |
| No UserDefaults fallback | Notification action lost if app was not in memory |
| Recording notification not cleared on stop | Stale "Recording in Progress" banner persists after recording ends |

### Widget Limitations

| Issue | Impact |
|---|---|
| `panel.center()` centers on primary screen | On multi-monitor setups, widget always appears on main display regardless of where user is |
| Single NSPanel instance, never recreated | `contentView` replaced on every `show()` call even if same content |
| `setFrameAutosaveName` may restore to wrong screen | After monitor configuration change, panel position may be off-screen |

---

## Post-Refactor Architecture (implemented)

### Provider Protocol Layer

```
Sources/Orin/Providers/
  Protocols/
    MeetingProviderTypes.swift    — CalendarEventDescriptor, MeetingDetectionConfidence,
                                    NotificationAction (platform-agnostic types)
    CalendarProvider.swift        — abstracts EventKit
    MeetingDetectorProvider.swift — abstracts MeetingDetectorService interface
    NotificationProvider.swift    — abstracts UNUserNotificationCenter
    OverlayProvider.swift         — abstracts NSPanel widget
    SystemAudioProvider.swift     — abstracts ScreenCaptureKit + MeetingDetectorProvider
    AccessibilityProvider.swift   — abstracts CGWindowList / AudioActivityProvider
  macOS/
    EventKitCalendarProvider.swift   — EKEvent → CalendarEventDescriptor conversion
    macOSAccessibilityProvider.swift — CGWindowListCopyWindowInfo window titles
                                       + AVAudioActivityProvider microphone activity
    NSPanelOverlayProvider.swift     — delegates to FloatingRecordingWidgetWindowManager
    SCKitSystemAudioProvider.swift   — wraps SystemAudioCaptureService
```

### Dependency Map (post-refactor)

```
EventKitCalendarProvider  (only file importing EventKit for detection)
    │
    ▼
MeetingDetectorService (conforms to MeetingDetectorProvider)
    │  calendarProvider: any CalendarProvider
    │  accessibilityProvider: any AccessibilityProvider
    │  audioActivityProvider: any AudioActivityProvider
    │  detectNativeApp() → process + window title score
    │  detectFromCalendar() → CalendarProvider (or legacy EK fallback)
    │  detectBrowserMeeting() → NSAppleScript
    ▼
Six confidence signals → MeetingDetectionConfidence.total ≥ 40
    ▼
MainContainerView (OverlayProvider + NotificationProvider via concrete services)
```

---

## Signal Coverage Matrix (post-refactor)

| Signal | Score | Provider | Always Available |
|---|---|---|---|
| Calendar event with meeting URL | 40 | EventKitCalendarProvider | Requires calendar permission |
| Browser tab with meeting URL | 30 | NSAppleScript | Requires Automation permission |
| Native app running | 25 | NSWorkspace | Always |
| Call window title confirmed | 30 | macOSAccessibilityProvider | Requires Screen Recording permission |
| Microphone in use by another app | 20 | AVAudioActivityProvider | Always |
| System audio active (future) | 20 | (reserved) | Requires Screen Recording permission |

### Meeting Scenarios Covered

| Scenario | Pre-refactor | Post-refactor |
|---|---|---|
| Teams app running | 25 (below threshold) | 25+20+20=65 with window+mic ✅ |
| Zoom direct call | 25 (below threshold) | 25+30=55 with call window ✅ |
| Slack huddle | Detected (CGWindow) | Detected + mic signal = 45 ✅ |
| Google Meet (Chrome, no calendar) | 30 (below threshold) | 30+20=50 with mic ✅ |
| Google Meet (with calendar event) | 40 ✅ | 40 ✅ |
| In-person (no app, mic active) | 0 — not detected | 0 — intentionally not detected |
