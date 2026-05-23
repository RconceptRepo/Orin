import SwiftUI

struct SettingsView: View {
    @AppStorage("orin.theme.mode") private var themeModeRawValue = OrinThemeMode.system.rawValue
    @AppStorage("orin.ai.provider") private var provider = "ollama"
    @AppStorage("orin.ai.ollamaEndpoint") private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage("orin.ai.openAIConfigured") private var openAIConfigured = false
    @AppStorage("orin.ai.anthropicConfigured") private var anthropicConfigured = false
    @AppStorage("orin.ai.geminiConfigured") private var geminiConfigured = false
    @AppStorage("orin.calendar.backgroundSync") private var calendarBackgroundSync = true
    @AppStorage("orin.launchAtLogin") private var launchAtLogin = false
    @State private var ollamaService = ServiceContainer.shared.resolve(OllamaInstallerService.self)
    @State private var openAIKeyDraft = ""
    @State private var anthropicKeyDraft = ""
    @State private var geminiKeyDraft = ""

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $themeModeRawValue) {
                    ForEach(OrinThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Toggle("Launch automatically on login", isOn: $launchAtLogin)
                Toggle("Calendar background sync", isOn: $calendarBackgroundSync)
            }

            Section("AI") {
                Picker("Primary Provider", selection: $provider) {
                    Text("Ollama Local").tag("ollama")
                    Text("OpenAI").tag("openAI")
                    Text("Claude").tag("anthropic")
                    Text("Gemini").tag("gemini")
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

                LabeledContent("OpenAI") {
                    providerStatus(openAIConfigured)
                }
                SecureField("OpenAI API Key", text: $openAIKeyDraft)
                Button("Test & Save OpenAI") {
                    openAIConfigured = !openAIKeyDraft.isEmpty
                    openAIKeyDraft = ""
                }

                LabeledContent("Claude") {
                    providerStatus(anthropicConfigured)
                }
                SecureField("Claude API Key", text: $anthropicKeyDraft)
                Button("Test & Save Claude") {
                    anthropicConfigured = !anthropicKeyDraft.isEmpty
                    anthropicKeyDraft = ""
                }

                LabeledContent("Gemini") {
                    providerStatus(geminiConfigured)
                }
                SecureField("Gemini API Key", text: $geminiKeyDraft)
                Button("Test & Save Gemini") {
                    geminiConfigured = !geminiKeyDraft.isEmpty
                    geminiKeyDraft = ""
                }
            }

            Section("Privacy") {
                LabeledContent("Default AI Mode", value: provider == "ollama" ? "Local only" : "External with local failover")
                LabeledContent("Calendar Source", value: "EventKit")
                LabeledContent("Vault Storage", value: "Local encrypted")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
    }

    private func providerStatus(_ configured: Bool) -> some View {
        Label(configured ? "Configured" : "Not configured", systemImage: configured ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(configured ? .green : .secondary)
    }

    private var ollamaStatusColor: Color {
        switch ollamaService.status {
        case .connected: OrinColor.success
        case .missing: OrinColor.warning
        case .failed: OrinColor.error
        case .unknown: .secondary
        }
    }
}
