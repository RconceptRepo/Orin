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

    private var backgroundSyncTimer: Timer?
    /// 15-minute interval matches the product spec for background refresh.
    static let backgroundSyncInterval: TimeInterval = 900

    // MARK: - Authorization

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
            await MainActor.run { status = .red }
        }
    }

    // MARK: - Sync

    func syncEvents() async {
        guard status != .red else { return }

        let now = Date()
        let calendar = Calendar.current
        guard let oneDayAgo = calendar.date(byAdding: .day, value: -1, to: now),
              let sevenDaysAhead = calendar.date(byAdding: .day, value: 7, to: now) else { return }

        let predicate = eventStore.predicateForEvents(withStart: oneDayAgo, end: sevenDaysAhead, calendars: nil)
        let fetched = eventStore.events(matching: predicate)

        await MainActor.run {
            events = fetched.sorted { $0.startDate < $1.startDate }
            status = .green
            lastSyncTimestamp = Date()
        }
    }

    // MARK: - Background sync (15-minute timer)

    /// Starts a 15-minute repeating timer that calls `syncEvents()` automatically.
    /// Safe to call multiple times — subsequent calls are no-ops.
    @MainActor
    func startBackgroundSync() {
        guard backgroundSyncTimer == nil else { return }
        backgroundSyncTimer = Timer.scheduledTimer(
            withTimeInterval: Self.backgroundSyncInterval,
            repeats: true
        ) { [weak self] _ in
            Task { await self?.syncEvents() }
        }
    }

    @MainActor
    func stopBackgroundSync() {
        backgroundSyncTimer?.invalidate()
        backgroundSyncTimer = nil
    }

    var isBackgroundSyncActive: Bool {
        backgroundSyncTimer != nil
    }
}
