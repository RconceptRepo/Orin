import Foundation

// MARK: - SystemAudioProvider
//
// Abstracts system-wide audio capture (ScreenCaptureKit on macOS,
// WASAPI loopback on Windows) from the meeting recording pipeline.
//
// macOS implementation: SCKitSystemAudioProvider (thin wrapper over
//   the existing SystemAudioCaptureService)
//
// The protocol is @MainActor-isolated because capture state is observed
// by SwiftUI views.

@MainActor
protocol SystemAudioProvider: AnyObject {

    // MARK: - State

    /// `true` once the capture pipeline has successfully started.
    var isCapturing: Bool { get }

    /// `true` if Screen Recording permission was obtained and capture
    /// can be attempted.
    var isAvailable: Bool { get }

    /// Speaker-labeled transcript of the participant audio stream.
    /// Format: `"Participant: <text>"`.  Empty when `transcript` is empty.
    var participantSpeakerTranscript: String { get }

    // MARK: - Lifecycle

    /// Starts system-audio capture for the given meeting session.
    ///
    /// Silently degrades to mic-only if permission is denied or
    /// hardware is unavailable — never blocks the mic recording pipeline.
    func startCapturing(for meetingID: UUID?) async

    /// Stops capture and finalises the participant transcript.
    /// Safe to call when not capturing.
    func stopCapturing()
}

// MARK: - MeetingDetectorProvider
//
// Abstracts the meeting-presence detection engine from the main container view
// and the notification workflow.  The engine is responsible for:
//   • Polling all detection sources (calendar, browser, process, window, audio)
//   • Computing a MeetingDetectionConfidence score each poll cycle
//   • Presenting the recording prompt only when confidence ≥ threshold
//   • Calling onMeetingDetected / onMeetingEnded for downstream consumers
//
// macOS implementation: MeetingDetectorService
// Protocol is @MainActor because UI observers bind to its state.

@MainActor
protocol MeetingDetectorProvider: AnyObject {

    // MARK: - Observable State

    var detectedMeetingApp: String? { get }
    var shouldShowRecordingPrompt: Bool { get }
    var currentConfidence: MeetingDetectionConfidence { get }

    // MARK: - Callbacks

    /// Called once per newly discovered meeting session with the display name
    /// of the detected application.  Not called for repeat polls of the same session.
    var onMeetingDetected: ((String) -> Void)? { get set }

    /// Called on the main actor when a previously detected meeting disappears
    /// from all detection sources.  The auto-stop watchdog registers here.
    var onMeetingEnded: (() -> Void)? { get set }

    // MARK: - Lifecycle

    func startMonitoring()
    func stopMonitoring()

    /// Switches to a shorter poll interval while recording is active so
    /// meeting-end detection is responsive within ≤ 4 s.
    func enableFastPoll()

    /// Restores the normal (30 s) poll interval after recording stops.
    func disableFastPoll()

    /// Hides the overlay prompt without ending the detected session.
    func dismissPrompt()

    /// Re-runs browser detection immediately after the user grants
    /// Automation permission.
    func retryBrowserDetection()
}
