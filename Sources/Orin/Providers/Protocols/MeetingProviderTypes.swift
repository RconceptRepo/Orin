import Foundation

// MARK: - CalendarEventDescriptor
//
// Platform-agnostic representation of a calendar event.
// EventKit (macOS), WinRT Calendar (Windows), or Google Calendar SDK
// all convert their native types into this struct before handing to
// the meeting-detection engine.

struct CalendarEventDescriptor: Sendable {
    let identifier: String
    let title: String?
    let startDate: Date
    let endDate: Date
    let url: URL?
    let notes: String?
    let location: String?

    init(
        identifier: String,
        title: String?,
        startDate: Date,
        endDate: Date,
        url: URL?,
        notes: String?,
        location: String?
    ) {
        self.identifier = identifier
        self.title      = title
        self.startDate  = startDate
        self.endDate    = endDate
        self.url        = url
        self.notes      = notes
        self.location   = location
    }
}

// MARK: - MeetingDetectionConfidence
//
// Weighted confidence score assembled from all six detection signals.
// The threshold is 40 — a single "definitive" signal (calendar event,
// verified meeting URL) suffices; ambiguous signals (process running,
// audio activity) need to combine.
//
// Score table:
//   fromCalendarEvent      : 40  — calendar event with meeting URL in window
//   fromMeetingURL         : 30  — browser tab contains a known meeting URL
//   fromRunningProcess     : 25  — known meeting app is running
//   fromWindowTitle        : 30  — window title confirms active call
//   microphoneActivityScore: 20  — mic is in use by another app
//   systemAudioActivityScore:20  — system audio capture is producing signal
//
// Example combinations:
//   Teams (25) + call window (30) = 55  → detected ✅
//   Teams (25) + mic (20) + audio (20) = 65 → detected ✅
//   Browser URL (30) + mic (20) = 50 → detected ✅
//   Process alone (25) = 25 → NOT detected ❌

struct MeetingDetectionConfidence: Equatable, Sendable {
    var fromCalendarEvent:       Int = 0
    var fromMeetingURL:          Int = 0
    var fromRunningProcess:      Int = 0
    var fromWindowTitle:         Int = 0
    var microphoneActivityScore: Int = 0
    var systemAudioActivityScore: Int = 0

    var total: Int {
        fromCalendarEvent + fromMeetingURL + fromRunningProcess
        + fromWindowTitle + microphoneActivityScore + systemAudioActivityScore
    }

    static let threshold = 40

    var meetsThreshold: Bool { total >= Self.threshold }

    static let zero = MeetingDetectionConfidence()
}

// MARK: - NotificationAction

/// Platform-agnostic notification action identifiers.
/// Implementations map their platform action strings to these cases.
enum NotificationAction: Sendable {
    case startRecording
    case stopRecording
    case dismissMeeting
}
