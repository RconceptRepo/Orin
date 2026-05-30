import EventKit
import Foundation

// MARK: - EventKitCalendarProvider
//
// macOS CalendarProvider implementation.
// Wraps CalendarService (EventKit) and converts EKEvent → CalendarEventDescriptor.
// Only this file imports EventKit; the detection engine stays framework-free.

final class EventKitCalendarProvider: CalendarProvider, Service {

    private let calendarService: CalendarService

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
    }

    // MARK: - CalendarProvider

    nonisolated var isAuthorized: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return true
        default: return false
        }
    }

    nonisolated func events(from startDate: Date, to endDate: Date) -> [CalendarEventDescriptor] {
        calendarService
            .events(from: startDate, to: endDate)
            .map { CalendarEventDescriptor(ekEvent: $0) }
    }

    func syncEvents() async {
        await calendarService.syncEvents()
    }

    func requestPermission() async {
        await calendarService.requestPermission()
    }
}

// MARK: - EKEvent → CalendarEventDescriptor

private extension CalendarEventDescriptor {
    init(ekEvent: EKEvent) {
        let rawID = ekEvent.eventIdentifier ?? ""
        let id: String
        if rawID.isEmpty {
            let epoch = Int(ekEvent.startDate.timeIntervalSince1970)
            id = "unsaved_\(ekEvent.title ?? "unknown")_\(epoch)"
        } else {
            id = rawID
        }
        self.init(
            identifier: id,
            title:      ekEvent.title,
            startDate:  ekEvent.startDate,
            endDate:    ekEvent.endDate,
            url:        ekEvent.url,
            notes:      ekEvent.notes,
            location:   ekEvent.location
        )
    }
}
