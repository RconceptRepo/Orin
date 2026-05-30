import Foundation

// MARK: - CalendarProvider
//
// Abstracts the platform calendar system (EventKit on macOS, WinRT Calendar
// on Windows, Google Calendar SDK in a web context) away from the meeting
// detection engine.  The engine works exclusively with CalendarEventDescriptor;
// only the concrete macOS implementation imports EventKit.
//
// macOS implementation: EventKitCalendarProvider
// Test implementation:  any closure that returns [CalendarEventDescriptor]

protocol CalendarProvider: AnyObject, Sendable {

    // MARK: - Status

    /// Whether the provider currently has permission to read calendar events.
    var isAuthorized: Bool { get }

    // MARK: - Queries

    /// All events cached from the most recent sync whose time range overlaps
    /// `[startDate, endDate]`.  May return stale data between syncs.
    func events(from startDate: Date, to endDate: Date) -> [CalendarEventDescriptor]

    // MARK: - Sync

    /// Fetches fresh data from the underlying calendar system.
    /// After completion, `events(from:to:)` returns up-to-date results.
    func syncEvents() async

    /// Requests calendar access from the user if not yet determined.
    func requestPermission() async
}
