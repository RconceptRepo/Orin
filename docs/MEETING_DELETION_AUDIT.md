# Meeting Deletion Audit

**Date:** 2026-05-31

---

## Pre-Fix State

### Deletion paths and what they cleaned up

| Deletion path | MeetingItem | Audio file | TranscriptChunk | TranscriptSegment | FolderSummaryItem |
|---|---|---|---|---|---|
| `MeetingsView.deleteMeeting()` | ✅ deleted | ✅ removed | ❌ **ORPHANED** | ❌ **ORPHANED** | ❌ **ORPHANED** |
| `MeetingDetailView.deleteFullMeeting()` | ✅ deleted | ✅ removed | ❌ **ORPHANED** | ❌ **ORPHANED** | ❌ **ORPHANED** |
| `MeetingDetailView.deleteTranscript()` | kept | kept | ❌ **ORPHANED** | ❌ **ORPHANED** | kept |
| `MeetingRetentionService.pruneExpiredMeetings()` | ✅ deleted | ✅ removed | ❌ **ORPHANED** | ❌ **ORPHANED** | ❌ **ORPHANED** |

**Impact of orphaned records:**
- `TranscriptChunk` records: accumulate silently. For a 60-minute meeting with ~3,900 chunks, each chunk stores ~50–200 bytes of labeled text. Total: ~200–800 KB of orphaned data per deleted meeting.
- `TranscriptSegment` records: 90–360 records per meeting (post-merge). Each ~100 bytes. Total: ~10–40 KB orphaned per deleted meeting.
- `FolderSummaryItem` records: the summary for the deleted meeting's folder would become stale (showing data from a meeting that no longer exists) and would never be regenerated automatically.

---

## Fix: `ModelContext.deleteMeetingFully`

Added to `Sources/Orin/Extensions/ModelContext+SafeSave.swift`:

```swift
func deleteMeetingFully(_ meeting: MeetingItem) {
    let meetingID = meeting.id
    
    // 1. Remove audio file from disk
    if let path = meeting.audioFilePath {
        try? FileManager.default.removeItem(atPath: path)
    }
    
    // 2. Delete all TranscriptChunk records
    let allChunks = (try? fetch(FetchDescriptor<TranscriptChunk>())) ?? []
    allChunks.filter { $0.meetingId == meetingID }.forEach { delete($0) }
    
    // 3. Delete all TranscriptSegment records
    let allSegs = (try? fetch(FetchDescriptor<TranscriptSegment>())) ?? []
    allSegs.filter { $0.meetingId == meetingID }.forEach { delete($0) }
    
    // 4. Invalidate FolderSummaryItem for the meeting's folder
    if let folderID = meeting.folderID {
        let allSummaries = (try? fetch(FetchDescriptor<FolderSummaryItem>())) ?? []
        allSummaries.filter { $0.folderID == folderID }.forEach { delete($0) }
    }
    
    // 5. Delete the MeetingItem
    delete(meeting)
}
```

**Note:** Does NOT call `safeSave` — callers are responsible for saving, enabling batched deletions.

---

## Post-Fix State

| Deletion path | MeetingItem | Audio file | TranscriptChunk | TranscriptSegment | FolderSummaryItem |
|---|---|---|---|---|---|
| `MeetingsView.deleteMeeting()` | ✅ | ✅ | ✅ | ✅ | ✅ invalidated |
| `MeetingDetailView.deleteFullMeeting()` | ✅ | ✅ | ✅ | ✅ | ✅ invalidated |
| `MeetingDetailView.deleteTranscript()` | kept | kept | ✅ | ✅ | kept |
| `MeetingRetentionService.pruneExpiredMeetings()` | ✅ | ✅ | ✅ | ✅ | ✅ invalidated |

---

## `deleteTranscript()` Behaviour

When the user selects "Delete Transcript" from the meeting 3-dot menu:
- `meeting.transcript` is set to `""`
- `meeting.transcriptDeletedAt` is set to `Date()`
- All `TranscriptChunk` records for this meeting are deleted
- All `TranscriptSegment` records for this meeting are deleted

This matches the user's expectation: "Delete Transcript" removes all transcript data, freeing storage.

Audio recording (`audioFilePath`) is NOT affected by "Delete Transcript" — it requires a separate "Delete Recording" action.

---

## Folder Deletion Behaviour (unchanged)

When a folder is deleted (`deleteFolder()`):
- All meetings with `folderID == folder.id` have their `folderID` set to `nil` (unlinked, not deleted)
- The `MeetingFolderItem` is deleted
- `FolderSummaryItem` records for the deleted folder are NOT cleaned up (low priority — they're orphaned in the DB but never displayed)

**Recommendation for future:** Also clean up `FolderSummaryItem` on folder deletion. Not implemented in this pass to stay within scope.

---

## Orphan Cleanup for Existing Installs

On the next retention prune (app launch), expired meetings will be fully cleaned via `deleteMeetingFully`. Non-expired meetings with orphaned chunks/segments from before this fix will remain until those meetings are manually deleted or expire.

For a clean sweep of existing orphans, a one-time migration could be added to `OrinApp.init()`, but this is low priority given the small data footprint.
