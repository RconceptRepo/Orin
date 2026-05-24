import Foundation
import OSLog
import SwiftData

private let retentionLogger = Logger(subsystem: "com.clavrit.orin", category: "MeetingRetention")

/// Enforces meeting retention policy by deleting records older than the chosen window.
/// Called on app launch and optionally on a schedule.
final class MeetingRetentionService: Service {

    enum RetentionPolicy: Int, CaseIterable, Identifiable {
        case thirtyDays    = 30
        case ninetyDays    = 90
        case oneEightyDays = 180
        case forever       = 0

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .thirtyDays:    "30 days"
            case .ninetyDays:    "90 days"
            case .oneEightyDays: "180 days"
            case .forever:       "Forever"
            }
        }

        static func from(rawValue: Int) -> RetentionPolicy {
            RetentionPolicy(rawValue: rawValue) ?? .thirtyDays
        }
    }

    /// Delete meeting records older than `policy`. No-op when policy is `.forever`.
    /// - Returns: count of meetings pruned.
    @discardableResult
    func pruneExpiredMeetings(in context: ModelContext, policy: RetentionPolicy) throws -> Int {
        guard policy != .forever else { return 0 }
        let cutoff = cutoffDate(for: policy)
        let descriptor = FetchDescriptor<MeetingItem>(
            predicate: #Predicate<MeetingItem> { $0.date < cutoff }
        )
        let expired = try context.fetch(descriptor)
        for meeting in expired {
            // Remove associated local audio file if present — best-effort, non-blocking
            if let path = meeting.audioFilePath {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    retentionLogger.warning("Could not remove expired audio file at \(path): \(error)")
                }
            }
            context.delete(meeting)
        }
        if !expired.isEmpty {
            try context.save()
        }
        return expired.count
    }

    func cutoffDate(for policy: RetentionPolicy) -> Date {
        Calendar.current.date(byAdding: .day, value: -policy.rawValue, to: Date()) ?? Date()
    }
}
