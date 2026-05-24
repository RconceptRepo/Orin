import SwiftUI

struct SettingsView: View {
    @AppStorage("orin.theme.mode") private var themeModeRawValue = OrinThemeMode.system.rawValue
    @AppStorage("orin.ai.provider") private var providerRaw = AIProvider.ollama.rawValue
    @AppStorage("orin.ai.ollamaEndpoint") private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage("orin.calendar.backgroundSync") private var calendarBackgroundSync = true

    @State private var ollamaService     = ServiceContainer.shared.resolve(OllamaInstallerService.self)
    @State private var loginItemService  = ServiceContainer.shared.resolve(LoginItemService.self)

    // External key drafts — held only long enough to be saved to Keychain, never persisted
    @State private var openAIKeyDraft    = ""
    @State private var anthropicKeyDraft = ""
    @State private var geminiKeyDraft    = ""

    // Keychain presence flags, refreshed in onAppear and after save/delete
    @State private var openAIConfigured    = AIKeychainService.hasKey(for: AIService.openAIAccount)
    @State private var anthropicConfigured = AIKeychainService.hasKey(for: AIService.anthropicAccount)
    @State private var geminiConfigured    = AIKeychainService.hasKey(for: AIService.geminiAccount)

    var body: some View {
        Form {
            // MARK: General
            Section("General") {
                Picker("Appearance", selection: $themeModeRawValue) {
                    ForEach(OrinThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                Toggle("Launch automatically on login", isOn: Binding(
                    get: { loginItemService.isEnabled },
                    set: { loginItemService.setEnabled($0) }
                ))

                if let error = loginItemService.errorMessage {
                    Text(error)
                        .font(OrinFont.caption)
                        .foregroundStyle(OrinColor.error)
                }

                Toggle("Calendar background sync", isOn: $calendarBackgroundSync)
            }

            // MARK: AI
            Section("AI") {
                Picker("Primary Provider", selection: $providerRaw) {
                    Text("Ollama Local").tag(AIProvider.ollama.rawValue)
                    Text("OpenAI").tag(AIProvider.openAI.rawValue)
                    Text("Claude").tag(AIProvider.anthropic.rawValue)
                    Text("Gemini").tag(AIProvider.gemini.rawValue)
                }

                TextField("Ollama Endpoint", text: $ollamaEndpoint)
                LabeledContent("Ollama") {
                    HStack {
                        Text(ollamaService.status.rawValue)
                            .foregroundStyle(ollamaStatusColor)
                        Button("Verify") {
                            Task { await ollamaService.verify(endpoint: ollamaEndpoint) }
                        }
                    }
                }
                Text(ollamaService.message)
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)

                providerRow(
                    label: "OpenAI",
                    isConfigured: openAIConfigured,
                    draft: $openAIKeyDraft,
                    placeholder: "OpenAI API Key",
                    account: AIService.openAIAccount,
                    configured: $openAIConfigured
                )

                providerRow(
                    label: "Claude",
                    isConfigured: anthropicConfigured,
                    draft: $anthropicKeyDraft,
                    placeholder: "Anthropic API Key",
                    account: AIService.anthropicAccount,
                    configured: $anthropicConfigured
                )

                providerRow(
                    label: "Gemini",
                    isConfigured: geminiConfigured,
                    draft: $geminiKeyDraft,
                    placeholder: "Gemini API Key",
                    account: AIService.geminiAccount,
                    configured: $geminiConfigured
                )
            }

            // MARK: Privacy
            Section("Privacy") {
                LabeledContent("Default AI Mode", value: providerRaw == AIProvider.ollama.rawValue ? "Local only" : "External with local fallover")
                LabeledContent("Calendar Source", value: "EventKit (local)")
                LabeledContent("Vault Storage", value: "On-device AES-256-GCM")
                LabeledContent("Transcription", value: "On-device via SFSpeechRecognizer")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
        .onAppear {
            loginItemService.refreshStatus()
            openAIConfigured    = AIKeychainService.hasKey(for: AIService.openAIAccount)
            anthropicConfigured = AIKeychainService.hasKey(for: AIService.anthropicAccount)
            geminiConfigured    = AIKeychainService.hasKey(for: AIService.geminiAccount)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func providerRow(
        label: String,
        isConfigured: Bool,
        draft: Binding<String>,
        placeholder: String,
        account: String,
        configured: Binding<Bool>
    ) -> some View {
        LabeledContent(label) { providerStatus(isConfigured) }
        SecureField(placeholder, text: draft)
        HStack {
            Button("Save \(label) Key") {
                guard !draft.wrappedValue.isEmpty else { return }
                AIKeychainService.save(draft.wrappedValue, account: account)
                configured.wrappedValue = true
                draft.wrappedValue = ""
            }
            .disabled(draft.wrappedValue.isEmpty)

            if isConfigured {
                Button("Remove", role: .destructive) {
                    AIKeychainService.delete(account: account)
                    configured.wrappedValue = false
                }
            }
        }
    }

    private func providerStatus(_ configured: Bool) -> some View {
        Label(
            configured ? "Configured" : "Not configured",
            systemImage: configured ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(configured ? Color.green : .secondary)
    }

    private var ollamaStatusColor: Color {
        switch ollamaService.status {
        case .connected: OrinColor.success
        case .missing:   OrinColor.warning
        case .failed:    OrinColor.error
        case .unknown:   .secondary
        }
    }
}
