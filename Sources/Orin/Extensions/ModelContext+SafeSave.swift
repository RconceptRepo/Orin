import OSLog
import SwiftData

private let storageLogger = Logger(subsystem: "com.clavrit.orin", category: "Storage")

extension ModelContext {
    /// Save the context, routing any failure through `ErrorManager` instead of silently discarding it.
    ///
    /// Replaces `try? save()` throughout the app.  The `context` parameter appears in
    /// the user-facing error message: "Your **task** could not be saved."
    ///
    /// - Parameter context: Lowercase noun describing what was being saved, e.g. `"task"`, `"meeting"`.
    func safeSave(
        context: String = "data",
        file: String = #fileID,
        line: Int = #line
    ) {
        do {
            try save()
        } catch {
            storageLogger.error("ModelContext.save failed [\(context)]: \(error)")
            ErrorManager.shared.report(.storageSaveFailed(context: context))
        }
    }

    /// Save the context with automatic retry on transient failures.
    ///
    /// Attempts up to `retries` times with no delay between attempts.  Each
    /// failure is logged at warning level; a final failure is escalated via
    /// `ErrorManager` just like `safeSave`.
    ///
    /// Use this in performance-sensitive paths (checkpoint timers, finalization)
    /// where a single transient WAL-checkpoint contention should not surface as
    /// a user-visible error.
    ///
    /// - Parameters:
    ///   - context: Lowercase noun describing what was being saved, e.g. `"transcript checkpoint"`.
    ///   - retries: Maximum number of attempts (default 2).
    func safeSaveWithRetry(
        context: String = "data",
        retries: Int = 2,
        file: String = #fileID,
        line: Int = #line
    ) {
        var lastError: Error?
        for attempt in 1...max(1, retries) {
            do {
                try save()
                if attempt > 1 {
                    storageLogger.info("ModelContext.save succeeded on attempt \(attempt) [\(context)]")
                }
                return
            } catch {
                lastError = error
                storageLogger.warning("ModelContext.save attempt \(attempt)/\(retries) failed [\(context)]: \(error)")
            }
        }
        storageLogger.error("ModelContext.save failed after \(retries) attempts [\(context)]: \(String(describing: lastError))")
        ErrorManager.shared.report(.storageSaveFailed(context: context))
    }

    // MARK: - Fully-clean meeting deletion
    //
    // Single authoritative deletion path for a MeetingItem.
    // Cleans up every associated record so no orphaned data remains:
    //
    //   • Audio recording file (on disk)
    //   • TranscriptChunk records  (crash-recovery layer)
    //   • TranscriptSegment records (conversation-timeline layer)
    //   • FolderSummaryItem for the meeting's folder (invalidated; must be regenerated)
    //   • The MeetingItem itself
    //
    // Does NOT call safeSave — callers are responsible for saving so batched
    // deletions (e.g. prune, bulk-delete) can share a single commit.

    func deleteMeetingFully(_ meeting: MeetingItem) {
        let meetingID = meeting.id

        // 1. Remove audio file from disk (best-effort)
        if let path = meeting.audioFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }

        // 2. Delete all TranscriptChunk records for this meeting
        let allChunks = (try? fetch(FetchDescriptor<TranscriptChunk>())) ?? []
        allChunks.filter { $0.meetingId == meetingID }.forEach { delete($0) }

        // 3. Delete all TranscriptSegment records for this meeting
        let allSegs = (try? fetch(FetchDescriptor<TranscriptSegment>())) ?? []
        allSegs.filter { $0.meetingId == meetingID }.forEach { delete($0) }

        // 4. Invalidate FolderSummaryItem for the meeting's folder — it will be
        //    regenerated on the next "Generate Summary" request.
        if let folderID = meeting.folderID {
            let allSummaries = (try? fetch(FetchDescriptor<FolderSummaryItem>())) ?? []
            allSummaries.filter { $0.folderID == folderID }.forEach { delete($0) }
        }

        // 5. Delete the MeetingItem
        delete(meeting)

        storageLogger.info("deleteMeetingFully: cleaned meeting=\(meetingID) chunks+segments+summary")
    }
}
