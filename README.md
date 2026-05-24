# Orin V1

Orin is a local-first Personal Execution OS for macOS, built with SwiftUI and SwiftData.

## Design System

The UI contract lives in [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md). Treat it as immutable unless intentionally revised. Shared SwiftUI tokens and components live in `Sources/Orin/Views/Shared/OrinDesignSystem.swift`.

## Feature Status

| Area | Status |
|---|---|
| Tasks / Today / Backlog / Reflow | Complete |
| Task editing (All Tasks view) | Complete |
| Calendar — EventKit sync + 15-min background refresh | Complete |
| Meetings — transcript, intelligence, commitments | Complete |
| Meeting Detection Engine (native apps + browser tabs) | Complete |
| Live transcription via `SFSpeechRecognizer` + local audio file storage | Complete |
| Whisper transcription stub (`WhisperTranscriptionService`) | Complete |
| Meeting retention policies (30 / 90 / 180 days / Forever) | Complete |
| Vault — biometric unlock, AES-256-GCM, Keychain | Complete |
| AI — Ollama local + OpenAI / Claude / Gemini fallover | Complete |
| AI provider keys secured in Keychain | Complete |
| Login item (`SMAppService`) | Complete |
| Quick Capture with NL parser | Complete |
| Daily Executive Brief | Complete |
| Voice command parser foundation | Complete |
| App Intents / Siri Shortcuts — `WhatsLeftToday`, `ReflowDay`, `AddTask` | Complete |
| URL scheme deep links — `orin://whatsLeftToday`, `orin://reflow`, `orin://addTask?title=...` | Complete |
| `AssistantService` — routes intents + URL commands into live services | Complete |
| Entitlements + Info.plist (all usage strings + screen recording) | Complete |
| Xcode app target (`Orin.xcodeproj`, bundle ID `com.rconcept.orin`) | Complete |
| `project.yml` (XcodeGen reproducible project) | Complete |
| DMG build script (`scripts/build_dmg.sh`) | Complete |
| Automated test suite (84 tests) | Complete |
| Production signing + notarization | **Pending** (requires Developer ID certificate) |

## What's Implemented

### Core app
- SwiftUI macOS app entry point with `@main` in `main.swift` (SPM-importable for tests)
- SwiftData schema: `TaskItem`, `SubTaskItem`, `MeetingItem`, `CommitmentItem`, `VaultItem`, `AISuggestionItem`, `DailyBriefItem`, `FocusPatternItem`
- `ServiceContainer` dependency injection
- `RolloverEngine` — daily startup rollover of overdue tasks and backlog activation

### Tasks
- Today view: Daily Brief, active tasks with drag ordering, commitments, AI suggestions, reflow planning
- All Tasks view: full list with **working Edit sheet** (title, description, priority, effort, due date)
- Backlog view with trigger-date activation
- Quick Capture overlay: natural-language parser for `today`, `tomorrow`, `P0`–`P3`

### Calendar
- EventKit integration with full/restricted/denied permission handling
- Sync status badge: green (synced) / yellow (pending) / red (unavailable)
- **15-minute background sync timer** wired in `MainContainerView`, respects the Settings toggle
- `CalendarService.startBackgroundSync()` / `stopBackgroundSync()` — idempotent, `@MainActor`

### Meetings & Recording
- Meetings view with transcript import, analysis, decisions, action items, suggested tasks
- `MeetingIntelligenceService` — Ollama summary with deterministic keyword-extraction fallback
- `RecordingService` — full `AVFoundation` + `SFSpeechRecognizer` pipeline:
  - Explicit permission request for microphone and speech recognition
  - On-device recognition preferred (when model is available)
  - Near-real-time `transcript` property updated from partial results
  - **Local audio file stored** in `~/Library/Application Support/Orin/Recordings/` as `.caf`
  - `recordingURL` property exposed after `stopRecording()` for meeting attachment
  - `errorMessage` surfaced in `RecordingWidgetView` when permission is denied or engine fails
- `WhisperTranscriptionService` — extension point for whisper.cpp server transcription:
  - Set `serverEndpoint` to `http://localhost:8080/inference` to enable
  - Falls back to SFSpeechRecognizer transcript when not configured

### Meeting Retention
- `MeetingRetentionService` with policies: `30 days` (default), `90 days`, `180 days`, `Forever`
- Policy configured in Settings → Meetings
- Applied on launch: deletes expired `MeetingItem` records + their local audio files
- Stored in `UserDefaults` key `orin.meetings.retentionDays`

### Meeting Detection Engine
See detailed section below.

### Vault
- `VaultService`: Touch ID / Face ID unlock → Keychain master key → AES-256-GCM encrypt/decrypt
- `VaultView`: create, reveal, delete items; locked-state placeholder

### AI
- `AIService` with provider routing: Ollama → OpenAI → Claude → Gemini
- Automatic fallover: external call fails → retries Ollama, surfaces "External AI unavailable. Using Local AI."
- `AIKeychainService`: save / load / delete API keys under `com.orin.ai-provider-keys` — never stored in `UserDefaults` or SwiftData
- Settings UI: per-provider `SecureField` + Save/Remove, Keychain presence badge

### Login item
- `LoginItemService` wraps `SMAppService.mainApp` with graceful error messaging
- Wired to the "Launch automatically on login" toggle in Settings
- Fails cleanly in unsigned / non-`/Applications` dev builds with an inline error message

### Siri / App Intents

| Intent | Siri phrase examples | Result |
|--------|---------------------|--------|
| `WhatsLeftTodayIntent` | "What's left today in Orin" | Reads tasks, returns spoken summary |
| `ReflowDayIntent` | "Reflow my day in Orin" | Opens Orin, triggers reflow |
| `AddTaskIntent` | "Add task finish proposal in Orin" | Creates task via NL parser |

### URL Scheme Deep Links

| URL | Action |
|-----|--------|
| `orin://whatsLeftToday` | Shows today summary |
| `orin://reflow` | Triggers reflow |
| `orin://addTask?title=...&due=...` | Creates task |

`AssistantService.handleURL(_:)` processes these; `processPendingIntents()` flushes the UserDefaults bridge on each foreground pass.

---

## Unified Meeting Detection Engine

`Sources/Orin/Services/MeetingDetectorService.swift` polls every 30 seconds.

### Native app tracking

| App | Bundle ID |
|-----|-----------|
| Zoom | `us.zoom.xos` |
| Microsoft Teams (classic) | `com.microsoft.teams` |
| Microsoft Teams (new) | `com.microsoft.teams2` |
| Slack | `com.tinyspeck.slackmacgap` |
| Webex | `com.cisco.webex.meetings` |

Slack only surfaces when a Huddle or call window is on-screen (`CGWindowListCopyWindowInfo` — silently fails without Screen Recording permission).

### Browser tab inspection

Inspects active tab URLs via `NSAppleScript` in **Chromium** (Chrome, Edge, Arc) and **Safari**. Matched against:

```
meet.google.com/
zoom.us/j/
zoom.us/s/
teams.live.com
teams.microsoft.com/v2/
```

Scripts run on a serial `DispatchQueue` via `withCheckedContinuation`. Permission errors and closed-browser states are swallowed silently.

### Deduplication & dismiss behaviour

- **`activeMeetingKey`** — stable per-session key (`bundleID|active` or trimmed URL path). Repeated polls of the same session are no-ops.
- **`dismissedMeetingKey`** — set when the user dismisses the overlay. The same ongoing session will not re-prompt even if still detected. Cleared only when the meeting fully ends (detection returns `nil`).
- Meeting end resets both keys and `shouldShowRecordingPrompt`, so a new instance of the same meeting will re-prompt correctly.

### Meeting Detected overlay

Surfaces in `MainContainerView` when a new session is found:
- **Title:** Meeting Detected
- **Notice:** Ensure all participants are aware of recording.
- **Start Listening** — calls `RecordingService.startRecording()`
- **Dismiss** — sets `dismissedMeetingKey`, hides overlay without ending detection

### Thread safety

All detection runs in `Task.detached(priority: .utility)`. UI state is only mutated from `@MainActor`-annotated functions. `startMonitoring`, `stopMonitoring`, and `dismissPrompt` are all `@MainActor`.

---

## Automated Tests

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --jobs 1
```

| Suite | Tests | Coverage |
|---|---|---|
| `MeetingDetectorServiceTests` | 16 | Deduplication, dismiss, meeting-end reset, stop-monitoring, URL stable-key, pattern matching |
| `QuickCaptureParserTests` | 17 | Title, priority P0–P3, today/tomorrow, combined tokens, any order, case, whitespace, edge cases |
| `AIKeychainServiceTests` | 9 | Save, load, overwrite, delete, cross-account isolation, empty-string rejection |
| `RolloverEngineTests` | 9 | First-launch guard, same-day idempotency, overdue rollover, future/nil date, backlog, completed exclusion |
| `CalendarServiceTests` | 11 | Background sync start/stop/idempotency/restart, 900 s interval, initial state, auth refresh |
| `MeetingRetentionServiceTests` | 9 | All policies, mixed-age data, cutoff accuracy, display names, from-rawValue |
| `URLSchemeTests` | 7 | All three URL commands, empty title guard, wrong scheme, unknown host |
| `AssistantServiceTests` | 6 | Empty summary, task listing, backlog/completed exclusion, 5-item cap, priority ordering |
| **Total** | **84** | 0 failures |

All tests use in-memory SwiftData containers or real-Keychain with UUID-scoped accounts (cleaned up in `tearDown`). No mocks, no network calls.

---

## Xcode Project (app target)

The repository includes a generated `Orin.xcodeproj` produced by [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate          # regenerates Orin.xcodeproj from project.yml
```

**Bundle ID:** `com.rconcept.orin`  
**Entitlements:** `Orin.entitlements`  
**Info.plist:** `Orin/Info.plist` (all usage strings + `orin://` URL scheme)

The `OrinTests` target in the Xcode project mirrors the SPM test suite and runs against the app target via `@testable import Orin`.

---

## DMG Packaging

```bash
# Set required environment variables (see script header for details)
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
export APPLE_TEAM_ID="YOURTEAMID"
export NOTARY_APPLE_ID="you@example.com"
export NOTARY_PASSWORD="@keychain:notarytool-password"

./scripts/build_dmg.sh
# → build/Orin.dmg (signed + notarized)

# Skip notarization for local testing:
./scripts/build_dmg.sh --skip-notary
```

The script: archives with Xcode, exports a hardened runtime `.app`, notarizes via `notarytool`, staples the ticket, then packages into a `hdiutil`-created DMG with an Applications symlink.

**Clean-machine install checklist:**
1. Open `Orin.dmg`, drag to `/Applications`
2. Launch — Gatekeeper verifies the notarization ticket
3. Grant Calendar, Microphone, Speech Recognition, and Apple Events permissions when prompted
4. Enable "Launch at login" in Settings → General

---

## Requirements

- macOS 14 (Sonoma) or later
- Full Xcode toolchain (SwiftData macros require Xcode — Command Line Tools alone will fail)

## Build (SPM)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --jobs 1
```

## Test (SPM)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --jobs 1
```

## Run (SPM)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run Orin
```

## Open in Xcode

```bash
open Orin.xcodeproj
```

Set the scheme to `Orin`, select "My Mac" as destination, and press ⌘R.
