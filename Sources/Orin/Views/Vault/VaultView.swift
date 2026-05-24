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
    @State private var errorMessage: String?
    @State private var showingRecoveryKey = false
    @State private var recoveryKeyString = ""

    private let vaultService = ServiceContainer.shared.resolve(VaultService.self)

    private var selectedItem: VaultItem? {
        vaultItems.first { $0.id == selectedItemID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                        Label(vaultService.canUseBiometrics ? "Unlock with Touch ID" : "Unlock", systemImage: "touchid")
                    }
                } else {
                    Button {
                        isAddingItem = true
                    } label: {
                        Label("New Item", systemImage: "plus")
                    }

                    Button {
                        lock()
                    } label: {
                        Label("Lock", systemImage: "lock")
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

            if vaultKey == nil {
                ContentUnavailableView(
                    "Vault Locked",
                    systemImage: "lock.shield",
                    description: Text("Tap Unlock to authenticate with Touch ID or your device password.")
                )
            } else {
                HSplitView {
                    List(vaultItems, selection: $selectedItemID) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.body)
                            Text(item.itemType.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(item.id)
                    }
                    .frame(minWidth: 240)
                    .onChange(of: selectedItemID) { _, _ in
                        reveal(selectedItem)
                    }

                    VaultDetailView(
                        item: selectedItem,
                        revealedSecret: revealedSecret,
                        onReveal: { reveal(selectedItem) },
                        onDelete: {
                            if let selectedItem { delete(selectedItem) }
                        }
                    )
                    .frame(minWidth: 360)
                }
            }
        }
        .padding()
        .sheet(isPresented: $isAddingItem) {
            VaultItemEditorView { draft in
                save(draft)
            }
        }
        .sheet(isPresented: $showingRecoveryKey) {
            VaultRecoveryKeyView(recoveryKey: recoveryKeyString) {
                recoveryKeyShown = true
                showingRecoveryKey = false
            }
        }
    }

    private func unlock() async {
        errorMessage = nil
        switch await vaultService.unlockVault() {
        case .success(let key):
            vaultKey = key
            if !recoveryKeyShown {
                recoveryKeyString = vaultService.recoveryKeyString(from: key)
                showingRecoveryKey = true
            }
        case .failure:
            errorMessage = "Vault unlock failed. Ensure Touch ID or a device password is configured in System Settings."
        }
    }

    private func lock() {
        vaultKey = nil
        selectedItemID = nil
        revealedSecret = ""
    }

    private func reveal(_ item: VaultItem?) {
        guard let item, let vaultKey else {
            revealedSecret = ""
            return
        }

        do {
            let decrypted = try vaultService.decrypt(item.encryptedSecret, using: vaultKey)
            revealedSecret = String(data: decrypted, encoding: .utf8) ?? ""
            item.lastAccessed = Date()
            try? modelContext.save()
        } catch {
            revealedSecret = ""
            errorMessage = "Could not decrypt this item."
        }
    }

    private func save(_ draft: VaultItemDraft) {
        guard let vaultKey else { return }

        do {
            let data = Data(draft.secret.utf8)
            let encrypted = try vaultService.encrypt(data, using: vaultKey)
            modelContext.insert(VaultItem(title: draft.title, encryptedSecret: encrypted, itemType: draft.itemType))
            try modelContext.save()
        } catch {
            errorMessage = "Could not save vault item."
        }
    }

    private func delete(_ item: VaultItem) {
        modelContext.delete(item)
        selectedItemID = nil
        revealedSecret = ""
        try? modelContext.save()
    }
}

// MARK: - Recovery key sheet

private struct VaultRecoveryKeyView: View {
    let recoveryKey: String
    var onDismiss: () -> Void

    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "key.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text("Your Recovery Key")
                    .font(.title2.weight(.semibold))
            }

            Text("This key can unlock your vault if Touch ID becomes unavailable. Save it somewhere safe — it will not be shown again.")
                .font(.body)
                .foregroundStyle(.secondary)

            Text(recoveryKey)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recoveryKey, forType: .string)
                confirmed = true
            } label: {
                Label(confirmed ? "Copied!" : "Copy to Clipboard", systemImage: confirmed ? "checkmark" : "doc.on.doc")
            }

            Toggle("I have saved my recovery key in a safe place", isOn: $confirmed)

            HStack {
                Spacer()
                Button("I've Saved It") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!confirmed)
            }
        }
        .padding(28)
        .frame(width: 520)
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
                        Text(item.title)
                            .font(.title3.weight(.semibold))
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

                Button {
                    onReveal()
                } label: {
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
            Text("New Vault Item")
                .font(.title2.weight(.semibold))

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
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.secret.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
