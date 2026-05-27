#if DEBUG
import SwiftUI
import SwiftData

// MARK: - Notification name

extension Notification.Name {
    /// Posted by the Developer → Reset Application State menu command.
    /// Observed in OrinApp to present `DebugResetView`.
    static let debugResetRequested = Notification.Name("com.rconcept.orin.debug.resetRequested")
}

// MARK: - View

/// Full-screen sheet UI for the debug reset workflow.
/// Presented ONLY in DEBUG builds via the Developer menu.
struct DebugResetView: View {
    @Environment(\.dismiss)      private var dismiss
    @Environment(\.modelContext) private var modelContext

    // MARK: State

    private enum Phase { case confirm, resetting, complete }

    @State private var phase: Phase = .confirm
    @State private var includeVault = false
    @State private var report = DebugResetReport()

    private let resetService = DebugResetService()

    // MARK: Body

    var body: some View {
        Group {
            switch phase {
            case .confirm:  confirmView
            case .resetting: progressView
            case .complete:  completeView
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.15), value: phase == .complete)
    }

    // MARK: - Confirm

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 20) {

            // ── Header ──
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reset All Local Application Data?")
                        .font(.title3.weight(.semibold))
                    Text("This action cannot be undone and takes effect immediately.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // ── What is cleared ──
            VStack(alignment: .leading, spacing: 8) {
                Label("Always cleared:", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                itemRow("Onboarding completion flag")
                itemRow("All UserDefaults preferences")
                itemRow("All SwiftData records — tasks, meetings, suggestions, briefs")
                itemRow("Application Support files (recordings)")
                itemRow("Application caches")
                itemRow("Temporary files")
            }

            Divider()

            // ── Vault option ──
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $includeVault) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(includeVault ? .orange : .secondary)
                        Text("Also clear Vault data")
                            .font(.callout.weight(.medium))
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityHint("When enabled, also deletes vault master key from Keychain, all encrypted vault items, recovery tokens, and AI provider keys.")

                if includeVault {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach([
                            "Vault UserDefaults metadata and recovery tokens",
                            "Vault master key from Keychain",
                            "AI provider API keys from Keychain",
                            "All encrypted VaultItem records",
                        ], id: \.self) { text in
                            Label(text, systemImage: "lock.slash")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.leading, 26)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.12), value: includeVault)

            Divider()

            // ── Footer ──
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                Spacer()

                Button(role: .destructive) {
                    triggerReset()
                } label: {
                    Label("Reset Application State", systemImage: "trash.fill")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .accessibilityHint("Immediately clears all selected local data. Cannot be undone.")
            }
        }
        .padding(26)
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .scaleEffect(1.4)
                .padding(.top, 8)
            Text("Resetting application state…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(44)
    }

    // MARK: - Complete

    private var completeView: some View {
        VStack(alignment: .leading, spacing: 20) {

            // ── Header ──
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: report.errors.isEmpty
                      ? "checkmark.circle.fill"
                      : "exclamationmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(report.errors.isEmpty ? .green : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(report.errors.isEmpty ? "Reset Complete" : "Reset Completed with Warnings")
                        .font(.title3.weight(.semibold))
                    Text("The app is ready for a fresh first-launch experience.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Deleted items ──
            if !report.deletedItems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Deleted (\(report.deletedItems.count) items):")
                        .font(.subheadline.weight(.medium))
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(report.deletedItems, id: \.self) { item in
                                Label(item, systemImage: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 150)
                }
            }

            // ── Errors / warnings ──
            if !report.errors.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Warnings (\(report.errors.count)):")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                    ForEach(report.errors, id: \.self) { err in
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Divider()

            // ── Footer ──
            HStack {
                Button("Close Without Restarting") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Spacer()
                Button {
                    dismiss()
                    // Brief delay lets the sheet dismiss before relaunching
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        relaunchApp()
                    }
                } label: {
                    Label("Quit and Relaunch", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Quits the current process and relaunches Orin from the same bundle. The next launch will show onboarding.")
            }
        }
        .padding(26)
    }

    // MARK: - Helpers

    private func itemRow(_ text: String) -> some View {
        Label(text, systemImage: "minus.circle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private func triggerReset() {
        phase = .resetting
        Task { @MainActor in
            // Yield once so SwiftUI renders the .resetting phase before
            // the synchronous reset operations begin.
            try? await Task.sleep(nanoseconds: 120_000_000)  // 0.12 s
            report = resetService.performReset(
                includeVault: includeVault,
                modelContext: modelContext
            )
            phase = .complete
        }
    }

    private func relaunchApp() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Preview

#Preview("Confirm phase") {
    DebugResetView()
}
#endif
