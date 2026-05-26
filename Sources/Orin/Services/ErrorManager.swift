import Foundation
import OSLog
import SwiftUI

// MARK: - Permission Type

/// Identifies which system permission is involved in a permission error.
enum OrinPermissionType: String, Sendable {
    case microphone
    case speechRecognition
    case calendar
    case automation

    var displayName: String {
        switch self {
        case .microphone:        "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .calendar:          "Calendar"
        case .automation:        "Automation"
        }
    }
}

// MARK: - Error Severity

/// Controls how aggressively an error is surfaced to the user.
enum ErrorSeverity: Sendable {
    /// Log only — no UI shown. For expected non-failure states (e.g. user cancellation).
    case low
    /// Auto-dismissing toast (~4 s). For transient, recoverable failures.
    case medium
    /// Persistent toast with optional retry. For operation failures the user should know about.
    case high
    /// Full modal. For state that blocks user progress until explicitly resolved.
    case critical
}

// MARK: - Recovery Action

/// Actions available to the user when an error is presented.
enum ErrorRecoveryAction: Sendable, Identifiable, Equatable {
    case dismiss
    case retry
    case openSystemSettingsPrivacy
    case openSystemSettings
    /// Opens System Settings → Privacy & Security → Automation.
    case openSystemSettingsAutomation

    var id: String {
        switch self {
        case .dismiss:                      "dismiss"
        case .retry:                        "retry"
        case .openSystemSettingsPrivacy:    "privacy"
        case .openSystemSettings:           "settings"
        case .openSystemSettingsAutomation: "automation-settings"
        }
    }

    var label: String {
        switch self {
        case .dismiss:                      "Dismiss"
        case .retry:                        "Try Again"
        case .openSystemSettingsPrivacy:    "Open Privacy Settings"
        case .openSystemSettings:           "Open System Settings"
        case .openSystemSettingsAutomation: "Open Automation Settings"
        }
    }

    var isPrimary: Bool { self != .dismiss }
}

// MARK: - Application Error

/// Unified error type for all Orin failure modes.
/// Add new cases here; never expose raw `Error` or stack traces to the UI.
enum ApplicationError: Error, Sendable {

    // MARK: Network
    case networkUnavailable
    case networkTimeout
    case networkServerError(statusCode: Int)
    case networkRequestFailed(reason: String)

    // MARK: AI
    case aiProviderUnavailable(provider: String)
    case aiRequestFailed(reason: String)
    case aiRateLimited(provider: String)
    case aiModelNotFound(model: String)
    case aiNoProvidersConfigured

    // MARK: Storage
    case storageSaveFailed(context: String)
    case storageDeleteFailed(context: String)
    case storageLoadFailed(context: String)

    // MARK: Permissions
    case permissionDenied(OrinPermissionType)
    case permissionRestricted(OrinPermissionType)

    // MARK: Recording
    case recordingDeviceUnavailable
    case recordingFailed(reason: String)
    case transcriptionFailed

    // MARK: Vault
    case vaultAuthenticationFailed
    case vaultNotConfigured
    case vaultKeychainFailed(status: OSStatus)
    case vaultUserCancelled
    case vaultEncryptionFailed
    case vaultRecoveryFailed

    // MARK: Calendar
    case calendarAccessDenied
    case calendarSyncFailed
    case calendarEventCreationFailed

    // MARK: Automation (AppleScript / browser meeting detection)
    /// NSAppleScript returned -1743 (errAEEventNotPermitted) for the named application.
    case automationPermissionDenied(app: String)

    // MARK: Unknown
    case unknown(underlying: String)
}

// MARK: - User-Facing Properties

extension ApplicationError {

    /// Short title shown in toast/modal headers. No developer jargon.
    var errorTitle: String {
        switch self {
        case .networkUnavailable:           return "No Internet Connection"
        case .networkTimeout:               return "Connection Timed Out"
        case .networkServerError:           return "Server Error"
        case .networkRequestFailed:         return "Request Failed"

        case .aiProviderUnavailable(let p): return "\(p) Unavailable"
        case .aiRequestFailed:              return "AI Request Failed"
        case .aiRateLimited(let p):         return "\(p) Rate Limited"
        case .aiModelNotFound(let m):       return "Model Not Found: \(m)"
        case .aiNoProvidersConfigured:      return "No AI Provider Configured"

        case .storageSaveFailed:            return "Could Not Save"
        case .storageDeleteFailed:          return "Could Not Delete"
        case .storageLoadFailed:            return "Could Not Load"

        case .permissionDenied(let t):      return "\(t.displayName) Access Denied"
        case .permissionRestricted(let t):  return "\(t.displayName) Restricted"

        case .recordingDeviceUnavailable:   return "Microphone Unavailable"
        case .recordingFailed:              return "Recording Failed"
        case .transcriptionFailed:          return "Transcription Unavailable"

        case .vaultAuthenticationFailed:    return "Authentication Failed"
        case .vaultNotConfigured:           return "Vault Not Set Up"
        case .vaultKeychainFailed:          return "Keychain Error"
        case .vaultUserCancelled:           return "Authentication Cancelled"
        case .vaultEncryptionFailed:        return "Encryption Failed"
        case .vaultRecoveryFailed:          return "Recovery Failed"

        case .calendarAccessDenied:         return "Calendar Access Denied"
        case .calendarSyncFailed:           return "Calendar Sync Failed"
        case .calendarEventCreationFailed:  return "Could Not Create Event"

        case .automationPermissionDenied:   return "Automation Access Denied"

        case .unknown:                      return "Something Went Wrong"
        }
    }

    /// Friendly explanation. Never exposes stack traces, error codes, or internal state.
    var errorMessage: String {
        switch self {
        case .networkUnavailable:
            return "Check your internet connection and try again."
        case .networkTimeout:
            return "The request took too long. Please try again."
        case .networkServerError(let code):
            return "The server returned an error (\(code)). Please try again later."
        case .networkRequestFailed(let reason):
            return reason.isEmpty ? "The request could not be completed. Please try again." : reason

        case .aiProviderUnavailable(let provider):
            return "\(provider) is not responding. Check your connection and provider settings."
        case .aiRequestFailed(let reason):
            return reason.isEmpty ? "The AI request could not be completed." : reason
        case .aiRateLimited(let provider):
            return "You have reached \(provider)'s usage limit. Please wait a moment and try again."
        case .aiModelNotFound(let model):
            return "The model \"\(model)\" was not found. Check your AI provider settings."
        case .aiNoProvidersConfigured:
            return "Add an AI provider in Settings to enable intelligent features."

        case .storageSaveFailed(let context):
            return "Your \(context) could not be saved. Please try again."
        case .storageDeleteFailed(let context):
            return "Could not delete \(context). Please try again."
        case .storageLoadFailed(let context):
            return "Could not load \(context). Try restarting Orin."

        case .permissionDenied(let type):
            return "\(type.displayName) access was denied. Grant access in System Settings to continue."
        case .permissionRestricted(let type):
            return "\(type.displayName) access is restricted on this device."

        case .recordingDeviceUnavailable:
            return "No microphone was found. Connect a microphone and try again."
        case .recordingFailed(let reason):
            return reason.isEmpty ? "Recording stopped unexpectedly. Please try again." : reason
        case .transcriptionFailed:
            return "Transcription is temporarily unavailable. Your recording was saved."

        case .vaultAuthenticationFailed:
            return "Your identity could not be verified. Please try again."
        case .vaultNotConfigured:
            return "Set up your vault to start storing secure credentials."
        case .vaultKeychainFailed:
            return "A keychain error occurred. Try locking and unlocking the vault."
        case .vaultUserCancelled:
            return ""
        case .vaultEncryptionFailed:
            return "The item could not be encrypted. Your data was not saved."
        case .vaultRecoveryFailed:
            return "Recovery could not be completed. Verify your recovery key and try again."

        case .calendarAccessDenied:
            return "Grant calendar access in System Settings to sync events with Orin."
        case .calendarSyncFailed:
            return "Calendar sync encountered an error and will retry automatically."
        case .calendarEventCreationFailed:
            return "The calendar event could not be created. Please try again."

        case .automationPermissionDenied(let app):
            return "Orin needs Automation access to check \(app) for browser-based meetings. " +
                   "Open System Settings → Privacy & Security → Automation and enable Orin."

        case .unknown:
            return "An unexpected error occurred. If this continues, please restart Orin."
        }
    }

    /// Determines presentation tier. Drive all new cases here.
    var severity: ErrorSeverity {
        switch self {
        case .vaultUserCancelled:
            return .low

        case .networkTimeout, .networkRequestFailed, .networkUnavailable,
             .aiRateLimited, .transcriptionFailed, .calendarSyncFailed:
            return .medium

        case .storageSaveFailed, .storageDeleteFailed, .storageLoadFailed,
             .recordingFailed, .recordingDeviceUnavailable,
             .aiProviderUnavailable, .aiModelNotFound, .aiRequestFailed,
             .networkServerError,
             .vaultAuthenticationFailed, .vaultKeychainFailed,
             .vaultEncryptionFailed, .vaultRecoveryFailed,
             .calendarEventCreationFailed,
             // Automation denial is .high (not .critical) because the app still functions
             // via native-app and calendar-based meeting detection.
             .automationPermissionDenied,
             .unknown:
            return .high

        case .aiNoProvidersConfigured,
             .permissionDenied, .permissionRestricted,
             .calendarAccessDenied,
             .vaultNotConfigured:
            return .critical
        }
    }

    /// Recovery actions shown in the error UI. Order: primary first.
    var recoveryActions: [ErrorRecoveryAction] {
        switch self {
        case .permissionDenied, .permissionRestricted, .calendarAccessDenied:
            return [.openSystemSettingsPrivacy, .dismiss]
        case .automationPermissionDenied:
            // Primary: deep-link to Automation pane. Secondary: retry detection immediately.
            return [.openSystemSettingsAutomation, .retry, .dismiss]
        case .aiNoProvidersConfigured, .vaultNotConfigured:
            return [.dismiss]
        case .vaultUserCancelled:
            return []
        default:
            return isRetryable ? [.retry, .dismiss] : [.dismiss]
        }
    }

    var isRetryable: Bool {
        switch self {
        case .permissionDenied, .permissionRestricted,
             .calendarAccessDenied,
             .aiNoProvidersConfigured,
             .vaultNotConfigured,
             .vaultUserCancelled,
             .vaultEncryptionFailed:
            return false
        default:
            return true
        }
    }

    /// SF Symbol name for the category icon.
    var systemImageName: String {
        switch self {
        case .networkUnavailable, .networkTimeout,
             .networkServerError, .networkRequestFailed:
            return "wifi.slash"
        case .aiProviderUnavailable, .aiRequestFailed, .aiRateLimited,
             .aiModelNotFound, .aiNoProvidersConfigured:
            return "cpu.fill"
        case .storageSaveFailed, .storageDeleteFailed, .storageLoadFailed:
            return "externaldrive.badge.exclamationmark"
        case .permissionDenied, .permissionRestricted:
            return "hand.raised.fill"
        case .recordingDeviceUnavailable, .recordingFailed:
            return "mic.slash.fill"
        case .transcriptionFailed:
            return "waveform.slash"
        case .vaultAuthenticationFailed, .vaultNotConfigured, .vaultKeychainFailed,
             .vaultUserCancelled, .vaultEncryptionFailed, .vaultRecoveryFailed:
            return "lock.fill"
        case .calendarAccessDenied, .calendarSyncFailed, .calendarEventCreationFailed:
            return "calendar.badge.exclamationmark"
        case .automationPermissionDenied:
            return "gearshape.2"
        case .unknown:
            return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - VaultError Bridge

extension ApplicationError {
    /// Convert the existing `VaultError` enum to `ApplicationError`.
    static func from(_ vaultError: VaultError) -> ApplicationError {
        switch vaultError {
        case .userCancelled:            return .vaultUserCancelled
        case .authenticationFailed:     return .vaultAuthenticationFailed
        case .keychainError(let s):     return .vaultKeychainFailed(status: s)
        }
    }
}

// MARK: - Presentation Items

/// Data for a non-intrusive toast notification.
struct ErrorToastItem: Identifiable {
    let id = UUID()
    let error: ApplicationError
    var retryAction: (() async -> Void)?
}

/// Data for a full-modal error alert.
struct ErrorModalItem: Identifiable {
    let id = UUID()
    let error: ApplicationError
    var retryAction: (() async -> Void)?
}

// MARK: - Error Manager

/// Central authority for collecting, logging, and presenting application errors.
///
/// Usage from any view or service:
/// ```swift
/// ErrorManager.shared.report(.storageSaveFailed(context: "task"))
/// ErrorManager.shared.report(.networkTimeout, retryAction: { await reload() })
/// ```
@Observable
final class ErrorManager {
    static let shared = ErrorManager()

    private(set) var activeToast: ErrorToastItem?
    private(set) var activeModal: ErrorModalItem?

    private let logger = Logger(subsystem: "com.clavrit.orin", category: "ErrorManager")
    private var toastTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Report an `ApplicationError`. Presentation tier is derived from `error.severity`.
    /// May be called from any thread — UI updates dispatch to main actor automatically.
    func report(
        _ error: ApplicationError,
        retryAction: (() async -> Void)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        logError(error, file: file, line: line)
        guard error.severity != .low else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if error.severity == .critical {
                self.showModal(ErrorModalItem(error: error, retryAction: retryAction))
            } else {
                self.showToast(
                    ErrorToastItem(error: error, retryAction: retryAction),
                    autoDismiss: error.severity == .medium
                )
            }
        }
    }

    /// Convenience wrapper that lifts any raw `Error` into `ApplicationError`.
    func report(
        raw error: Error,
        context: String = "operation",
        file: String = #fileID,
        line: Int = #line
    ) {
        if let appError = error as? ApplicationError {
            report(appError, file: file, line: line)
        } else {
            report(
                .unknown(underlying: "\(context): \(error.localizedDescription)"),
                file: file,
                line: line
            )
        }
    }

    @MainActor
    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        withAnimation(.easeOut(duration: 0.25)) { activeToast = nil }
    }

    @MainActor
    func dismissModal() {
        withAnimation(.easeOut(duration: 0.25)) { activeModal = nil }
    }

    // MARK: - Private

    @MainActor
    private func showToast(_ item: ErrorToastItem, autoDismiss: Bool) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { activeToast = item }

        guard autoDismiss else { return }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismissToast()
        }
    }

    @MainActor
    private func showModal(_ item: ErrorModalItem) {
        withAnimation(.easeInOut(duration: 0.25)) { activeModal = item }
    }

    private func logError(_ error: ApplicationError, file: String, line: Int) {
        let msg = "[\(file):\(line)] \(error.errorTitle): \(error.errorMessage)"
        switch error.severity {
        case .low:      logger.debug("\(msg)")
        case .medium:   logger.warning("\(msg)")
        case .high:     logger.error("\(msg)")
        case .critical: logger.critical("\(msg)")
        }
    }
}
