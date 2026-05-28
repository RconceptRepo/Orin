import AppKit
import Foundation
import OSLog
import UserNotifications

extension Notification.Name {
    static let orinNotificationStartRecording = Notification.Name("orin.notification.startRecording")
    static let orinNotificationDismissMeeting = Notification.Name("orin.notification.dismissMeeting")
    static let orinNotificationStopRecording = Notification.Name("orin.notification.stopRecording")
}

final class MeetingNotificationService: NSObject, Service, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "com.clavrit.orin", category: "MeetingNotifications")
    private let center = UNUserNotificationCenter.current()
    private var configured = false
    private var activeMeetingKeys: [String: Date] = [:]
    private let cooldown: TimeInterval = 180

    private enum Action {
        static let start = "ORIN_START_RECORDING"
        static let dismiss = "ORIN_DISMISS_MEETING"
        static let stop = "ORIN_STOP_RECORDING"
        static let category = "ORIN_MEETING_DETECTED"
        static let recordingCategory = "ORIN_RECORDING_ACTIVE"
    }

    func configure() {
        guard !configured else { return }
        configured = true
        center.delegate = self

        let start = UNNotificationAction(
            identifier: Action.start,
            title: "Start Recording",
            options: []
        )
        let dismiss = UNNotificationAction(
            identifier: Action.dismiss,
            title: "Dismiss",
            options: []
        )
        let stop = UNNotificationAction(
            identifier: Action.stop,
            title: "Stop Recording",
            options: [.destructive]
        )

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Action.category,
                actions: [start, dismiss],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Action.recordingCategory,
                actions: [stop],
                intentIdentifiers: [],
                options: []
            )
        ])

        center.requestAuthorization(options: [.alert, .sound, .badge]) { [logger] granted, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription)")
            } else {
                logger.info("Notification authorization granted=\(granted)")
            }
        }
    }

    func notifyMeetingDetected(appName: String) {
        configure()
        let key = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        if let last = activeMeetingKeys[key], now.timeIntervalSince(last) < cooldown {
            logger.info("Suppressed duplicate meeting notification for \(appName)")
            return
        }
        activeMeetingKeys[key] = now

        let content = UNMutableNotificationContent()
        content.title = "Meeting Detected"
        content.body = "\(appName) appears active. Ensure all participants are aware of recording."
        content.sound = .default
        content.categoryIdentifier = Action.category
        content.threadIdentifier = "orin.meeting.\(key)"

        let request = UNNotificationRequest(
            identifier: "orin.meeting.detected.\(key)",
            content: content,
            trigger: nil
        )
        center.add(request) { [logger] error in
            if let error {
                logger.error("Failed to deliver meeting notification: \(error.localizedDescription)")
            } else {
                logger.info("Delivered meeting notification for \(appName)")
            }
        }
    }

    func notifyRecordingActive() {
        configure()
        let content = UNMutableNotificationContent()
        content.title = "Recording in Progress"
        content.body = "Orin is listening. You can stop recording from this notification."
        content.sound = nil
        content.categoryIdentifier = Action.recordingCategory
        content.threadIdentifier = "orin.recording.active"

        center.add(UNNotificationRequest(
            identifier: "orin.recording.active",
            content: content,
            trigger: nil
        ))
    }

    func clearMeetingDedupe() {
        activeMeetingKeys.removeAll()
        center.removeDeliveredNotifications(withIdentifiers: ["orin.recording.active"])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            switch response.actionIdentifier {
            case Action.start, UNNotificationDefaultActionIdentifier:
                NotificationCenter.default.post(name: .orinNotificationStartRecording, object: nil)
            case Action.dismiss, UNNotificationDismissActionIdentifier:
                NotificationCenter.default.post(name: .orinNotificationDismissMeeting, object: nil)
            case Action.stop:
                NotificationCenter.default.post(name: .orinNotificationStopRecording, object: nil)
            default:
                break
            }
        }
    }
}
