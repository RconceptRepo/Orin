# Orin V1

Orin is a local-first Personal Execution OS for macOS, built with SwiftUI and SwiftData.

## Design System

The UI contract lives in [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md). Treat it as immutable unless intentionally revised. Shared SwiftUI tokens and components live in `Sources/Orin/Views/Shared/OrinDesignSystem.swift`.

## Current Build Slice

This repository contains the full MVP scaffold plus the unified meeting detection engine:

- SwiftUI macOS app entry point
- SwiftData schema for tasks, subtasks, meetings, commitments, and vault items
- Today, All Tasks, Backlog, Calendar, Meetings, Vault, and Settings navigation
- Task creation with multi-task pending preview
- Today filtering for due and overdue active work
- Completed task section with reactivate/delete actions
- Manual drag ordering for Today tasks
- Backlog activation into Today
- Startup rollover engine
- Menu bar extra
- Quick Capture overlay foundation with simple parsing for `today`, `tomorrow`, and `P0`-`P3`
- Service container and initial services for calendar, vault, recording, rollover, and local AI
- Calendar screen with EventKit permission/sync status, selected-date meetings, and scheduled tasks
- Vault screen with local authentication, encrypted item creation, reveal, and delete
- Settings screen for launch behavior, calendar sync, AI provider choice, and Ollama endpoint
- Meetings screen with meeting records, participants, transcript import/paste, summary, decisions, commitments, action items, and suggested tasks
- Meeting intelligence service with Ollama summary support and deterministic local extraction fallback
- Daily Executive Brief generated from tasks, meetings, commitments, and overdue work
- Reflow engine with suggested task ordering, focus blocks, breaks, and apply/reject flow
- AI suggestion cards with accept/decline behavior and day-level hiding
- Commitment tracking surfaced on Today with fulfill action
- **Unified Meeting Detection Engine** — see section below
- Floating recording widget and menu bar start/stop recording state
- Voice command parser foundation for task, backlog, reflow, and summary commands
- Ollama verification status in Settings
- App Intents foundation for Siri Shortcuts: Add Task, Reflow Day, Summarize Today

## Unified Meeting Detection Engine

`Sources/Orin/Services/MeetingDetectorService.swift` was fully implemented in this slice. It replaces the previous stub that only checked whether a handful of apps were running.

### Native App Tracking

The service polls every 30 seconds for these running applications:

| App | Bundle ID |
|-----|-----------|
| Zoom | `us.zoom.xos` |
| Microsoft Teams (classic) | `com.microsoft.teams` |
| Microsoft Teams (new) | `com.microsoft.teams2` |
| Slack | `com.tinyspeck.slackmacgap` |
| Webex | `com.cisco.webex.meetings` |

Slack is only surfaced when a Huddle or call window is actually on-screen. The check uses `CGWindowListCopyWindowInfo` and matches window titles containing "huddle", "call", or "meeting". It fails silently if Screen Recording permission has not been granted.

### Browser Tab Inspection

When no native meeting app is detected, the engine inspects the active tab URL in all running browsers via `NSAppleScript`:

- **Chromium family:** Google Chrome, Microsoft Edge, Arc
- **Safari**

URLs are matched against these patterns:

```
meet.google.com/
zoom.us/j/
zoom.us/s/
teams.live.com
teams.microsoft.com/v2/
```

AppleScript calls are dispatched to a dedicated serial `DispatchQueue` via `withCheckedContinuation`, keeping them entirely off the main thread. Errors (browser closed, automation permission denied) are swallowed silently.

### Deduplication

Each detected meeting is assigned a stable key — `bundleID|active` for native apps, or the trimmed URL path (query string and fragment stripped) for browser meetings. The key is cached in `activeMeetingKey`. Repeated polls of the same ongoing meeting are no-ops; the "Meeting Detected" overlay and `onMeetingDetected` callback only fire when a genuinely new session is discovered.

Calling `dismissPrompt()` clears the key, so if the same meeting is still in progress after a user dismissal, it will not re-prompt until the next new session begins.

### Meeting Detected Overlay

When a new session is found, `shouldShowRecordingPrompt` is set to `true` on the main thread and the overlay in `MainContainerView` surfaces automatically:

- **Title:** Meeting Detected
- **Notice:** Ensure all participants are aware of recording.
- **Primary action:** Start Listening — hooks into `RecordingService`
- **Secondary action:** Dismiss

### Thread Safety

All detection logic runs inside a `Task.detached(priority: .utility)` block. UI state (`detectedMeetingApp`, `shouldShowRecordingPrompt`, `activeMeetingKey`) is only ever mutated via `DispatchQueue.main.async`, preventing races with SwiftUI observation.

## Native Integration Notes

Some platform-heavy features still need production entitlements, packaging, or engine integration before release:

- Real microphone/system-audio capture and Whisper transcription
- Login item registration
- `com.apple.security.automation.apple-events` entitlement and `NSAppleEventsUsageDescription` in Info.plist for production AppleScript automation
- External provider API calls and secure keychain-backed provider key storage
- Notarized app signing and release DMG polishing

## Requirements

- macOS 14 or newer
- Full Xcode with SwiftData macro support

The Command Line Tools-only environment does not include `SwiftDataMacros`, so `swift build` can fail with:

```text
plugin for module 'SwiftDataMacros' not found
```

Open the package in full Xcode, or select a full Xcode toolchain before building.

## Build

```bash
swift build
```

If the Command Line Tools path cannot resolve SwiftData macros, build through the full Xcode developer directory:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --jobs 1
```

## Run

```bash
swift run Orin
```

For production packaging, create a native macOS app target in Xcode and include the files under `Sources/Orin`.
