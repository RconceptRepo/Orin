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
    func safeSave(context: String = "data") {
        do {
            try save()
        } catch {
            storageLogger.error("ModelContext.save failed [\(context)]: \(error)")
            ErrorManager.shared.report(.storageSaveFailed(context: context))
        }
    }
}
