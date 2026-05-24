import CryptoKit
import SwiftData
import SwiftUI

struct VaultView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VaultItem.lastAccessed, order: .reverse)
    private var vaultItems: [VaultItem]

    @AppStorage("orin.vault.recoveryKeyShown") private var recoveryKeyShown = false

    @State private var vaultKey: SymmetricKey?
    @State private var selectedItemID: UUID?
    @State private var revealedSecret = ""
    @State private var isAddingItem = false
    @State private var isUnlocking = false

    // Recovery key onboarding (first unlock)
    @State private var showingRecoveryKey = false
    @State private var recoveryKeyString = ""

    // Recovery flow (use saved key to unlock)
    @State private var showingRecoveryEntry = false

    // Re-link banner and sheet (after recovery-key unlock)
    @State private var unlockedViaRecovery = false
    @State private var showingRelinkOffer = false

    // Vault security settings
    @State private var showingVaultSettings = false

    private let vaultService = ServiceContainer.shared.resolve(VaultService.self)

    private var selectedItem: VaultItem? {
        vaultItems.first { $0.id == selectedItemID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow

            if unlockedViaRecovery, vaultKey != nil {
                recoveryBanner
            }

            if vaultKey == nil {
                lockedContent
            } else {
                unlockedContent
            }
        }
        .padding()
        .sheet(isPresented: $isAddingItem) {
            VaultItemEditorView { draft in save(draft) }
        }
        .sheet(isPresented: $showingRecoveryKey) {
            VaultRecoveryOnboardingView(recoveryKey: recoveryKeyString) {
                recoveryKeyShown = true
                showingRecoveryKey = false
            }
        }
        .sheet(isPresented: $showingRecoveryEntry) {
            VaultRecoveryKeyEntryView(
                vaultService: vaultService,
                onSuccess: { key in
                    showingRecoveryEntry = false
                    vaultKey = key
                    vaultService.clearSession()  // Don't cache — re-link is pending
                    unlockedViaRecovery = true
                    if !recoveryKeyShown {
                        recoveryKeyString = vaultService.recoveryKeyString(from: key)
                        showingRecoveryKey = true
                    }
                },
                onCancel: { showingRecoveryEntry = false }
            )
        }
        .sheet(isPresented: $showingRelinkOffer) {
            if let key = vaultKey {
                VaultRelinkView(
                    vaultService: vaultService,
                    vaultKey: key,
                    onDone: { showingRelinkOffer = false }
                )
            }
        }
        .sheet(isPresented: $showingVaultSettings) {
            VaultSecuritySettingsView(
                vaultService: vaultService,
                vaultKey: vaultKey,
                onResetVault: {
                    showingVaultSettings = false
                    performVaultReset()
                }
            )
        }
    }

    // MARK: - Sub-views

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Vault")
                    .font(.title2.weight(.semibold))
                Text(vaultKey == nil ? "Locked" : "Unlocked")
                    .font(.subheadline)
                    .foregroundStyle(vaultKey == nil ? Color.secondary : Color.green)
            }

            Spacer()

            if vaultKey == nil {
                Button {
                    Task { await unlock() }
                } label: {
                    if isUnlocking {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Unlocking…")
                        }
                        .frame(height: 28)
                    } else {
                        Label(vaultService.canUseBiometrics ? "Unlock with Touch ID" : "Unlock",
                              systemImage: vaultService.canUseBiometrics ? "touchid" : "lock.open")
                    }
                }
                .disabled(isUnlocking)
            } else {
                Button { isAddingItem = true } label: {
                    Label("New Item", systemImage: "plus")
                }
                Button { lock() } label: {
                    Label("Lock", systemImage: "lock")
                }
            }

            Button { showingVaultSettings = true } label: {
                Image(systemName: "gear")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Vault Security Settings")
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Vault Locked",
                systemImage: "lock.shield",
                description: Text(vaultService.canUseBiometrics
                    ? "Tap Unlock to authenticate with Touch ID. Your password is used as a fallback if Touch ID is unavailable."
                    : "Tap Unlock and enter your device password to access the vault.")
            )

            Button {
                showingRecoveryEntry = true
            } label: {
                Text("Can't unlock? Use Recovery Key")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    private var unlockedContent: some View {
        HSplitView {
            List(vaultItems, selection: $selectedItemID) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.body)
                    Text(item.itemType.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(item.id)
            }
            .frame(minWidth: 240)
            .onChange(of: selectedItemID) { _, _ in reveal(selectedItem) }

            VaultDetailView(
                item: selectedItem,
                revealedSecret: revealedSecret,
                onReveal: { reveal(selectedItem) },
                onDelete: { if let selectedItem { delete(selectedItem) } }
            )
            .frame(minWidth: 360)
        }
    }

    private var recoveryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal.fill")
                .foregroundStyle(.orange)
            Text("Vault unlocked with recovery key.")
                .font(.callout)
            Spacer()
            Button("Re-link to Touch ID") {
                unlockedViaRecovery = false
                showingRelinkOffer = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .font(.callout)

            Button { unlockedViaRecovery = false } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func unlock() async {
        isUnlocking = true
        defer { isUnlocking = false }
        switch await vaultService.unlockVault() {
        case .success(let key):
            vaultKey = key
            // Register verification token for vaults created before this feature
            if !vaultService.hasVerificationToken {
                vaultService.storeVerificationToken(for: key)
            }
            if !recoveryKeyShown {
                recoveryKeyString = vaultService.recoveryKeyString(from: key)
                showingRecoveryKey = true
            }
        case .failure(.userCancelled):
            break  // Expected — user dismissed the prompt; no error shown
        case .failure(.authenticationFailed):
            ErrorManager.shared.report(.vaultAuthenticationFailed,
                                       retryAction: { await unlock() })
        case .failure(.keychainError(let status)):
            ErrorManager.shared.report(.vaultKeychainFailed(status: status))
        }
    }

    private func lock() {
        vaultService.clearSession()
        vaultKey = nil
        selectedItemID = nil
        revealedSecret = ""
        unlockedViaRecovery = false
    }

    private func reveal(_ item: VaultItem?) {
        guard let item, let vaultKey else { revealedSecret = ""; return }
        do {
            let decrypted = try vaultService.decrypt(item.encryptedSecret, using: vaultKey)
            revealedSecret = String(data: decrypted, encoding: .utf8) ?? ""
            item.lastAccessed = Date()
            modelContext.safeSave(context: "vault access timestamp")
        } catch {
            revealedSecret = ""
            ErrorManager.shared.report(.vaultEncryptionFailed)
        }
    }

    private func save(_ draft: VaultItemDraft) {
        guard let vaultKey else { return }
        do {
            let encrypted = try vaultService.encrypt(Data(draft.secret.utf8), using: vaultKey)
            modelContext.insert(VaultItem(title: draft.title, encryptedSecret: encrypted, itemType: draft.itemType))
            modelContext.safeSave(context: "vault item")
        } catch {
            ErrorManager.shared.report(.vaultEncryptionFailed)
        }
    }

    private func delete(_ item: VaultItem) {
        modelContext.delete(item)
        selectedItemID = nil
        revealedSecret = ""
        modelContext.safeSave(context: "vault item")
    }

    private func performVaultReset() {
        for item in vaultItems { modelContext.delete(item) }
        modelContext.safeSave(context: "vault reset")
        vaultService.resetVault()
        recoveryKeyShown = false
        vaultKey = nil
        selectedItemID = nil
        revealedSecret = ""
        unlockedViaRecovery = false
    }
}

// MARK: - Detail view

private struct VaultDetailView: View {
    let item: VaultItem?
    let revealedSecret: String
    var onReveal: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.title3.weight(.semibold))
                        Text("Last accessed \(item.lastAccessed.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }

                TextEditor(text: .constant(revealedSecret))
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button { onReveal() } label: {
                    Label("Reveal Again", systemImage: "eye")
                }
            } else {
                ContentUnavailableView(
                    "No Vault Item Selected",
                    systemImage: "key",
                    description: Text("Choose an item to reveal its encrypted contents.")
                )
            }
        }
        .padding()
    }
}

// MARK: - Add item

private struct VaultItemDraft {
    var title = ""
    var itemType = "password"
    var secret = ""
}

private struct VaultItemEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = VaultItemDraft()
    var onSave: (VaultItemDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Vault Item").font(.title2.weight(.semibold))

            Form {
                TextField("Title", text: $draft.title)
                Picker("Type", selection: $draft.itemType) {
                    Text("Password").tag("password")
                    Text("Token").tag("token")
                    Text("Note").tag("note")
                }
                SecureField("Secret", text: $draft.secret)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.secret.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
