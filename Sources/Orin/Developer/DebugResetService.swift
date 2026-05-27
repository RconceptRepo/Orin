#if DEBUG
import Foundation
import Security
import SwiftData

// MARK: - Report

/// Accumulates what was deleted and any non-fatal errors during a debug reset.
struct DebugResetReport {
    var deletedItems: [String] = []
    var errors: [String] = []

    mutating func append(_ other: DebugResetReport) {
        deletedItems.append(contentsOf: other.deletedItems)
        errors.append(contentsOf: other.errors)
    }
}

// MARK: - Service

/// Debug-only helper that wipes all local Orin application data so QA testers
/// can reproduce the first-launch experience without reinstalling.
///
/// **Never compiled into Release builds.**
///
/// Call `performReset(includeVault:modelContext:)` from the main thread
/// (it is synchronous and assumes a main-thread `ModelContext`).
struct DebugResetService {

    // MARK: - UserDefaults keys

    /// All UserDefaults keys written by Orin (non-vault).
    private static let coreDefaultsKeys: [String] = [
        "orin.hasCompletedOnboarding",
        "orin.theme.mode",
        "orin.ai.ollamaEndpoint",
        "orin.ai.provider",
        "orin.ai.anthropicConfigured",
        "orin.ai.geminiConfigured",
        "orin.ai.openAIConfigured",
        "orin.calendar.backgroundSync",
        "orin.meetings.retentionDays",
        "orin.meetings.autoAnalyze",
        "orin.meetings.minDurationMinutes",
        "orin.taskDragHintShown",
        "orin.vault.recoveryKeyShown",
        "orin.pendingIntentReflow",
        "orin.pendingIntentSummary",
        "orin.pendingIntentTask",
        "orin.whisper.endpoint",
        "com.orin.lastRolloverTimestamp",
    ]

    /// Vault-specific UserDefaults keys (cleared only when `includeVault` is true).
    private static let vaultDefaultsKeys: [String] = [
        "orin.vault.verificationToken",
        "orin.vault.recovery.failCount",
        "orin.vault.recovery.lockoutUntil",
    ]

    // MARK: - Main entry point

    /// Wipes all selected application state.
    ///
    /// - Parameters:
    ///   - includeVault: When `true`, also clears vault Keychain items, vault
    ///     UserDefaults keys, and all `VaultItem` SwiftData records.
    ///   - modelContext: A main-thread `ModelContext` used to delete SwiftData records.
    func performReset(includeVault: Bool, modelContext: ModelContext) -> DebugResetReport {
        var report = DebugResetReport()

        report.append(clearUserDefaults(includeVault: includeVault))
        report.append(deleteSwiftDataRecords(modelContext: modelContext, includeVault: includeVault))
        report.append(deleteApplicationSupportFiles())
        report.append(deleteCaches())
        report.append(deleteTempFiles())

        if includeVault {
            report.append(clearVaultKeychain())
        }

        return report
    }

    // MARK: - UserDefaults

    private func clearUserDefaults(includeVault: Bool) -> DebugResetReport {
        var report = DebugResetReport()
        let ud = UserDefaults.standard

        var keys = Self.coreDefaultsKeys
        if includeVault { keys += Self.vaultDefaultsKeys }

        for key in keys {
            if ud.object(forKey: key) != nil {
                ud.removeObject(forKey: key)
                report.deletedItems.append("UserDefaults → \(key)")
            }
        }

        ud.synchronize()
        return report
    }

    // MARK: - SwiftData

    private func deleteSwiftDataRecords(
        modelContext: ModelContext,
        includeVault: Bool
    ) -> DebugResetReport {
        var report = DebugResetReport()

        // Order matters when there are cascading relationships.
        // Delete children before parents where applicable.
        report.append(deleteModel(SubTaskItem.self,      from: modelContext))
        report.append(deleteModel(TaskItem.self,         from: modelContext))
        report.append(deleteModel(MeetingItem.self,      from: modelContext))
        report.append(deleteModel(CommitmentItem.self,   from: modelContext))
        report.append(deleteModel(AISuggestionItem.self, from: modelContext))
        report.append(deleteModel(DailyBriefItem.self,   from: modelContext))
        report.append(deleteModel(FocusPatternItem.self, from: modelContext))

        if includeVault {
            report.append(deleteModel(VaultItem.self, from: modelContext))
        }

        return report
    }

    private func deleteModel<T: PersistentModel>(
        _ type: T.Type,
        from context: ModelContext
    ) -> DebugResetReport {
        var report = DebugResetReport()
        do {
            let items = try context.fetch(FetchDescriptor<T>())
            guard !items.isEmpty else { return report }
            for item in items { context.delete(item) }
            try context.save()
            let n = items.count
            report.deletedItems.append(
                "SwiftData → \(n) \(String(describing: T.self))\(n == 1 ? "" : "s")"
            )
        } catch {
            report.errors.append(
                "SwiftData \(String(describing: T.self)): \(error.localizedDescription)"
            )
        }
        return report
    }

    // MARK: - Application Support

    private func deleteApplicationSupportFiles() -> DebugResetReport {
        var report = DebugResetReport()
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            report.errors.append("Application Support: could not resolve directory")
            return report
        }

        // Named Orin directories written by the app.
        // Does NOT include SwiftData store files (deleting while the container
        // is open is unsafe; the records are already deleted via modelContext).
        let candidates: [URL] = [
            base.appendingPathComponent("Orin"),          // recordings
        ]

        for url in candidates {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                report.deletedItems.append("App Support → \(url.lastPathComponent)/")
            } catch {
                report.errors.append(
                    "App Support \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        return report
    }

    // MARK: - Caches

    private func deleteCaches() -> DebugResetReport {
        var report = DebugResetReport()
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            report.errors.append("Caches: could not resolve directory")
            return report
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.rconcept.orin"
        let candidates: [URL] = [
            base.appendingPathComponent(bundleID),
            base.appendingPathComponent("com.orin"),
            base.appendingPathComponent("Orin"),
        ]

        for url in candidates {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                report.deletedItems.append("Cache → \(url.lastPathComponent)/")
            } catch {
                report.errors.append("Cache \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return report
    }

    // MARK: - Temp files

    private func deleteTempFiles() -> DebugResetReport {
        var report = DebugResetReport()
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

        guard let contents = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else {
            return report
        }

        var count = 0
        for item in contents where item.lastPathComponent.lowercased().hasPrefix("orin") {
            try? fm.removeItem(at: item)
            count += 1
        }

        if count > 0 {
            report.deletedItems.append("Temp → \(count) orin-prefixed file\(count == 1 ? "" : "s")")
        }

        return report
    }

    // MARK: - Vault Keychain

    private func clearVaultKeychain() -> DebugResetReport {
        var report = DebugResetReport()

        // Vault master key
        let vaultStatus = deleteKeychainItem(service: "com.orin.vault.masterkey")
        switch vaultStatus {
        case errSecSuccess:
            report.deletedItems.append("Keychain → vault master key")
        case errSecItemNotFound:
            break  // Nothing to delete — not an error
        default:
            report.errors.append(
                "Keychain vault: \(keychainErrorString(vaultStatus))"
            )
        }

        // AI provider API keys
        let aiStatus = deleteKeychainItem(service: "com.orin.ai-provider-keys")
        switch aiStatus {
        case errSecSuccess:
            report.deletedItems.append("Keychain → AI provider keys")
        case errSecItemNotFound:
            break
        default:
            report.errors.append(
                "Keychain AI keys: \(keychainErrorString(aiStatus))"
            )
        }

        // Clear VaultService in-memory session so it doesn't cache stale state
        let vault = ServiceContainer.shared.resolve(VaultService.self)
        vault.clearSession()
        report.deletedItems.append("VaultService → session cleared")

        return report
    }

    private func deleteKeychainItem(service: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        return SecItemDelete(query as CFDictionary)
    }

    private func keychainErrorString(_ status: OSStatus) -> String {
        if let msg = SecCopyErrorMessageString(status, nil) {
            return "\(msg) (\(status))"
        }
        return "status \(status)"
    }
}
#endif
