import CryptoKit
import SwiftData
import SwiftUI

struct VaultView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VaultItem.lastAccessed, order: .reverse)
    private var vaultItems: [VaultItem]

    @State private var vaultKey: SymmetricKey?
    @State private var selectedItemID: UUID?
    @State private var revealedSecret = ""
    @State private var isAddingItem = false
    @State private var errorMessage: String?

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
                        Label("Unlock", systemImage: "touchid")
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
            }

            if vaultKey == nil {
                ContentUnavailableView("Vault Locked", systemImage: "lock.shield", description: Text("Unlock with Touch ID or your device password to view and manage local secrets."))
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
                            if let selectedItem {
                                delete(selectedItem)
                            }
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
    }

    private func unlock() async {
        switch await vaultService.unlockVault() {
        case .success(let key):
            vaultKey = key
            errorMessage = nil
        case .failure:
            errorMessage = "Vault unlock failed."
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
                ContentUnavailableView("No Vault Item Selected", systemImage: "key", description: Text("Choose an item to reveal its encrypted contents."))
            }
        }
        .padding()
    }
}

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
