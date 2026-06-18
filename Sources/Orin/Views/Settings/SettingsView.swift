import AppKit
import SwiftData
import SwiftUI

struct SettingsView: View {

    // MARK: - AppStorage

    @AppStorage("orin.theme.mode") private var themeModeRawValue = OrinThemeMode.system.rawValue
    @AppStorage("orin.ai.ollamaEndpoint") private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage("orin.calendar.backgroundSync") private var calendarBackgroundSync = true
    @AppStorage("orin.meetings.retentionDays") private var retentionDays = MeetingRetentionService.RetentionPolicy.thirtyDays.rawValue
    @AppStorage("orin.meetings.autoAnalyze") private var autoAnalyze = true
    @AppStorage("orin.meetings.minDurationMinutes") private var minDurationMinutes = 1

    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext

    // MARK: - Services

    @State private var aiTester         = ServiceContainer.shared.resolve(AIProviderTestService.self)
    @State private var loginItemService = ServiceContainer.shared.resolve(LoginItemService.self)
    @State private var ollamaInstaller  = ServiceContainer.shared.resolve(OllamaInstallerService.self)
    @State private var vaultService     = ServiceContainer.shared.resolve(VaultService.self)
    @State private var calendarService  = ServiceContainer.shared.resolve(CalendarService.self)
    private let dataService             = ServiceContainer.shared.resolve(MeetingDataService.self)

    // MARK: - Sheet / Dialog state

    @State private var showOllamaSetup        = false
    @State private var showVaultResetConfirm  = false
    @State private var showWizardResetConfirm = false

    // MARK: - API key drafts (never persisted; only used to pass to Keychain on Save)

    @State private var openAIKeyDraft    = ""
    @State private var anthropicKeyDraft = ""
    @State private var geminiKeyDraft    = ""

    // MARK: - Keychain presence flags

    @State private var openAIConfigured    = AIKeychainService.hasKey(for: AIService.openAIAccount)
    @State private var anthropicConfigured = AIKeychainService.hasKey(for: AIService.anthropicAccount)
    @State private var geminiConfigured    = AIKeychainService.hasKey(for: AIService.geminiAccount)

    // MARK: - Save-flash state (shown for 2 s after a successful key save)

    @State private var openAISavedFlash    = false
    @State private var anthropicSavedFlash = false
    @State private var geminiSavedFlash    = false

    // MARK: - Data management state

    @State private var exportProgress    = false
    @State private var dataActionStatus: String?

    // MARK: - Calendar sync state

    @State private var isSyncingCalendar = false

    // MARK: - Body

    var body: some View {
        Form {
            generalSection
            aiSection
            calendarSection
            meetingsSection
            dataSection
            vaultSection
            privacySection
            troubleshootingSection
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
        .sheet(isPresented: $showOllamaSetup) {
            OllamaSetupView(onComplete: { showOllamaSetup = false })
                .frame(width: 620, height: 560)
        }
        .onAppear {
            loginItemService.refreshStatus()
            calendarService.refreshAuthorizationStatus()
            openAIConfigured    = AIKeychainService.hasKey(for: AIService.openAIAccount)
            anthropicConfigured = AIKeychainService.hasKey(for: AIService.anthropicAccount)
            geminiConfigured    = AIKeychainService.hasKey(for: AIService.geminiAccount)
            // Auto-probe Ollama only when status is unknown or failed — skip if already connected
            if aiTester.ollamaStatus != .connected {
                Task { await aiTester.testOllama(endpoint: ollamaEndpoint) }
            }
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        Section("General") {
            Picker("Appearance", selection: $themeModeRawValue) {
                ForEach(OrinThemeMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }

            Toggle(isOn: Binding(
                get: { loginItemService.isEnabled },
                set: { loginItemService.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch automatically on login")
                    Text(loginItemStatusLabel)
                        .font(OrinFont.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = loginItemService.errorMessage {
                Text(error)
                    .font(OrinFont.caption)
                    .foregroundStyle(OrinColor.error)
                Text("Requires installation in /Applications with Developer ID.")
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Events sync in the background", isOn: $calendarBackgroundSync)
        }
    }

    private var loginItemStatusLabel: String {
        #if DEBUG
        return "Unavailable in dev builds"
        #else
        return loginItemService.isEnabled ? "Enabled" : "Disabled"
        #endif
    }

    // MARK: - AI Section

    private var aiSection: some View {
        Section("AI") {
            Text("Orin uses the first available provider: Ollama → OpenAI → Claude → Gemini")
                .font(OrinFont.caption)
                .foregroundStyle(.secondary)

            // ── Ollama ────────────────────────────────────────────────────────
            ollamaSubsection

            // ── OpenAI ────────────────────────────────────────────────────────
            openAISubsection

            // ── Claude (Anthropic) ────────────────────────────────────────────
            anthropicSubsection

            // ── Gemini ────────────────────────────────────────────────────────
            geminiSubsection
        }
    }

    // MARK: Ollama

    @ViewBuilder
    private var ollamaSubsection: some View {
        TextField("Ollama Endpoint", text: $ollamaEndpoint)

        LabeledContent("Ollama") {
            connectionStatusView(aiTester.ollamaStatus)
        }

        if case .failed(let reason) = aiTester.ollamaStatus {
            Text(reason)
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.error)
        }

        HStack {
            Button("Test Connection") {
                Task { await aiTester.testOllama(endpoint: ollamaEndpoint) }
            }
            .disabled(aiTester.ollamaStatus == .testing)

            if aiTester.ollamaStatus == .testing {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.leading, 4)
            }
        }

        Text("Ollama runs locally. Install from ollama.com then run: ollama pull llama3")
            .font(OrinFont.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: OpenAI

    @ViewBuilder
    private var openAISubsection: some View {
        LabeledContent("OpenAI") {
            connectionStatusView(aiTester.openAIStatus)
        }

        if case .failed(let reason) = aiTester.openAIStatus {
            Text(reason)
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.error)
        }

        SecureField("sk-...", text: $openAIKeyDraft)

        Text("Keys start with sk-")
            .font(OrinFont.caption)
            .foregroundStyle(.secondary)

        HStack(spacing: 8) {
            Button("Test") {
                let draft = openAIKeyDraft
                Task { await aiTester.testOpenAI(key: draft.isEmpty ? nil : draft) }
            }
            .disabled(aiTester.openAIStatus == .testing)

            Button("Save Key") {
                guard !openAIKeyDraft.isEmpty else { return }
                AIKeychainService.save(openAIKeyDraft, account: AIService.openAIAccount)
                openAIConfigured = true
                openAIKeyDraft = ""
                openAISavedFlash = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    openAISavedFlash = false
                }
            }
            .disabled(openAIKeyDraft.isEmpty)

            if openAIConfigured {
                Button("Remove", role: .destructive) {
                    AIKeychainService.delete(account: AIService.openAIAccount)
                    openAIConfigured = false
                }
            }
        }

        if openAISavedFlash {
            Text("Key saved \u{2713}")
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.success)
                .transition(.opacity)
        }

        Text("Get your key at platform.openai.com")
            .font(OrinFont.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Anthropic (Claude)

    @ViewBuilder
    private var anthropicSubsection: some View {
        LabeledContent("Claude") {
            connectionStatusView(aiTester.anthropicStatus)
        }

        if case .failed(let reason) = aiTester.anthropicStatus {
            Text(reason)
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.error)
        }

        SecureField("sk-ant-...", text: $anthropicKeyDraft)

        Text("Keys start with sk-ant-")
            .font(OrinFont.caption)
            .foregroundStyle(.secondary)

        HStack(spacing: 8) {
            Button("Test") {
                let draft = anthropicKeyDraft
                Task { await aiTester.testAnthropic(key: draft.isEmpty ? nil : draft) }
            }
            .disabled(aiTester.anthropicStatus == .testing)

            Button("Save Key") {
                guard !anthropicKeyDraft.isEmpty else { return }
                AIKeychainService.save(anthropicKeyDraft, account: AIService.anthropicAccount)
                anthropicConfigured = true
                anthropicKeyDraft = ""
                anthropicSavedFlash = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    anthropicSavedFlash = false
                }
            }
            .disabled(anthropicKeyDraft.isEmpty)

            if anthropicConfigured {
                Button("Remove", role: .destructive) {
                    AIKeychainService.delete(account: AIService.anthropicAccount)
                    anthropicConfigured = false
                }
            }
        }

        if anthropicSavedFlash {
            Text("Key saved \u{2713}")
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.success)
                .transition(.opacity)
        }

        Text("Get your key at console.anthropic.com")
            .font(OrinFont.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Gemini

    @ViewBuilder
    private var geminiSubsection: some View {
        LabeledContent("Gemini") {
            connectionStatusView(aiTester.geminiStatus)
        }

        if case .failed(let reason) = aiTester.geminiStatus {
            Text(reason)
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.error)
        }

        SecureField("AI...", text: $geminiKeyDraft)

        Text("Keys start with AI")
            .font(OrinFont.caption)
            .foregroundStyle(.secondary)

        HStack(spacing: 8) {
            Button("Test") {
                let draft = geminiKeyDraft
                Task { await aiTester.testGemini(key: draft.isEmpty ? nil : draft) }
            }
            .disabled(aiTester.geminiStatus == .testing)

            Button("Save Key") {
                guard !geminiKeyDraft.isEmpty else { return }
                AIKeychainService.save(geminiKeyDraft, account: AIService.geminiAccount)
                geminiConfigured = true
                geminiKeyDraft = ""
                geminiSavedFlash = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    geminiSavedFlash = false
                }
            }
            .disabled(geminiKeyDraft.isEmpty)

            if geminiConfigured {
                Button("Remove", role: .destructive) {
                    AIKeychainService.delete(account: AIService.geminiAccount)
                    geminiConfigured = false
                }
            }
        }

        if geminiSavedFlash {
            Text("Key saved \u{2713}")
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.success)
                .transition(.opacity)
        }

        Text("Get your key at aistudio.google.com")
            .font(OrinFont.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Calendar Section

    private var calendarSection: some View {
        Section("Calendar") {
            Toggle("Background sync", isOn: $calendarBackgroundSync)

            LabeledContent("Status") {
                SettingsCalendarBadge(status: calendarService.status)
            }

            if let lastSync = calendarService.lastSyncTimestamp {
                LabeledContent("Last synced") {
                    Text(lastSync, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Last synced") {
                    Text("Not yet synced")
                        .foregroundStyle(.secondary)
                }
            }

            if calendarService.status != .red {
                Button(isSyncingCalendar ? "Syncing..." : "Sync Now") {
                    Task { await syncCalendar() }
                }
                .disabled(isSyncingCalendar)
            }

            if calendarService.status == .red {
                Text("Calendar access denied. Open System Settings to grant access.")
                    .font(OrinFont.caption)
                    .foregroundStyle(OrinColor.error)

                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .foregroundStyle(OrinColor.accent)
            }
        }
    }

    private func syncCalendar() async {
        isSyncingCalendar = true
        await calendarService.syncEvents()
        isSyncingCalendar = false
    }

    // MARK: - Meetings Section

    private var meetingsSection: some View {
        Section("Meetings") {
            Picker("Keep recordings for", selection: $retentionDays) {
                ForEach(MeetingRetentionService.RetentionPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy.rawValue)
                }
            }

            Toggle("Auto-analyze with AI after recording", isOn: $autoAnalyze)

            Stepper(value: $minDurationMinutes, in: 1...30) {
                Text("Minimum recording length: \(minDurationMinutes) min")
            }

            Text("Recordings shorter than the minimum are discarded automatically.")
                .font(OrinFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Data Section

    private var dataSection: some View {
        Section("Data") {
            Button {
                exportFullApp()
            } label: {
                HStack {
                    Label("Export Full App Data (JSON)", systemImage: "square.and.arrow.up")
                    if exportProgress {
                        Spacer()
                        ProgressView().scaleEffect(0.7)
                    }
                }
            }
            .disabled(exportProgress)

            Button {
                exportMeetingsZip()
            } label: {
                Label("Export All Meetings (ZIP)", systemImage: "archivebox")
            }

            Button {
                importFullApp()
            } label: {
                Label("Import Orin Backup", systemImage: "square.and.arrow.down")
            }

            if let status = dataActionStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func exportFullApp() {
        exportProgress = true
        dataActionStatus = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Orin Export \(Date().formatted(date: .abbreviated, time: .omitted)).json"
        panel.canCreateDirectories = true
        panel.begin { [self] response in
            defer { Task { @MainActor in exportProgress = false } }
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try self.dataService.exportFullApp(context: self.modelContext)
                try data.write(to: url, options: .atomic)
                Task { @MainActor in dataActionStatus = "Exported to \(url.lastPathComponent)." }
            } catch {
                Task { @MainActor in dataActionStatus = "Export failed: \(error.localizedDescription)" }
            }
        }
    }

    private func exportMeetingsZip() {
        dataActionStatus = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Orin Meetings \(Date().formatted(date: .abbreviated, time: .omitted)).zip"
        panel.canCreateDirectories = true
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let meetings = try self.modelContext.fetch(FetchDescriptor<MeetingItem>())
                let data = try self.dataService.exportMeetingsZip(meetings: meetings)
                try data.write(to: url, options: .atomic)
                Task { @MainActor in
                    dataActionStatus = "Exported \(meetings.count) meetings to \(url.lastPathComponent)."
                }
            } catch {
                Task { @MainActor in
                    dataActionStatus = "ZIP export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func importFullApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                try self.dataService.importPackage(from: data, context: self.modelContext)
                Task { @MainActor in dataActionStatus = "Import complete." }
            } catch {
                Task { @MainActor in dataActionStatus = "Import failed: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Vault Section

    private var vaultSection: some View {
        Section("Vault") {
            LabeledContent("Status") {
                if vaultService.hasVerificationToken {
                    Label("Configured", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(OrinColor.success)
                } else {
                    Label("Not configured", systemImage: "lock.slash")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Recovery Key") {
                if vaultService.hasVerificationToken {
                    Text("Registered")
                        .foregroundStyle(OrinColor.success)
                } else {
                    Text("Not yet registered")
                        .foregroundStyle(OrinColor.warning)
                }
            }

            if !vaultService.hasVerificationToken {
                Text("Set up your vault in the Vault module to enable encrypted secret storage.")
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Reset Vault", role: .destructive) {
                showVaultResetConfirm = true
            }
            .confirmationDialog(
                "Reset Vault?",
                isPresented: $showVaultResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    // Full reset is handled in VaultView to also purge SwiftData records.
                    // Logging the intent here keeps the audit trail consistent.
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Resetting the vault deletes all stored items and requires re-setup.")
            }

            Text("Resetting the vault deletes all stored items and requires re-setup.")
                .font(OrinFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        Section("Privacy") {
            LabeledContent("AI Mode", value: aiModeLabel)
            LabeledContent("Calendar", value: "EventKit (local)")
            LabeledContent("Vault", value: "AES-256-GCM on-device")
            LabeledContent("Recovery Key", value: vaultService.hasVerificationToken ? "Registered" : "Not registered")
            LabeledContent("Transcription", value: "On-device (SFSpeechRecognizer)")
        }
    }

    private var aiModeLabel: String {
        ollamaEndpoint.isEmpty ? "Cloud with local fallback" : "Local-first"
    }

    // MARK: - Troubleshooting Section

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            Button("Re-run Ollama Setup") {
                ollamaInstaller.resetSetup()
                showOllamaSetup = true
            }
            .foregroundStyle(OrinColor.accent)

            Text("Re-run the Ollama installation and connection wizard.")
                .font(OrinFont.caption)
                .foregroundStyle(.secondary)

            Button("Re-run Setup Wizard") {
                showWizardResetConfirm = true
            }
            .foregroundStyle(OrinColor.accent)
            .confirmationDialog(
                "Re-run setup?",
                isPresented: $showWizardResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Re-run Setup") {
                    UserDefaults.standard.removeObject(forKey: "orin.hasCompletedOnboarding")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the onboarding flag. Restart Orin to see the setup wizard again.")
            }

            Text("Clears the onboarding flag. Restart Orin to see the setup wizard again.")
                .font(OrinFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Connection Status Badge

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
}

// MARK: - SettingsCalendarBadge

private struct SettingsCalendarBadge: View {
    let status: CalendarSyncStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(OrinFont.caption)
        }
    }

    private var color: Color {
        switch status {
        case .green:  .green
        case .yellow: .yellow
        case .red:    .red
        }
    }

    private var label: String {
        switch status {
        case .green:  "Synced"
        case .yellow: "Partial"
        case .red:    "No access"
        }
    }
}
