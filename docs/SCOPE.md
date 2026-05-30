# Orin v1 — Product Scope Document

**App name:** Orin  
**Tagline:** Think Less. Do Better.  
**Platform:** macOS (minimum: macOS 14 Sonoma)  
**Architecture:** SwiftUI + SwiftData, local-first, menu bar + main window  
**Bundle ID:** com.clavrit.orin

---

## 1. Product Overview

Orin is a native macOS productivity assistant that unifies task management, meeting intelligence, calendar awareness, and encrypted secret storage into a single local-first application. It is designed for knowledge workers who need their work surface to stay organized automatically — capturing meetings, extracting commitments, surfacing what matters today, and keeping sensitive information secure — without relying on cloud sync or subscriptions. AI inference runs locally via Ollama by default, with optional cloud AI providers as fallback.

---

## 2. Application Shell

### 2.1 Window

| Property | Value |
|---|---|
| Style | Titled bar, unified toolbar |
| Minimum size | 1280 × 720 pt |
| Window management | Standard macOS (minimize, zoom, close) |

### 2.2 Sidebar

The primary navigation element. Collapses to icon-only mode (≈72 pt wide) or expands to full mode (≈240 pt wide). Collapse state is persisted across launches.

**Sidebar modules, in order:**

| # | Module | Icon |
|---|---|---|
| 1 | Today | `sun.max` |
| 2 | All Tasks | `list.bullet` |
| 3 | Calendar | `calendar` |
| 4 | Meetings | `video` |
| 5 | Backlog | `archivebox` |
| 6 | Vault | `lock.shield` |
| 7 | Settings | `gearshape` |

Active module is indicated by an accent-colored 3 pt vertical rule and accent-tinted background on the row. Sidebar has a 1 pt right border separating it from the detail area.

### 2.3 Menu Bar Extra

A persistent `bolt.shield` icon lives in the macOS menu bar. Clicking it opens `OrinMenuBarView` as a `.window`-style menu bar extra. This provides access to core actions without requiring the main window to be open.

### 2.4 Floating Recording Widget

When a recording is active, a floating `NSPanel` capsule appears above all other windows (including full-screen apps). It displays:
- Live recording duration (HH:MM:SS)
- Rolling transcript preview
- Stop button

Tapping Stop calls `recordingService.stopRecording()` and the widget auto-hides.

### 2.5 Quick Capture Window

A floating `NSPanel` accessible via **Control+Option+Space** (or menu item "Quick Capture"). Allows rapid task entry from any context, including while another app is in focus. The captured text is parsed for task intent, then persisted to SwiftData and dismissed.

### 2.6 Theme

Supports System / Light / Dark modes. The `orin.theme.mode` AppStorage key controls this. The preferred color scheme is applied at the root `MainContainerView`.

### 2.7 Design System

`OrinDesignSystem` defines:
- **Colors:** `backgroundPrimary`, `backgroundSecondary`, `sidebarBackground`, `border`, `accent`, `primaryText`, `secondaryText`, all with light/dark variants
- **Fonts:** `body`, `caption`, `heading` — system fonts at specific weights and sizes
- **Spacing:** named spacing tokens
- **Corner radius:** named radius tokens

### 2.8 Launch Behavior

On every launch:
1. SwiftData container is initialized (with auto-recovery on schema mismatch)
2. All services are registered in `ServiceContainer`
3. Meeting retention policy is run (prunes expired meetings)
4. `RolloverEngine.verifyAndExecuteRollover()` runs to catch up any missed daily rollovers
5. `AssistantService.processPendingIntents()` runs to dispatch any queued Siri/URL intents
6. `TranscriptStore.recoverOrphan()` runs to restore any transcript from a prior crash
7. Calendar authorization status is refreshed
8. Calendar background sync starts (if enabled)
9. Meeting detector starts monitoring
10. If onboarding is incomplete, `OnboardingView` sheet is presented (non-dismissable)

---

## 3. Feature: Onboarding

Shown on first launch. Non-interactively dismissable — user must complete the flow.

### Steps

**Step 1 — Welcome**  
Branding screen with app name, tagline, and a "Get Started" button.

**Step 2 — Calendar Permissions**  
Requests EventKit access. Explains what Orin uses it for. Options: Grant Access / Skip.

**Step 3 — Microphone Permissions**  
Requests AVFoundation microphone access. Explains meeting recording. Options: Allow Microphone / Skip.

**Step 4 — Ollama Setup**  
`OllamaSetupView` sub-flow:
- Detects if Ollama is already installed and running at `http://localhost:11434`
- If not installed: shows installation instructions (links to ollama.com)
- Polls for Ollama availability
- Once detected: lists available models, allows selection
- Validates by running a test inference
- Can be skipped (AI features degrade gracefully to text-extraction fallbacks)

**Step 5 — Ready**  
Completion screen. Sets `orin.hasCompletedOnboarding = true`, dismisses sheet, and shows main app.

---

## 4. Feature: Today View

The default landing module. Purpose: show the user exactly what they need to execute today.

### 4.1 Daily Brief Card

Displayed at the top when generated. Contains:
- **Focus statement** — AI-generated single sentence describing today's priority
- **Critical tasks** — list of P0/P1 tasks due today
- **Meetings** — today's calendar events
- **Commitments** — outstanding meeting commitments due today
- **Overdue work** — tasks past their due date
- **Suggested focus blocks** — time blocks recommended by `ReflowEngine`

The brief is generated by `DailyBriefService` from the current task, meeting, and commitment state.

### 4.2 Active Tasks

List of non-completed tasks scheduled for today, ordered by priority (P0 → P3). Each task row shows:
- Priority badge (color-coded: P0=red, P1=orange, P2=blue, P3=gray)
- Task title
- Optional description (collapsed by default, tap to expand)
- Effort estimate (if set)
- Due date badge (color-coded: overdue=red, today=orange, future=green)
- Tag badges
- Subtask progress indicator (e.g. "2/5")
- Completion toggle (checkbox)

Completing a task via the toggle marks it `TaskStatus.completed` and moves it to the Completed section.

### 4.3 Completed Tasks Section

Collapsible section showing tasks completed today. Tapping a completed task can re-activate it.

### 4.4 Commitments Section

Lists `CommitmentItem` records extracted from past meetings with due dates on or before today. Each shows the commitment text, source meeting title, and due date. Can be marked complete inline.

### 4.5 AI Suggestions Section

Shows `AISuggestionItem` records in `pending` status that are not hidden until a future date. Each suggestion shows:
- Suggested action text
- Accept button → creates a `TaskItem` from the suggestion, marks suggestion `accepted`
- Decline button → marks suggestion `declined`
- Snooze button → sets `hiddenUntil` to tomorrow

### 4.6 Reflow Button

Triggers `ReflowEngine` to re-sequence active tasks based on:
- Priority order
- Due dates
- Estimated effort
- Remaining hours in the day
- Today's calendar events (meeting-aware gaps)
- Recommended break intervals

Output: reordered task list and optional focus block suggestions appended to the Daily Brief.

### 4.7 Task Creation

A "New Task" button opens `TaskEditorView` as a sheet. Tasks created here are added to today's active list.

---

## 5. Feature: All Tasks View

Full task library. Shows all active tasks regardless of due date.

### 5.1 Task List

Fetches all `TaskItem` records with `status == .active` and `isBacklog == false`. Grouped or filtered by:
- Priority (P0, P1, P2, P3)
- Due date
- Tags
- Search text

### 5.2 Sorting & Filtering

Controls at the top of the view allow the user to:
- Search by task title
- Filter by priority
- Filter by tag
- Sort by: priority, due date, creation date

### 5.3 Task Row (`TaskRowView`)

Each task shows the same row structure as Today View with the addition of:
- Full description visible when expanded
- Inline subtask list with individual completion toggles
- Tap to open full `TaskEditSheet`

### 5.4 Task Creation (`TaskEditorView`)

Multi-task creation sheet. Fields:
- Title (required)
- Description (optional, multi-line)
- Priority: P0 Critical / P1 High / P2 Medium / P3 Low
- Effort estimate: XS / S / M / L / XL
- Due date (date picker)
- Tags (comma-separated or tag picker)
- Backlog flag (toggles to save directly to backlog instead of active)
- Trigger date (if backlog: date when it auto-activates)

Multiple tasks can be queued in sequence before committing.

### 5.5 Task Editing (`TaskEditSheet`)

Full sheet editor for an existing task. All fields from creation plus:
- Subtask management (add, reorder via drag, rename, delete, toggle complete)
- Delete task action (with confirmation)

### 5.6 Drag Reorder

Tasks support drag-to-reorder within their priority group. First drag shows a one-time hint tooltip (`orin.taskDragHintShown`).

---

## 6. Feature: Backlog View

Stores tasks the user wants to capture but not act on yet.

### 6.1 Backlog List

Fetches all `TaskItem` records with `isBacklog == true`. Organized by trigger date proximity.

### 6.2 Trigger Date System

Each backlog task has an optional `triggerDate`. `RolloverEngine` runs on every launch and at midnight — any backlog task whose `triggerDate` is today or in the past is moved to the active task list (`isBacklog = false`).

### 6.3 Activation

User can manually activate a backlog task (move to active) at any time via a row action or swipe gesture.

### 6.4 Creation

"Add to Backlog" action in `TaskEditorView` (via the backlog flag). Backlog items can also be added from Quick Capture by parsing "add to backlog" intent.

---

## 7. Feature: Calendar View

Displays native macOS calendar events alongside Orin tasks.

### 7.1 Event Display

Fetches events from `CalendarService` (EventKit) for a configurable date range. Events display:
- Event title
- Start/end time
- Calendar color
- Location (if set)

### 7.2 Task Integration

Today's tasks with due times or effort estimates are shown alongside calendar events, giving a unified view of committed time.

### 7.3 Authorization States

Displays distinct UI states:
- Not determined → prompt to grant access
- Denied → shows instructions to re-enable in System Settings
- Authorized → shows event list

### 7.4 Background Sync

`CalendarService` refreshes events on a 15-minute timer when `orin.calendar.backgroundSync` is enabled. Manual refresh available. Toggle in Settings → Calendar.

### 7.5 Sync Status

Displays last-synced timestamp and a manual "Refresh" button.

---

## 8. Feature: Meetings View

Meeting library with full transcript, summary, and action item capabilities.

### 8.1 Layout

Split-view: meeting list on the left, meeting detail on the right.

### 8.2 Meeting List

Shows all non-deleted `MeetingItem` records. Supports:
- **Search** by title, transcript text, participants
- **Folder filtering** — click a folder to filter to its meetings
- **Multi-select** with batch operations (delete, move to folder, export)
- **Sort** by date descending (default)

Each meeting row shows:
- Meeting title
- Date and duration
- Participant avatars/initials (up to 3, then "+N more")
- Transcription status indicator (has transcript / no transcript)
- Analysis status (analyzed / pending / not analyzed)
- Recording indicator (has audio / no audio)

### 8.3 Folder Organization

`MeetingFolderItem` records group meetings. Features:
- Create folder (name input)
- Rename folder (inline edit)
- Delete folder (meetings reassigned to "Unfiled")
- Expand/collapse folders in sidebar
- Drag meetings into folders
- Sort order persisted per folder

**Recurring folder suggestions:** `MeetingDetectorService` tracks same-title meetings on the same day of the week. After 2+ occurrences, Orin suggests creating a dedicated folder (e.g. "Monday Standups"). User can accept or dismiss the suggestion.

### 8.4 Meeting Detail View

Right pane when a meeting is selected:

**Header:**
- Editable title (click to edit inline)
- Date, duration
- Participant list (editable: add/remove names)
- Tags
- Folder assignment dropdown

**Recording Controls (live):**
- Start Recording button (if no recording active)
- While recording: live transcript preview scrolls in real-time; Stop Recording button
- After recording: audio playback controls (if audio file exists)

**Transcript Tab:**
- Full transcript text with speaker labels ("Me:" / "Participant:")
- Timestamps per utterance
- Search within transcript
- Copy transcript to clipboard

**Summary Tab:**
- AI-generated paragraph summary of the meeting
- "Regenerate Summary" button (re-runs `MeetingIntelligenceService`)
- Manual edit of summary text

**Decisions Tab:**
- Bulleted list of decisions extracted from transcript
- Add / edit / delete individual decisions

**Action Items Tab:**
- List of action items with owner and due date
- Extracted automatically by AI; editable
- "Create Task" button per action item → creates `TaskItem` pre-filled from action item

**Commitments Tab:**
- `CommitmentItem` records extracted from transcript
- Shows commitment text, due date, completion status
- Toggle completion inline

**Suggested Tasks Tab:**
- AI-suggested task titles from meeting context
- Accept (creates `TaskItem`) or dismiss each

**Export Meeting:**
- Bottom action bar with "Export" button
- Format picker: JSON / Markdown / Plain Text
- `NSSavePanel` for file destination

### 8.5 Meeting Creation (Manual)

"New Meeting" button opens `MeetingEditorView`:
- Title
- Date and time picker
- Participants (comma-separated or tag input)
- Optional notes pre-fill

### 8.6 Meeting Editing

Inline within the detail view. Title, participants, tags, folder, summary, decisions, and action items are all editable.

### 8.7 Meeting Deletion

Single delete via context menu or swipe. Batch delete via multi-select. Deletion is soft-flagged (`isDeleted = true`) for retention policy compliance; audio files are cleaned up after the retention window.

---

## 9. Feature: Recording & Transcription

### 9.1 Recording Lifecycle

States: `idle → starting → recording → stopping → idle`

**Start recording** (manual or auto-detected):
1. `RecordingService` configures `AVAudioEngine` with mic input node
2. `SystemAudioCaptureService` starts `SCStream` for system audio
3. Both services emit speaker-labeled transcript chunks
4. `TranscriptStore.beginSession()` opens a session with the meeting ID
5. Floating widget appears

**During recording:**
- Mic: `SFSpeechRecognizer` on-device transcription, labeled "Me:"
- System audio: parallel `SFSpeechRecognizer`, labeled "Participant:"
- `TranscriptStore` merges both streams into a single `liveTranscript`
- Auto-checkpoint every 3 seconds to SwiftData
- UserDefaults backup written simultaneously (crash safety)
- Floating widget shows elapsed time and rolling transcript preview

**Stop recording:**
1. `RecordingService.stopRecording()` called
2. `TranscriptStore.finalize()` waits 1.5 s for trailing recognition chunks
3. Best-of-N selection: longest available transcript text wins (live, checkpoint, UserDefaults backup)
4. Integrity check: final text must be non-empty if recording was > N seconds
5. Audio file URL saved to `MeetingItem.audioFilePath` (M4A format)
6. Floating widget hides

### 9.2 Automatic Meeting Detection

`MeetingDetectorService` polls at 5-second intervals (fast-poll: 3 seconds while recording active). Detection sources:

**Native apps (process name check):**
- Zoom.us
- Microsoft Teams
- Slack
- Webex

**Browser tabs (AppleScript URL extraction):**
- Google Chrome
- Microsoft Edge
- Arc Browser

Detected meeting domains: `meet.google.com`, `teams.microsoft.com`, `webex.com`, `zoom.us/j/`

**Prompt behavior:**
- When meeting detected: `MeetingRecordingPromptView` overlay appears (bottom-right of main window)
- Also triggers a local notification with "Start Recording" and "Dismiss" actions
- On Start: creates a new `MeetingItem`, begins recording, navigates to Meetings module
- On Dismiss: hides prompt for the current meeting session

**Auto-stop:**
- When meeting disappears from detection (app quit, tab closed): 1.5 s grace period
- If recording still active after grace: `recordingService.stopRecording()` auto-called

### 9.3 Whisper Transcription (Optional)

`WhisperTranscriptionService` provides an alternative to `SFSpeechRecognizer` via a local whisper.cpp HTTP server. Endpoint configurable at `orin.whisper.endpoint`. When configured, it is preferred over on-device speech recognition. Falls back gracefully if unavailable.

### 9.4 Transcript Recovery

On every app launch, `TranscriptStore.recoverOrphan()` checks for:
- A UserDefaults backup with a meeting ID that exists in SwiftData
- The corresponding `MeetingItem` has empty or shorter transcript
- If so: restores the backed-up text to the meeting record

This ensures a transcript is never lost even if the app was force-quit or crashed mid-recording.

---

## 10. Feature: Meeting Intelligence (AI Analysis)

Runs after recording stops (or on-demand via "Analyze Meeting" button). Powered by `MeetingIntelligenceService`.

### 10.1 AI Provider Fallback Chain

Priority order:
1. Ollama (local, preferred)
2. OpenAI
3. Anthropic Claude
4. Google Gemini

If the primary provider fails, the next is tried automatically. If all fail, a text-extraction fallback extracts content using keyword heuristics on the raw transcript.

### 10.2 Generated Artifacts

From the meeting transcript, the AI produces:
- **Summary** (paragraph)
- **Decisions** (bulleted list)
- **Action items** (with inferred owner and due date)
- **Commitments** (promises made, with due dates)
- **Suggested task titles** (for creation as `TaskItem` records)

All artifacts are stored on the `MeetingItem` and displayed in the Meeting Detail View.

### 10.3 Auto-Analysis

Controlled by `orin.meetings.autoAnalyze` setting. When enabled, analysis runs automatically after recording stops if meeting duration exceeds `orin.meetings.minDurationMinutes`.

---

## 11. Feature: Vault

Encrypted local storage for sensitive information (passwords, API keys, private notes, etc.).

### 11.1 Encryption

- AES-256 symmetric encryption via CryptoKit
- Master key stored in macOS Keychain (`com.orin.vault.masterkey`)
- Each `VaultItem.encryptedData` field holds encrypted bytes
- Key is zeroed from memory on service deallocation

### 11.2 Authentication

**Primary:** Touch ID / Face ID (LocalAuthentication framework)  
**Fallback:** System password (LAPolicy.deviceOwnerAuthentication)

### 11.3 Session Management

After successful unlock, the vault remains unlocked for **5 minutes** (in-memory RAM cache). After timeout, the next access requires re-authentication. The vault can be manually locked at any time.

### 11.4 Lockout

After **5 consecutive failed recovery attempts**, the vault enters a lockout state for **30 minutes**. Counter and lockout timestamp stored in UserDefaults.

### 11.5 Recovery Key System

On first vault unlock:
- A 64-character hex recovery key is generated
- `VaultRecoveryOnboardingView` displays it with options: Copy to clipboard, Export to file, Print
- User must acknowledge they have saved it
- The flag `orin.vault.recoveryKeyShown` is set

**Recovery flow:**
1. Vault is locked and biometric/password auth fails (or is unavailable)
2. User taps "Recover with Key"
3. `VaultRecoveryKeyEntryView` prompts for the 64-character key
4. If valid: vault unlocks and `VaultRelinkView` prompts to re-register biometrics
5. If invalid: failed attempt counter increments (lockout after 5 failures)

**Reset flow:**
- In `VaultSecuritySettingsView` or after all recovery attempts exhausted
- Shows explicit confirmation ("This will delete all vault items")
- Clears all `VaultItem` records, regenerates master key
- Presents new recovery key via `VaultRecoveryOnboardingView`

### 11.6 Vault Item Types

VaultItems have a type field. Current types:
- Password
- API Key
- Secure Note
- Other

### 11.7 Vault UI States

- **Locked** — shows lock icon and "Unlock" button; triggers biometric auth on tap
- **Unlocked** — shows item list
- **Corrupted** — shows error state with reset option
- **RecoveryRequired** — forces recovery key entry before unlock

### 11.8 Vault Item List

When unlocked:
- List of `VaultItem` records grouped by type
- Each row: title, type badge, last-accessed timestamp
- Tap to reveal / copy the decrypted secret (auto-relocks item display after 30 seconds)
- Swipe or context menu to delete (with confirmation)

### 11.9 Item Creation/Editing

Sheet with:
- Title
- Type picker
- Secret value (SecureField while typing, optional reveal toggle)
- Save → encrypts and stores `encryptedData`

### 11.10 Vault Settings (`VaultSecuritySettingsView`)

- Toggle biometric authentication
- View recovery key (re-authenticates first)
- Reset vault (with confirmation)
- Export vault metadata (titles + types only, no encrypted data)

---

## 12. Feature: Settings View

Full configuration panel organized into sections.

### 12.1 General

- **Theme:** System / Light / Dark (writes to `orin.theme.mode`)
- **Launch at Login:** Toggle (uses `SMAppService`)

### 12.2 AI Providers

Four provider rows: Ollama, OpenAI, Anthropic Claude, Google Gemini.

**Ollama:**
- Endpoint URL field (default: `http://localhost:11434`)
- Auto-detect / manual entry
- Model selector (populated by querying the Ollama API)
- "Test Connection" button → `AIProviderTestService` runs a test inference and reports result
- Re-run `OllamaSetupView` wizard button

**OpenAI / Claude / Gemini:**
- API key field (stored in Keychain via `AIKeychainService`)
- "Test Connection" button per provider
- Priority order indicator (drag to reorder fallback chain)

Provider test results show: ✓ Connected with model name / ✗ Error with message / ⏳ Testing.

### 12.3 Calendar

- **Calendar Sync:** Toggle background 15-minute refresh (`orin.calendar.backgroundSync`)
- **Authorization Status:** shows current EventKit permission state
- **Re-request Permission:** button (opens System Settings if denied)

### 12.4 Meetings

- **Auto-Analyze:** Toggle (`orin.meetings.autoAnalyze`)
- **Minimum Duration:** Stepper for minimum meeting duration to trigger auto-analysis (`orin.meetings.minDurationMinutes`)
- **Retention Policy:** Picker — 30 days / 90 days / 180 days / Forever (`orin.meetings.retentionDays`)
- **Whisper Endpoint:** Optional URL field for whisper.cpp server (`orin.whisper.endpoint`)

### 12.5 Data Management

- **Export All Data:** triggers `MeetingDataService` to build an `OrinExportPackage` (JSON), opens `NSSavePanel`
- **Import Data:** opens `NSOpenPanel` for a `.json` file, `MeetingDataService` imports it with deduplication
- **Export Package contents:** Meetings, folders, tasks, vault metadata (no encrypted data), settings snapshot

### 12.6 Vault

Shortcut to `VaultSecuritySettingsView` inline.

### 12.7 Privacy

- Toggle microphone usage
- Toggle screen capture (for system audio / meeting detection via browser)
- Links to open System Settings → Privacy for each permission type
- "Clear All Transcripts" — bulk-deletes all transcript text from all meetings (audio files untouched)

### 12.8 Troubleshooting

- **App version and build number**
- **Logs export** — copy recent error log to clipboard
- **Reset Application State** (DEBUG builds only) — opens `DebugResetView` which clears all SwiftData, UserDefaults, Keychain entries, and resets `hasCompletedOnboarding`
- **Error history** — shows recent errors from `ErrorManager` with severity and recovery actions

---

## 13. Feature: Export & Import

### 13.1 Single Meeting Export

Available from Meeting Detail View. Formats:

| Format | Contents |
|---|---|
| JSON | All fields: title, date, duration, participants, transcript, summary, decisions, action items, suggested tasks, tags, audio path |
| Markdown | Structured document: header, summary, transcript, decisions, action items |
| Plain Text | Linear text dump |

NSSavePanel opens for file naming and destination.

### 13.2 Full App Export (`OrinExportPackage`)

Structure:
```json
{
  "version": "1.0",
  "exportedAt": "<ISO8601 timestamp>",
  "meetings": [...],
  "folders": [...],
  "tasks": [...],
  "vaultMetadata": [...],
  "settings": {
    "theme": "...",
    "calendarSync": true,
    "sidebarCollapsed": false,
    "retentionDays": 90
  }
}
```

### 13.3 Import

`MeetingDataService` reads the JSON, validates the version field, then:
1. Inserts new records only (skips if ID already exists — no overwrite)
2. Re-links `MeetingItem` → `MeetingFolderItem` by persisted ID
3. Re-links `TaskItem` → `MeetingItem` (for meeting-sourced tasks)
4. Restores folder sort order and expansion state

---

## 14. Feature: Daily Rollover

`RolloverEngine` runs on every app launch and registers for a midnight `NSCalendar` notification.

**Rollover logic:**
1. Checks `com.orin.lastRolloverTimestamp`
2. If last rollover was not today: executes rollover
3. Rollover actions:
   - Tasks with `dueDate < today` and `status == .active`: reset `dueDate` to today (carry-forward)
   - Backlog tasks with `triggerDate <= today`: set `isBacklog = false` (activate)
4. Updates timestamp

---

## 15. Feature: Reflow Engine

`ReflowEngine` re-sequences today's task list and suggests focus blocks.

**Inputs:**
- All active tasks (priority, effort estimate, due date)
- Today's calendar events (from `CalendarService`)
- Current time
- User's focus preferences (`FocusPatternItem` if available)

**Outputs:**
- Reordered task array (priority → deadline → effort)
- Focus block suggestions: time windows between calendar events
- Break recommendations (after long focus blocks)
- Warning if high-priority tasks won't fit in remaining day

Results are surfaced in the Daily Brief card on Today View.

---

## 16. Feature: Daily Brief

`DailyBriefService` generates a `DailyBriefItem` each morning (or on-demand).

**Contents:**
- Focus statement (AI-generated or heuristic)
- Critical tasks (P0/P1 due today or overdue)
- Today's meetings (from calendar events)
- Commitments due today
- Overdue tasks count
- Suggested focus blocks (from `ReflowEngine`)

Stored in SwiftData, displayed at the top of Today View.

---

## 17. Feature: Error Handling

### 17.1 `ErrorManager`

Singleton. Receives `ApplicationError` values with:
- `message: String` (user-facing)
- `severity: Severity` — `.low`, `.medium`, `.high`, `.critical`
- `recoveryAction: RecoveryAction` — `.dismiss`, `.retry(handler)`, `.openSettings(permissionType)`

### 17.2 Error UI

**Toast** (`ErrorToastView`): auto-dismisses after 3 seconds. Used for `.low` and `.medium` severity. Shown via `.errorHandlingOverlay()` modifier on `MainContainerView`.

**Modal** (`ErrorModalView`): full-screen overlay. Used for `.high` and `.critical` severity. Shows message and recovery action buttons.

### 17.3 Permission Errors

When a required permission (mic, screen capture, calendar, automation) is missing, the error includes an `.openSettings` recovery action that links directly to the relevant System Settings pane.

---

## 18. Feature: App Intents & URL Scheme

### 18.1 App Intents (Siri / Shortcuts)

Three registered intents:

| Intent | Siri phrase | Action |
|---|---|---|
| WhatsLeftTodayIntent | "What's left today in Orin?" | Returns summary of active tasks |
| ReflowMyDayIntent | "Reflow my day in Orin" | Triggers `ReflowEngine` |
| AddTaskIntent | "Add task [title] in Orin" | Creates `TaskItem` |

### 18.2 URL Scheme (`orin://`)

| URL | Action |
|---|---|
| `orin://whatsLeftToday` | Shows today summary |
| `orin://reflow` | Triggers day reflow |
| `orin://addTask?title=X&due=YYYY-MM-DD` | Creates task with title and optional due date |

Intents and URLs are queued in UserDefaults if the app is not running and processed on next launch by `AssistantService.processPendingIntents()`.

---

## 19. Feature: Notifications

`MeetingNotificationService` (UNUserNotificationCenter delegate).

**Notification types:**

| Trigger | Message | Actions |
|---|---|---|
| Meeting detected | "Meeting detected in [App Name]" | "Start Recording", "Dismiss" |
| Recording active | "Recording in progress" | "Stop Recording" |

Actions are handled via `UNNotificationResponse`, which posts internal notifications (`orinNotificationStartRecording`, `orinNotificationStopRecording`, `orinNotificationDismissMeeting`) picked up by `MainContainerView`.

---

## 20. Data Models (Complete)

### TaskItem

| Field | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| title | String | Required |
| taskDescription | String? | Optional notes |
| priority | TaskPriority | p0/p1/p2/p3 |
| effortEstimate | String? | XS/S/M/L/XL |
| dueDate | Date? | |
| tags | [String] | |
| status | TaskStatus | active/completed |
| isBacklog | Bool | |
| triggerDate | Date? | Backlog activation date |
| createdAt | Date | |
| completedAt | Date? | |
| subtasks | [SubTaskItem] | Cascade delete |
| sourceMeeting | MeetingItem? | If created from meeting |

### SubTaskItem

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| title | String | |
| isCompleted | Bool | |
| sortIndex | Int | Drag order |
| parentTask | TaskItem | Inverse relationship |

### MeetingItem

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| title | String | |
| date | Date | |
| durationSeconds | Int | |
| participants | [String] | |
| transcript | String | Raw merged text |
| summary | String? | AI-generated |
| decisions | [String] | |
| actionItems | [String] | |
| suggestedTasks | [String] | |
| tags | [String] | |
| audioFilePath | String? | Relative path M4A |
| isDeleted | Bool | Soft delete |
| deletedAt | Date? | |
| transcriptDeletedAt | Date? | Retention tracking |
| audioDeletedAt | Date? | Retention tracking |
| folder | MeetingFolderItem? | |
| commitments | [CommitmentItem] | Cascade delete |

### MeetingFolderItem

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| name | String | |
| isExpanded | Bool | |
| sortOrder | Int | |
| meetings | [MeetingItem] | |

### CommitmentItem

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| text | String | |
| dueDate | Date? | |
| isCompleted | Bool | |
| meeting | MeetingItem | Inverse relationship |

### VaultItem

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| title | String | |
| encryptedData | Data | AES-256 ciphertext |
| itemType | String | Password/APIKey/Note/Other |
| lastAccessedAt | Date? | |
| createdAt | Date | |

### AISuggestionItem

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| text | String | Suggestion content |
| status | SuggestionStatus | pending/accepted/declined |
| hiddenUntil | Date? | Snooze until |
| sourceMeeting | MeetingItem? | |
| createdAt | Date | |

### DailyBriefItem

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| date | Date | Day this brief covers |
| focusStatement | String | |
| criticalTaskTitles | [String] | |
| meetingTitles | [String] | |
| commitmentTexts | [String] | |
| overdueCount | Int | |
| focusBlockSuggestions | [String] | |

### FocusPatternItem

| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| preferredStartHour | Int | 0–23 |
| preferredEndHour | Int | 0–23 |
| peakCompletionHour | Int | |
| interruptionsPerDay | Int | |

---

## 21. Complete User Flows

### Flow 1: First Launch

```
App opens
  → hasCompletedOnboarding == false
  → OnboardingView (non-dismissable sheet)
    → Welcome screen → "Get Started"
    → Calendar permission request → Grant / Skip
    → Microphone permission request → Allow / Skip
    → OllamaSetupView:
        → Detect Ollama at localhost:11434
        → If not found: show install instructions, poll for availability
        → If found: list models, select, test inference, confirm
        → Skip option available
    → "You're ready!" completion screen
    → Tap "Start Using Orin"
  → hasCompletedOnboarding = true, sheet dismisses
  → MainContainerView renders with Today module selected
  → RolloverEngine checks for pending rollover
  → MeetingDetector begins polling
  → Calendar sync starts (if permitted)
```

### Flow 2: Daily Morning Routine

```
User opens Orin (or app wakes from background)
  → RolloverEngine.verifyAndExecuteRollover():
      → Carries forward incomplete tasks from yesterday
      → Activates backlog items whose triggerDate <= today
  → DailyBriefService generates today's brief (async)
  → Today View renders:
      → Daily Brief card appears at top (loading spinner until generated)
      → Active tasks listed by priority
      → Commitments due today
      → Pending AI suggestions
  → User reviews Daily Brief → focus statement + critical tasks
  → User taps "Reflow" if schedule changed
      → ReflowEngine re-orders tasks around today's calendar events
      → Focus block suggestions appear in brief
  → User works through task list:
      → Tap checkbox → task moves to Completed section
      → Tap task title → full task edit sheet
```

### Flow 3: Capture a Task Quickly

**Option A — Quick Capture Window:**
```
User is in another app
  → Presses Control+Option+Space
  → Floating NSPanel appears over current app
  → Types "Review Q3 report by Friday"
  → Presses Enter
  → QuickCaptureWindowManager parses intent:
      → Title: "Review Q3 report"
      → Due: this Friday
  → TaskItem saved to SwiftData
  → Panel dismisses
```

**Option B — Task Editor:**
```
User in Today or All Tasks view
  → Taps "New Task"
  → TaskEditorView sheet opens
  → Fills: Title, Priority (P1), Effort (M), Due date, Tags
  → Taps Save
  → TaskItem inserted, list refreshes
```

**Option C — Siri / Shortcuts:**
```
User says "Add task Review Q3 report due Friday in Orin"
  → AddTaskIntent fires
  → If app running: AssistantService.handleURL creates task immediately
  → If app not running: saved to UserDefaults pending intent
      → Next launch: processPendingIntents() creates task
```

### Flow 4: Meeting Recording (Auto-Detected)

```
User starts a Zoom call
  → MeetingDetectorService detects "zoom.us" process (5s poll)
  → MeetingRecordingPromptView overlay appears bottom-right
  → Local notification sent: "Meeting detected in Zoom"
  → User taps "Start Recording" (in overlay OR notification)
  → startRecordingFromDetectedMeeting():
      → Creates MeetingItem: "Meeting — [timestamp]"
      → Saves to SwiftData
      → Navigates sidebar to Meetings module
      → Dismisses detection prompt
      → recordingService.startRecording(for: meetingID)
      → systemAudioService.startCapturing(for: meetingID)
      → transcriptStore.beginSession(...)
      → FloatingRecordingWidgetWindowManager.show(...)
  → Floating widget visible: duration counting, transcript preview scrolling
  → User conducts meeting
  → Zoom call ends
  → MeetingDetectorService: zoom.us disappears from process list
  → onMeetingEnded fires → 1.5s grace period
  → recordingService.stopRecording() auto-called
  → TranscriptStore.finalize():
      → Waits 1.5s for trailing recognition
      → Selects best-of-N transcript text
      → Saves final transcript + audio path to MeetingItem
  → Floating widget hides
  → (If autoAnalyze enabled): MeetingIntelligenceService runs
      → AI generates: summary, decisions, commitments, action items, suggestions
      → Saved to MeetingItem
```

### Flow 5: Meeting Recording (Manual)

```
User in Meetings module, MeetingDetailView for an existing or new meeting
  → Taps "Start Recording"
  → RecordingService starts
  → Live transcript appears in Transcript tab, scrolling in real-time
  → Floating widget shows duration
  → User taps "Stop Recording" (in detail view OR floating widget)
  → Recording stops, finalization runs
  → User navigates to Summary tab → "Analyze Meeting" (if not auto-analyzed)
  → MeetingIntelligenceService generates artifacts
  → User reviews Action Items → taps "Create Task" on each relevant item
      → TaskItem pre-filled from action item text
  → User taps "Export" → selects Markdown → NSSavePanel
```

### Flow 6: Vault — Store a New Secret

```
User navigates to Vault module
  → VaultView shows Locked state
  → User taps "Unlock"
  → LAContext.evaluatePolicy runs Touch ID / Face ID prompt
  → If success:
      → Vault unlocks (5-minute session begins)
      → VaultItem list renders
  → User taps "+"
  → Item creation sheet:
      → Title: "AWS Root Key"
      → Type: API Key
      → Secret: [pastes value into SecureField]
      → Taps Save
  → VaultService encrypts secret with master key → stores Data in VaultItem.encryptedData
  → Item appears in list
  → After 5 minutes: vault auto-locks (next access requires re-authentication)
```

### Flow 7: Vault Recovery

```
User's Touch ID fails repeatedly (hardware issue)
  → Vault shows authentication error
  → User taps "Recover with Key"
  → VaultRecoveryKeyEntryView presents
  → User types/pastes their 64-character hex key
  → VaultService validates key against stored verification token
  → If valid:
      → Vault unlocks
      → VaultRelinkView offers: "Register Biometrics Again"
      → User completes Touch ID re-registration
  → If invalid (5 consecutive failures):
      → 30-minute lockout begins
      → Error displayed with retry-after time
```

### Flow 8: Settings — Add OpenAI as Fallback Provider

```
User navigates to Settings → AI Providers
  → Sees Ollama (active, green checkmark)
  → Taps "OpenAI" row
  → API Key field appears
  → User pastes key
  → Taps "Test Connection"
  → AIProviderTestService sends test request
  → "✓ Connected — gpt-4o" result shown
  → User drags OpenAI row to position 2 in fallback chain
  → Settings saved
  → Next time Ollama is unavailable: OpenAI automatically used
```

### Flow 9: Export All Data

```
User navigates to Settings → Data Management
  → Taps "Export All Data"
  → MeetingDataService builds OrinExportPackage (async)
      → Fetches all meetings, folders, tasks, vault metadata, settings
      → Serializes to JSON with ISO8601 dates
  → NSSavePanel opens: "Save Orin Backup"
  → User names file: "orin-backup-2026-05-30.json"
  → File written to chosen location
  → Success toast appears
```

### Flow 10: Import Data to New Machine

```
User on new Mac, has exported JSON backup
  → Settings → Data Management → Import Data
  → NSOpenPanel opens
  → User selects backup JSON file
  → MeetingDataService reads file:
      → Validates version field
      → For each meeting: if ID not in DB → insert new MeetingItem
      → For each folder: if ID not in DB → insert new MeetingFolderItem
      → For each task: if ID not in DB → insert new TaskItem
      → Re-links meeting→folder, task→meeting relationships
      → Restores folder sort order
  → Success: "Imported 47 meetings, 183 tasks, 12 folders"
  → Vault items NOT imported (encrypted data excluded from export by design)
```

---

## 22. Required macOS Permissions

| Permission | Framework | Purpose | Behavior if Denied |
|---|---|---|---|
| Microphone | AVFoundation | Meeting recording | Recording unavailable; error shown |
| Screen & System Audio | ScreenCaptureKit | Participant audio capture | Mic-only recording (no speaker labels) |
| Calendar | EventKit | Calendar view and meeting scheduling | Calendar module shows permission prompt |
| Automation (Accessibility) | AppleScript/NSAppleScript | Browser meeting URL detection | Browser-based meeting detection disabled |
| Local Network | (implicit) | Ollama localhost communication | AI features fall back to cloud providers |
| Notifications | UNUserNotificationCenter | Meeting detection and recording alerts | No push notifications; overlay only |

---

## 23. Persistence Architecture

| Layer | Technology | Contents |
|---|---|---|
| Primary store | SwiftData (SQLite) | All models (tasks, meetings, vault, etc.) |
| App settings | AppStorage (UserDefaults) | Theme, sidebar, sync flags |
| Crash-safe transcript | UserDefaults | Live transcript backup (overwritten every 3s) |
| API keys | Keychain | AI provider API keys |
| Vault master key | Keychain (access control) | AES-256 master key, biometric-protected |
| Rollover timestamp | UserDefaults | Last rollover date |
| Pending intents | UserDefaults | Queued Siri/URL intents |
| Audio files | App Support directory | M4A recordings |

**SwiftData recovery strategy:**
1. Normal open (fast path)
2. Delete store + retry (schema mismatch recovery)
3. In-memory fallback (disk unwritable — app still launches, data is transient)

---

## 24. Testing Coverage

12 test files covering:
- `RolloverEngine` — rollover logic, edge cases (same-day, multi-day miss)
- `VaultService` — encrypt/decrypt, lockout, session expiry
- `TranscriptStore` — session lifecycle, checkpoint, orphan recovery, finalization
- `MeetingDetectorService` — detection logic, fast poll, auto-stop grace
- `MeetingRetentionService` — pruning logic per policy
- `MeetingDataService` — export serialization, import deduplication
- `AIService` — provider fallback chain
- `ReflowEngine` — reorder logic
- `QuickCaptureParser` — intent parsing from raw text
- `TaskItem` / `SubTaskItem` model validation
- `DailyBriefService` — brief generation from mock data
- Integration: app init with in-memory SwiftData container

Total: **62 tests, all passing**.

---

*Generated from source — covers all 60 source files, 24 services, 22 views, 9 SwiftData models, and all user-facing flows as implemented in Orin v1.*
