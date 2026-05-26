import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Onboarding (first-unlock key presentation)

/// Full-featured recovery key presentation shown after first unlock.
/// Provides copy, file export, and print. Dismissal is gated behind
/// an explicit "I've saved it" confirmation.
struct VaultRecoveryOnboardingView: View {
    let recoveryKey: String
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var confirmed = false
    @State private var copied = false
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: "key.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save Your Recovery Key")
                        .font(.title2.weight(.semibold))
                    Text("You won't be able to see this again")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 20)

            // Warning banner
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Store this key somewhere safe. If you lose both your device password and this key, your vault cannot be recovered.")
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 16)

            // What this key does
            Text("This 64-character key is the only way to access your vault if Touch ID and your device password both stop working — for example after a Mac reinstall or Touch ID hardware change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)

            // Key display
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR RECOVERY KEY")
                    .font(.system(.caption, design: .default).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1)

                Text(recoveryKey)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
            .padding(.bottom, 16)

            // Action buttons
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recoveryKey, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {
                    isExporting = true
                } label: {
                    Label("Export File", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {
                    printRecoverySheet(recoveryKey: recoveryKey)
                } label: {
                    Label("Print", systemImage: "printer")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(.bottom, 20)

            Divider().padding(.bottom, 16)

            // Storage checklist
            VStack(alignment: .leading, spacing: 8) {
                Text("Where to save it:")
                    .font(.callout.weight(.medium))
                ChecklistRow(text: "Print and store in a secure physical location")
                ChecklistRow(text: "An encrypted USB drive kept offline")
                ChecklistRow(text: "A password manager that is separate from this Mac")
                WarningRow(text: "Do not save to iCloud, Dropbox, or any cloud storage")
                WarningRow(text: "Do not share this key with anyone, including Orin support")
            }
            .padding(.bottom, 20)

            // Confirmation gate
            Toggle(isOn: $confirmed) {
                Text("I have saved my recovery key in a secure location")
                    .font(.callout)
            }
            .padding(.bottom, 16)

            // Footer buttons.
            // Cancel lets the user exit without checking the confirmation toggle —
            // the key sheet will reappear on next unlock so no information is lost.
            // Done requires the toggle and records that the key has been saved.
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)   // Escape key
                    .controlSize(.large)
                    .accessibilityHint("Exit without confirming the recovery key has been saved. The sheet will reappear next time you unlock.")
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!confirmed)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint(confirmed
                        ? "Confirms the key has been saved and closes this sheet."
                        : "Check the box above to confirm you have saved the key before closing.")
            }
        }
        .padding(28)
        .frame(width: 560)
        .fileExporter(
            isPresented: $isExporting,
            document: RecoveryKeyDocument(recoveryKey: recoveryKey),
            contentType: .plainText,
            defaultFilename: "Orin Vault Recovery Key"
        ) { _ in }
    }
}

// MARK: - Recovery entry (use key to unlock)

/// Shown when normal authentication fails and the user chooses to use
/// their saved recovery key instead.
struct VaultRecoveryKeyEntryView: View {
    let vaultService: VaultService
    var onSuccess: (SymmetricKey) -> Void
    var onCancel: () -> Void

    @State private var input = ""
    @State private var errorMessage: String?
    @State private var showingLostKey = false
    @State private var isSubmitting = false

    private var isLocked: Bool { vaultService.isRecoveryLocked }
    private var canSubmit: Bool {
        !isLocked && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 22))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Recovery Key")
                        .font(.title2.weight(.semibold))
                    Text("Enter the key you saved when you set up your vault")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 20)

            // Instructions
            Text("Paste or type your 64-character recovery key. Dashes are optional.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            // Key entry field
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX",
                              text: $input,
                              axis: .vertical)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2...3)
                    .disabled(isLocked)
                    .onChange(of: input) { _, new in
                        // Normalise to uppercase and strip characters that aren't hex or dashes
                        let cleaned = new.uppercased().filter { "0123456789ABCDEF- ".contains($0) }
                        if cleaned != new { input = cleaned }
                        errorMessage = nil
                    }

                    Button {
                        if let pasted = NSPasteboard.general.string(forType: .string) {
                            input = pasted.uppercased().filter { "0123456789ABCDEF-".contains($0) }
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Paste from clipboard")
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(errorMessage != nil ? Color.red.opacity(0.5) : Color.clear, lineWidth: 1)
                )
            }
            .padding(.bottom, 8)

            // Error / lockout status
            Group {
                if isLocked {
                    lockedBanner
                } else if let msg = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(msg).foregroundStyle(.red)
                        Spacer()
                        Text("\(vaultService.remainingRecoveryAttempts) attempt\(vaultService.remainingRecoveryAttempts == 1 ? "" : "s") remaining")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(.bottom, 16)

            // Submit
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 20)

            Divider().padding(.bottom, 12)

            // Lost key link
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Button("I've lost my recovery key") {
                    showingLostKey = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .font(.callout)
        }
        .padding(28)
        .frame(width: 540)
        .sheet(isPresented: $showingLostKey) {
            VaultLostKeyView(
                onBack: { showingLostKey = false },
                onCancel: { showingLostKey = false; onCancel() }
            )
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        if let key = vaultService.verifyAndParseRecoveryKey(input) {
            isSubmitting = false
            onSuccess(key)
        } else {
            isSubmitting = false
            if vaultService.isRecoveryLocked {
                errorMessage = nil   // lockedBanner will render
            } else {
                errorMessage = "That recovery key is incorrect."
            }
        }
    }

    @ViewBuilder
    private var lockedBanner: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let until = vaultService.recoveryLockoutUntil {
                let remaining = max(0, until.timeIntervalSince(context.date))
                let minutes = Int(remaining) / 60
                let seconds = Int(remaining) % 60
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.red)
                    Text("Too many incorrect attempts. Try again in \(minutes):\(String(format: "%02d", seconds)).")
                        .foregroundStyle(.red)
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Re-link after recovery

/// After a successful recovery-key unlock, offer to re-link the vault to
/// Touch ID / password so future unlocks don't require the recovery key.
struct VaultRelinkView: View {
    let vaultService: VaultService
    let vaultKey: SymmetricKey
    var onDone: () -> Void

    @State private var isRelinking = false
    @State private var result: RelinkResult?

    enum RelinkResult { case success, failed(String), skipped }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vault Unlocked")
                        .font(.title2.weight(.semibold))
                    Text("Your recovery key worked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 20)

            if let result {
                resultContent(result)
            } else {
                Text("Re-linking your vault to Touch ID means you won't need your recovery key for everyday unlocks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)

                HStack {
                    Spacer()
                    Button("Skip for Now") {
                        onDone()
                    }

                    Button {
                        Task { await relink() }
                    } label: {
                        if isRelinking {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.75)
                                Text("Re-linking…")
                            }
                        } else {
                            Label(vaultService.canUseBiometrics ? "Re-link with Touch ID" : "Re-link with Password",
                                  systemImage: "touchid")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRelinking)
                }
            }
        }
        .padding(28)
        .frame(width: 480)
    }

    @ViewBuilder
    private func resultContent(_ result: RelinkResult) -> some View {
        switch result {
        case .success:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Vault re-linked successfully. Future unlocks will use Touch ID or your password.")
                    .foregroundStyle(.primary)
            }
            .font(.callout)
            .padding(.bottom, 16)
            HStack { Spacer(); Button("Continue") { onDone() }.buttonStyle(.borderedProminent) }

        case .failed(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(msg).foregroundStyle(.primary)
            }
            .font(.callout)
            .padding(.bottom, 16)
            HStack {
                Spacer()
                Button("Try Again") { Task { await relink() } }
                Button("Skip") { onDone() }.buttonStyle(.borderedProminent)
            }

        case .skipped:
            EmptyView()
        }
    }

    private func relink() async {
        isRelinking = true
        switch await vaultService.relinkToKeychain(vaultKey) {
        case .success:
            result = .success
        case .failure(.userCancelled):
            isRelinking = false  // Let user try again
        case .failure(.authenticationFailed):
            result = .failed("Re-linking failed. You can try again from Vault Settings.")
        case .failure(.keychainError(let status)):
            result = .failed("Keychain error (\(status)). Try restarting the app.")
        }
        isRelinking = false
    }
}

// MARK: - Lost key flow

struct VaultLostKeyView: View {
    var onBack: () -> Void
    var onCancel: () -> Void

    @State private var showingResetConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                }
                Text("Lost Recovery Key")
                    .font(.title2.weight(.semibold))
            }
            .padding(.bottom, 20)

            Text("Without your recovery key, the vault can only be opened with Touch ID or your device password.")
                .font(.callout)
                .padding(.bottom, 10)

            Text("If none of those options work, the data in your vault is permanently inaccessible. This is by design — it means no one can get in without your credentials, including Orin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 10) {
                Text("Before giving up, try:")
                    .font(.callout.weight(.medium))
                BulletRow(text: "Restart your Mac — Touch ID hardware sometimes needs a reboot to respond")
                BulletRow(text: "Check if your recovery key was emailed, printed, or saved to a USB drive")
                BulletRow(text: "Check a password manager you used at the time you set up Orin")
            }
            .padding(.bottom, 24)

            Divider().padding(.bottom, 16)

            // Danger zone
            VStack(alignment: .leading, spacing: 8) {
                Label("Permanent Data Loss", systemImage: "trash.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text("If you choose to create a new vault, all items currently stored in the vault will be permanently deleted. This cannot be undone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.red.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 16)

            HStack {
                Button("I Found My Key") { onBack() }

                Spacer()

                Button("Create a New Vault") {
                    showingResetConfirm = true
                }
                .foregroundStyle(.red)
            }
        }
        .padding(28)
        .frame(width: 500)
        .sheet(isPresented: $showingResetConfirm) {
            VaultResetConfirmView(
                onConfirm: { showingResetConfirm = false; onCancel() },
                onCancel: { showingResetConfirm = false }
            )
        }
    }
}

// MARK: - Vault reset confirmation

struct VaultResetConfirmView: View {
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @State private var confirmText = ""
    private var isConfirmed: Bool { confirmText == "DELETE" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                Text("Delete All Vault Items?")
                    .font(.title2.weight(.semibold))
            }
            .padding(.bottom, 20)

            Text("This will permanently delete:")
                .font(.callout.weight(.medium))
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                BulletRow(text: "All passwords, tokens, and notes stored in your vault")
                BulletRow(text: "Your vault encryption key")
                BulletRow(text: "Your recovery key (a new one will be generated)")
            }
            .padding(.bottom, 16)

            Text("This action cannot be undone. You will start with a completely empty vault.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)

            // Confirmation text field
            VStack(alignment: .leading, spacing: 6) {
                Text("Type **DELETE** to confirm:")
                    .font(.callout)
                TextField("", text: $confirmText)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .padding(10)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isConfirmed ? Color.red.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            }
            .padding(.bottom, 20)

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete Everything") {
                    onConfirm()
                }
                .foregroundStyle(.white)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!isConfirmed)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}

// MARK: - Vault security settings

/// Settings sheet accessible from the Vault header.
/// Available in both locked and unlocked states.
struct VaultSecuritySettingsView: View {
    let vaultService: VaultService
    let vaultKey: SymmetricKey?            // nil when vault is locked
    var onResetVault: () -> Void

    @Environment(\.dismiss) private var dismiss

    @AppStorage("orin.vault.recoveryKeyShown") private var recoveryKeyShown = false

    @State private var verifyInput = ""
    @State private var verifyResult: VerifyResult?
    @State private var showingReexportOnboarding = false
    @State private var showingResetConfirm = false

    enum VerifyResult: Equatable { case valid, invalid }

    private var recoveryKeyString: String? {
        vaultKey.map { vaultService.recoveryKeyString(from: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Vault Security")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 20)

            Form {
                // Recovery key status
                Section {
                    LabeledContent("Recovery Key") {
                        if vaultService.hasVerificationToken {
                            Label("Registered", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Not registered — unlock vault first", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        }
                    }

                    if vaultKey != nil {
                        Button("Re-export Recovery Key") {
                            showingReexportOnboarding = true
                        }
                        Text("Shows your recovery key again so you can save it to a new location. Your key does not change.")
                            .font(OrinFont.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Unlock your vault to re-export your recovery key.")
                            .font(OrinFont.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recovery Key")
                }

                // Verify saved key
                if vaultService.hasVerificationToken {
                    Section {
                        Text("Confirm that the recovery key you have saved is still correct, without unlocking your vault.")
                            .font(OrinFont.caption)
                            .foregroundStyle(.secondary)

                        // Input row — onChange clears any previous result so the
                        // feedback stays in sync with what the user has typed.
                        HStack {
                            TextField("Paste or type your recovery key", text: $verifyInput)
                                .font(.system(.callout, design: .monospaced))
                                .onChange(of: verifyInput) { _, _ in verifyResult = nil }
                                .accessibilityLabel("Recovery key input field")

                            Button {
                                if let pasted = NSPasteboard.general.string(forType: .string) {
                                    verifyInput = pasted.uppercased()
                                        .filter { "0123456789ABCDEF-".contains($0) }
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Paste recovery key from clipboard")
                            .help("Paste from clipboard")
                        }

                        // Verify button — uses verifyRecoveryKey() which is side-effect
                        // free: no brute-force counter increment, no lockout check.
                        // The input field is intentionally NOT cleared here; clearing it
                        // would trigger onChange which would immediately wipe the result
                        // before SwiftUI can render it. The user dismisses or edits instead.
                        Button("Verify Key") {
                            verifyResult = vaultService.verifyRecoveryKey(verifyInput)
                                ? .valid : .invalid
                        }
                        .disabled(verifyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Verify the recovery key you have typed")
                        .accessibilityHint("Checks whether the key is correct without consuming any recovery attempts")

                        // Result banner — persists until the user edits the input or
                        // taps the dismiss button. Dismiss clears the input, which
                        // triggers onChange, which clears the result.
                        if let result = verifyResult {
                            HStack(spacing: 8) {
                                if result == .valid {
                                    Label("Recovery key is correct.", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("Verification passed. Your recovery key is correct.")
                                } else {
                                    Label("That is not the correct recovery key.", systemImage: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .accessibilityLabel("Verification failed. The key you entered does not match your vault.")
                                }
                                Spacer()
                                Button {
                                    verifyInput = ""   // onChange fires → verifyResult = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Dismiss verification result and clear input")
                                .help("Clear and dismiss")
                            }
                            .font(.callout)
                            .padding(10)
                            .background(result == .valid
                                        ? Color.green.opacity(0.1)
                                        : Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        }
                    } header: {
                        Text("Verify Saved Key")
                    }
                }

                // Danger zone
                Section {
                    Button("Reset Vault…") {
                        showingResetConfirm = true
                    }
                    .foregroundStyle(.red)
                    .disabled(vaultKey == nil)

                    if vaultKey == nil {
                        Text("Unlock your vault before resetting.")
                            .font(OrinFont.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Permanently deletes all vault items and generates a new encryption key. This cannot be undone.")
                            .font(OrinFont.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Danger Zone")
                }
            }
            .formStyle(.grouped)

            // ── Footer ─────────────────────────────────────────────────────────
            // Provides all non-destructive exit paths from the settings sheet.
            // The two hidden buttons wire keyboard shortcuts so users never need
            // to hunt for a close path.
            Divider()
                .padding(.top, 8)

            HStack {
                // Escape — semantically "done" not "cancel": settings are not
                // transactional, so there is nothing to abandon.
                Button("") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
                    .accessibilityHidden(true)

                // Cmd+W — redirects to sheet-level dismissal instead of closing
                // the parent app window accidentally.
                Button("") { dismiss() }
                    .keyboardShortcut("w", modifiers: .command)
                    .hidden()
                    .accessibilityHidden(true)

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityLabel("Close Vault Security Settings")
                    .accessibilityHint("Closes this sheet. All changes are saved immediately.")
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 480)
        .sheet(isPresented: $showingReexportOnboarding) {
            if let keyStr = recoveryKeyString {
                VaultRecoveryOnboardingView(recoveryKey: keyStr) {
                    showingReexportOnboarding = false
                }
            }
        }
        .sheet(isPresented: $showingResetConfirm) {
            VaultResetConfirmView(
                onConfirm: {
                    showingResetConfirm = false
                    onResetVault()
                },
                onCancel: { showingResetConfirm = false }
            )
        }
    }
}

// MARK: - File export document

struct RecoveryKeyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let recoveryKey: String
    private let generatedAt: Date

    init(recoveryKey: String) {
        self.recoveryKey = recoveryKey
        self.generatedAt = Date()
    }

    init(configuration: ReadConfiguration) throws {
        recoveryKey = ""
        generatedAt = Date()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(recoverySheetText(recoveryKey: recoveryKey, date: generatedAt).utf8))
    }
}

// MARK: - Print

func printRecoverySheet(recoveryKey: String) {
    let text = recoverySheetText(recoveryKey: recoveryKey, date: Date())
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 800))
    textView.string = text
    textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.isEditable = false

    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.topMargin    = 72
    info.bottomMargin = 72
    info.leftMargin   = 72
    info.rightMargin  = 72
    info.verticalPagination   = .automatic
    info.horizontalPagination = .fit

    let op = NSPrintOperation(view: textView, printInfo: info)
    op.showsPrintPanel   = true
    op.showsProgressPanel = true
    op.run()
}

// MARK: - Recovery sheet text generator

private func recoverySheetText(recoveryKey: String, date: Date) -> String {
    let dateStr = date.formatted(date: .long, time: .omitted)
    return """
    ORIN VAULT RECOVERY KEY
    =======================
    Generated: \(dateStr)

    YOUR RECOVERY KEY:

        \(recoveryKey)

    ---------------------------------------------------------------
    SECURITY NOTICE
    ---------------------------------------------------------------

    • This key grants FULL ACCESS to all secrets in your Orin vault.
    • Anyone who obtains this key can read your vault.
    • Store this in a secure, offline location:
        - Printed paper in a locked safe
        - An encrypted, offline USB drive
        - A separate password manager not stored on this Mac
    • Do NOT store this file in iCloud, Dropbox, or any cloud
      service.
    • Orin support will NEVER ask you for this key.

    ---------------------------------------------------------------
    HOW TO USE THIS KEY
    ---------------------------------------------------------------

    If you cannot unlock your vault with Touch ID or your password:

    1. Open Orin on your Mac
    2. Go to the Vault section in the sidebar
    3. Click "Unlock Vault"
    4. Click "Can't unlock? Use Recovery Key"
    5. Enter the key above (dashes and spaces are optional)
    6. After unlocking, go to Vault Security Settings and
       re-link to Touch ID for easier future unlocks

    ---------------------------------------------------------------
    ABOUT THIS FILE
    ---------------------------------------------------------------

    Generated by Orin. After printing or saving to a secure
    offline location, delete this file from your Mac.

    """
}

// MARK: - Small helper views (shared within this file)

private struct ChecklistRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct WarningRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct BulletRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.callout).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}
