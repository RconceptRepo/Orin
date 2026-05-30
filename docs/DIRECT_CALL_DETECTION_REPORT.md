# Direct Call Detection Report

**Date:** 2026-05-30  
**Method:** Multi-signal confidence scoring via `MeetingDetectorService` + `macOSAccessibilityProvider` + `AVAudioActivityProvider`

---

## Detection Matrix

### Microsoft Teams

| Detection Type | Status | Implementation | Notes |
|---|---|---|---|
| Teams app running (process) | ✅ **SUPPORTED** | `NSWorkspace` bundle ID check (`com.microsoft.teams`, `com.microsoft.teams2`) | Base signal: 25 pts |
| Calendar event with Teams URL | ✅ **SUPPORTED** | EventKitCalendarProvider; patterns: `teams.microsoft.com/v2/`, `/meet/`, `/l/meetup-join`, `teams.live.com` | 40 pts — alone meets threshold |
| Browser tab (Teams web) | ✅ **SUPPORTED** | AppleScript; same URL patterns | 30 pts |
| Call window title | ⚠️ **PARTIAL** | `macOSAccessibilityProvider` CGWindowList; titles: "In a call", "call in progress", "meeting in progress", "meeting" | Requires Screen Recording permission; Teams 2.0 may not expose call-state in title |
| Teams + mic active | ✅ **SUPPORTED** | Process (25) + mic in use (20) = 45 ≥ 40 | Detects any Teams audio session |
| Teams + window + mic | ✅ **SUPPORTED** | 25 + 30 + 20 = 75 ≥ 40 | Highest confidence when Screen Recording granted |
| Direct call (no calendar/URL) | ✅ **SUPPORTED** | Process + mic active = 45 ≥ 40 | Works without calendar or URL signal |

**Overall:** ✅ SUPPORTED (all paths covered; window title is PARTIAL due to Teams 2.0 title behavior)

---

### Slack Huddles

| Detection Type | Status | Implementation | Notes |
|---|---|---|---|
| Slack app running | ✅ **SUPPORTED** | `NSWorkspace` bundle ID `com.tinyspeck.slackmacgap` | Base signal: 25 pts |
| Slack huddle window | ✅ **SUPPORTED** | `slackHasActiveCall()` via CGWindowList; title keywords: "huddle", "Slack Call", "call" | 25 pts process |
| Window title confirmation | ✅ **SUPPORTED** | `macOSAccessibilityProvider.hasWindow(appNamed: "Slack", withTitleContaining: ["Huddle", "huddle", "Slack Call", "call"])` | +30 pts when Screen Recording granted |
| Mic active during huddle | ✅ **SUPPORTED** | `AVAudioActivityProvider.isMicrophoneInUseByAnotherApp()` | +20 pts |
| Slack huddle without Screen Recording | ✅ **SUPPORTED** | Process (25) + mic (20) = 45 ≥ 40 | Falls back to process + audio |
| Browser-based Slack (no app) | ❌ **NOT SUPPORTED** | Slack.com is not in meeting URL patterns | Would need `slack.com/huddle/` URL pattern |

**Overall:** ✅ SUPPORTED (native app huddles fully covered; browser Slack NOT supported)

---

### Zoom (Direct Calls and Meetings)

| Detection Type | Status | Implementation | Notes |
|---|---|---|---|
| Zoom app running | ✅ **SUPPORTED** | `NSWorkspace` bundle ID `us.zoom.xos` | Base signal: 25 pts |
| "Zoom Meeting" window vs. launcher | ✅ **SUPPORTED** | `callWindowKeywords["us.zoom.xos"] = ["Zoom Meeting", "zoom meeting"]` | Distinguishes active call from app launcher |
| Calendar event with Zoom URL | ✅ **SUPPORTED** | Patterns: `zoom.us/j/`, `zoom.us/s/`, `zoom.us/wc/` | 40 pts alone |
| Browser Zoom (zoom.us/j/) | ✅ **SUPPORTED** | AppleScript URL scan | 30 pts |
| Direct Zoom call (no calendar) | ✅ **SUPPORTED** | Process (25) + call window (30) = 55 ≥ 40 | Detects the "Zoom Meeting" window vs. launcher |
| Direct Zoom call + mic | ✅ **SUPPORTED** | 25 + 30 + 20 = 75 ≥ 40 | |
| Zoom running without active call | ✅ **CORRECTLY REJECTED** | Zoom launcher "Zoom" title doesn't match keywords | 25 pts only → below threshold without audio |

**Overall:** ✅ SUPPORTED (full coverage including launcher vs. active-call disambiguation)

---

### Google Meet

| Detection Type | Status | Implementation | Notes |
|---|---|---|---|
| Calendar event with Meet URL | ✅ **SUPPORTED** | Pattern: `meet.google.com/` | 40 pts alone |
| Browser tab in Chrome/Edge/Arc | ✅ **SUPPORTED** | AppleScript URL scan for `meet.google.com/` | 30 pts |
| Browser + mic active | ✅ **SUPPORTED** | 30 + 20 = 50 ≥ 40 | Covers meetings without calendar event |
| Native app | ❌ **NOT SUPPORTED** | No native macOS Google Meet app exists | N/A |
| Meet without audio (viewer/silent) | ⚠️ **PARTIAL** | 30 pts from URL alone < 40 threshold | Calendar event required for detection without audio |

**Overall:** ✅ SUPPORTED (with browser; silent viewing sessions without calendar NOT detected by design)

---

### Webex

| Detection Type | Status | Implementation | Notes |
|---|---|---|---|
| Webex native app running | ✅ **SUPPORTED** | `NSWorkspace` bundle ID `com.cisco.webex.meetings` | 25 pts |
| Window title confirmation | ✅ **SUPPORTED** | Keywords: "Webex Meeting", "Cisco Webex", "meeting" | +30 pts when Screen Recording granted |
| Calendar event | ✅ **SUPPORTED** | Patterns: `web.webex.com/meet/`, `webex.com/meet/` | 40 pts alone |
| Browser-based Webex | ✅ **SUPPORTED** | AppleScript URL scan for `webex.com/meet/` | 30 pts |
| Direct Webex call + mic | ✅ **SUPPORTED** | Process (25) + mic (20) = 45 ≥ 40 | Without window title |
| Webex app without active session | ✅ **CORRECTLY REJECTED** | 25 pts only → needs audio to reach threshold | |

**Overall:** ✅ SUPPORTED

---

### FaceTime

| Detection Type | Status | Implementation | Notes |
|---|---|---|---|
| FaceTime app running | ❌ **NOT SUPPORTED** | `com.apple.FaceTime` bundle ID NOT in `nativeApps` list | |
| FaceTime window title | ❌ **NOT SUPPORTED** | Not in detection pipeline | |
| FaceTime + mic active | ⚠️ **PARTIAL** | Mic activity (20) alone < 40 threshold | Would need FaceTime in nativeApps for process signal |

**Overall:** ❌ NOT SUPPORTED (FaceTime bundle ID not registered)  
**Fix required:** Add `("com.apple.FaceTime", "FaceTime")` to `nativeApps` and `callWindowKeywords`.

---

### Additional Platforms

| Platform | Status | Notes |
|---|---|---|
| Microsoft Teams (consumer web: teams.live.com) | ✅ SUPPORTED | URL pattern `teams.live.com` in browser detection |
| Discord | ❌ NOT SUPPORTED | No bundle ID or URL patterns |
| Google Meet (Safari) | ✅ SUPPORTED | Safari AppleScript detection included |
| Whereby | ❌ NOT SUPPORTED | No URL pattern |
| Jitsi Meet | ❌ NOT SUPPORTED | No URL pattern |
| Phone calls via Continuity | ❌ NOT SUPPORTED | No detection mechanism |
| In-person (mic only) | ❌ NOT SUPPORTED (by design) | No meeting app or URL → 0 pts; would need explicit manual recording |

---

## Confidence Score Examples

```
Teams direct call (with Screen Recording):
  fromRunningProcess = 25
  fromWindowTitle    = 30  (window: "In a call")
  microphoneScore    = 20  (Teams has mic)
  Total = 75 ✅ Detected

Teams app open but idle:
  fromRunningProcess = 25
  fromWindowTitle    =  0  (window: "Teams" — no call keyword)
  microphoneScore    =  0  (mic not in use)
  Total = 25 ❌ Not detected (correct)

Zoom direct call (without Screen Recording):
  fromRunningProcess = 25
  fromWindowTitle    =  0  (no Screen Recording)
  microphoneScore    = 20  (Zoom has mic)
  Total = 45 ✅ Detected

Slack huddle (without Screen Recording):
  fromRunningProcess = 25
  slackHasActiveCall = from existing CGWindowList check (Slack only)
  microphoneScore    = 20
  Total = 45 ✅ Detected (slackHasActiveCall guards the process match)

Google Meet in Chrome (no calendar, with mic):
  fromMeetingURL     = 30
  microphoneScore    = 20
  Total = 50 ✅ Detected
```

---

## Gaps and Recommendations

| Gap | Recommendation |
|---|---|
| FaceTime not detected | Add `("com.apple.FaceTime", "FaceTime")` to `nativeApps` and keywords `["FaceTime", "Video"]` |
| Browser Slack not detected | Add `slack.com/huddle` URL pattern to `meetingURLPatterns` |
| Silent Google Meet (no mic, no calendar) | By design — require at least audio or calendar to avoid false positives |
| Discord | Add `com.hnc.Discord` bundle ID + keywords `["voice channel", "video call"]` |
| Windows Teams title variability | Teams 2.0 window title during call shows contact name, not "In a call" — needs real-device testing to confirm keywords |
