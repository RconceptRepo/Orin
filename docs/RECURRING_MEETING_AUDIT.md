# Recurring Meeting Audit Report

**Date:** 2026-05-31

---

## Pre-Implementation State

### MeetingFolderItem (pre-change)

| Field | Type | Present |
|---|---|---|
| id | UUID | ✅ |
| name | String | ✅ |
| createdAt | Date | ✅ |
| updatedAt | Date | ✅ |
| isExpanded | Bool | ✅ |
| sortIndex | Int | ✅ |
| **description** | String | ❌ Missing |
| **color** | String | ❌ Missing |
| **icon** | String | ❌ Missing |

### Folder-Meeting Relationship

- `MeetingItem.folderID: UUID?` — soft reference (no SwiftData relationship)
- `MeetingFolderItem` has NO back-reference to meetings
- Queries filter: `meetings.filter { $0.folderID == folder.id }`

### Existing Recurring Detection (`refreshRecurringSuggestion`)

- **Algorithm:** Groups meetings by `(normalizedTitle)#(sortedParticipants)` signature
- **Signals:** Title (exact) + Participants (exact). Two signals only.
- **Limitations:**
  - Exact title match required — "Standup" and "Team Standup" not grouped
  - Single suggestion shown at a time
  - No confidence score
  - No day/time pattern detection
  - No topic similarity
  - Shows as an `.alert` (blocking)

### GranolaFolderBlockView

- "Rename Folder" button was a stub (`/* trigger rename */`) — never implemented
- No folder-detail view (clicking folder only expanded/collapsed)
- No FolderSummaryService or cross-meeting intelligence

### MeetingDataService

- `MeetingFolderSnapshot` missing `description`, `color`, `icon` fields
- Import/export did not preserve these fields

---

## Post-Implementation State

### MeetingFolderItem (post-change)

| Field | Type | Default |
|---|---|---|
| id | UUID | UUID() |
| name | String | required |
| **folderDescription** | String | "" |
| createdAt | Date | Date() |
| updatedAt | Date | Date() |
| isExpanded | Bool | true |
| sortIndex | Int | 0 |
| **color** | String | "blue" |
| **icon** | String | "folder" |

### New Models

- `FolderSummaryItem` — persisted AI cross-meeting analysis per folder

### New Services

- `RecurringMeetingService` — 5-signal confidence scoring
- `FolderSummaryService` — AI-powered cross-meeting intelligence

### UI Changes

- `GranolaFolderBlockView` — "Rename Folder" now triggers `RenameFolderSheet`
- `GranolaFolderBlockView` — folder name tap → `FolderDetailView` in right panel
- `FolderDetailView` — new: shows Meetings + Intelligence tabs
- `RecurringSuggestionBanner` — inline non-blocking suggestion cards (multiple at once)
- `MeetingsView` — up to 3 suggestion banners shown simultaneously

---

## Folder-Meeting Relationship Analysis

The existing soft-reference design (`MeetingItem.folderID: UUID?`) is preserved. This was an intentional design choice:

**Pros:**
- Simple to query (single fetch, filter by folderID)
- Safe to delete folder without cascading meeting deletion
- Import/export can reconstruct relationships by ID

**Cons:**
- No referential integrity (orphaned folderIDs if folder deleted)
- Cannot use SwiftData relationship queries (e.g., `@Relationship`)

The current `deleteFolder` function correctly orphans meetings (`meeting.folderID = nil`) before deleting the folder, preventing stale references.

---

## Detection Algorithm Comparison

| Signal | Previous | Now |
|---|---|---|
| Title similarity | Exact match only | Jaccard token similarity ≥ 55% |
| Participants | Exact set match | Jaccard similarity (pairwise avg) |
| Day of week | Not detected | Fraction on same weekday |
| Time of day | Not detected | Spread of start times |
| Topic similarity | Not detected | Keyword overlap in summaries |
| Confidence score | None | Weighted (35/25/20/15/5) |
| Threshold | N/A | 60% |
| Display | Single `.alert` | Up to 3 inline banners |
