import EventKit
import Foundation
import Observation

enum CalendarSyncStatus {
    case green
    case yellow
    case red

    var title: String {
        switch self {
        case .green: "Synced"
        case .yellow: "Pending"
        case .red: "Unavailable"
        }
    }
}

@Observable
final class CalendarService: Service {
    private let eventStore = EKEventStore()
    var status: CalendarSyncStatus = .red
    var events: [EKEvent] = []
    var lastSyncTimestamp: Date?

    func refreshAuthorizationStatus() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly, .authorized:
            status = lastSyncTimestamp == nil ? .yellow : .green
        case .notDetermined:
            status = .yellow
        case .denied, .restricted:
            status = .red
        @unknown default:
            status = .red
        }
    }

    func requestPermission() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            await MainActor.run {
                status = granted ? .yellow : .red
            }
        } catch {
            await MainActor.run {
                status = .red
            }
        }
    }

    func syncEvents() async {
        guard status != .red else { return }

        let now = Date()
        let calendar = Calendar.current
        guard let oneDayAgo = calendar.date(byAdding: .day, value: -1, to: now),
              let sevenDaysAhead = calendar.date(byAdding: .day, value: 7, to: now) else {
            return
        }

        let predicate = eventStore.predicateForEvents(withStart: oneDayAgo, end: sevenDaysAhead, calendars: nil)
        let fetchedEvents = eventStore.events(matching: predicate)

        await MainActor.run {
            events = fetchedEvents.sorted { $0.startDate < $1.startDate }
            status = .green
            lastSyncTimestamp = Date()
        }
    }
}
