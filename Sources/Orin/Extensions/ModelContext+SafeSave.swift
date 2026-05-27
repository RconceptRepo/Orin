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
        // CRASH-DIAG: Record EVERY save with its call site, context address, and task context.
        //
        // Key question: Is the save that precedes "selectedModule = .meetings" (in
        // MainContainerView.onStart) happening inside a Swift task?  If it IS in a task,
        // the @Query notification should also fire in-task — which means the crash is NOT
        // about task-context but about view-teardown ordering (use-after-free).
        //
        // If isInSwiftTask == false at a save site, THAT save is the culprit — its
        // SwiftData notification fires outside a task, causing swift_task_isMainExecutorImpl
        // to read from an invalid executor reference (0x1e).
        CrashDiag.trace(
            "ModelContext.safeSave BEGIN ctx=\(CrashDiag.addr(self)) reason='\(context)' inTask=\(CrashDiag.isInSwiftTask)",
            file: file, line: line
        )
        do {
            try save()
            CrashDiag.trace(
                "ModelContext.safeSave END (ok) reason='\(context)' inTask=\(CrashDiag.isInSwiftTask)",
                file: file, line: line
            )
        } catch {
            CrashDiag.trace(
                "ModelContext.safeSave END (FAIL) reason='\(context)' error=\(error)",
                file: file, line: line
            )
            storageLogger.error("ModelContext.save failed [\(context)]: \(error)")
            ErrorManager.shared.report(.storageSaveFailed(context: context))
        }
    }
}
