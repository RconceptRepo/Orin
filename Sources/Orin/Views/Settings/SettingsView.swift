import SwiftUI

struct SettingsView: View {
    @AppStorage("orin.theme.mode") private var themeModeRawValue = OrinThemeMode.system.rawValue
    @AppStorage("orin.ai.provider") private var providerRaw = AIProvider.ollama.rawValue
    @AppStorage("orin.ai.ollamaEndpoint") private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage("orin.calendar.backgroundSync") private var calendarBackgroundSync = true
    @AppStorage("orin.meetings.retentionDays") private var retentionDays = MeetingRetentionService.RetentionPolicy.thirtyDays.rawValue

    @State private var aiTester        = ServiceContainer.shared.resolve(AIProviderTestService.self)
    @State private var loginItemService = ServiceContainer.shared.resolve(LoginItemService.self)

    // Key drafts — held only long enough to be saved to Keychain, never persisted elsewhere
    @State private var openAIKeyDraft    = ""
    @State private var anthropicKeyDraft = ""
    @State private var geminiKeyDraft    = ""

    // Keychain presence flags — refreshed on appear and after save/delete
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
                    Text("Login item requires Orin to be installed in /Applications and signed with a Developer ID certificate.")
                        .font(OrinFont.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Calendar background sync", isOn: $calendarBackgroundSync)
            }

            // MARK: AI
            Section("AI") {
                Picker("Provider Priority", selection: $providerRaw) {
                    Text("Ollama Local").tag(AIProvider.ollama.rawValue)
                    Text("OpenAI").tag(AIProvider.openAI.rawValue)
                    Text("Claude").tag(AIProvider.anthropic.rawValue)
                    Text("Gemini").tag(AIProvider.gemini.rawValue)
                }
                Text("Inference cascades automatically: Ollama → OpenAI → Claude → Gemini.")
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)

                // ── Ollama ──────────────────────────────────────────────────
                TextField("Ollama Endpoint", text: $ollamaEndpoint)
                LabeledContent("Ollama") { connectionStatusView(aiTester.ollamaStatus) }
                if case .failed(let reason) = aiTester.ollamaStatus {
                    Text(reason)
                        .font(OrinFont.caption)
                        .foregroundStyle(OrinColor.error)
                }
                Button("Test Connection") {
                    Task { await aiTester.testOllama(endpoint: ollamaEndpoint) }
                }
                .disabled(aiTester.ollamaStatus == .testing)

                // ── OpenAI ──────────────────────────────────────────────────
                providerRow(
                    label: "OpenAI",
                    isConfigured: openAIConfigured,
                    draft: $openAIKeyDraft,
                    placeholder: "sk-...",
                    account: AIService.openAIAccount,
                    configured: $openAIConfigured,
                    status: aiTester.openAIStatus,
                    onTest: {
                        let draft = openAIKeyDraft
                        Task { await aiTester.testOpenAI(key: draft.isEmpty ? nil : draft) }
                    }
                )

                // ── Claude ──────────────────────────────────────────────────
                providerRow(
                    label: "Claude",
                    isConfigured: anthropicConfigured,
                    draft: $anthropicKeyDraft,
                    placeholder: "sk-ant-...",
                    account: AIService.anthropicAccount,
                    configured: $anthropicConfigured,
                    status: aiTester.anthropicStatus,
                    onTest: {
                        let draft = anthropicKeyDraft
                        Task { await aiTester.testAnthropic(key: draft.isEmpty ? nil : draft) }
                    }
                )

                // ── Gemini ──────────────────────────────────────────────────
                providerRow(
                    label: "Gemini",
                    isConfigured: geminiConfigured,
                    draft: $geminiKeyDraft,
                    placeholder: "AI...",
                    account: AIService.geminiAccount,
                    configured: $geminiConfigured,
                    status: aiTester.geminiStatus,
                    onTest: {
                        let draft = geminiKeyDraft
                        Task { await aiTester.testGemini(key: draft.isEmpty ? nil : draft) }
                    }
                )
            }

            // MARK: Meetings
            Section("Meetings") {
                Picker("Keep meeting records", selection: $retentionDays) {
                    ForEach(MeetingRetentionService.RetentionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                Text("Older meetings and their local recordings are deleted automatically on launch.")
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Siri & Shortcuts
            Section("Siri & Shortcuts") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(OrinColor.warning)
                        Text("Requires App Store or TestFlight distribution")
                            .font(OrinFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Siri phrases and Shortcuts require the app to be signed with a Developer ID and distributed via the App Store or TestFlight. They are unavailable in local/ad-hoc builds.")
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Privacy
            Section("Privacy") {
                LabeledContent("Default AI Mode", value: providerRaw == AIProvider.ollama.rawValue ? "Local only" : "External with local fallover")
                LabeledContent("Calendar Source", value: "EventKit (local)")
                LabeledContent("Vault Storage", value: "On-device AES-256-GCM")
                LabeledContent("Transcription", value: "On-device via SFSpeechRecognizer")
            }

            // MARK: Troubleshooting
            Section("Troubleshooting") {
                Button("Re-run Setup Wizard") {
                    UserDefaults.standard.removeObject(forKey: "orin.hasCompletedOnboarding")
                }
                .foregroundStyle(OrinColor.accent)
                Text("Use this to re-grant permissions if the setup wizard was dismissed too early.")
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: - Shared status indicator

    @ViewBuilder
    private func connectionStatusView(_ status: ProviderConnectionStatus) -> some View {
        switch status {
        case .unknown:
            Label("Not tested", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Testing...").foregroundStyle(.secondary)
            }
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(OrinColor.success)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(OrinColor.error)
        case .notConfigured:
            Label("Not configured", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - External provider row (key entry + test + save + remove)

    @ViewBuilder
    private func providerRow(
        label: String,
        isConfigured: Bool,
        draft: Binding<String>,
        placeholder: String,
        account: String,
        configured: Binding<Bool>,
        status: ProviderConnectionStatus,
        onTest: @escaping () -> Void
    ) -> some View {
        LabeledContent(label) { connectionStatusView(status) }

        if case .failed(let reason) = status {
            Text(reason)
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.error)
        }

        SecureField(placeholder, text: draft)

        HStack {
            Button("Test") { onTest() }
                .disabled(status == .testing)

            Button("Save") {
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
}
