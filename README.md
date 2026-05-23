# Orin V1

Orin is a local-first Personal Execution OS for macOS, built with SwiftUI and SwiftData.

## Design System

The UI contract lives in [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md). Treat it as immutable unless intentionally revised. Shared SwiftUI tokens and components live in `Sources/Orin/Views/Shared/OrinDesignSystem.swift`.

## Current Build Slice

This repository contains the first MVP scaffold:

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
- Meeting detector foundation with every-time recording prompt
- Floating recording widget and menu bar start/stop recording state
- Voice command parser foundation for task, backlog, reflow, and summary commands
- Ollama verification status in Settings
- App Intents foundation for Siri Shortcuts: Add Task, Reflow Day, Summarize Today

## Native Integration Notes

Some platform-heavy features now have safe local foundations but still need production entitlements, packaging, or engine integration before release:

- Real microphone/system-audio capture and Whisper transcription
- Login item registration
- Browser-tab meeting detection beyond running app detection
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
