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
        // Use deleteMeetingFully so TranscriptChunk, TranscriptSegment, and
        // FolderSummaryItem records are also cleaned up for each expired meeting.
        for meeting in expired {
            context.deleteMeetingFully(meeting)
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
